#!/usr/bin/env bash
# =====================================================================
# Hermetic tests for deploy/teardown-stack.sh: no Azure, no network, no KVO.
#
# `az` is a stub on a temp PATH that answers the read-only calls from case
# statements and RECORDS every delete-class call (group delete, vm delete,
# resource delete) into a log instead of acting. scripts/kvo_license.py is
# replaced through CLOUDLENS_KVO_LICENSE_PY by a small python stub whose
# behaviour two env vars choose: LIST_COUNT (the count on --list's JSON
# last line) and RELEASE_RC (the exit code of --release-all). Both stubs
# stamp each call with a number from one shared counter, so the ORDER of
# "confirm, release, gate, delete" is proven from the logs, not inferred.
#
# The teardown is run without a controlling terminal (a setsid wrapper) and
# with stdin from /dev/null, so its /dev/tty re-attach cannot make it
# interactive even when this file is run from a real terminal.
#
# Usage:
#   bash deploy/tests/test_teardown_release.sh
#   TEARDOWN_STACK_SH=/elsewhere/teardown-stack.sh bash deploy/tests/test_teardown_release.sh
#   TEARDOWN_TEST_VERBOSE=1 bash deploy/tests/test_teardown_release.sh   # print every run's output
# =====================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEARDOWN_STACK_SH="${TEARDOWN_STACK_SH:-$HERE/../teardown-stack.sh}"
if [[ ! -f "$TEARDOWN_STACK_SH" ]]; then
  echo "teardown script not found: $TEARDOWN_STACK_SH" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required (the teardown needs it for the licence release)" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/teardown-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

export AZ_LOG="$WORK/az.log"
export LIC_LOG="$WORK/lic.log"
export SEQ_FILE="$WORK/seq"
OUT="$WORK/out.txt"
RC=0

# The password used in the tests. Distinctive, so its absence from every
# log and from the output can be asserted with a plain grep.
TEST_PASS='s3cr3t-Pa55-XYZ'

# ---------------------------------------------------------------------
# The az stub
# ---------------------------------------------------------------------
cat > "$STUB_BIN/az" <<'AZSTUB'
#!/usr/bin/env bash
# Stub az for deploy/tests/test_teardown_release.sh. Read-only calls are
# answered from a fixed resource group; delete-class calls are recorded and
# take effect on later listings, so the teardown's verify phase sees what it
# "deleted". Behaviour knobs: STUB_NO_TAG=1 (group has no deployedBy tag),
# STUB_OTHER=1 (a customer VM, NIC and storage account share the group),
# STUB_DELETE_OPTION=1 (the VM's disk, NICs and public IP go with the VM),
# STUB_SHARED_VNET=1 (the deploy's one shared VNet, cloudlens-vnet, tagged
# deployedBy=cloudlens-stack, holds every CloudLens NIC), STUB_AKS=1 (the
# sample AKS cluster cloudlens-aks-rg-aks and the registry cloudlens0ba7fd8f
# of Phase 13b share the group, both tagged deployedBy=cloudlens-stack and
# cloudlens:stack=cl-rg, the cluster's scale set with an ipConfiguration in
# cloudlens-vnet from its node group MC_cl-rg_cloudlens-aks-rg-aks_eastus2),
# STUB_AKS_UNTAGGED=1 (with STUB_AKS: the same cluster and registry carry
# no tags at all), STUB_AKS_ONETAG=db|st (with STUB_AKS: they carry only
# deployedBy=cloudlens-stack, or only cloudlens:stack=cl-rg),
# STUB_AKS_SHOW_FAIL=1 (`az aks show` fails, so the node resource group
# cannot be read), STUB_AKS_DELETE_FAIL=1 (`az aks delete` is refused and
# records nothing), STUB_NODE_RG_TARGET=1 (the group asked for is a
# cluster's node resource group: `az group show` returns the
# aks-managed-cluster-name/-rg tags), STUB_RES_LIST_FAIL=1 (every
# `az resource list` of the group, the count included, answers nothing: a
# slow or failed az), STUB_EMPTY_GROUP=1 (the group exists and holds no
# resource at all, so the listing is empty and the count answers 0),
# STUB_GROUP_SHOW_FAIL=1 (`az group show` answers nothing: a failed or slow
# call), STUB_AKS_DELETE_NOTFOUND=1 (the cluster was removed by hand after
# the listing: `az aks delete` answers ResourceNotFound and its node group is
# already gone), STUB_NODE_RG_LAG=N (the node group is still reported for N
# `az group exists` calls after the cluster delete, as Azure finishes it).
set -u
LOG="${AZ_LOG:?}"; SEQ="${SEQ_FILE:?}"
next_seq() { local n; n="$(cat "$SEQ" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$SEQ"; printf '%s' "$n"; }
rec() { printf '%s az %s\n' "$(next_seq)" "$*" >> "$LOG"; }
# every line in LOG is a delete, so any line naming the id means it is gone.
# With STUB_DELETE_OPTION=1 the templates' deleteOption is emulated: a disk,
# NIC or public IP whose VM (its name prefix) was deleted is gone with it.
# A cluster or registry is deleted by NAME (az aks delete -n / az acr
# delete -n), so those are matched on the name, not the id.
gone() {
  local id="$1" n vm
  if grep -qF -- "$id" "$LOG" 2>/dev/null; then return 0; fi
  if grep -q "az group delete" "$LOG" 2>/dev/null; then return 0; fi
  case "$id" in
    */managedClusters/*) n="${id##*/}"; if grep -q "aks delete .* -n ${n}\( \|$\)" "$LOG" 2>/dev/null; then return 0; fi ;;
    */registries/*)      n="${id##*/}"; if grep -q "acr delete .* -n ${n}\( \|$\)" "$LOG" 2>/dev/null; then return 0; fi ;;
  esac
  if [[ "${STUB_DELETE_OPTION:-0}" == "1" ]]; then
    case "$id" in
      */disks/*|*/networkInterfaces/*|*/publicIPAddresses/*)
        n="${id##*/}"; vm="${n%%[-_]*}"
        if grep -q "vm delete .*virtualMachines/${vm}\( \|$\)" "$LOG" 2>/dev/null; then return 0; fi ;;
    esac
  fi
  return 1
}

