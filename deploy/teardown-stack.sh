#!/usr/bin/env bash
# =====================================================================
# CloudLens Stack Teardown (Azure): release the KVO's licences, then
# delete the CloudLens resource group, or only the CloudLens resources
# inside a group that is not ours to delete.
# =====================================================================
# This lives in its own file, and NOT behind a --teardown flag on
# deploy-stack.sh, on purpose. deploy-stack.sh states in a dozen places that
# it never deletes anything, and that promise is what makes it safe to paste
# into a terminal from a curl pipe with whatever flags someone half-remembers.
# A mistyped argument to a deploy script must never be able to delete a
# resource group, so the destructive tool is a separate name you have to
# reach for deliberately.
#
# Why Azure needs a teardown script at all, when `az group delete` exists:
#
#   1. The KVO's licences. Activation codes are bound to the KVO host they
#      were activated on. While that host is alive the counts can be
#      returned to the entitlement (the licensing API's deactivate
#      operation: proven, 20 counts recovered). Once the VM is gone they
#      cannot be, ever. `az group delete` by hand, which is what every
#      customer has done so far, strands them, with nothing anywhere warning
#      that it will. Three activation codes worth 500 counts each died that
#      way.
#   2. The group is not always ours to delete. The deploy reuses a group the
#      customer names (--resource-group), and a customer's group can hold
#      their own VMs, storage and networks next to ours. A teardown that
#      deleted the group would take those with it.
#   3. Deleting the VMs alone is not enough. deleteOption never covers the
#      NSG or the VNet, and stacks deployed before the templates set it (and
#      VMs made from the Marketplace UI) keep their Premium_LRS OS disk,
#      NICs and public IPs after `az vm delete` too, with the disk and the
#      public IPs still billing. Whatever did go with the VM is skipped.
#
# ---------------------------------------------------------------------
# SCOPING RULE. This is the one rule the whole script rests on.
#
# Nothing is deleted unless Azure itself ties it to CloudLens, by one of
# exactly three pieces of evidence, none of which is a guess:
#
#   1. Marketplace plan: the VM's plan.product is one of the three CloudLens
#      products (vController, KVO, vPB). Fixed by the image, whatever the VM
#      was named.
#   2. Attachment: the resource is the OS disk or a NIC that such a VM
#      reports attached, recorded while the attachment still exists (a
#      detached disk remembers nothing).
#   3. Template naming: the resource is a disk, NIC, public IP, NSG or VNet
#      whose name derives from a CloudLens VM's name the way the product
#      templates name them (<vm>-pip, <vm>-mgmt-nic, <vm>_OsDisk_1_..., and
#      so on). Only those five types: a storage account called kvo-backups
#      is reported as "other" and never touched.
#
# The whole resource group is deleted only when ALL of these hold: the
# deploy created it (it carries the deployedBy=cloudlens-stack tag the
# deploy writes on groups it creates, never on ones it reuses), nothing but
# CloudLens resources is inside it, and --keep-resource-group was not
# given. Otherwise only the CloudLens resources go, in dependency order, and
# the group and everything else in it stay, with the reason printed.
# ---------------------------------------------------------------------
#
# Usage:
#   bash deploy/teardown-stack.sh --resource-group RG
#   bash deploy/teardown-stack.sh --resource-group RG --audit     # read-only
#   bash deploy/teardown-stack.sh --resource-group RG --dry-run   # print, delete nothing
#
# Nothing here deletes anything without an explicit confirmation: a yes on a
# terminal, or --yes when there is no terminal. There is no default that
# destroys.
# =====================================================================
set -euo pipefail
# Brace-wrapped for the same reason deploy-stack.sh is: bash must buffer the
# whole file before running any of it, or a `curl ... | bash` invocation would
# lose the pipe the moment stdin is re-attached to the terminal below. The
# closing brace is the last line of the file.
{

# ---------------------------------------------------------------------
# Re-attach stdin to the terminal when invoked via `curl ... | bash`, exactly
# as deploy-stack.sh does. Without it every prompt below would try to read the
# script itself, and a destructive tool must never mis-read its own body as an
# answer to "are you sure".
# ---------------------------------------------------------------------
if [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  if { exec 3</dev/tty; } 2>/dev/null; then
    exec <&3 3<&-
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$PWD")"

# ---------------------------------------------------------------------
# Config + globals
# ---------------------------------------------------------------------
RESOURCE_GROUP="${CLOUDLENS_RG:-}"
ARG_RG=""

DRY_RUN=false
AUDIT_ONLY=false          # --audit: read-only, deletes nothing, ever
ASSUME_YES=false          # the ONLY way a non-interactive run may delete
ACCEPT_LICENCE_LOSS=false # the second confirmation, required when a KVO exists
RELEASE_LICENCES=false    # --release-licences: release the KVO's licences with no terminal to ask on
KEEP_RG=false             # --keep-resource-group: never the whole group, only what is ours
ARG_KVO_USER=""           # --kvo-admin-user / --kvo-admin-pass / --kvo-address
ARG_KVO_PASS=""
ARG_KVO_ADDRESS=""
# az is slow: the CLI alone takes a second or two to start, and a VM listing
# with per-VM instance views takes longer. 45s is generous for a single
# read-only call and still bounds a hung one.
PROBE_TIMEOUT="${CLOUDLENS_PROBE_TIMEOUT:-45}"
DELETE_TIMEOUT="${CLOUDLENS_DELETE_TIMEOUT:-1800}"   # 30 minutes for a group delete
KVO_HTTP_TIMEOUT="${CLOUDLENS_KVO_HTTP_TIMEOUT:-15}"        # per HTTP call to the KVO
KVO_RELEASE_TIMEOUT="${CLOUDLENS_KVO_RELEASE_TIMEOUT:-600}" # the whole release, overall

# Where scripts/kvo_license.py comes from when this script is run through
# `curl | bash` and the repo is not on disk: the same raw tree deploy-stack.sh
# fetches its templates from, into a temp dir that is removed on exit.
REPO_OWNER="Keysight-Tech"
REPO_NAME="cloudlens-ansible-azure"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
LIC_PY=""                 # the kvo_license.py in use, once located
LIC_CACHE_DIR=""          # temp dir holding a fetched copy, if one was needed
LIC_RELEASED=false        # true ONLY on exit 0 from kvo_license.py --release-all,
                          # or a list the KVO answered with nothing on it
LIC_WHY=""                # with LIC_RELEASED: "released" or "held nothing", for the waiver
LIC_RC=0                  # set by lic_run
_lic_out=""               # the temp file holding kvo_license.py's output, while it exists
# How the licence count is read from kvo_license.py: the `count` of the JSON
# object it prints as the last line of its output (with --json, on every
# exit path), through the python3 the release already requires. Never its
# prose: a wording change must not be able to turn "2 licences" into "could
# not tell", or into 0.
LIC_COUNT_PARSE='import json,sys; print(json.load(sys.stdin)["count"])'

# The three Marketplace plans the deploy's templates use. A VM is CloudLens
# when its plan.product is one of these, whatever it was named: this is the
# same test deploy-stack.sh uses to detect products it should reuse.
PRODUCT_VCONTROLLER="keysight-cloudlens-vcontroller"
PRODUCT_KVO="keysight-vision-orchestrator"
PRODUCT_VPB="keysight-cloudlens-virtual-packet-broker"
# The tag deploy-stack.sh writes on a group it CREATES (never on one it
# reuses): the only evidence that the group itself is ours.
DEPLOYED_BY_TAG="cloudlens-stack"
# The deploy's default VM names, used as name prefixes only when no
# CloudLens VM is left to read the names from (deleted by hand, leftovers
# still billing). Same env overrides as deploy-stack.sh.
DEFAULT_VCONTROLLER_NAME="${CLOUDLENS_VCONTROLLER_NAME:-vcontroller}"
DEFAULT_KVO_NAME="${CLOUDLENS_KVO_NAME:-kvo}"
DEFAULT_VPB_NAME="${CLOUDLENS_VPB_NAME:-vpb}"

SUBSCRIPTION_NAME=""
SUBSCRIPTION_ID=""
RG_LOCATION=""
RG_DEPLOYED_BY=""
HAS_KVO=false
KVO_VM_NAME=""
KVO_PUBLIC_IP=""
KVO_PRIVATE_IP=""

# CloudLens VMs, one per line:
#   name<TAB>product<TAB>id<TAB>os-disk-id<TAB>nic-ids(space separated)<TAB>power<TAB>public-ip<TAB>private-ip
CL_VM_LINES=""
CL_VM_NAMES=""        # space separated
CL_VM_IDS=""          # space separated, lower-cased for comparison
CL_ATTACHED_IDS=""    # OS disks + NICs the VMs report attached, lower-cased
PREFIX_NAMES=""       # the VM names resources are matched against
PREFIX_ASSUMED=false  # true when PREFIX_NAMES came from the deploy defaults

# Everything in the group, one per line: name<TAB>type<TAB>id
RES_LINES=""
CL_RES_LINES=""       # the CloudLens set (VMs included), same layout
OTHER_RES_LINES=""    # everything else, same layout
# The CloudLens set split by type for the per-resource delete, one id per
# line (ids carry no spaces, but a VNet's name is needed for the in-use
# check, so VNets carry name<TAB>id).
CL_DISK_IDS=""
CL_NIC_IDS=""
CL_PIP_IDS=""
CL_NSG_IDS=""
CL_VNET_LINES=""

PLAN=""               # "group" or "resources"
PLAN_WHY=""

DELETED_VMS=0; DELETED_DISKS=0; DELETED_NICS=0; DELETED_PIPS=0; DELETED_NSGS=0; DELETED_VNETS=0
KEPT_VNETS=""
GROUP_GONE=false
FAILED_ITEMS=""
SCRIPT_DONE=false
PHASE_NAME="startup"

# ---------------------------------------------------------------------
# Pretty output (same vocabulary as deploy-stack.sh, on purpose: the two
# scripts are read back to back in the same terminal)
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'
  C_RED='\033[0;31m'; C_GREY='\033[0;90m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RED=''; C_GREY=''; C_BOLD=''; C_RESET=''
fi

banner() {
  local msg="$1"
  echo -e "${C_BLUE}================================================================${C_RESET}"
  printf "${C_BLUE}  ${C_BOLD}%s${C_RESET}\n" "$msg"
  echo -e "${C_BLUE}================================================================${C_RESET}"
}
ok()    { echo -e "${C_GREEN}[ok]${C_RESET} $1"; }
warn()  { echo -e "${C_YELLOW}[warn]${C_RESET} $1"; }
fail()  { echo -e "${C_RED}[x]${C_RESET} $1" >&2; SCRIPT_DONE=true; exit 1; }
step()  { echo; echo -e "${C_BLUE}--- $1 ---${C_RESET}"; PHASE_NAME="$1"; }
note()  { echo -e "${C_GREY}  -> $1${C_RESET}"; }
dryrun_say() { echo -e "${C_YELLOW}[dry-run]${C_RESET} $1"; }

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------
# Prompting that can never block. Identical mechanism to deploy-stack.sh:
# the /dev/tty re-attach above is what makes a piped invocation interactive
# at all, and this single -t 0 check AFTER it decides whether there is
# anybody to ask. When there is not, every prompt takes its default, and for
# this script every destructive default is "no".
# ---------------------------------------------------------------------
INTERACTIVE=false
if [[ -t 0 ]]; then INTERACTIVE=true; fi

ask() {
  local prompt="$1" def="${2:-}" ans=""
  if [[ "$INTERACTIVE" == "true" ]]; then
    read -rp "$prompt" ans || true
  fi
  printf '%s' "${ans:-$def}"
}

# ask_yn "prompt" "y|n"  -> returns 0 for yes, 1 for no
ask_yn() {
  local ans; ans="$(to_lower "$(ask "$1" "$2")")"
  [[ "$ans" == "y" || "$ans" == "yes" ]]
}

# ---------------------------------------------------------------------
# Read-only probes. Lifted from the AWS teardown unchanged in behaviour: a
# probe may never abort the run and may never hang it. Anything that fails,
# times out or is killed yields EMPTY, and empty means "unknown", never
# "there is nothing there" and never "safe to delete". There is no `timeout`
# binary on macOS, so the bound is a kill timer of our own.
# ---------------------------------------------------------------------
PROBE_TICK=""
probe() {
  local out="" tmp pid ticks=0 limit
  if [[ -z "$PROBE_TICK" ]]; then
    if sleep 0.2 >/dev/null 2>&1; then PROBE_TICK="0.2"; else PROBE_TICK="1"; fi
  fi
  if [[ "$PROBE_TICK" == "0.2" ]]; then limit=$(( PROBE_TIMEOUT * 5 )); else limit="$PROBE_TIMEOUT"; fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/cloudlens-teardown.XXXXXX" 2>/dev/null)" || tmp=""
  if [[ -z "$tmp" ]]; then
    if [[ "${PROBE_MERGE_STDERR:-}" == "1" ]]; then "$@" 2>&1 || true; else "$@" 2>/dev/null || true; fi
    return 0
  fi

  if [[ "${PROBE_MERGE_STDERR:-}" == "1" ]]; then
    "$@" >"$tmp" 2>&1 </dev/null &
  else
    "$@" >"$tmp" 2>/dev/null </dev/null &
  fi
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (( ticks < limit )); do
    sleep "$PROBE_TICK" 2>/dev/null || sleep 1
    ticks=$((ticks+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    : > "$tmp"          # a half-written answer is not an answer
  fi
  wait "$pid" 2>/dev/null || true
  out="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp" 2>/dev/null || true
  printf '%s' "$out"
  return 0
}

# Every read-only az call goes through here. Nothing else in this file runs
# `az` except del_az, which is the destructive wrapper below.
ro_az() { probe az "$@"; }

# `-o tsv` prints a JSON null as the word None, inside a row and as a row of
# its own. Empty is what "unknown" looks like everywhere else in this file,
# so None is folded into it.
det_clean() { local v="$1"; if [[ "$v" == "None" ]]; then v=""; fi; printf '%s' "$v"; }

# First NON-BLANK line: az leads some error output with a blank one.
first_line() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' 2>/dev/null | head -1 || true
}

# Nth non-blank line of a probe's output. `-o tsv` prints a top-level list
# of scalars one per line, so `--query "[name,id]"` is read with this.
nth_line() {
  printf '%s\n' "$2" | grep -v '^[[:space:]]*$' 2>/dev/null | sed -n "${1}p" || true
}

# Collapse tabs/newlines from `-o tsv` into a single space-separated token
# list, and drop the None a null prints as.
tokens() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' ' | sed 's/^ //; s/ $//' \
    | tr ' ' '\n' | grep -v '^None$' 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true
}

in_list() {
  local needle="$1" hay="$2"
  case " $hay " in *" $needle "*) return 0 ;; esac
  return 1
}

count_lines() { printf '%s\n' "$1" | grep -c -v '^[[:space:]]*$' 2>/dev/null || true; }
count_words() { printf '%s' "$1" | wc -w | tr -d ' '; }

# ---------------------------------------------------------------------
# The DESTRUCTIVE wrapper. Prints instead of acting under --dry-run, refuses
# outright under --audit, and never aborts the run on failure: one NIC that
# will not delete must not stop the other resources from being cleaned.
# ---------------------------------------------------------------------
DEL_ERR=""
del_az() {
  local out rc=0
  if [[ "$AUDIT_ONLY" == "true" ]]; then
    DEL_ERR="refused: --audit is read-only"
    return 1
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "az $*"
    DEL_ERR=""
    return 0
  fi
  out="$(az "$@" 2>&1 </dev/null)" || rc=$?
  if (( rc != 0 )); then DEL_ERR="$(first_line "$out")"; return 1; fi
  DEL_ERR=""
  return 0
}

record_failure() { FAILED_ITEMS="${FAILED_ITEMS}${FAILED_ITEMS:+$'\n'}  $1: ${2:-unknown error}"; }

# "deleted" or "would delete", so a rehearsal never reads like it did something.
did() { if [[ "$DRY_RUN" == "true" ]]; then printf 'would delete'; else printf 'deleted'; fi; }

# The last path segment of a resource id, for messages.
id_name() { printf '%s' "${1##*/}"; }

# ---------------------------------------------------------------------
show_help() {
  cat <<'HLP'
CloudLens Stack Teardown (Azure)

Usage:
  bash deploy/teardown-stack.sh --resource-group RG [options]

Releases the licences on the KVO deploy-stack.sh put in the group, then
deletes the group (when the deploy created it and nothing else lives in it)
or only the CloudLens resources inside it: the vController, KVO and vPB VMs
and their disks, NICs, public IPs, NSGs and VNets. `az group delete` by hand
strands the KVO's licences; `az vm delete` alone leaves the disks and public
IPs billing.

Nothing is deleted without an explicit confirmation: a yes on a terminal, or
--yes when there is no terminal. There is no default that destroys.

Modes:
  --audit                   READ-ONLY. Lists the CloudLens resources in the
                            group, everything else in it, and exactly what a
                            teardown would delete. Never deletes, never
                            touches the KVO. (--orphans is an alias.)
  --dry-run                 Walk the whole teardown and print every az
                            command it would run, touching nothing. Nothing
                            is called on the KVO either.

Required:
  --resource-group RG       The resource group deploy-stack.sh deployed into
                            ($CLOUDLENS_RG). Prompted for on a terminal.

Scope:
  --keep-resource-group     Never delete the group itself, only the CloudLens
                            resources in it, even when the deploy created it
                            and nothing else is inside.

Confirmation (a non-interactive run needs these, and never assumes them):
  --yes                     Confirm the teardown without a terminal to ask on.
  --accept-licence-loss     Second confirmation, required only when the group
                            contains a KVO whose licences were NOT released.
                            Licences can be RELEASED from a live KVO: this
                            script offers to do it for you once the teardown
                            is confirmed and before anything is deleted
                            (Phase 4a, the licensing API's deactivate
                            operation, proven to return the counts), and the
                            KVO UI can too (Settings > Product Licensing >
                            Deactivate licenses). Once the KVO is deleted they
                            cannot: the quantity still activated on it is
                            stranded for good. A release that leaves the KVO
                            clear waives this flag; anything else needs it.

KVO licence release (only when the group contains a KVO):
  --release-licences        Release every licence the KVO holds, without
                            asking. On a terminal the script asks instead
                            ("Release all N licences ...? [Y/n]", default
                            yes). Without a terminal and without this flag
                            nothing is released.
  --kvo-admin-user USER     KVO login for the release. Defaults: this flag,
  --kvo-admin-pass PASS     then $CLOUDLENS_KVO_ADMIN_USER / _PASS, then a
                            prompt on a terminal (admin / admin offered). The
                            script never echoes, logs or records the
                            password, but a value given with --kvo-admin-pass
                            sits in your shell history and is visible in ps
                            while the script runs. Prefer the
                            CLOUDLENS_KVO_ADMIN_PASS variable or the prompt.
  --kvo-address ADDR        Where to reach the KVO, if Azure cannot say.
                            Found from the KVO VM's public IP, else its
                            private IP (reachable from inside the VNet).

Scoping (why this is safe to run in a shared group):
  A VM is CloudLens when its Marketplace plan says so, whatever it is named.
  Its OS disk and NICs are taken from the VM itself while they are attached.
  Disks, NICs, public IPs, NSGs and VNets named from a CloudLens VM the way
  the product templates name them are CloudLens too. Nothing else is: every
  other resource in the group is listed and left alone, and its presence
  keeps the group itself from being deleted. The group is deleted only when
  deploy-stack.sh created it (deployedBy=cloudlens-stack) AND nothing but
  CloudLens resources is inside AND --keep-resource-group was not given.

Env-var overrides:
  CLOUDLENS_RG, CLOUDLENS_PROBE_TIMEOUT (per read-only az call, 45s),
  CLOUDLENS_DELETE_TIMEOUT (wait for a group delete, 1800s),
  CLOUDLENS_KVO_ADMIN_USER, CLOUDLENS_KVO_ADMIN_PASS,
  CLOUDLENS_KVO_HTTP_TIMEOUT (per call, 15s), CLOUDLENS_KVO_RELEASE_TIMEOUT
  (the whole release, 600s), CLOUDLENS_KVO_LICENSE_PY (path to
  scripts/kvo_license.py, for tests)

Examples:
  # What is in this group, and what would a teardown delete? Deletes nothing.
  bash deploy/teardown-stack.sh --resource-group cloudlens-rg --audit

  # Rehearse the whole teardown, touch nothing.
  bash deploy/teardown-stack.sh --resource-group cloudlens-rg --dry-run

  # Real teardown, no terminal, group contains a KVO: release its licences
  # first, then delete. Stops if the release leaves anything on the KVO.
  bash deploy/teardown-stack.sh --resource-group cloudlens-rg \
       --yes --release-licences

  # Same, but accept losing whatever is still activated on the KVO.
  bash deploy/teardown-stack.sh --resource-group cloudlens-rg \
       --yes --accept-licence-loss

  # A shared group: remove only the CloudLens VMs and their resources.
  bash deploy/teardown-stack.sh --resource-group shared-rg --keep-resource-group

Order of operations:
  1. Pre-flight: az present and logged in, the group exists.
  2. Discover, read-only: the CloudLens VMs by Marketplace plan, their
     attached disks and NICs (captured while still attached), everything
     else in the group, and whether the group itself is ours to delete.
  3. Report everything found and the plan: the whole group, or only the
     CloudLens resources with the reason.
  4. Confirm the teardown. Asked before any licence is touched, so the next
     step only ever strips a KVO you have already chosen to destroy.
  4a. List the licences on the group's KVO and offer to release them all,
     while the KVO is still alive to release them. A release that leaves the
     KVO clear means nothing is stranded and step 4b is skipped.
  4b. Warn about stranded KVO licences and take the licence-loss
     confirmation (the typed resource group name, or --accept-licence-loss).
  5. Delete: the group, then wait for it to go; or the VMs, then their
     disks, NICs, public IPs, NSGs and VNets in that order.
  6. Verify what is left and report what was deleted, what failed and why,
     and whether the licences were released.
HLP
}

# ---------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) ARG_RG="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --audit|--orphans) AUDIT_ONLY=true; shift ;;
    --keep-resource-group) KEEP_RG=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --accept-licence-loss|--accept-license-loss) ACCEPT_LICENCE_LOSS=true; shift ;;
    --release-licences|--release-licenses) RELEASE_LICENCES=true; shift ;;
    --kvo-admin-user) ARG_KVO_USER="${2:-}"; shift 2 ;;
    --kvo-admin-pass) ARG_KVO_PASS="${2:-}"; shift 2 ;;
    --kvo-address) ARG_KVO_ADDRESS="${2:-}"; shift 2 ;;
    -h|--help) show_help; SCRIPT_DONE=true; exit 0 ;;
    *) warn "Unknown argument: $1"; show_help; SCRIPT_DONE=true; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------
