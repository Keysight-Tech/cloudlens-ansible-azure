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
# deployedBy=cloudlens-stack, holds every CloudLens NIC).
set -u
LOG="${AZ_LOG:?}"; SEQ="${SEQ_FILE:?}"
next_seq() { local n; n="$(cat "$SEQ" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$SEQ"; printf '%s' "$n"; }
rec() { printf '%s az %s\n' "$(next_seq)" "$*" >> "$LOG"; }
# every line in LOG is a delete, so any line naming the id means it is gone.
# With STUB_DELETE_OPTION=1 the templates' deleteOption is emulated: a disk,
# NIC or public IP whose VM (its name prefix) was deleted is gone with it.
gone() {
  local id="$1" n vm
  if grep -qF -- "$id" "$LOG" 2>/dev/null; then return 0; fi
  if grep -q "az group delete" "$LOG" 2>/dev/null; then return 0; fi
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
    if grep -q "az group delete" "$LOG" 2>/dev/null; then echo false; else echo true; fi ;;
  "group show")
    if [[ "${STUB_NO_TAG:-0}" == "1" ]]; then echo None; else echo cloudlens-stack; fi
    echo eastus2 ;;
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
    while IFS='|' read -r n t; do
      [[ -n "$n" ]] || continue
      gone "$(rid "$n" "$t")" && continue
      printf '%s\t%s\t%s\n' "$n" "$t" "$(rid "$n" "$t")"
    done <<< "$RES" ;;
  "resource delete")
    shift 2; rec resource delete "$@" ;;
  "network vnet")
    n="$(argval -n "$@")"
    for nic in $(vnet_nics "$n"); do
      gone "$(rid "$nic" "$NIC_T")" && continue
      printf '%s/ipConfigurations/ipconfig1\n' "$(rid "$nic" "$NIC_T")"
    done ;;
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
  export LIST_COUNT=0 RELEASE_RC=0 STUB_NO_TAG=0 STUB_OTHER=0 STUB_DELETE_OPTION=0 STUB_SHARED_VNET=0
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

run_teardown() {
  RC=0
  PATH="$STUB_BIN:$PATH" \
  CLOUDLENS_KVO_LICENSE_PY="$WORK/kvo_license_stub.py" \
  CLOUDLENS_KVO_HTTP_TIMEOUT=2 CLOUDLENS_KVO_RELEASE_TIMEOUT=5 CLOUDLENS_PROBE_TIMEOUT=20 \
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

echo
echo "${PASS} PASS, ${FAIL} FAIL"
if (( FAIL > 0 )); then exit 1; fi
exit 0