SUB="00000000-0000-0000-0000-000000000000"
RG="cl-rg"
P="/subscriptions/${SUB}/resourceGroups/${RG}/providers"
VM_T="Microsoft.Compute/virtualMachines"; DISK_T="Microsoft.Compute/disks"
NIC_T="Microsoft.Network/networkInterfaces"; PIP_T="Microsoft.Network/publicIPAddresses"
NSG_T="Microsoft.Network/networkSecurityGroups"; VNET_T="Microsoft.Network/virtualNetworks"
AKS_T="Microsoft.ContainerService/managedClusters"; ACR_T="Microsoft.ContainerRegistry/registries"
AKS_NAME="cloudlens-aks-rg-aks"; ACR_NAME="cloudlens0ba7fd8f"
AKS_NODE_RG="MC_${RG}_${AKS_NAME}_eastus2"
# the two tag columns of the teardown's extended listing: deployedBy, cloudlens:stack
res_tags() {
  case "$1" in
    "$AKS_NAME"|"$ACR_NAME")
      if [[ "${STUB_AKS_UNTAGGED:-0}" == "1" ]]; then printf 'None\tNone'
      elif [[ "${STUB_AKS_ONETAG:-}" == "db" ]]; then printf 'cloudlens-stack\tNone'
      elif [[ "${STUB_AKS_ONETAG:-}" == "st" ]]; then printf 'None\t%s' "$RG"
      else printf 'cloudlens-stack\t%s' "$RG"; fi ;;
    cloudlens-vnet) printf 'cloudlens-stack\tNone' ;;
    *) printf 'None\tNone' ;;
  esac
}

# name|type, one per line: what the three product templates create.
RES="vcontroller|$VM_T
vcontroller-pip|$PIP_T
vcontroller-nsg|$NSG_T
vcontroller-vnet|$VNET_T
vcontroller-nic|$NIC_T
vcontroller_OsDisk_1_aaa|$DISK_T
kvo|$VM_T
kvo-pip|$PIP_T
kvo-nsg|$NSG_T
kvo-vnet|$VNET_T
kvo-nic|$NIC_T
kvo_OsDisk_1_bbb|$DISK_T
vpb|$VM_T
vpb-mgmt-pip|$PIP_T
vpb-mgmt-nsg|$NSG_T
vpb-vnet|$VNET_T
vpb-mgmt-nic|$NIC_T
vpb-ingress-1|$NIC_T
vpb-egress-1|$NIC_T
vpb_OsDisk_1_ccc|$DISK_T"
if [[ "${STUB_SHARED_VNET:-0}" == "1" ]]; then
  RES="$RES
cloudlens-vnet|$VNET_T"
fi
if [[ "${STUB_OTHER:-0}" == "1" ]]; then
  RES="$RES
customer-web01|$VM_T
customer-nic|$NIC_T
customerstorage|Microsoft.Storage/storageAccounts"
fi
if [[ "${STUB_AKS:-0}" == "1" ]]; then
  RES="$RES
${AKS_NAME}|$AKS_T
${ACR_NAME}|$ACR_T"
fi
if [[ "${STUB_EMPTY_GROUP:-0}" == "1" ]]; then RES=""; fi
rid() { printf '%s/%s/%s' "$P" "$2" "$1"; }