# Last line of defence: no exit may ever be silent. Same reasoning as
# deploy-stack.sh, and it matters more here: a teardown that stopped without
# saying why leaves the operator unsure whether anything was deleted.
# ---------------------------------------------------------------------
on_exit() {
  local code=$?
  if [[ "${BASHPID:-$$}" != "$$" ]]; then return 0; fi
  if [[ -n "$LIC_CACHE_DIR" ]]; then rm -rf "$LIC_CACHE_DIR" 2>/dev/null || true; fi
  if [[ -n "$_lic_out" ]]; then rm -f "$_lic_out" 2>/dev/null || true; fi
  if [[ "$SCRIPT_DONE" == "true" ]]; then return 0; fi
  if (( code == 0 )); then return 0; fi
  echo
  echo -e "${C_RED}[x] Stopped in: ${PHASE_NAME} (exit ${code})${C_RESET}" >&2
  echo "    Nothing above explained this, which means a command failed under" >&2
  echo "    'set -e'. The usual cause is an az call: an expired login, no" >&2
  echo "    network, or a missing permission." >&2
  echo "    Check with: az account show" >&2
  echo "    Re-run with --audit to see what is still there. It deletes nothing." >&2
}
trap on_exit EXIT

on_interrupt() {
  echo
  SCRIPT_DONE=true
  if [[ -n "$LIC_CACHE_DIR" ]]; then rm -rf "$LIC_CACHE_DIR" 2>/dev/null || true; fi
  if [[ -n "$_lic_out" ]]; then rm -f "$_lic_out" 2>/dev/null || true; fi
  warn "Interrupted in: ${PHASE_NAME}"
  warn "Re-run with --audit to see what is left; a re-run of the teardown removes it."
  exit 130
}
trap on_interrupt INT TERM