# per-VM facts: product, OS disk, NICs
vm_product() {
  case "$1" in
    vcontroller) echo "keysight-cloudlens-vcontroller" ;;
    kvo) echo "keysight-vision-orchestrator" ;;
    vpb) echo "keysight-cloudlens-virtual-packet-broker" ;;
    *) echo "None" ;;
  esac
}
vm_disk() {
  case "$1" in
    vcontroller) rid vcontroller_OsDisk_1_aaa "$DISK_T" ;;
    kvo) rid kvo_OsDisk_1_bbb "$DISK_T" ;;
    vpb) rid vpb_OsDisk_1_ccc "$DISK_T" ;;
    *) rid customer_OsDisk_1_ddd "$DISK_T" ;;
  esac
}
vm_nics() {
  case "$1" in
    vcontroller) rid vcontroller-nic "$NIC_T" ;;
    kvo) rid kvo-nic "$NIC_T" ;;
    vpb) printf '%s %s %s' "$(rid vpb-mgmt-nic "$NIC_T")" "$(rid vpb-ingress-1 "$NIC_T")" "$(rid vpb-egress-1 "$NIC_T")" ;;
    *) rid customer-nic "$NIC_T" ;;
  esac
}
vnet_nics() {
  case "$1" in
    vcontroller-vnet) echo "vcontroller-nic" ;;
    kvo-vnet) if [[ "${STUB_OTHER:-0}" == "1" ]]; then echo "kvo-nic customer-nic"; else echo "kvo-nic"; fi ;;
    vpb-vnet) echo "vpb-mgmt-nic vpb-ingress-1 vpb-egress-1" ;;
    cloudlens-vnet) echo "vcontroller-nic kvo-nic vpb-mgmt-nic vpb-ingress-1 vpb-egress-1" ;;
  esac
}
# the value after a flag, e.g. -n NAME or --ids ID
argval() { local want="$1"; shift; while [[ $# -gt 0 ]]; do if [[ "$1" == "$want" ]]; then printf '%s' "${2:-}"; return 0; fi; shift; done; return 0; }

cmd="${1:-} ${2:-}"
case "$cmd" in
  "account show")
    printf 'Stub Subscription\n%s\n' "$SUB" ;;
  "group exists")
    n="$(argval -n "$@")"
    if [[ "$n" == "$AKS_NODE_RG" ]]; then
      # the node group goes when the AKS service deletes the cluster, never
      # with cl-rg's own delete
      if [[ "${STUB_AKS_DELETE_NOTFOUND:-0}" == "1" ]]; then echo false
      elif grep -q "aks delete .* -n ${AKS_NAME}\( \|$\)" "$LOG" 2>/dev/null; then
        lagf="${LOG}.nodergcalls"; c="$(cat "$lagf" 2>/dev/null || echo 0)"; c=$((c+1)); printf '%s' "$c" > "$lagf"
        if (( c <= ${STUB_NODE_RG_LAG:-0} )); then echo true; else echo false; fi
      else echo true; fi
    elif grep -q "az group delete" "$LOG" 2>/dev/null; then echo false; else echo true; fi ;;
  "aks show")
    n="$(argval -n "$@")"
    if [[ "${STUB_AKS_SHOW_FAIL:-0}" == "1" ]]; then echo "Request timed out" >&2; exit 1; fi
    if gone "$(rid "$n" "$AKS_T")"; then echo "ResourceNotFound" >&2; exit 1; fi
    echo "$AKS_NODE_RG" ;;
  "aks delete")
    if [[ "${STUB_AKS_DELETE_FAIL:-0}" == "1" ]]; then
      echo "(OperationNotAllowed) The cluster is locked by a scope lock" >&2; exit 1
    fi
    if [[ "${STUB_AKS_DELETE_NOTFOUND:-0}" == "1" ]]; then
      echo "(ResourceNotFound) The Resource 'Microsoft.ContainerService/managedClusters/${AKS_NAME}' under resource group 'cl-rg' was not found." >&2; exit 1
    fi
    shift 2; rec aks delete "$@" ;;
  "acr delete")
    shift 2; rec acr delete "$@" ;;
  "group show")
    # four columns: deployedBy, location, aks-managed-cluster-name, -rg
    if [[ "${STUB_GROUP_SHOW_FAIL:-0}" == "1" ]]; then exit 0; fi
    if [[ "${STUB_NO_TAG:-0}" == "1" ]]; then echo None; else echo cloudlens-stack; fi
    echo eastus2
    if [[ "${STUB_NODE_RG_TARGET:-0}" == "1" ]]; then printf '%s\n%s\n' "$AKS_NAME" "$RG"; else printf 'None\nNone\n'; fi ;;
  "group list")
    printf 'cl-rg\teastus2\n' ;;
  "group delete")
    shift 2; rec group delete "$@" ;;
  "vm list")
    while IFS='|' read -r n t; do
      [[ "$t" == "$VM_T" ]] || continue
      gone "$(rid "$n" "$t")" && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$(vm_product "$n")" "$(rid "$n" "$t")" "$(vm_disk "$n")" "$(vm_nics "$n")"
    done <<< "$RES" ;;
  "vm list-ip-addresses")
    n="$(argval -n "$@")"
    case "$n" in
      kvo) printf '20.1.2.3\n10.0.2.4\n' ;;
      vpb) printf '20.1.2.5\n10.0.3.4\n' ;;
      *) printf '20.1.2.1\n10.0.1.4\n' ;;
    esac ;;
  "vm get-instance-view")
    echo "VM running" ;;
  "vm show")
    id="$(argval --ids "$@")"
    if gone "$id"; then echo "ResourceNotFound" >&2; exit 1; fi
    printf '%s\n' "${id##*/}" ;;
  "vm delete")
    shift 2; rec vm delete "$@" ;;
  "resource list")
    # The teardown's second listing asks only for VNets carrying the deploy's
    # tag; only the shared VNet has it.
    if printf '%s\n' "$@" | grep -q -- '--resource-type'; then
      if [[ "${STUB_SHARED_VNET:-0}" == "1" ]] && ! gone "$(rid cloudlens-vnet "$VNET_T")"; then
        printf '%s\n' "$(rid cloudlens-vnet "$VNET_T")"
      fi
      exit 0
    fi
    # STUB_RES_LIST_FAIL=1: az did not answer. Every listing of the group,
    # the count the teardown asks for on an empty answer included, is empty.
    if [[ "${STUB_RES_LIST_FAIL:-0}" == "1" ]]; then exit 0; fi
    # The count the teardown asks for when the listing came back empty: a
    # real empty group answers 0, which is what tells it from a failed call.
    if [[ "$(argval --query "$@")" == "length(@)" ]]; then
      c=0
      while IFS='|' read -r n t; do
        [[ -n "$n" ]] || continue
        gone "$(rid "$n" "$t")" && continue
        c=$((c+1))
      done <<< "$RES"
      echo "$c"; exit 0
    fi
    # The Phase 2 listing asks for two tag columns on top of name, type, id
    # (the deploy stamp); the re-listings in Phases 5 and 6 ask for three.
    want_tags=0
    if printf '%s\n' "$(argval --query "$@")" | grep -q 'tags\.'; then want_tags=1; fi
    while IFS='|' read -r n t; do
      [[ -n "$n" ]] || continue
      gone "$(rid "$n" "$t")" && continue
      if [[ "$want_tags" == "1" ]]; then
        printf '%s\t%s\t%s\t%s\n' "$n" "$t" "$(rid "$n" "$t")" "$(res_tags "$n")"
      else
        printf '%s\t%s\t%s\n' "$n" "$t" "$(rid "$n" "$t")"
      fi
    done <<< "$RES" ;;
  "resource delete")
    shift 2; rec resource delete "$@" ;;
  "network vnet")
    n="$(argval -n "$@")"
    for nic in $(vnet_nics "$n"); do
      gone "$(rid "$nic" "$NIC_T")" && continue
      printf '%s/ipConfigurations/ipconfig1\n' "$(rid "$nic" "$NIC_T")"
    done
    # STUB_FOREIGN_NIC=1: a customer NIC from ANOTHER resource group sits in
    # the shared VNet. Nothing in cl-rg is "other", only the VNet knows.
    if [[ "$n" == "cloudlens-vnet" && "${STUB_FOREIGN_NIC:-0}" == "1" ]]; then
      printf '%s\n' "/subscriptions/sub/resourceGroups/other-rg/providers/Microsoft.Network/networkInterfaces/customer-nic/ipConfigurations/ipconfig1"
    fi
    # STUB_AKS=1: the cluster's scale set (Azure CNI) has an address in the
    # shared VNet from its node resource group, until the cluster is deleted.
    if [[ "$n" == "cloudlens-vnet" && "${STUB_AKS:-0}" == "1" ]] && ! gone "$(rid "$AKS_NAME" "$AKS_T")"; then
      printf '%s\n' "/subscriptions/${SUB}/resourceGroups/${AKS_NODE_RG}/providers/Microsoft.Compute/virtualMachineScaleSets/aks-nodepool1-12345678-vmss/virtualMachines/0/networkInterfaces/aks-nodepool1-12345678-vmss/ipConfigurations/ipconfig1"
    fi ;;
  "network public-ip")
    echo "20.1.2.3" ;;
  *)
    echo "stub az: unhandled call: $*" >&2
    exit 1 ;;
esac
exit 0
AZSTUB
chmod +x "$STUB_BIN/az"

# ---------------------------------------------------------------------
# The kvo_license.py stub. Records its argv and WHETHER the password
# variable was in its environment (never its value).
# ---------------------------------------------------------------------
cat > "$WORK/kvo_license_stub.py" <<'PYSTUB'
#!/usr/bin/env python3
import json, os, sys

argv = sys.argv[1:]
seq_file = os.environ["SEQ_FILE"]
try:
    n = int(open(seq_file).read().strip() or "0")
except (IOError, ValueError):
    n = 0
n += 1
open(seq_file, "w").write(str(n))
present = "1" if "CLOUDLENS_KVO_ADMIN_PASS" in os.environ else "0"
with open(os.environ["LIC_LOG"], "a") as f:
    f.write("%d lic argv=%s pass_present=%s\n" % (n, json.dumps(argv), present))

count = int(os.environ.get("LIST_COUNT", "0"))
if "--list" in argv:
    print("[stub] list: %d licence(s) on the KVO" % count)
    if "--json" in argv:
        print(json.dumps({"count": count, "clear": count == 0, "unreadable": None, "exit": 0}, sort_keys=True))
    sys.exit(0)
if "--release-all" in argv:
    rc = int(os.environ.get("RELEASE_RC", "0"))
    print("[stub] release-all called")
    if "--json" in argv:
        print(json.dumps({"clear": rc == 0, "exit": rc}, sort_keys=True))
    sys.exit(rc)
print("[stub] unexpected mode: %s" % argv, file=sys.stderr)
sys.exit(2)
PYSTUB

# Runs a command in its own session: no controlling terminal, so the
# teardown's `exec 3</dev/tty` fails and it stays non-interactive.
cat > "$WORK/nosetty.py" <<'PYSETSID'
import os, sys
pid = os.fork()
if pid == 0:
    try:
        os.setsid()
    except OSError:
        pass
    os.execvp(sys.argv[1], sys.argv[1:])
_, status = os.waitpid(pid, 0)
if os.WIFEXITED(status):
    sys.exit(os.WEXITSTATUS(status))
sys.exit(128 + os.WTERMSIG(status))
PYSETSID

# ---------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------
PASS=0; FAIL=0
CASE_OK=true; CASE_TITLE=""; CASE_NOTES=""

begin_case() {
  CASE_TITLE="$1"; CASE_OK=true; CASE_NOTES=""
  : > "$AZ_LOG"; : > "$LIC_LOG"; : > "$SEQ_FILE"; : > "$OUT"
  # behaviour defaults, overridden per case before run_teardown
  export LIST_COUNT=0 RELEASE_RC=0 STUB_NO_TAG=0 STUB_OTHER=0 STUB_DELETE_OPTION=0 STUB_SHARED_VNET=0 STUB_FOREIGN_NIC=0
  export STUB_AKS=0 STUB_AKS_UNTAGGED=0 STUB_AKS_ONETAG="" STUB_AKS_SHOW_FAIL=0 STUB_AKS_DELETE_FAIL=0 STUB_NODE_RG_TARGET=0
  export STUB_RES_LIST_FAIL=0 STUB_EMPTY_GROUP=0
  export STUB_GROUP_SHOW_FAIL=0 STUB_AKS_DELETE_NOTFOUND=0 STUB_NODE_RG_LAG=0
  rm -f "${AZ_LOG}.nodergcalls"
  # A scratch HOME of its own for every case, never the real one: the
  # teardown removes $HOME/.kube/cloudlens-aks-<cluster> after a cluster
  # delete, and the stub cluster carries the live lab's name.
  TEST_HOME="$WORK/home-$((PASS+FAIL+1))"; mkdir -p "$TEST_HOME"
  unset CLOUDLENS_KVO_ADMIN_USER CLOUDLENS_KVO_ADMIN_PASS 2>/dev/null || true
}
end_case() {
  if [[ "${TEARDOWN_TEST_VERBOSE:-0}" == "1" ]]; then
    echo "===== ${CASE_TITLE} (exit ${RC}) ====="
    sed 's/^/  | /' "$OUT"
    echo "  --- az log ---"; sed 's/^/  | /' "$AZ_LOG"
    echo "  --- lic log ---"; sed 's/^/  | /' "$LIC_LOG"
  fi
  if [[ "$CASE_OK" == "true" ]]; then
    PASS=$((PASS+1)); echo "PASS  ${CASE_TITLE}"
  else
    FAIL=$((FAIL+1)); echo "FAIL  ${CASE_TITLE}"
    printf '%s\n' "$CASE_NOTES"
    echo "      --- output (last 25 lines) ---"
    tail -n 25 "$OUT" | sed 's/^/      | /'
    echo "      --- az log ---"; sed 's/^/      | /' "$AZ_LOG"
    echo "      --- lic log ---"; sed 's/^/      | /' "$LIC_LOG"
  fi
}
# a failed assertion marks the case; the message names what was expected
flunk() { CASE_OK=false; CASE_NOTES="${CASE_NOTES}      expected: $1"$'\n'; }

# TEST_HOME (set by begin_case) is the HOME the teardown sees: the deploy's
# kubeconfig lives at $HOME/.kube/cloudlens-aks-<cluster>, and the real one
# must never be touched by a test.
run_teardown() {
  RC=0
  HOME="$TEST_HOME" \
  PATH="$STUB_BIN:$PATH" \
  CLOUDLENS_KVO_LICENSE_PY="$WORK/kvo_license_stub.py" \
  CLOUDLENS_KVO_HTTP_TIMEOUT=2 CLOUDLENS_KVO_RELEASE_TIMEOUT=5 CLOUDLENS_PROBE_TIMEOUT=20 \
  CLOUDLENS_NODE_RG_WAIT="${NODE_RG_WAIT_T:-3}" CLOUDLENS_NODE_RG_POLL=1 \
  python3 "$WORK/nosetty.py" bash "$TEARDOWN_STACK_SH" "$@" </dev/null >"$OUT" 2>&1 || RC=$?
}

out_has()     { grep -qF -- "$1" "$OUT" || flunk "output to contain: $1"; }
out_lacks()   { if grep -qF -- "$1" "$OUT"; then flunk "output NOT to contain: $1"; fi; }
out_match()   { grep -Eq -- "$1" "$OUT" || flunk "output to match: $1"; }
out_line()    { grep -n -m1 -F -- "$1" "$OUT" | cut -d: -f1; }
az_has()      { grep -q -- "$1" "$AZ_LOG" || flunk "az log to contain: $1"; }
az_lacks()    { if grep -q -- "$1" "$AZ_LOG"; then flunk "az log NOT to contain: $1"; fi; }
az_empty()    { if [[ -s "$AZ_LOG" ]]; then flunk "no delete-class az call at all"; fi; }
lic_has()     { grep -q -- "$1" "$LIC_LOG" || flunk "kvo_license.py to be called with: $1"; }
lic_lacks()   { if grep -q -- "$1" "$LIC_LOG"; then flunk "kvo_license.py NOT to be called with: $1"; fi; }
lic_empty()   { if [[ -s "$LIC_LOG" ]]; then flunk "kvo_license.py never to run"; fi; }
rc_is()       { [[ "$RC" == "$1" ]] || flunk "exit $1, got $RC"; }
rc_nonzero()  { [[ "$RC" != "0" ]] || flunk "a non-zero exit, got 0"; }
# the sequence number stamped on the first log line matching a pattern
seq_of()      { grep -m1 -- "$2" "$1" | awk '{print $1}'; }
# output order: line of A before line of B
out_before()  {
  local a b; a="$(out_line "$1")"; b="$(out_line "$2")"
  if [[ -z "$a" || -z "$b" ]]; then flunk "both in the output: '$1' and '$2'"; return 0; fi
  (( a < b )) || flunk "'$1' (line $a) before '$2' (line $b)"
}