# =====================================================================
# Phase 1: pre-flight
# =====================================================================
step "Phase 1: Pre-flight"
banner "CloudLens Stack Teardown (Azure)"
echo
if [[ "$AUDIT_ONLY" == "true" ]]; then
  warn "AUDIT MODE (--audit): read-only. Nothing will be deleted, the KVO is not touched."
elif [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY-RUN MODE: every az command is printed, nothing is deleted, the KVO is not touched."
fi
echo

# On macOS the az on PATH is sometimes a pyenv shim whose azure-cli modules
# are broken (deploy-stack.sh routes around the same thing). Only a pyenv
# shim is bypassed: an az that is already something else, including one a
# test puts on PATH, is used as found.
if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
  case "$(command -v az 2>/dev/null || true)" in
    */.pyenv/shims/*)
      for _cand in /opt/homebrew/bin/az /usr/local/bin/az; do
        if [[ -x "$_cand" ]]; then
          export PATH="$(dirname "$_cand"):$PATH"
          note "Routing around pyenv: using ${_cand}"
          break
        fi
      done ;;
  esac
fi

if ! command -v az >/dev/null 2>&1; then
  fail "Azure CLI not found. Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
fi

_acct="$(ro_az account show --query "[name,id]" -o tsv)"
SUBSCRIPTION_NAME="$(det_clean "$(nth_line 1 "$_acct")")"
SUBSCRIPTION_ID="$(det_clean "$(nth_line 2 "$_acct")")"
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  fail "Not logged in to Azure, or az did not answer within ${PROBE_TIMEOUT}s.
  Run: az login    (then: az account set --subscription <name or id>)"
fi
ok "Azure subscription: ${SUBSCRIPTION_NAME:-unnamed} (${SUBSCRIPTION_ID})"

RESOURCE_GROUP="${ARG_RG:-$RESOURCE_GROUP}"
if [[ -z "$RESOURCE_GROUP" && "$INTERACTIVE" == "true" ]]; then
  echo
  echo "Resource groups deploy-stack.sh created in this subscription:"
  _rgs="$(ro_az group list --query "[?tags.deployedBy=='${DEPLOYED_BY_TAG}'].[name,location]" -o tsv)"
  if [[ -n "$_rgs" ]]; then printf '%s\n' "$_rgs" | sed 's/^/  /'; else echo "  (none tagged; a reused group carries no tag)"; fi
  echo
  RESOURCE_GROUP="$(ask "Resource group to tear down: " "")"
fi
if [[ -z "$RESOURCE_GROUP" ]]; then
  fail "No resource group. Pass --resource-group RG (or set CLOUDLENS_RG). See --help."
fi

# `az group exists` answers true/false on exit 0 either way, so empty means
# the probe itself failed, and that is a stop, never an assumption.
_exists="$(to_lower "$(first_line "$(ro_az group exists -n "$RESOURCE_GROUP" -o tsv)")")"
case "$_exists" in
  true) ok "Resource group '${RESOURCE_GROUP}' exists" ;;
  false)
    fail "Resource group '${RESOURCE_GROUP}' does not exist in subscription ${SUBSCRIPTION_NAME:-$SUBSCRIPTION_ID}.
  Nothing to tear down. If the name is right, check the subscription:
    az account show --query name    /    az group list -o table" ;;
  *)
    fail "Could not tell whether '${RESOURCE_GROUP}' exists (az did not answer). Refusing to
  guess: this script deletes things. Check with:
    az group show -n ${RESOURCE_GROUP}" ;;
esac

# =====================================================================
# Phase 2: discover (read-only)
#
# This runs BEFORE anything is deleted, and that ordering is the whole point.
# A VM that is still there names its OS disk and its NICs; once it is gone
# the disk is a name in a list with nothing to tie it back. Capture the
# evidence while it exists.
# =====================================================================
step "Phase 2: Discover what is in ${RESOURCE_GROUP} (read-only)"

_rg="$(ro_az group show -n "$RESOURCE_GROUP" --query "[tags.deployedBy,location]" -o tsv)"
RG_DEPLOYED_BY="$(det_clean "$(nth_line 1 "$_rg")")"
RG_LOCATION="$(det_clean "$(nth_line 2 "$_rg")")"
if [[ "$RG_DEPLOYED_BY" == "$DEPLOYED_BY_TAG" ]]; then
  ok "Group tag deployedBy=${RG_DEPLOYED_BY}: deploy-stack.sh created this group"
else
  note "Group carries no deployedBy=${DEPLOYED_BY_TAG} tag: deploy-stack.sh reused it, or it was made by hand."
  note "The group itself will not be deleted, only the CloudLens resources inside it."
fi
if [[ -n "$RG_LOCATION" ]]; then note "location ${RG_LOCATION}"; fi

# ---- the CloudLens VMs, by Marketplace plan ----------------------------
# One row per VM: name, plan.product (None when the VM is not from a
# Marketplace plan), id, OS disk id, NIC ids. The disk and NIC ids are the
# attachment evidence, and they are read here, while the VM still holds them.
_vms="$(ro_az vm list -g "$RESOURCE_GROUP" \
  --query "[].[name, plan.product, id, storageProfile.osDisk.managedDisk.id, join(' ', networkProfile.networkInterfaces[].id)]" -o tsv)"

# ---- everything in the group --------------------------------------------
_res="$(ro_az resource list -g "$RESOURCE_GROUP" --query "[].[name, type, id]" -o tsv)"
if [[ -z "$_res" ]]; then
  # An empty group and a probe that failed look the same. Ask once more
  # before believing "empty".
  _res="$(ro_az resource list -g "$RESOURCE_GROUP" --query "[].[name, type, id]" -o tsv)"
fi
RES_LINES="$_res"

# The VM listing failing while the resource listing shows VMs would make
# every VM "other" and, worse, hide the KVO from the licence gate. Fail
# closed on that.
if [[ -z "$_vms" ]] && printf '%s\n' "$RES_LINES" | grep -qi $'\tMicrosoft.Compute/virtualMachines\t' 2>/dev/null; then
  fail "The group contains VMs but 'az vm list' returned nothing (a failed or slow call).
  Refusing to guess which of them are CloudLens. Check with:
    az vm list -g ${RESOURCE_GROUP} -o table"
fi

while IFS=$'\t' read -r _vn _vp _vid _vdisk _vnics; do
  if [[ -z "${_vn:-}" ]]; then continue; fi
  _vp="$(det_clean "${_vp:-}")"
  case "$_vp" in
    "$PRODUCT_VCONTROLLER"|"$PRODUCT_KVO"|"$PRODUCT_VPB") ;;
    *) continue ;;
  esac
  _vdisk="$(det_clean "${_vdisk:-}")"
  _vnics="$(tokens "${_vnics:-}")"
  CL_VM_NAMES="${CL_VM_NAMES}${CL_VM_NAMES:+ }${_vn}"
  CL_VM_IDS="${CL_VM_IDS}${CL_VM_IDS:+ }$(to_lower "$_vid")"
  if [[ -n "$_vdisk" ]]; then CL_ATTACHED_IDS="${CL_ATTACHED_IDS}${CL_ATTACHED_IDS:+ }$(to_lower "$_vdisk")"; fi
  for _n in $_vnics; do CL_ATTACHED_IDS="${CL_ATTACHED_IDS}${CL_ATTACHED_IDS:+ }$(to_lower "$_n")"; done
  if [[ "$_vp" == "$PRODUCT_KVO" ]]; then
    HAS_KVO=true
    if [[ -z "$KVO_VM_NAME" ]]; then KVO_VM_NAME="$_vn"; fi
  fi
  # Power state and addresses, per CloudLens VM only: these are extra calls
  # each, and a shared group can hold a hundred VMs that are not ours.
  _pw="$(det_clean "$(first_line "$(ro_az vm get-instance-view -g "$RESOURCE_GROUP" -n "$_vn" \
          --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)")")"
  # `|| 'none'` keeps both slots filled when the VM has no public IP, so the
  # two tokens always come back in the same order.
  _ips="$(tokens "$(ro_az vm list-ip-addresses -g "$RESOURCE_GROUP" -n "$_vn" \
          --query "[0].virtualMachine.network.[publicIpAddresses[0].ipAddress || 'none', privateIpAddresses[0] || 'none']" -o tsv)")"
  _pub="${_ips%% *}"; _priv=""
  if [[ "$_ips" == *" "* ]]; then _priv="${_ips#* }"; fi
  if [[ "$_pub" == "none" ]]; then _pub=""; fi
  if [[ "$_priv" == "none" ]]; then _priv=""; fi
  if [[ "$_vp" == "$PRODUCT_KVO" && "$_vn" == "$KVO_VM_NAME" ]]; then
    KVO_PUBLIC_IP="$_pub"; KVO_PRIVATE_IP="$_priv"
  fi
  CL_VM_LINES="${CL_VM_LINES}${CL_VM_LINES:+$'\n'}${_vn}"$'\t'"${_vp}"$'\t'"${_vid}"$'\t'"${_vdisk}"$'\t'"${_vnics}"$'\t'"${_pw:-unknown}"$'\t'"${_pub}"$'\t'"${_priv}"
done <<< "$_vms"

if [[ -n "$CL_VM_NAMES" ]]; then
  PREFIX_NAMES="$CL_VM_NAMES"
  ok "CloudLens VMs (by Marketplace plan): $(count_words "$CL_VM_NAMES")"
else
  # No CloudLens VM left: the usual reason is that someone deleted the VMs
  # by hand and the disks and public IPs are still billing. Their names
  # derive from the deploy's VM names, and with no VM to read those from,
  # the deploy's defaults are the best evidence there is. Still only the
  # five template-created types, and the audit shows every match before
  # anything is confirmed.
  PREFIX_NAMES="${DEFAULT_VCONTROLLER_NAME} ${DEFAULT_KVO_NAME} ${DEFAULT_VPB_NAME}"
  PREFIX_ASSUMED=true
  warn "No CloudLens VM in ${RESOURCE_GROUP}. Leftovers are matched against the deploy's"
  warn "default VM names (${PREFIX_NAMES}) instead; the audit below lists every match."
fi

# name_from_cl_vm NAME: whether NAME is a CloudLens VM's name or derives from
# one the way the templates derive names: <vm>-pip, <vm>-mgmt-nic,
# <vm>-ingress-1, <vm>-vnet, and Azure's own <vm>_OsDisk_1_<hash> for the OS
# disk. A VM named kvo-2 (KVO_COUNT>1) is itself a CloudLens VM, so kvo-2-pip
# is matched by its own name, not by kvo's.
name_from_cl_vm() {
  local n="$1" vm
  for vm in $PREFIX_NAMES; do
    if [[ "$n" == "$vm" || "$n" == "${vm}-"* || "$n" == "${vm}_"* || "$n" == "${vm}/"* ]]; then return 0; fi
  done
  return 1
}

# ---- classify every resource in the group -------------------------------
while IFS=$'\t' read -r _rn _rt _rid; do
  if [[ -z "${_rn:-}" ]]; then continue; fi
  _rtl="$(to_lower "${_rt:-}")"
  _ridl="$(to_lower "${_rid:-}")"
  _cls="other"
  case "$_rtl" in
    microsoft.compute/virtualmachines)
      if in_list "$_ridl" "$CL_VM_IDS"; then _cls="vm"; fi ;;
    microsoft.compute/disks)
      if in_list "$_ridl" "$CL_ATTACHED_IDS" || name_from_cl_vm "$_rn"; then _cls="disk"; fi ;;
    microsoft.network/networkinterfaces)
      if in_list "$_ridl" "$CL_ATTACHED_IDS" || name_from_cl_vm "$_rn"; then _cls="nic"; fi ;;
    microsoft.network/publicipaddresses)
      if name_from_cl_vm "$_rn"; then _cls="pip"; fi ;;
    microsoft.network/networksecuritygroups)
      if name_from_cl_vm "$_rn"; then _cls="nsg"; fi ;;
    microsoft.network/virtualnetworks)
      if name_from_cl_vm "$_rn"; then _cls="vnet"; fi ;;
    microsoft.compute/virtualmachines/extensions)
      # Deleted with its VM; listed so the audit is complete.
      if name_from_cl_vm "$_rn"; then _cls="ext"; fi ;;
  esac
  case "$_cls" in
    other) OTHER_RES_LINES="${OTHER_RES_LINES}${OTHER_RES_LINES:+$'\n'}${_rn}"$'\t'"${_rt}"$'\t'"${_rid}" ;;
    *)     CL_RES_LINES="${CL_RES_LINES}${CL_RES_LINES:+$'\n'}${_rn}"$'\t'"${_rt}"$'\t'"${_rid}" ;;
  esac
  case "$_cls" in
    disk) CL_DISK_IDS="${CL_DISK_IDS}${CL_DISK_IDS:+$'\n'}${_rid}" ;;
    nic)  CL_NIC_IDS="${CL_NIC_IDS}${CL_NIC_IDS:+$'\n'}${_rid}" ;;
    pip)  CL_PIP_IDS="${CL_PIP_IDS}${CL_PIP_IDS:+$'\n'}${_rid}" ;;
    nsg)  CL_NSG_IDS="${CL_NSG_IDS}${CL_NSG_IDS:+$'\n'}${_rid}" ;;
    vnet) CL_VNET_LINES="${CL_VNET_LINES}${CL_VNET_LINES:+$'\n'}${_rn}"$'\t'"${_rid}" ;;
  esac
done <<< "$RES_LINES"

# ---- the plan ------------------------------------------------------------
if [[ "$KEEP_RG" == "true" ]]; then
  PLAN="resources"; PLAN_WHY="--keep-resource-group was given"
elif [[ "$RG_DEPLOYED_BY" != "$DEPLOYED_BY_TAG" ]]; then
  PLAN="resources"; PLAN_WHY="the group carries no deployedBy=${DEPLOYED_BY_TAG} tag, so deploy-stack.sh did not create it"
elif [[ -n "$OTHER_RES_LINES" ]]; then
  PLAN="resources"; PLAN_WHY="the group holds $(count_lines "$OTHER_RES_LINES") resource(s) that are not CloudLens"
else
  PLAN="group"; PLAN_WHY="deploy-stack.sh created the group and nothing but CloudLens is in it"
fi

# =====================================================================
# Phase 3: the audit report. Always printed; --audit stops after it.
# =====================================================================
step "Phase 3: What is in ${RESOURCE_GROUP}"

if [[ -n "$CL_VM_LINES" ]]; then
  echo "  CloudLens VMs (by Marketplace plan):"
  while IFS=$'\t' read -r _vn _vp _vid _vdisk _vnics _pw _pub _priv; do
    if [[ -z "${_vn:-}" ]]; then continue; fi
    case "$_vp" in
      "$PRODUCT_VCONTROLLER") _lbl="vController" ;;
      "$PRODUCT_KVO")         _lbl="KVO" ;;
      "$PRODUCT_VPB")         _lbl="vPB" ;;
      *)                      _lbl="$_vp" ;;
    esac
    printf '    %-12s %-28s %-16s public %-16s private %s\n' "$_lbl" "$_vn" "${_pw:-unknown}" "${_pub:-none}" "${_priv:-none}"
  done <<< "$CL_VM_LINES"
else
  warn "No CloudLens VM found in ${RESOURCE_GROUP}."
fi

if [[ -n "$CL_RES_LINES" ]]; then
  echo
  if [[ "$PREFIX_ASSUMED" == "true" ]]; then
    echo "  CloudLens resources (matched by the deploy's DEFAULT names, no VM left to confirm):"
  else
    echo "  CloudLens resources (the VMs, what they have attached, and what is named from them):"
  fi
  while IFS=$'\t' read -r _rn _rt _rid; do
    if [[ -z "${_rn:-}" ]]; then continue; fi
    printf '    %-44s %s\n' "$_rn" "$_rt"
  done <<< "$CL_RES_LINES"
  note "Deleting a VM never deletes its NSG or VNet, and on stacks deployed before"
  note "the templates set deleteOption it leaves the disk, NICs and public IPs too."
  note "The teardown removes them by name; whatever went with the VM is skipped."
fi

echo
if [[ -n "$OTHER_RES_LINES" ]]; then
  echo "  Other resources in the group (NOT CloudLens, never deleted by this script):"
  while IFS=$'\t' read -r _rn _rt _rid; do
    if [[ -z "${_rn:-}" ]]; then continue; fi
    printf '    %-44s %s\n' "$_rn" "$_rt"
  done <<< "$OTHER_RES_LINES"
else
  ok "Nothing else in the group: every resource is CloudLens."
fi

echo
if [[ "$HAS_KVO" == "true" ]]; then
  warn "The group contains a KVO (${KVO_VM_NAME}). Its licences must be released BEFORE it"
  warn "is deleted or they are stranded for good; the teardown offers to do that."
fi
echo "  Plan: "
if [[ "$PLAN" == "group" ]]; then
  echo "    delete the whole resource group ${RESOURCE_GROUP}"
  echo "    because ${PLAN_WHY}."
else
  echo "    delete only the CloudLens resources listed above, in dependency order"
  echo "    (VMs, then disks, NICs, public IPs, NSGs, VNets), and leave the group"
  echo "    and everything else in it alone, because ${PLAN_WHY}."
fi

if [[ "$AUDIT_ONLY" == "true" ]]; then
  echo
  step "Audit complete"
  echo "  Resource group:        ${RESOURCE_GROUP} (${RG_LOCATION:-location unknown}, deployedBy=${RG_DEPLOYED_BY:-none})"
  echo "  CloudLens VMs:         $(count_words "$CL_VM_NAMES")$(if [[ "$HAS_KVO" == "true" ]]; then printf ' (includes a KVO: %s)' "$KVO_VM_NAME"; fi)"
  echo "  CloudLens resources:   $(count_lines "$CL_RES_LINES")"
  echo "  Other resources:       $(count_lines "$OTHER_RES_LINES")"
  echo "  Would delete:          $(if [[ "$PLAN" == "group" ]]; then printf 'the whole group'; else printf 'only the CloudLens resources'; fi)"
  echo
  echo "  Nothing was deleted and the KVO was not touched. To actually tear this down:"
  echo "    bash deploy/teardown-stack.sh --resource-group ${RESOURCE_GROUP}"
  SCRIPT_DONE=true
  exit 0
fi

# =====================================================================
# Phase 4a helpers: release the KVO's licences, while there is still a KVO
#
# Activation codes are bound to the KVO host they were activated on. While
# that host is alive the counts can be returned (the licensing API's
# deactivate operation: proven, 20 counts recovered); once the VM is
# deleted they cannot, ever. Phase 4a is the last moment that is possible,
# so it lists what the KVO holds and offers to release all of it, with
# scripts/kvo_license.py doing the API work.
#
# It runs AFTER the teardown itself has been confirmed (Phase 4), so the
# licences are only ever stripped from a KVO the operator has already
# committed to destroying: a release followed by a "no" at the delete would
# leave a running KVO with nothing on it.
#
# Fail CLOSED. The only thing that waives the licence gate in Phase 4b is
# kvo_license.py exiting 0, which it does only when every deactivate
# reported SUCCESS and the KVO then reports no licence left (or the KVO
# answered the list with nothing on it to begin with). An unreachable KVO,
# a refused password, a pending EULA, an operation that failed or ran out
# of time, a list that could not be read: every one of those is reported
# with its reason and the gate runs unchanged.
#
# Every call here is bounded: the list by lic_run's kill timer, the release
# by kvo_license.py's own --timeout. Nothing in this phase can hang the
# teardown, and nothing in it can delete anything.
# =====================================================================

# The KVO's address: --kvo-address, else the public IP the VM reported in
# Phase 2, else its private IP (right from inside the VNet), and as a last
# resort the public IP resource the template names <vm>-pip, for a KVO that
# is stopped and reports no address. Prints the address or nothing; never
# fails.
kvo_address() {
  local a=""
  if [[ -n "$ARG_KVO_ADDRESS" ]]; then printf '%s' "$ARG_KVO_ADDRESS"; return 0; fi
  a="${KVO_PUBLIC_IP:-$KVO_PRIVATE_IP}"
  if [[ -z "$a" && -n "$KVO_VM_NAME" ]]; then
    a="$(det_clean "$(first_line "$(ro_az network public-ip show -g "$RESOURCE_GROUP" \
          -n "${KVO_VM_NAME}-pip" --query ipAddress -o tsv)")")"
  fi
  if [[ ! "$a" =~ ^[A-Za-z0-9.:-]+$ ]]; then a=""; fi
  printf '%s' "$a"
  return 0
}

# lic_py_has_modes FILE: whether FILE is a whole kvo_license.py that carries
# the release modes. Two checks: the --release-all marker (argparse would
# refuse --list without it and the run would read that as an unreachable
# KVO), and the entry point in the last three lines, so a download cut
# short cannot pass as the script: a truncated copy can still parse, and
# then stops somewhere in the middle of a release.
lic_py_has_modes() {
  grep -q -- '--release-all' "$1" 2>/dev/null \
    && tail -n 3 "$1" 2>/dev/null | grep -q 'sys.exit(main())'
}

# scripts/kvo_license.py, wherever this run can get it: a checkout next to
# this script, the clone deploy-stack.sh makes under $HOME, the current
# directory, and failing all of those the raw file from the repo, fetched
# over TLS into a temp dir and kept for this run. A copy that predates the
# release modes is skipped and said so. A fetched copy is checked to be
# whole, to carry the modes and to parse as Python before it is used, and
# LIC_FIND_WHY says which of those it failed. Sets LIC_PY, or leaves it
# empty. Never fails.
LIC_FIND_WHY=""
find_kvo_license_py() {
  local cand="" tmp=""
  LIC_PY=""
  LIC_FIND_WHY=""
  if [[ -n "${CLOUDLENS_KVO_LICENSE_PY:-}" ]]; then
    # An explicit override is honoured or reported, never quietly replaced
    # by some other copy.
    if [[ -f "$CLOUDLENS_KVO_LICENSE_PY" ]]; then
      LIC_PY="$CLOUDLENS_KVO_LICENSE_PY"
    else
      LIC_FIND_WHY="CLOUDLENS_KVO_LICENSE_PY names a file that does not exist"
    fi
    return 0
  fi
  for cand in "$SCRIPT_DIR/../scripts/kvo_license.py" "$HOME/${REPO_NAME}/scripts/kvo_license.py" \
              "$PWD/scripts/kvo_license.py"; do
    if [[ ! -f "$cand" ]]; then continue; fi
    if ! lic_py_has_modes "$cand"; then
      note "skipping ${cand}: it predates the release modes (or is not the whole script)"
      continue
    fi
    LIC_PY="$cand"
    return 0
  done
  if ! command -v curl >/dev/null 2>&1; then
    LIC_FIND_WHY="curl is not available to fetch it"
    return 0
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloudlens-teardown-lic.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$tmp" ]]; then
    LIC_FIND_WHY="no temp dir could be made to fetch it into"
    return 0
  fi
  LIC_CACHE_DIR="$tmp"
  note "scripts/kvo_license.py is not on this machine; fetching it from ${REPO_RAW}"
  if ! curl -fsSL --proto '=https' --max-time 30 -o "$tmp/kvo_license.py" "${REPO_RAW}/scripts/kvo_license.py" 2>/dev/null; then
    LIC_FIND_WHY="it could not be fetched from ${REPO_RAW}"
  elif ! grep -q -- '--release-all' "$tmp/kvo_license.py" 2>/dev/null; then
    LIC_FIND_WHY="the copy at ${REPO_RAW} predates the release modes (no --release-all)"
  elif ! tail -n 3 "$tmp/kvo_license.py" 2>/dev/null | grep -q 'sys.exit(main())'; then
    LIC_FIND_WHY="the fetched copy is not the whole script (its last lines are not the entry point)"
  elif ! python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$tmp/kvo_license.py" 2>/dev/null; then
    LIC_FIND_WHY="the fetched copy does not parse as Python"
  else
    LIC_PY="$tmp/kvo_license.py"
  fi
  return 0
}

# lic_run LIMIT OUTFILE cmd...: run cmd with stdout and stderr in OUTFILE and
# stdin closed, and kill it after LIMIT seconds. LIC_RC is the command's exit
# status, or 124 when it was killed at the bound. Same contract as probe: it
# never fails and never hangs, so a KVO that stopped answering costs a bounded
# wait and a warning, never the run.
lic_run() {
  local limit="$1" out="$2" pid="" ticks=0
  shift 2
  LIC_RC=0
  "$@" >"$out" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (( ticks < limit )); do
    sleep 1
    ticks=$((ticks+1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    LIC_RC=124
    return 0
  fi
  wait "$pid" 2>/dev/null && LIC_RC=0 || LIC_RC=$?
  return 0
}

# What to do when the release did not happen or did not finish clean: the
# gate in Phase 4b runs, and the operator is told the two ways back.
lic_fallback_note() {
  note "Nothing was released. The licence gate below runs as it always has."
  note "To release first: re-run this teardown once the cause is fixed and"
  note "answer yes to the release (or pass --release-licences), or deactivate"
  note "each code in the KVO UI > Settings > Product Licensing, then re-run."
}

# =====================================================================
# Phase 4: confirm the teardown
#
# Asked BEFORE the licences are touched, on purpose. Phase 4a strips the
# KVO of its licences, and a release followed by a "no" here would leave
# a running KVO with nothing on it. So the operator commits to destroying
# the stack first; only then is the KVO in it emptied, and the one
# question left after that is the licence-loss gate (Phase 4b), which
# runs only when the release did not leave the KVO clear.
# =====================================================================
step "Phase 4: Confirm the teardown"
echo
echo "  About to delete, in subscription ${SUBSCRIPTION_NAME:-$SUBSCRIPTION_ID}:"
if [[ "$PLAN" == "group" ]]; then
  echo "    - the whole resource group ${RESOURCE_GROUP} ($(count_lines "$CL_RES_LINES") resources, all CloudLens)"
else
  echo "    - $(count_words "$CL_VM_NAMES") CloudLens VM(s) in ${RESOURCE_GROUP}: ${CL_VM_NAMES:-none}"
  echo "    - their $(count_lines "$CL_DISK_IDS") disk(s), $(count_lines "$CL_NIC_IDS") NIC(s), $(count_lines "$CL_PIP_IDS") public IP(s), $(count_lines "$CL_NSG_IDS") NSG(s), $(count_lines "$CL_VNET_LINES") VNet(s)"
  echo "    - NOT the group, and NOT the $(count_lines "$OTHER_RES_LINES") other resource(s): ${PLAN_WHY}"
fi
if [[ "$HAS_KVO" == "true" ]]; then
  echo "    - the KVO ${KVO_VM_NAME}, with every licence still activated on it. The"
  echo "      next step offers to release them first; whatever is not released is"
  echo "      stranded for good when the KVO is deleted."
fi
echo

if [[ "$DRY_RUN" == "true" ]]; then
  dryrun_say "a real run would ask for confirmation here (or require --yes)"
elif [[ "$INTERACTIVE" == "true" ]]; then
  if ! ask_yn "  Proceed with the teardown? [y/N]: " "n"; then
    fail "Aborted. Nothing was deleted, and no licence was released."
  fi
elif [[ "$ASSUME_YES" == "true" ]]; then
  ok "Proceeding (--yes)."
else
  fail "No terminal to confirm on and --yes was not given, so nothing was deleted.
  Re-run with --yes to confirm, or with --audit to see what is there without
  deleting anything."
fi

# =====================================================================
# Phase 4a: release the KVO's licences (see the helpers above for why)
# =====================================================================
if [[ "$HAS_KVO" == "true" ]]; then
  step "Phase 4a: Release KVO licences"
  echo "  This group has a KVO. The licence counts activated on it can be returned"
  echo "  to your entitlement NOW, while the KVO is alive, and never after it is"
  echo "  deleted. This script can release them for you (the licensing API's"
  echo "  deactivate operation, what Settings > Product Licensing > Deactivate"
  echo "  licenses does), and asks before it does."
  echo
  KVO_ADDR="$(kvo_address)"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "KVO address: ${KVO_ADDR:-not found (no public or private IP on ${KVO_VM_NAME}, no ${KVO_VM_NAME}-pip)}"
    dryrun_say "would run scripts/kvo_license.py --list against it, then offer to release every"
    dryrun_say "licence it holds with --release-all (asked on a terminal, --release-licences without one)"
    dryrun_say "a real run skips the licence-loss gate below only when the release leaves the KVO clear"
    dryrun_say "nothing is called on the KVO in a dry run"
  elif [[ -z "$KVO_ADDR" ]]; then
    warn "Could not find the KVO's address: ${KVO_VM_NAME} reports no public or private"
    warn "IP (is it deallocated?), and there is no ${KVO_VM_NAME}-pip to read."
    note "Pass it with --kvo-address ADDR (its public IP, or private from inside the VNet)."
    lic_fallback_note
  elif ! command -v python3 >/dev/null 2>&1; then
    warn "python3 is not available here, and the release runs through scripts/kvo_license.py."
    lic_fallback_note
  else
    find_kvo_license_py
    if [[ -z "$LIC_PY" ]]; then
      warn "No usable scripts/kvo_license.py: ${LIC_FIND_WHY:-none found on this machine}."
      lic_fallback_note
    else
      # Credentials: flags, then the deploy's env names, then a prompt with the
      # KVO's defaults offered. The password is read without echo, passed to
      # the script through the environment (never a command line), and never
      # written anywhere: not a state file, not a log.
      KVO_USER="${ARG_KVO_USER:-${CLOUDLENS_KVO_ADMIN_USER:-}}"
      KVO_PASS="${ARG_KVO_PASS:-${CLOUDLENS_KVO_ADMIN_PASS:-}}"
      if [[ "$INTERACTIVE" == "true" ]]; then
        echo "  KVO at ${KVO_ADDR}. Its admin login is needed to list and release the licences."
        if [[ -z "$KVO_USER" ]]; then
          KVO_USER="$(ask "  KVO admin user [admin]: " "admin")"
        fi
        if [[ -z "$KVO_PASS" ]]; then
          read -rsp "  KVO admin password [admin]: " KVO_PASS || true
          echo
          if [[ -z "$KVO_PASS" ]]; then KVO_PASS="admin"; fi
        fi
      fi
      if [[ -z "$KVO_USER" ]]; then KVO_USER="admin"; fi
      if [[ -z "$KVO_PASS" ]]; then KVO_PASS="admin"; fi
      export CLOUDLENS_KVO_ADMIN_PASS="$KVO_PASS"
      LIC_ARGS=(--kvo "$KVO_ADDR" --user "$KVO_USER" --password-env CLOUDLENS_KVO_ADMIN_PASS
                --insecure --http-timeout "$KVO_HTTP_TIMEOUT")

      _lic_out="$(mktemp "${TMPDIR:-/tmp}/cloudlens-teardown-lic.XXXXXX" 2>/dev/null || true)"
      if [[ -z "$_lic_out" ]]; then
        warn "Could not create a temp file for the licence list."
        lic_fallback_note
      else
        note "Listing the licences on KVO ${KVO_ADDR} (bounded: ${KVO_HTTP_TIMEOUT}s per call)..."
        # token + list, each bounded by the script, and the whole thing by
        # the kill timer in case the KVO answers nothing at all
        lic_run $(( KVO_HTTP_TIMEOUT * 3 + 5 )) "$_lic_out" python3 "$LIC_PY" "${LIC_ARGS[@]}" --list --json
        # The count is the JSON object on the last line (see LIC_COUNT_PARSE).
        # Anything but a whole number from that parse is "could not tell",
        # fail closed: nothing is released on it and the gate runs. The
        # lines before it are the script's own report, shown as they are.
        _lic_n="$(tail -n 1 "$_lic_out" 2>/dev/null | python3 -c "$LIC_COUNT_PARSE" 2>/dev/null || true)"
        if [[ "$_lic_n" =~ ^[0-9]+$ ]]; then
          sed '$d' "$_lic_out" 2>/dev/null | sed 's/^/    /' || true
        else
          _lic_n=""
          sed 's/^/    /' "$_lic_out" 2>/dev/null || true
        fi
        rm -f "$_lic_out" 2>/dev/null || true
        _lic_out=""

        case "$LIC_RC" in
          0)
            if [[ "${_lic_n:-}" == "0" ]]; then
              ok "The KVO holds no licences. Nothing to release, nothing will be stranded."
              LIC_RELEASED=true
              LIC_WHY="held nothing"
            elif [[ -z "${_lic_n:-}" ]]; then
              warn "Could not tell how many licences the KVO holds: kvo_license.py's summary"
              warn "line did not parse (its output is above). Not releasing on a guess."
              lic_fallback_note
            else
              _go=false
              if [[ "$INTERACTIVE" == "true" ]]; then
                # Default yes: releasing is the safe direction. The counts go
                # back to the entitlement and can be activated again anywhere.
                if ask_yn "  Release all ${_lic_n} licences from this KVO now? [Y/n]: " "y"; then _go=true; fi
              elif [[ "$RELEASE_LICENCES" == "true" ]]; then
                note "Releasing all ${_lic_n} licences (--release-licences)."
                _go=true
              else
                note "No terminal to ask on and no --release-licences: not releasing."
                note "Pass --release-licences to release them without a prompt."
              fi
              if [[ "$_go" == "true" ]]; then
                note "Each deactivate goes to the Keysight licensing backend and can take up"
                note "to a minute; progress is printed per licence. Bounded: ${KVO_RELEASE_TIMEOUT}s overall."
                _rel_rc=0
                python3 "$LIC_PY" "${LIC_ARGS[@]}" --release-all --timeout "$KVO_RELEASE_TIMEOUT" </dev/null || _rel_rc=$?
                case "$_rel_rc" in
                  0)
                    ok "All ${_lic_n} licences released. The KVO reports none left: nothing will be stranded."
                    LIC_RELEASED=true
                    LIC_WHY="released" ;;
                  3)
                    warn "The release did not leave the KVO clear (the reasons are above): an"
                    warn "operation failed or its outcome is unknown, or licences remain."
                    lic_fallback_note ;;
                  6)
                    warn "The KVO refused the login or stopped answering during the release."
                    lic_fallback_note ;;
                  *)
                    warn "kvo_license.py exited ${_rel_rc} during the release."
                    lic_fallback_note ;;
                esac
              else
                lic_fallback_note
              fi
            fi ;;
          6)
            warn "KVO ${KVO_ADDR} could not be used: unreachable within ${KVO_HTTP_TIMEOUT}s, the"
            warn "password was refused, or its EULA is pending (the reason is above)."
            note "Check the address (--kvo-address) and the login (--kvo-admin-user / --kvo-admin-pass,"
            note "or CLOUDLENS_KVO_ADMIN_USER / CLOUDLENS_KVO_ADMIN_PASS)."
            lic_fallback_note ;;
          124)
            warn "KVO ${KVO_ADDR} did not answer within $(( KVO_HTTP_TIMEOUT * 3 + 5 ))s; gave up listing its licences."
            lic_fallback_note ;;
          3)
            warn "The KVO's licence list could not be read (the reason is above)."
            lic_fallback_note ;;
          *)
            warn "kvo_license.py exited ${LIC_RC} while listing the licences."
            lic_fallback_note ;;
        esac
      fi
      unset CLOUDLENS_KVO_ADMIN_PASS KVO_PASS
      ARG_KVO_PASS=""
    fi
  fi
fi

# =====================================================================
# Phase 4b: the licence-loss gate
#
# Only when the group has a KVO, and always before the first delete.
# Phase 4a can waive it, and only by reporting the KVO clear; every other
# outcome leaves it exactly as it was: the red warning and the typed
# resource group name, or --accept-licence-loss with no terminal.
# =====================================================================
if [[ "$HAS_KVO" == "true" ]]; then
  step "Phase 4b: Confirm the licence loss"
fi
if [[ "$HAS_KVO" == "true" && "$LIC_RELEASED" == "true" ]]; then
  case "$LIC_WHY" in
    released) ok "Phase 4a released every licence, and the KVO reports none left: nothing will" ;;
    *)        ok "Phase 4a found the KVO held nothing, and it reports none left: nothing will" ;;
  esac
  ok "be stranded, so no licence-loss confirmation is needed."
elif [[ "$HAS_KVO" == "true" ]]; then
  echo
  echo -e "${C_RED}${C_BOLD}  LICENCES ARE ABOUT TO BE STRANDED, PERMANENTLY.${C_RESET}"
  echo
  echo "  This group contains a KVO. KVO activation codes are bound to the KVO"
  echo "  host they were activated on. While that host is alive the counts CAN"
  echo "  be released: this script offers to do it (Phase 4a above, or"
  echo "  --release-licences with no terminal), and the KVO UI can too"
  echo "  (Settings > Product Licensing > Deactivate licenses). Both drive the"
  echo "  licensing API's deactivate operation: proven, 20 counts recovered."
  echo "  Deleting the VM destroys that host, and the quantity still activated"
  echo "  on it is NOT returned afterwards: it is stranded for good."
  echo
  echo "  This is not theoretical. Three activation codes worth 500 counts each"
  echo "  came back availableQuantity=0 after the KVO they were activated on was"
  echo "  deleted: 1500 counts lost, with nothing anywhere warning it would happen."
  echo
  echo "  Get them back FIRST, if you ever want them:"
  echo "    re-run this teardown and answer yes to the release in Phase 4a"
  echo "    (or pass --release-licences), or deactivate each code in the"
  echo "    KVO UI > Settings > Product Licensing, then re-run this teardown."
  echo "  The release above did not happen or did not leave the KVO clear; the"
  echo "  reason is printed in Phase 4a."
  echo
  echo "  Continuing destroys the KVO and every licence count activated on it."
  echo
  if [[ "$INTERACTIVE" == "true" ]]; then
    _typed="$(ask "  Type the resource group name '${RESOURCE_GROUP}' to accept the licence loss: " "")"
    if [[ "$_typed" != "$RESOURCE_GROUP" ]]; then
      fail "Not confirmed (got '${_typed}'). Nothing was deleted."
    fi
    ok "Licence loss accepted."
  elif [[ "$ACCEPT_LICENCE_LOSS" == "true" ]]; then
    ok "Licence loss accepted (--accept-licence-loss)."
  elif [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "a real run would stop here and require --accept-licence-loss"
  else
    fail "This group has a KVO and there is no terminal to confirm on.
  Deleting it strands the licence quantity activated on it, permanently.
  Release the licences first, with --yes --release-licences (this script
  does it; a release that leaves the KVO clear needs no other flag) or in
  the KVO UI, or accept the loss with:
    --yes --accept-licence-loss"
  fi
fi

# =====================================================================
# Phase 5: delete
# =====================================================================
step "Phase 5: Delete"

# vnet_other_users NAME: the ipConfiguration ids still in NAME's subnets that
# do NOT belong to a CloudLens NIC. Anything printed means another NIC,
# possibly from another group, still lives in the VNet and it must stay.
# Works before and after our own NICs are deleted, so --dry-run can answer
# it too. Empty on a failed probe, which reads as "no other user": the
# delete itself then fails on Azure's own dependency check and is reported,
# so a lost probe cannot delete anything Azure would not.
vnet_other_users() {
  local ids="" id="" nic="" nicl="" out=""
  ids="$(ro_az network vnet show -g "$RESOURCE_GROUP" -n "$1" --query "subnets[].ipConfigurations[].id" -o tsv)"
  for id in $(tokens "$ids"); do
    # .../networkInterfaces/<nic>/ipConfigurations/<cfg>
    nic="${id%/ipConfigurations/*}"
    nicl="$(to_lower "$nic")"
    if printf '%s\n' "$CL_NIC_IDS" | tr '[:upper:]' '[:lower:]' | grep -qx -- "$nicl" 2>/dev/null; then continue; fi
    out="${out}${out:+ }$(id_name "$nic")"
  done
  printf '%s' "$out"
  return 0
}

wait_for_group_gone() {
  local waited=0 interval=15 last_report=0 st=""
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "would poll 'az group exists -n ${RESOURCE_GROUP}' every ${interval}s for up to $(( DELETE_TIMEOUT / 60 )) minutes"
    GROUP_GONE=true
    return 0
  fi
  while (( waited < DELETE_TIMEOUT )); do
    st="$(to_lower "$(first_line "$(ro_az group exists -n "$RESOURCE_GROUP" -o tsv)")")"
    if [[ "$st" == "false" ]]; then GROUP_GONE=true; return 0; fi
    if (( waited - last_report >= 120 )); then
      note "still deleting ($(( waited / 60 ))m elapsed)"
      last_report="$waited"
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
  done
  return 2
}

if [[ "$PLAN" == "group" ]]; then
  # --no-wait and a poll of our own instead of az's blocking delete: the
  # blocking form gives no progress for up to half an hour, and a Ctrl+C in
  # it leaves the operator unsure whether the delete was ever accepted.
  if del_az group delete -n "$RESOURCE_GROUP" --yes --no-wait; then
    ok "Delete requested for resource group ${RESOURCE_GROUP}"
  else
    fail "az group delete was rejected: ${DEL_ERR}"
  fi
  note "Waiting for the group to go (a stack takes 5 to 15 minutes)."
  _rc=0; wait_for_group_gone || _rc=$?
  if (( _rc == 0 )); then
    ok "Resource group ${RESOURCE_GROUP} deleted."
    DELETED_VMS="$(count_words "$CL_VM_NAMES")"
    DELETED_DISKS="$(count_lines "$CL_DISK_IDS")"; DELETED_NICS="$(count_lines "$CL_NIC_IDS")"
    DELETED_PIPS="$(count_lines "$CL_PIP_IDS")"; DELETED_NSGS="$(count_lines "$CL_NSG_IDS")"
    DELETED_VNETS="$(count_lines "$CL_VNET_LINES")"
  else
    warn "Resource group ${RESOURCE_GROUP} still exists after $(( DELETE_TIMEOUT / 60 )) minutes."
    note "Azure is usually still deleting it. Check with: az group show -n ${RESOURCE_GROUP}"
    note "Re-run this teardown later: it removes whatever is left."
    record_failure "$RESOURCE_GROUP" "still present after ${DELETE_TIMEOUT}s"
  fi
else
  # ---- VMs first: everything else hangs off them ------------------------
  if [[ -n "$CL_VM_IDS" ]]; then
    _vm_ids=""
    while IFS=$'\t' read -r _vn _vp _vid _rest; do
      if [[ -n "${_vn:-}" ]]; then _vm_ids="${_vm_ids}${_vm_ids:+ }${_vid}"; fi
    done <<< "$CL_VM_LINES"
    note "Deleting $(count_words "$_vm_ids") VM(s) (${CL_VM_NAMES}); each takes a minute or two."
    # One call for all of them: az deletes --ids in parallel. On a failure
    # each VM is retried alone so the failure is attributed to the VM that
    # caused it, skipping the ones the batch did remove.
    if del_az vm delete --ids $_vm_ids --yes; then
      ok "$(did) VMs: ${CL_VM_NAMES}"
      DELETED_VMS="$(count_words "$_vm_ids")"
    else
      warn "batch VM delete failed: ${DEL_ERR}; retrying one at a time"
      for _vid in $_vm_ids; do
        _still="$(det_clean "$(first_line "$(ro_az vm show --ids "$_vid" --query name -o tsv)")")"
        if [[ -z "$_still" ]]; then
          ok "deleted VM $(id_name "$_vid")"
          DELETED_VMS=$(( DELETED_VMS + 1 ))
          continue
        fi
        if del_az vm delete --ids "$_vid" --yes; then
          ok "$(did) VM $(id_name "$_vid")"
          DELETED_VMS=$(( DELETED_VMS + 1 ))
        else
          warn "could not delete VM $(id_name "$_vid"): ${DEL_ERR}"
          record_failure "VM $(id_name "$_vid")" "$DEL_ERR"
        fi
      done
    fi
  fi

  # ---- then what the VMs leave behind, in dependency order -------------
  # A NIC holds its public IP and NSG and sits in a subnet, so NICs go
  # before public IPs, NSGs and VNets. Disks detach when the VM delete
  # completes, so they can go straight after the VMs.
  #
  # Stacks from templates that set deleteOption take the OS disk, NICs and
  # public IPs with the VM. The group is re-listed once the VMs are gone
  # and what is already missing is skipped, not reported as a failure. An
  # empty re-list (a failed probe, or a group with nothing left) means
  # "unknown": every id is attempted, and Azure's own NotFound is read as
  # gone as well.
  AFTER_LINES=""
  if [[ "$DRY_RUN" != "true" ]]; then
    AFTER_LINES="$(ro_az resource list -g "$RESOURCE_GROUP" --query "[].[name, type, id]" -o tsv)"
  fi
  gone_with_vm() {
    if [[ -z "$AFTER_LINES" ]]; then return 1; fi
    if printf '%s\n' "$AFTER_LINES" | tr '[:upper:]' '[:lower:]' | grep -q -- $'\t'"$(to_lower "$1")"'$' 2>/dev/null; then
      return 1
    fi
    return 0
  }
  # del_leftover KIND ID: 0 when the resource is gone (deleted now, or
  # already), 1 when it is still there and the failure has been recorded.
  del_leftover() {
    local kind="$1" id="$2" name
    name="$(id_name "$id")"
    if [[ "$DRY_RUN" != "true" ]] && gone_with_vm "$id"; then
      ok "${kind} ${name} went with its VM (deleteOption)"
      return 0
    fi
    if del_az resource delete --ids "$id"; then
      ok "$(did) ${kind} ${name}"
      return 0
    fi
    case "$DEL_ERR" in
      *NotFound*|*"not found"*|*"could not be found"*)
        ok "${kind} ${name} was already gone"
        DEL_ERR=""
        return 0 ;;
    esac
    warn "could not delete ${kind} ${name}: ${DEL_ERR}"
    record_failure "${kind} ${name}" "$DEL_ERR"
    return 1
  }
  for _id in $(tokens "$CL_DISK_IDS"); do
    if del_leftover disk "$_id"; then DELETED_DISKS=$(( DELETED_DISKS + 1 )); fi
  done
  for _id in $(tokens "$CL_NIC_IDS"); do
    if del_leftover NIC "$_id"; then DELETED_NICS=$(( DELETED_NICS + 1 )); fi
  done
  for _id in $(tokens "$CL_PIP_IDS"); do
    if del_leftover "public IP" "$_id"; then DELETED_PIPS=$(( DELETED_PIPS + 1 )); fi
  done
  for _id in $(tokens "$CL_NSG_IDS"); do
    if del_leftover NSG "$_id"; then DELETED_NSGS=$(( DELETED_NSGS + 1 )); fi
  done
  # VNets last, and only when no NIC that is not ours still lives in them:
  # a VNet a customer VM sits in is theirs now, whatever it was named.
  while IFS=$'\t' read -r _vname _vid; do
    if [[ -z "${_vname:-}" ]]; then continue; fi
    _users="$(vnet_other_users "$_vname")"
    if [[ -n "$_users" ]]; then
      warn "keeping VNet ${_vname}: still used by NIC(s) that are not CloudLens: ${_users}"
      KEPT_VNETS="${KEPT_VNETS}${KEPT_VNETS:+ }${_vname}"
      continue
    fi
    if del_az resource delete --ids "$_vid"; then
      ok "$(did) VNet ${_vname}"; DELETED_VNETS=$(( DELETED_VNETS + 1 ))
    else
      warn "could not delete VNet ${_vname}: ${DEL_ERR}"; record_failure "VNet ${_vname}" "$DEL_ERR"
    fi
  done <<< "$CL_VNET_LINES"
fi

# =====================================================================
# Phase 6: verify, then the summary
# =====================================================================
step "Phase 6: Verify"
_left=""
if [[ "$DRY_RUN" == "true" ]]; then
  dryrun_say "would re-list ${RESOURCE_GROUP} and report any of the CloudLens set still present"
elif [[ "$PLAN" == "group" && "$GROUP_GONE" == "true" ]]; then
  ok "Resource group ${RESOURCE_GROUP} no longer exists."
else
  _now="$(ro_az resource list -g "$RESOURCE_GROUP" --query "[].[name, type, id]" -o tsv)"
  if [[ -n "$_now" && -n "$CL_RES_LINES" ]]; then
    while IFS=$'\t' read -r _rn _rt _rid; do
      if [[ -z "${_rn:-}" ]]; then continue; fi
      _ridl="$(to_lower "$_rid")"
      if printf '%s\n' "$_now" | tr '[:upper:]' '[:lower:]' | grep -q -- $'\t'"${_ridl}"'$' 2>/dev/null; then
        _left="${_left}${_left:+$'\n'}    ${_rn}  (${_rt})"
      fi
    done <<< "$CL_RES_LINES"
  fi
  if [[ -n "$_left" ]]; then
    warn "CloudLens resources still in ${RESOURCE_GROUP}:"
    printf '%s\n' "$_left"
  elif [[ -z "$_now" && -z "$FAILED_ITEMS" ]]; then
    ok "Nothing left in ${RESOURCE_GROUP} (or it could not be listed; check with: az resource list -g ${RESOURCE_GROUP} -o table)"
  else
    ok "None of the CloudLens set remains in ${RESOURCE_GROUP}."
  fi
fi

step "Teardown summary"
_lbl="deleted"
if [[ "$DRY_RUN" == "true" ]]; then _lbl="would delete"; fi
echo "  Subscription:       ${SUBSCRIPTION_NAME:-$SUBSCRIPTION_ID}"
echo "  Resource group:     ${RESOURCE_GROUP} ($(if [[ "$PLAN" == "group" ]]; then if [[ "$GROUP_GONE" == "true" ]]; then printf '%s' "$_lbl"; else printf 'still present'; fi; else printf 'kept: %s' "$PLAN_WHY"; fi))"
echo "  VMs ${_lbl}:        ${DELETED_VMS}"
echo "  Disks:              ${DELETED_DISKS}"
echo "  NICs:               ${DELETED_NICS}"
echo "  Public IPs:         ${DELETED_PIPS}"
echo "  NSGs:               ${DELETED_NSGS}"
echo "  VNets:              ${DELETED_VNETS}$(if [[ -n "$KEPT_VNETS" ]]; then printf ' (kept, in use by others: %s)' "$KEPT_VNETS"; fi)"
if [[ "$HAS_KVO" == "true" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  KVO licences:       not touched (dry run)"
  elif [[ "$LIC_RELEASED" == "true" ]]; then
    echo "  KVO licences:       ${LIC_WHY}, KVO reported clear"
  else
    echo "  KVO licences:       NOT released (the loss was accepted in Phase 4b)"
  fi
fi
if [[ -n "$FAILED_ITEMS" ]]; then
  echo
  warn "Some resources could not be removed:"
  printf '%s\n' "$FAILED_ITEMS"
  note "Fix the cause and re-run this teardown; it removes whatever is left."
fi
if [[ "$DRY_RUN" == "true" ]]; then
  echo
  warn "DRY RUN: nothing above was actually deleted, and the KVO was not touched."
fi
echo
note "Sensors are NOT removed by this script: they live on the workload VMs, not"
note "in this group. Remove them with: bash scripts/cleanup.sh customer_input.yaml"
echo
SCRIPT_DONE=true
if [[ -n "$FAILED_ITEMS" ]]; then exit 2; fi
exit 0

}   # End of brace-wrap for curl|bash safety