# ---------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------
begin_case "1: --audit lists the KVO, deletes nothing, never runs kvo_license.py"
  LIST_COUNT=2
  run_teardown --resource-group cl-rg --audit
  rc_is 0
  out_has "AUDIT MODE"
  out_match 'KVO +kvo +VM running +public 20.1.2.3 +private 10.0.2.4'
  out_has "kvo_OsDisk_1_bbb"
  out_has "The group contains a KVO (kvo)"
  out_has "Audit complete"
  out_has "delete the whole resource group cl-rg"
  az_empty
  lic_empty
end_case

begin_case "2: --dry-run prints the would-delete commands, never runs kvo_license.py, exits 0"
  LIST_COUNT=2
  run_teardown --resource-group cl-rg --dry-run
  rc_is 0
  out_has "DRY-RUN MODE"
  out_has "[dry-run] az group delete -n cl-rg --yes --no-wait"
  out_has "nothing is called on the KVO in a dry run"
  out_has "a real run would stop here and require --accept-licence-loss"
  out_has "DRY RUN: nothing above was actually deleted"
  az_empty
  lic_empty
end_case

begin_case "3: --yes --release-licences, 2 held, release ok: confirm, release, gate skipped, delete (in that order)"
  LIST_COUNT=2 RELEASE_RC=0
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_is 0
  out_has "Proceeding (--yes)"
  lic_has '--list'
  lic_has '--release-all'
  az_has "az group delete -n cl-rg --yes --no-wait"
  out_has "no licence-loss confirmation is needed"
  out_lacks "LICENCES ARE ABOUT TO BE STRANDED"
  out_has "Resource group cl-rg deleted"
  # order from the two logs: the release is stamped before the delete
  s_rel="$(seq_of "$LIC_LOG" '--release-all')"; s_del="$(seq_of "$AZ_LOG" 'group delete')"
  if [[ -z "$s_rel" || -z "$s_del" ]]; then flunk "both a release and a delete stamped"
  elif (( s_rel >= s_del )); then flunk "release (seq $s_rel) stamped before group delete (seq $s_del)"; fi
  # order in the output: confirm, release, delete
  out_before "Proceeding (--yes)" "[stub] release-all called"
  out_before "[stub] release-all called" "Delete requested for resource group cl-rg"
end_case

begin_case "4: --yes --release-licences, release exits 3: nothing deleted, non-zero, says --accept-licence-loss"
  LIST_COUNT=2 RELEASE_RC=3
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_nonzero
  lic_has '--release-all'
  out_has "did not leave the KVO clear"
  out_has "LICENCES ARE ABOUT TO BE STRANDED"
  out_has "--yes --accept-licence-loss"
  out_has "no terminal to confirm on"
  az_empty
end_case

begin_case "5: --yes --release-licences --accept-licence-loss, release exits 3: delete proceeds"
  LIST_COUNT=2 RELEASE_RC=3
  run_teardown --resource-group cl-rg --yes --release-licences --accept-licence-loss
  rc_is 0
  lic_has '--release-all'
  out_has "Licence loss accepted (--accept-licence-loss)"
  az_has "az group delete -n cl-rg --yes --no-wait"
  out_has "KVO licences:       NOT released"
end_case

begin_case "6: --yes without --release-licences, 2 held: nothing released, gate refuses, nothing deleted"
  LIST_COUNT=2 RELEASE_RC=0
  run_teardown --resource-group cl-rg --yes
  rc_nonzero
  lic_has '--list'
  lic_lacks '--release-all'
  out_has "no --release-licences: not releasing"
  out_has "no terminal to confirm on"
  out_has "--yes --accept-licence-loss"
  az_empty
end_case

begin_case "7: KVO holds nothing, --yes: gate skipped, delete proceeds, --release-all never called"
  LIST_COUNT=0
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  lic_has '--list'
  lic_lacks '--release-all'
  out_has "The KVO holds no licences"
  out_has "no licence-loss confirmation is needed"
  az_has "az group delete -n cl-rg --yes --no-wait"
end_case

begin_case "8: password from CLOUDLENS_KVO_ADMIN_PASS reaches the child by env and never appears in any argv, log or output"
  LIST_COUNT=2 RELEASE_RC=0
  export CLOUDLENS_KVO_ADMIN_USER="kvoadmin" CLOUDLENS_KVO_ADMIN_PASS="$TEST_PASS"
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_is 0
  lic_has 'pass_present=1'
  lic_has '--password-env", "CLOUDLENS_KVO_ADMIN_PASS'
  lic_has '--user", "kvoadmin'
  if grep -qF -- "$TEST_PASS" "$LIC_LOG"; then flunk "the password never in kvo_license.py's argv"; fi
  if grep -qF -- "$TEST_PASS" "$AZ_LOG"; then flunk "the password never on an az command line"; fi
  if grep -qF -- "$TEST_PASS" "$OUT"; then flunk "the password never in the output"; fi
  unset CLOUDLENS_KVO_ADMIN_USER CLOUDLENS_KVO_ADMIN_PASS
end_case

begin_case "9: group without the deployedBy tag: per-resource plan, no group delete, VMs deleted"
  LIST_COUNT=2 RELEASE_RC=0 STUB_NO_TAG=1
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_is 0
  out_has "carries no deployedBy=cloudlens-stack tag"
  out_has "delete only the CloudLens resources"
  az_lacks "group delete"
  az_has "az vm delete --ids .*virtualMachines/kvo .*--yes"
  az_has "resource delete --ids .*disks/kvo_OsDisk_1_bbb"
  az_has "resource delete --ids .*networkInterfaces/vpb-ingress-1"
  az_has "resource delete --ids .*publicIPAddresses/vpb-mgmt-pip"
  az_has "resource delete --ids .*networkSecurityGroups/vcontroller-nsg"
  az_has "resource delete --ids .*virtualNetworks/kvo-vnet"
  # dependency order: VM before its disk, NIC before its VNet
  s_vm="$(seq_of "$AZ_LOG" 'vm delete')"; s_disk="$(seq_of "$AZ_LOG" 'disks/')"
  s_nic="$(seq_of "$AZ_LOG" 'networkInterfaces/')"; s_vnet="$(seq_of "$AZ_LOG" 'virtualNetworks/')"
  if [[ -n "$s_vm" && -n "$s_disk" ]] && (( s_vm > s_disk )); then flunk "VM delete before disk delete"; fi
  if [[ -n "$s_nic" && -n "$s_vnet" ]] && (( s_nic > s_vnet )); then flunk "NIC delete before VNet delete"; fi
  out_has "Nothing left in cl-rg"
end_case

begin_case "10: --keep-resource-group forces the per-resource plan on a tagged group"
  LIST_COUNT=2 RELEASE_RC=0
  run_teardown --resource-group cl-rg --yes --release-licences --keep-resource-group
  rc_is 0
  out_has "--keep-resource-group was given"
  az_lacks "group delete"
  az_has "vm delete"
  az_has "resource delete --ids .*virtualNetworks/vpb-vnet"
end_case

begin_case "11: a customer VM shares the group: per-resource plan, its resources untouched, the VNet it uses is kept"
  LIST_COUNT=2 RELEASE_RC=0 STUB_OTHER=1
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_is 0
  out_has "resource(s) that are not CloudLens"
  out_has "customer-web01"
  out_has "customerstorage"
  az_lacks "group delete"
  az_lacks "customer-web01"
  az_lacks "customer-nic"
  az_lacks "customerstorage"
  az_lacks "virtualNetworks/kvo-vnet"
  az_has "resource delete --ids .*virtualNetworks/vcontroller-vnet"
  out_has "keeping VNet kvo-vnet: still used by NIC(s) that are not CloudLens: customer-nic"
  out_has "CloudLens resources still in cl-rg"
  out_has "    kvo-vnet  (Microsoft.Network/virtualNetworks)"
end_case

begin_case "12: templates with deleteOption: disk, NICs and public IP go with the VM, only NSG and VNet deleted, no failure"
  LIST_COUNT=2 RELEASE_RC=0 STUB_DELETE_OPTION=1
  run_teardown --resource-group cl-rg --yes --release-licences --keep-resource-group
  rc_is 0
  az_has "vm delete"
  az_lacks "resource delete --ids .*disks/"
  az_lacks "resource delete --ids .*networkInterfaces/"
  az_lacks "resource delete --ids .*publicIPAddresses/"
  az_has "resource delete --ids .*networkSecurityGroups/kvo-nsg"
  az_has "resource delete --ids .*virtualNetworks/kvo-vnet"
  out_has "disk kvo_OsDisk_1_bbb went with its VM (deleteOption)"
  out_has "NIC vpb-ingress-1 went with its VM (deleteOption)"
  out_has "public IP vpb-mgmt-pip went with its VM (deleteOption)"
  out_lacks "could not delete"
  out_lacks "Some resources could not be removed"
  out_has "Nothing left in cl-rg"
end_case

begin_case "13: the deploy's tagged shared VNet counts as CloudLens by its tag, and is deleted after the NICs"
  LIST_COUNT=0 STUB_SHARED_VNET=1 STUB_NO_TAG=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "    cloudlens-vnet "
  az_lacks "group delete"
  az_has "resource delete --ids .*virtualNetworks/cloudlens-vnet"
  s_nic="$(seq_of "$AZ_LOG" 'networkInterfaces/')"; s_vnet="$(seq_of "$AZ_LOG" 'virtualNetworks/cloudlens-vnet')"
  if [[ -n "$s_nic" && -n "$s_vnet" ]] && (( s_nic > s_vnet )); then flunk "NIC delete before the shared VNet delete"; fi
end_case

begin_case "14: with the shared VNet the tagged group still holds nothing but CloudLens, so the whole group goes"
  LIST_COUNT=0 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "    cloudlens-vnet "
  out_has "every resource is CloudLens"
  az_has "group delete"
end_case

begin_case "15: a NIC from another group sits in the tagged shared VNet: per-resource plan, VMs go, the VNet is kept, no group delete"
  LIST_COUNT=0 STUB_SHARED_VNET=1 STUB_FOREIGN_NIC=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  az_lacks "group delete"
  az_has "vm delete"
  az_lacks "resource delete --ids .*virtualNetworks/cloudlens-vnet"
  out_has "keeping VNet cloudlens-vnet"
  out_has "from outside the group"
end_case

# ---------------------------------------------------------------------
# Evidence class 4: the deploy-stamped AKS cluster and ACR of Phase 13b.
# The live failure of 2026-10-07: both were listed under "Other" and kept
# the group and the shared VNet.
# ---------------------------------------------------------------------
begin_case "16: deploy-created group with a stamped AKS cluster + ACR: cluster deleted BEFORE the group, the group goes, nothing is 'other'"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "Deploy-stamped resources (tagged deployedBy=cloudlens-stack and cloudlens:stack=<value>): deleted with the stack"
  out_has "    cloudlens-aks-rg-aks "
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2"
  out_has "    cloudlens0ba7fd8f "
  out_lacks "Other resources in the group"
  out_has "every resource is CloudLens"
  out_has "delete the whole resource group cl-rg"
  az_has "az aks delete -g cl-rg -n cloudlens-aks-rg-aks --yes"
  az_has "az group delete -n cl-rg --yes --no-wait"
  s_aks="$(seq_of "$AZ_LOG" 'aks delete')"; s_grp="$(seq_of "$AZ_LOG" 'group delete')"
  if [[ -z "$s_aks" || -z "$s_grp" ]]; then flunk "both an aks delete and a group delete stamped"
  elif (( s_aks >= s_grp )); then flunk "aks delete (seq $s_aks) stamped before group delete (seq $s_grp)"; fi
  out_has "deleted AKS cluster cloudlens-aks-rg-aks"
  out_has "Resource group cl-rg deleted"
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 no longer exists"
  out_has "AKS clusters:       1 (node resource group(s) gone: MC_cl-rg_cloudlens-aks-rg-aks_eastus2)"
  out_has "Registries:         1"
  out_lacks "Some resources could not be removed"
end_case

begin_case "17: per-resource plan with a stamped cluster + ACR: VMs, then aks delete, then acr delete, then the shared VNet (the scale set's address does not keep it)"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1 STUB_NO_TAG=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  az_lacks "group delete"
  az_has "vm delete"
  az_has "az aks delete -g cl-rg -n cloudlens-aks-rg-aks --yes"
  az_has "az acr delete -g cl-rg -n cloudlens0ba7fd8f --yes"
  az_has "resource delete --ids .*virtualNetworks/cloudlens-vnet"
  out_lacks "keeping VNet cloudlens-vnet"
  s_vm="$(seq_of "$AZ_LOG" 'vm delete')"; s_aks="$(seq_of "$AZ_LOG" 'aks delete')"
  s_acr="$(seq_of "$AZ_LOG" 'acr delete')"; s_vnet="$(seq_of "$AZ_LOG" 'virtualNetworks/cloudlens-vnet')"
  if [[ -z "$s_vm" || -z "$s_aks" || -z "$s_acr" || -z "$s_vnet" ]]; then flunk "vm, aks, acr and VNet deletes all stamped"
  else
    (( s_vm < s_aks ))  || flunk "VM delete (seq $s_vm) before aks delete (seq $s_aks)"
    (( s_aks < s_acr )) || flunk "aks delete (seq $s_aks) before acr delete (seq $s_acr)"
    (( s_aks < s_vnet )) || flunk "aks delete (seq $s_aks) before the shared VNet delete (seq $s_vnet)"
  fi
  out_has "deleted registry cloudlens0ba7fd8f"
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 no longer exists"
  out_has "Nothing left in cl-rg"
  out_lacks "Some resources could not be removed"
end_case

begin_case "18: an UNTAGGED cluster and registry: never deleted, listed under Other, the group and the VNet they use are kept"
  LIST_COUNT=0 STUB_AKS=1 STUB_AKS_UNTAGGED=1 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "Other resources in the group (NOT CloudLens, never deleted by this script):"
  out_before "Other resources in the group" "    cloudlens-aks-rg-aks "
  out_has "    cloudlens0ba7fd8f "
  out_lacks "Deploy-stamped resources"
  out_has "the group holds 2 resource(s) that are not CloudLens"
  az_lacks "aks delete"
  az_lacks "acr delete"
  az_lacks "group delete"
  az_lacks "cloudlens-aks-rg-aks"
  az_lacks "cloudlens0ba7fd8f"
  az_has "vm delete"
  az_lacks "resource delete --ids .*virtualNetworks/cloudlens-vnet"
  out_has "keeping VNet cloudlens-vnet: still used by NIC(s) that are not CloudLens: aks-nodepool1-12345678-vmss"
end_case

begin_case "19: --dry-run with a stamped cluster + ACR: 'would delete' for both, the kubeconfig left alone, zero delete calls"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1 STUB_NO_TAG=1
  mkdir -p "$TEST_HOME/.kube"
  : > "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  run_teardown --resource-group cl-rg --dry-run
  rc_is 0
  out_has "[dry-run] az aks delete -g cl-rg -n cloudlens-aks-rg-aks --yes"
  out_has "would delete AKS cluster cloudlens-aks-rg-aks"
  out_has "[dry-run] az acr delete -g cl-rg -n cloudlens0ba7fd8f --yes"
  out_has "would delete registry cloudlens0ba7fd8f"
  out_match '\[dry-run\] az resource delete --ids .*virtualNetworks/cloudlens-vnet'
  out_has "would delete VNet cloudlens-vnet"
  out_has "would remove the deploy's kubeconfig $TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  out_lacks "removed the deploy's kubeconfig"
  [[ -f "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks" ]] || flunk "the kubeconfig to still exist after a dry run"
  out_has "would check with 'az group exists' that each cluster's node resource group is gone"
  out_has "DRY RUN: nothing above was actually deleted"
  az_empty
  lic_empty
end_case

begin_case "20: --audit lists the stamped cluster (with its node group) and the ACR under their own heading, plans the whole group, deletes nothing"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --audit
  rc_is 0
  out_has "AUDIT MODE"
  out_has "Deploy-stamped resources (tagged deployedBy=cloudlens-stack and cloudlens:stack=<value>): deleted with the stack"
  out_before "Deploy-stamped resources" "    cloudlens-aks-rg-aks "
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 (removed by the AKS service with the cluster)"
  out_has "    cloudlens0ba7fd8f "
  out_has "is removed from this machine once the cluster is gone"
  out_lacks "Other resources in the group"
  out_has "every resource is CloudLens"
  out_has "(includes 2 deploy-stamped: 1 AKS cluster(s), 1 registry(ies))"
  out_has "Other resources:       0"
  out_has "Would delete:          the whole group"
  out_has "delete the whole resource group cl-rg"
  out_has "Audit complete"
  az_empty
  lic_empty
end_case

begin_case "21: the deploy's kubeconfig under HOME is removed after the cluster delete, and said so"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1
  mkdir -p "$TEST_HOME/.kube"
  : > "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  : > "$TEST_HOME/.kube/config"
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  az_has "az aks delete -g cl-rg -n cloudlens-aks-rg-aks --yes"
  out_has "removed the deploy's kubeconfig $TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  [[ ! -e "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks" ]] || flunk "the deploy's kubeconfig to be removed"
  [[ -f "$TEST_HOME/.kube/config" ]] || flunk "the default kubeconfig to be left alone"
end_case

# The stamp is BOTH tags. One alone is a customer's cluster that happens to
# carry a key the deploy also uses, and it is "other".
begin_case "22: a cluster and registry carrying ONLY deployedBy=cloudlens-stack: other, never deleted, the group is kept"
  LIST_COUNT=0 STUB_AKS=1 STUB_AKS_ONETAG=db STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "Other resources in the group (NOT CloudLens, never deleted by this script):"
  out_before "Other resources in the group" "    cloudlens-aks-rg-aks "
  out_has "    cloudlens0ba7fd8f "
  out_lacks "Deploy-stamped resources"
  out_has "the group holds 2 resource(s) that are not CloudLens"
  az_lacks "aks delete"
  az_lacks "acr delete"
  az_lacks "group delete"
  az_has "vm delete"
end_case

begin_case "23: a cluster and registry carrying ONLY cloudlens:stack: other, never deleted, the group is kept"
  LIST_COUNT=0 STUB_AKS=1 STUB_AKS_ONETAG=st STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "Other resources in the group (NOT CloudLens, never deleted by this script):"
  out_before "Other resources in the group" "    cloudlens-aks-rg-aks "
  out_has "    cloudlens0ba7fd8f "
  out_lacks "Deploy-stamped resources"
  out_has "the group holds 2 resource(s) that are not CloudLens"
  az_lacks "aks delete"
  az_lacks "acr delete"
  az_lacks "group delete"
  az_has "vm delete"
end_case

begin_case "24: 'az aks show' fails: the cluster is still deleted, its scale set is told apart by the MC_ name shape, the group plan holds, the node group is reported unverified"
  LIST_COUNT=0 STUB_AKS=1 STUB_AKS_SHOW_FAIL=1 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "node resource group of cloudlens-aks-rg-aks could not be read"
  out_has "node resource group: could not be read; its removal is not verified in Phase 6"
  out_lacks "from outside the group"
  out_has "every resource is CloudLens"
  out_has "delete the whole resource group cl-rg"
  az_has "az aks delete -g cl-rg -n cloudlens-aks-rg-aks --yes"
  az_has "az group delete -n cl-rg --yes --no-wait"
  s_aks="$(seq_of "$AZ_LOG" 'aks delete')"; s_grp="$(seq_of "$AZ_LOG" 'group delete')"
  if [[ -z "$s_aks" || -z "$s_grp" ]]; then flunk "both an aks delete and a group delete stamped"
  elif (( s_aks >= s_grp )); then flunk "aks delete (seq $s_aks) stamped before group delete (seq $s_grp)"; fi
  out_has "Resource group cl-rg deleted"
  out_has "node resource group of cloudlens-aks-rg-aks was not read in Phase 2; check for MC_cl-rg_cloudlens-aks-rg-aks_eastus2 by hand"
  out_has "AKS clusters:       1 (node resource group(s) not verified: cloudlens-aks-rg-aks)"
  out_lacks "Some resources could not be removed"
end_case

begin_case "25: the cluster delete is refused in the group plan: no group delete, the VMs and the ACR still go, the VNet is kept, the failure is reported"
  LIST_COUNT=0 STUB_AKS=1 STUB_AKS_DELETE_FAIL=1 STUB_SHARED_VNET=1
  run_teardown --resource-group cl-rg --yes
  rc_is 2
  out_has "delete the whole resource group cl-rg"
  out_has "could not delete AKS cluster cloudlens-aks-rg-aks: (OperationNotAllowed)"
  out_has "the whole-group delete is not asked for"
  az_lacks "group delete"
  az_lacks "aks delete"
  az_has "vm delete"
  az_has "az acr delete -g cl-rg -n cloudlens0ba7fd8f --yes"
  az_lacks "resource delete --ids .*virtualNetworks/cloudlens-vnet"
  out_has "keeping VNet cloudlens-vnet: still used by NIC(s) that are not CloudLens (or belong to the cluster that could not be deleted): aks-nodepool1-12345678-vmss"
  # tried once, whichever plan: the fallback must not ask the cluster again
  n_tries="$(grep -c "could not delete AKS cluster" "$OUT")"
  [[ "$n_tries" == "1" ]] || flunk "exactly one refused cluster delete, got $n_tries"
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 still exists"
  out_has "Resource group:     cl-rg (kept: the AKS cluster delete was refused"
  out_has "AKS clusters:       0"
  out_has "Some resources could not be removed"
  out_has "  AKS cluster cloudlens-aks-rg-aks: (OperationNotAllowed)"
end_case

begin_case "26: pointed at a cluster's MC_ node resource group: refused by name before Phase 2, nothing deleted"
  LIST_COUNT=0 STUB_AKS=1 STUB_NODE_RG_TARGET=1
  run_teardown --resource-group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 --yes
  rc_nonzero
  out_has "MC_cl-rg_cloudlens-aks-rg-aks_eastus2 is the node resource group of cluster cloudlens-aks-rg-aks in group cl-rg"
  out_has "bash deploy/teardown-stack.sh --resource-group cl-rg"
  out_lacks "Phase 3"
  az_empty
  lic_empty
end_case

# ---------------------------------------------------------------------
# An empty listing is unknown, never "nothing but CloudLens". The resource
# listing failing twice on a deploy-created group used to leave OTHER
# empty and fall through to the whole-group plan.
# ---------------------------------------------------------------------
begin_case "27: 'az resource list' answers nothing twice on a deploy-created group: refused before the plan, nothing deleted, no group delete"
  LIST_COUNT=2 STUB_RES_LIST_FAIL=1
  run_teardown --resource-group cl-rg --yes --release-licences
  rc_nonzero
  out_has "returned nothing twice and the count did not answer"
  out_has "Refusing to guess: this script deletes things"
  out_has "az resource list -g cl-rg -o table"
  out_lacks "Phase 3"
  out_lacks "every resource is CloudLens"
  out_lacks "delete the whole resource group"
  az_empty
  lic_empty
end_case

begin_case "28: a deploy-created group that really is empty (count answers 0): the whole group goes, nothing else is called"
  LIST_COUNT=0 STUB_EMPTY_GROUP=1
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "holds no resources (confirmed by count)"
  out_has "No CloudLens VM in cl-rg"
  out_has "every resource is CloudLens"
  out_has "delete the whole resource group cl-rg"
  az_has "az group delete -n cl-rg --yes --no-wait"
  az_lacks "vm delete"
  az_lacks "resource delete"
  out_has "Resource group cl-rg deleted"
  lic_empty
end_case

echo
begin_case "29: 'az group show' answers nothing: refused before any classification, nothing deleted, no licence call"
  LIST_COUNT=0 STUB_AKS=1 STUB_GROUP_SHOW_FAIL=1
  run_teardown --resource-group cl-rg --yes
  rc_nonzero
  out_has "'az group show -n cl-rg' did not answer"
  out_lacks "Phase 3"
  az_empty
  lic_empty
end_case

begin_case "30: the cluster is already gone at delete time (ResourceNotFound): counted as gone, its kubeconfig still removed, no failure"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1 STUB_AKS_DELETE_NOTFOUND=1
  mkdir -p "$TEST_HOME/.kube"
  : > "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  : > "$TEST_HOME/.kube/config"
  run_teardown --resource-group cl-rg --yes
  rc_is 0
  out_has "AKS cluster cloudlens-aks-rg-aks was already gone"
  out_has "removed the deploy's kubeconfig $TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks"
  [[ ! -e "$TEST_HOME/.kube/cloudlens-aks-cloudlens-aks-rg-aks" ]] || flunk "the deploy's kubeconfig to be removed"
  [[ -f "$TEST_HOME/.kube/config" ]] || flunk "the default kubeconfig to be left alone"
  out_lacks "Some resources could not be removed"
end_case

begin_case "31: the node group is still reported twice after a successful cluster delete: waited for, then gone, no failure"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1 STUB_NODE_RG_LAG=2 NODE_RG_WAIT_T=10
  run_teardown --resource-group cl-rg --yes
  NODE_RG_WAIT_T=""
  rc_is 0
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 still exists; waiting up to"
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 no longer exists"
  out_lacks "Some resources could not be removed"
end_case

begin_case "32: the node group outlives the wait after a successful cluster delete: reported, the run says so"
  LIST_COUNT=0 STUB_AKS=1 STUB_SHARED_VNET=1 STUB_NODE_RG_LAG=100 NODE_RG_WAIT_T=2
  run_teardown --resource-group cl-rg --yes
  NODE_RG_WAIT_T=""
  rc_nonzero
  out_has "node resource group MC_cl-rg_cloudlens-aks-rg-aks_eastus2 still exists (Azure may still be removing it"
  out_has "Some resources could not be removed"
end_case

echo "${PASS} PASS, ${FAIL} FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
