#!/usr/bin/env bash
# =====================================================================
# CloudLens Stack Deployment: vController + KVO + vPB + Sensors
# (vController is the new name for what used to be called CLMS)
# =====================================================================
# IMPORTANT: the entire script is wrapped in a { ... } brace block so
# bash buffers the WHOLE thing from stdin before executing any of it.
# Without this, when invoked via `curl ... | bash`, bash would start
# executing partially-read content. The first `exec < /dev/tty` would
# then close the pipe while curl was still writing to it, producing:
#   curl: (56) Failure writing output to destination, passed N returned 0
# The closing brace lives on the last line of the file.
{
# One paste, full stack. Detects Azure Cloud Shell vs local, accepts
# Marketplace terms, deploys CLMS, waits for init, optionally adds vPB,
# and chains into the sensor playbook via quickstart.sh.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/deploy/deploy-stack.sh | bash
#   OR
#   bash deploy/deploy-stack.sh [--dry-run]
#
# Flags:
#   --dry-run        Walk the prompts, print every az command, touch nothing
#   --resource-group RG_NAME
#   --location       REGION (e.g. eastus2)
#   --no-vpb         Skip vPB deployment
#   --no-sensors     Skip sensor chain at the end
#   -h | --help      Show this banner and exit
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------------
# Re-attach stdin to the terminal when invoked via `curl ... | bash`.
# Without this, every `read` would try to consume bytes from the curl
# pipe (which is the script itself), so the very first prompt fails.
# ---------------------------------------------------------------------
if [[ ! -t 0 ]] && [[ -e /dev/tty ]]; then
  exec < /dev/tty
fi

# ---------------------------------------------------------------------
# Config + globals
# ---------------------------------------------------------------------
REPO_OWNER="Keysight-Tech"
REPO_NAME="cloudlens-ansible-azure"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

CLMS_TEMPLATE_URL="${REPO_RAW}/deploy/clms-marketplace.json"
KVO_TEMPLATE_URL="${REPO_RAW}/deploy/kvo-marketplace.json"
VPB_TEMPLATE_URL="${REPO_RAW}/deploy/vpb-marketplace.json"

# vController (formerly CLMS) marketplace coordinates
CLMS_PUBLISHER="keysight-technologies-cloudlens"
CLMS_OFFER="keysight-cloudlens-vcontroller"
CLMS_PLAN="cloudlens-vcontroller-6-14-0_89"

# KVO (Keysight Vision Orchestrator) marketplace coordinates
KVO_PUBLISHER="keysight-technologies-kvop"
KVO_OFFER="keysight-vision-orchestrator"
KVO_PLAN="keysight_vision_orchestrator_3-0-0_55"

VPB_PUBLISHER="keysight-technologies-cloudlens"
VPB_OFFER="keysight-cloudlens-virtual-packet-broker"
VPB_PLAN="cloudlens-virtual-packet-broker-3-15-0_1"

# All defaults below are env-var overridable. Customer can:
#   - Just paste the curl line: gets the defaults below
#   - Set env vars first: CLOUDLENS_RG=my-rg CLOUDLENS_REGION=westeu curl ... | bash
#   - Pass flags:  bash deploy-stack.sh --location westeu --vcontroller-size Standard_D8s_v5
# No values are baked in. Every knob can be changed without editing the file.
DEFAULT_RG="${CLOUDLENS_RG:-cloudlens-rg}"
DEFAULT_LOCATION="${CLOUDLENS_REGION:-eastus2}"
DEFAULT_CLMS_NAME="${CLOUDLENS_VCONTROLLER_NAME:-vcontroller}"
DEFAULT_KVO_NAME="${CLOUDLENS_KVO_NAME:-kvo}"
DEFAULT_VPB_NAME="${CLOUDLENS_VPB_NAME:-vpb}"
DEFAULT_ADMIN_USER="${CLOUDLENS_ADMIN_USER:-azureuser}"

CLMS_VM_SIZE="${CLOUDLENS_VCONTROLLER_SIZE:-Standard_D4s_v5}"
KVO_VM_SIZE="${CLOUDLENS_KVO_SIZE:-Standard_D4s_v5}"
VPB_VM_SIZE="${CLOUDLENS_VPB_SIZE:-Standard_D8s_v3}"

# Rollback behavior: when ROLLBACK_ON_FAIL=true, the on_error trap will
# delete the resource group on failure - BUT only if we created it ourselves
# this run (CREATED_RG=true). Pre-existing RGs supplied via --resource-group
# are NEVER deleted by rollback. Default off so customers preserve partial
# progress and re-run idempotently.
ROLLBACK_ON_FAIL="${CLOUDLENS_ROLLBACK_ON_FAIL:-false}"

# Per-product instance counts and vPB NIC counts (1 each by default)
CLMS_COUNT="${CLOUDLENS_VCONTROLLER_COUNT:-1}"
KVO_COUNT="${CLOUDLENS_KVO_COUNT:-1}"
VPB_COUNT="${CLOUDLENS_VPB_COUNT:-1}"
VPB_INGRESS_NICS="${CLOUDLENS_VPB_INGRESS_NICS:-1}"
VPB_EGRESS_NICS="${CLOUDLENS_VPB_EGRESS_NICS:-1}"

SUMMARY_FILE="cloudlens-deploy-summary.txt"
LOG_FILE="cloudlens-deploy-stack.log"

# Flag defaults (set by argument parser)
DRY_RUN=false
DEPLOY_KVO=""
DEPLOY_VPB=""
CHAIN_SENSORS=""
ARG_RG=""
ARG_LOCATION=""

# State trackers (filled as we go) for trap reporting
PHASE_NAME="init"
CREATED_RG=false
DEPLOYED_CLMS=false
DEPLOYED_KVO=false
DEPLOYED_VPB=false
CLMS_PUBLIC_IP=""
KVO_PUBLIC_IP=""
VPB_PUBLIC_IP=""
ADMIN_USERNAME="azureuser"
ADMIN_PASSWORD=""

# ---------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'
  C_RED='\033[0;31m'; C_GREY='\033[0;90m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RED=''; C_GREY=''; C_BOLD=''; C_RESET=''
fi

banner() {
  local msg="$1"
  echo -e "${C_BLUE}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  printf "${C_BLUE}║${C_RESET}  ${C_BOLD}%-60s${C_RESET}${C_BLUE}║${C_RESET}\n" "$msg"
  echo -e "${C_BLUE}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
}
ok()    { echo -e "${C_GREEN}\xE2\x9C\x93${C_RESET} $1"; }
warn()  { echo -e "${C_YELLOW}\xE2\x9A\xA0${C_RESET} $1"; }
fail()  { echo -e "${C_RED}\xE2\x9C\x97${C_RESET} $1" >&2; exit 1; }
step()  { echo; echo -e "${C_BLUE}\xE2\x94\x80\xE2\x94\x80\xE2\x94\x80 $1 \xE2\x94\x80\xE2\x94\x80\xE2\x94\x80${C_RESET}"; PHASE_NAME="$1"; }
note()  { echo -e "${C_GREY}\xE2\x86\x92 $1${C_RESET}"; }
dryrun_say() { echo -e "${C_YELLOW}[dry-run]${C_RESET} $1"; }

# POSIX-portable lowercase (bash 3.2 compatible)
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------
# Logging: tee everything to log file
# ---------------------------------------------------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------
show_help() {
  cat <<'HLP'
CloudLens Stack Deployment

Usage:
  bash deploy/deploy-stack.sh [options]

Options:
  --dry-run                 Walk through prompts and print would-be az commands
                            without touching Azure. Safe to run anywhere.

Naming + region (all have sensible defaults, all overridable):
  --resource-group NAME     Resource group           (default: cloudlens-rg)
  --location REGION         Azure region             (default: eastus2)
  --admin-user NAME         OS admin username        (default: azureuser)
  --vcontroller-name NAME   vController VM prefix    (default: vcontroller)
  --kvo-name NAME           KVO VM prefix            (default: kvo)
  --vpb-name NAME           vPB VM prefix            (default: vpb)

VM sizes (override if your prod workload is bigger):
  --vcontroller-size SKU    vController VM size      (default: Standard_D4s_v5)
  --kvo-size SKU            KVO VM size              (default: Standard_D4s_v5)
  --vpb-size SKU            vPB VM size              (default: Standard_D8s_v3)

Per-product instance counts (HA / multi-region / scale-out):
  --vcontroller-count N     Number of vControllers   (1-3, default: 1)
  --kvo-count N             Number of KVOs           (1-2, default: 1)
  --vpb-count N             Number of vPBs           (1-5, default: 1)

vPB multi-NIC (fan-in / fan-out for prod):
  --vpb-ingress-nics N      Number of ingress NICs   (1-3, default: 1)
  --vpb-egress-nics N       Number of egress NICs    (1-3, default: 1)

Toggles:
  --no-kvo                  Skip KVO deployment
  --with-kvo                Deploy KVO (skip interactive prompt)
  --no-vpb                  Skip vPB deployment
  --no-sensors              Skip sensor playbook chain at the end
  --rollback                On any failure, delete the resource group we
                            created (NEVER touches pre-existing RGs).
                            5-second grace window to Ctrl+C the rollback.
                            Default: off (keep partial progress, re-run is idempotent).
  --no-rollback             Force keep-partial behavior (default).
  -h, --help                Show this help

Env-var overrides (alternative to flags, useful for curl | bash):
  CLOUDLENS_RG, CLOUDLENS_REGION, CLOUDLENS_ADMIN_USER,
  CLOUDLENS_VCONTROLLER_NAME / _SIZE / _COUNT,
  CLOUDLENS_KVO_NAME / _SIZE / _COUNT,
  CLOUDLENS_VPB_NAME / _SIZE / _COUNT,
  CLOUDLENS_VPB_INGRESS_NICS, CLOUDLENS_VPB_EGRESS_NICS

Example (full prod-style invocation):
  CLOUDLENS_RG=prod-cloudlens-rg CLOUDLENS_REGION=westeurope \\
  curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/deploy/deploy-stack.sh \\
  | bash -s -- --vcontroller-count 2 --kvo-count 2 --vpb-count 3 \\
                --vpb-ingress-nics 2 --vpb-egress-nics 3 \\
                --vpb-size Standard_D16s_v3

What it does (phases):
  1. Banner + environment detection (Cloud Shell vs local)
  2. Pre-flight checks (az CLI, subscription access, quota)
  3. Customer input (resource group, region, admin password)
  4. Marketplace terms acceptance (vController + KVO + vPB as selected)
  5. Resource group creation (skipped if exists)
  6. vController deployment via ARM template (formerly CLMS)
  7. Wait for vController to initialize (~15 minutes)
  8. KVO deployment (optional, orchestrator for vPB fleets)
  9. vPB deployment (optional)
 10. Manual project key step (from vController UI)
 11. Sensor chain (optional, runs quickstart.sh)
 12. Final summary written to cloudlens-deploy-summary.txt
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;

    # Toggles
    --no-kvo) DEPLOY_KVO=false; shift ;;
    --with-kvo) DEPLOY_KVO=true; shift ;;
    --no-vpb) DEPLOY_VPB=false; shift ;;
    --no-sensors) CHAIN_SENSORS=false; shift ;;

    # Rollback control
    --rollback) ROLLBACK_ON_FAIL=true; shift ;;
    --no-rollback) ROLLBACK_ON_FAIL=false; shift ;;

    # Naming + region
    --resource-group) ARG_RG="$2"; shift 2 ;;
    --location) ARG_LOCATION="$2"; shift 2 ;;
    --admin-user) DEFAULT_ADMIN_USER="$2"; shift 2 ;;
    --vcontroller-name) DEFAULT_CLMS_NAME="$2"; shift 2 ;;
    --kvo-name) DEFAULT_KVO_NAME="$2"; shift 2 ;;
    --vpb-name) DEFAULT_VPB_NAME="$2"; shift 2 ;;

    # VM sizes
    --vcontroller-size) CLMS_VM_SIZE="$2"; shift 2 ;;
    --kvo-size) KVO_VM_SIZE="$2"; shift 2 ;;
    --vpb-size) VPB_VM_SIZE="$2"; shift 2 ;;

    # Per-product counts
    --vcontroller-count) CLMS_COUNT="$2"; shift 2 ;;
    --kvo-count) KVO_COUNT="$2"; shift 2 ;;
    --vpb-count) VPB_COUNT="$2"; shift 2 ;;

    # vPB multi-NIC
    --vpb-ingress-nics) VPB_INGRESS_NICS="$2"; shift 2 ;;
    --vpb-egress-nics) VPB_EGRESS_NICS="$2"; shift 2 ;;

    -h|--help) show_help; exit 0 ;;
    *) warn "Unknown argument: $1"; show_help; exit 1 ;;
  esac
done

# Validate count bounds (matches ARM template allowedValues)
for v in CLMS_COUNT:1:3 KVO_COUNT:1:2 VPB_COUNT:1:5 VPB_INGRESS_NICS:1:3 VPB_EGRESS_NICS:1:3; do
  name="${v%%:*}"; rest="${v#*:}"; lo="${rest%%:*}"; hi="${rest##*:}"
  val="${!name}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < lo || val > hi )); then
    fail "$name must be an integer between $lo and $hi (got '$val'). Run with -h for usage."
  fi
done

# Use ADMIN_USERNAME (already declared) for the OS admin user from now on
ADMIN_USERNAME="$DEFAULT_ADMIN_USER"

# ---------------------------------------------------------------------
# Run az (or echo it in dry-run)
# ---------------------------------------------------------------------
run_az() {
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "az $*"
    return 0
  fi
  az "$@"
}

# Run az with stdout captured (used for outputs like IPs)
run_az_capture() {
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "az $* (would capture stdout)"
    echo "DRY_RUN_VALUE"
    return 0
  fi
  az "$@"
}

# ---------------------------------------------------------------------
# Error trap: explain partial state, point at cleanup
# ---------------------------------------------------------------------
on_error() {
  local exit_code=$?
  echo
  echo -e "${C_RED}\xE2\x9C\x97 FAILED in phase: ${PHASE_NAME}${C_RESET}"
  echo -e "${C_RED}  exit code: ${exit_code}${C_RESET}"
  echo
  echo "What was created so far:"
  [[ "$CREATED_RG" == "true" ]]    && echo "  - Resource group: ${RESOURCE_GROUP:-unknown}"
  [[ "$DEPLOYED_CLMS" == "true" ]] && echo "  - vController VM: ${DEFAULT_CLMS_NAME} (IP ${CLMS_PUBLIC_IP:-pending})"
  [[ "$DEPLOYED_KVO" == "true" ]]  && echo "  - KVO VM:         ${DEFAULT_KVO_NAME}  (IP ${KVO_PUBLIC_IP:-pending})"
  [[ "$DEPLOYED_VPB" == "true" ]]  && echo "  - vPB VM:         ${DEFAULT_VPB_NAME}  (IP ${VPB_PUBLIC_IP:-pending})"
  echo

  # Auto-rollback if requested AND we created the RG this run. Never
  # delete a pre-existing RG the customer pointed at via --resource-group.
  if [[ "$ROLLBACK_ON_FAIL" == "true" ]] && [[ "$CREATED_RG" == "true" ]] && [[ -n "${RESOURCE_GROUP:-}" ]]; then
    echo -e "${C_YELLOW}--rollback is ON. Deleting ${RESOURCE_GROUP} in 5 seconds (Ctrl+C to abort)...${C_RESET}"
    for i in 5 4 3 2 1; do
      printf "  %d... " "$i"; sleep 1
    done
    echo
    if az group delete -n "$RESOURCE_GROUP" --yes --no-wait >/dev/null 2>&1; then
      ok "Rollback initiated: az group delete -n ${RESOURCE_GROUP} --no-wait"
      echo "    (Azure will finish removing resources in the background, ~2-5 minutes.)"
    else
      warn "Rollback failed - the az group delete call did not succeed."
      warn "Inspect manually: az group show -n ${RESOURCE_GROUP}"
    fi
    return
  fi

  echo "Cleanup options:"
  if [[ "$CREATED_RG" == "true" ]] && [[ -n "${RESOURCE_GROUP:-}" ]]; then
    echo "  Auto-rollback next time: re-run with --rollback (or CLOUDLENS_ROLLBACK_ON_FAIL=true)"
    echo "  Delete everything now:   az group delete -n ${RESOURCE_GROUP} --yes --no-wait"
  fi
  echo "  Re-run this script:      bash deploy/deploy-stack.sh    # idempotent, skips existing"
  echo "  Inspect log:             ${LOG_FILE}"
}
trap on_error ERR

on_interrupt() {
  echo
  warn "Interrupted in phase: ${PHASE_NAME}"
  if [[ "$CREATED_RG" == "true" ]] && [[ -n "${RESOURCE_GROUP:-}" ]]; then
    warn "To remove what got created: az group delete -n ${RESOURCE_GROUP} --yes --no-wait"
  fi
  exit 130
}
trap on_interrupt INT TERM

# =====================================================================
# Phase 1: Banner + environment detection
# =====================================================================
step "Phase 1: Banner + environment detection"
banner "CloudLens Stack: vController + KVO + vPB + Sensors"
echo
[[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN MODE: no Azure resources will be created"
echo

IN_CLOUD_SHELL=false
if [[ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ]] \
   || [[ "${ACC_CLOUD:-}" == "PROD" ]] \
   || [[ -d /usr/cloudshell ]]; then
  IN_CLOUD_SHELL=true
  ok "Detected: Azure Cloud Shell (pre-authenticated)"
else
  ok "Detected: Local machine ($(uname -s))"
fi

echo
# Use printf (not echo) so the C_BOLD escape code is interpreted, not
# printed literally. `echo` without -e would emit \033[1m as text.
printf "${C_BOLD}Resolved configuration (override via flags or CLOUDLENS_* env vars):${C_RESET}\n"
printf "  %-22s %s\n" "Resource group:" "${ARG_RG:-$DEFAULT_RG}"
printf "  %-22s %s\n" "Location:" "${ARG_LOCATION:-$DEFAULT_LOCATION}"
printf "  %-22s %s\n" "Admin username:" "$DEFAULT_ADMIN_USER"
printf "  %-22s %s (count: %d, size: %s)\n" "vController:" "$DEFAULT_CLMS_NAME" "$CLMS_COUNT" "$CLMS_VM_SIZE"
printf "  %-22s %s (count: %d, size: %s)\n" "KVO:" "$DEFAULT_KVO_NAME" "$KVO_COUNT" "$KVO_VM_SIZE"
printf "  %-22s %s (count: %d, size: %s, ingress NICs: %d, egress NICs: %d)\n" \
  "vPB:" "$DEFAULT_VPB_NAME" "$VPB_COUNT" "$VPB_VM_SIZE" "$VPB_INGRESS_NICS" "$VPB_EGRESS_NICS"
printf "  %-22s %s\n" "Rollback on failure:" "$ROLLBACK_ON_FAIL  (override with --rollback / --no-rollback)"
echo

# =====================================================================
# Phase 2: Pre-flight checks
# =====================================================================
step "Phase 2: Pre-flight checks"

# On macOS, the system-default `az` often resolves to a pyenv-shimmed
# Python which has broken azure-cli modules (DATA_KEYVAULT, KeyError:
# ('dla',), etc). Homebrew's az at /opt/homebrew/bin/az (Apple Silicon)
# or /usr/local/bin/az (Intel) ships with its own bundled Python and
# works cleanly. Force-prefer it before any az call.
if [[ "$(uname -s)" == "Darwin" ]]; then
  for candidate in /opt/homebrew/bin/az /usr/local/bin/az; do
    if [[ -x "$candidate" ]]; then
      candidate_dir="$(dirname "$candidate")"
      if [[ ":$PATH:" != *":$candidate_dir:"* ]] || [[ "$(command -v az)" != "$candidate" ]]; then
        export PATH="$candidate_dir:$PATH"
        note "Routing around pyenv: using $candidate"
      fi
      break
    fi
  done
fi

# Auto-install Azure CLI if missing. Customers running this curl|bash
# in a fresh Cloud Shell already have az. Customers running on a fresh
# laptop or VM may not. Detect OS and install the official package.
install_az_cli() {
  local os; os="$(uname -s)"
  echo "Detecting OS to install Azure CLI..."
  if [[ "$os" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      note "Installing via Homebrew: brew install azure-cli (this takes 2-5 min)"
      brew install azure-cli
    else
      fail "Homebrew not found on macOS. Install brew from https://brew.sh, or install Azure CLI manually from https://learn.microsoft.com/cli/azure/install-azure-cli-macos, then re-run this script."
    fi
  elif [[ "$os" == "Linux" ]]; then
    if [[ -f /etc/debian_version ]] || command -v apt-get >/dev/null 2>&1; then
      note "Installing via Microsoft's official Debian/Ubuntu installer..."
      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
    elif [[ -f /etc/redhat-release ]] || command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      note "Installing via Microsoft's official RPM repo..."
      sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
      cat <<RPM | sudo tee /etc/yum.repos.d/azure-cli.repo >/dev/null
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
RPM
      if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y azure-cli
      else
        sudo yum install -y azure-cli
      fi
    else
      fail "Could not detect Linux package manager. Install Azure CLI manually from https://learn.microsoft.com/cli/azure/install-azure-cli-linux then re-run."
    fi
  else
    fail "Unsupported OS ($os). Install Azure CLI manually from https://learn.microsoft.com/cli/azure/install-azure-cli then re-run."
  fi
}

if ! command -v az >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "az CLI not installed (dry-run continues)"
  else
    warn "Azure CLI not installed."
    read -rp "Install it now? Pulls the official package for your OS. [Y/n]: " yn
    yn_lc=$(to_lower "${yn:-y}")
    if [[ "$yn_lc" == "n" ]] || [[ "$yn_lc" == "no" ]]; then
      fail "Azure CLI required. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli then re-run."
    fi
    install_az_cli
    if ! command -v az >/dev/null 2>&1; then
      fail "Azure CLI installation did not succeed. Check the output above and install manually."
    fi
    ok "Azure CLI installed"
  fi
else
  ok "Azure CLI present ($(az version --query \"\\\"azure-cli\\\"\" -o tsv 2>/dev/null || echo unknown))"
fi

# Check login
if [[ "$DRY_RUN" == "false" ]]; then
  if ! az account show >/dev/null 2>&1; then
    warn "Not logged in. Running az login..."
    az login --use-device-code
  fi
  SUB_ID=$(az account show --query id -o tsv)
  SUB_NAME=$(az account show --query name -o tsv)
  ok "Subscription: ${SUB_NAME} (${SUB_ID})"

  # Proactively test the token is still fresh. `az account show` reads a
  # local cache and can succeed even when the refresh token has expired
  # (Azure conditional-access policy caps lifetime at 12-24h). The real
  # API calls in later phases then dead-end on AADSTS70043. Catch it now.
  if ! az account get-access-token --query expiresOn -o tsv >/dev/null 2>&1; then
    warn "Azure refresh token expired (conditional access policy)."
    read -rp "Run 'az login --use-device-code' to refresh now? [Y/n]: " yn
    yn_lc=$(to_lower "${yn:-y}")
    if [[ "$yn_lc" == "n" ]] || [[ "$yn_lc" == "no" ]]; then
      fail "Cannot proceed without a fresh Azure token. Run 'az login --use-device-code' and re-run this script."
    fi
    az login --use-device-code
    SUB_ID=$(az account show --query id -o tsv)
    SUB_NAME=$(az account show --query name -o tsv)
    ok "Re-authenticated. Subscription: ${SUB_NAME} (${SUB_ID})"
  fi
else
  SUB_ID="00000000-0000-0000-0000-000000000000"
  SUB_NAME="DryRunSubscription"
  ok "Subscription: ${SUB_NAME} (${SUB_ID})  [dry-run placeholder]"
fi

# Quota probe is informational. We do not block the run on it.
check_quota_family() {
  local family="$1"
  local region="$2"
  local needed="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    note "Quota check skipped in dry-run for ${family} in ${region}"
    return 0
  fi
  local available
  available=$(az vm list-usage --location "$region" \
    --query "[?contains(name.value,'${family}')].{cur:currentValue,max:limit}" \
    -o tsv 2>/dev/null | head -1 || echo "")
  if [[ -z "$available" ]]; then
    note "Could not read quota for ${family} in ${region} (continuing)"
    return 0
  fi
  local cur max
  cur=$(echo "$available" | awk '{print $1}')
  max=$(echo "$available" | awk '{print $2}')
  local free=$((max - cur))
  if (( free < needed )); then
    warn "Quota tight: ${family} in ${region}: ${free} free, ${needed} needed"
  else
    ok "Quota OK: ${family} in ${region}: ${free} free (need ${needed})"
  fi
}

# =====================================================================
# Phase 3: Customer input
# =====================================================================
step "Phase 3: Customer input"

# Resource group
echo
echo "Where to deploy:"
echo "  - Resource group is the Azure container for all VMs + NICs + VNet."
echo "  - Type a new name to create it, OR type an existing RG name to reuse it."
echo "  - Press Enter to take the default."
if [[ -n "$ARG_RG" ]]; then
  RESOURCE_GROUP="$ARG_RG"
  ok "Resource group: ${RESOURCE_GROUP} (from --resource-group)"
else
  read -rp "Resource group name [${DEFAULT_RG}]: " input_rg; echo
  RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"
  ok "Resource group: ${RESOURCE_GROUP}"
fi

# Location
echo
echo "Azure region (e.g. eastus, eastus2, westeurope, southeastasia, etc.):"
echo "  - Press Enter to take the default."
if [[ -n "$ARG_LOCATION" ]]; then
  LOCATION="$ARG_LOCATION"
  ok "Region: ${LOCATION} (from --location)"
else
  read -rp "Azure region [${DEFAULT_LOCATION}]: " input_loc; echo
  LOCATION="${input_loc:-$DEFAULT_LOCATION}"
  ok "Region: ${LOCATION}"
fi

# Admin password: auto-generate or prompt
gen_password() {
  # 16 chars: upper, lower, digit, symbol guarantee + 12 random
  local alpha="ABCDEFGHJKLMNPQRSTUVWXYZ"
  local lower="abcdefghjkmnpqrstuvwxyz"
  local digit="23456789"
  local symbol='!@#%^*-_=+'
  local rand
  # SIGPIPE-safe: write urandom bytes via dd, then filter
  rand=$( (dd if=/dev/urandom bs=64 count=1 2>/dev/null || echo "fallbackRandomBytes" ) | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-12 )
  if [[ -z "$rand" ]]; then
    rand="Random12345Z"
  fi
  echo "${alpha:RANDOM%${#alpha}:1}${lower:RANDOM%${#lower}:1}${digit:RANDOM%${#digit}:1}${symbol:RANDOM%${#symbol}:1}${rand}"
}

cat <<'PWHELP'

About this password:
  - Used ONLY for OS-level SSH into the Linux VMs that host the products
    (e.g.  ssh azureuser@<vcontroller-ip>  or  ssh -p 9022 azureuser@<vpb-ip>).
  - It is NOT the web UI password for any product.
  - vController web UI logs in with the BUILT-IN admin / Cl0udLens@dm!n
    on first browser visit and prompts you to change it - nothing to do here.
  - KVO web UI logs in with the BUILT-IN admin / admin on first browser
    visit and prompts you to change it - nothing to do here.
  - vPB CLI uses its own separate credentials, configured during the
    auto-bootstrap. Nothing to do here either.
  - All three product web UIs are reachable as soon as their VMs come up;
    you do not need to enter or "accept" anything for them here.

Pick any 12+ char password with upper, lower, digit, and a symbol. Or
just press Enter and the script will generate one (saved to the deploy
summary file).

PWHELP
read -rsp "OS-level SSH password (Enter to auto-generate): " input_pw; echo
if [[ -z "$input_pw" ]]; then
  ADMIN_PASSWORD=$(gen_password)
  ok "Generated 16-char password (saved in ${SUMMARY_FILE})"
else
  ADMIN_PASSWORD="$input_pw"
  ok "Using supplied password"
fi

# Deploy KVO?
if [[ -z "$DEPLOY_KVO" ]]; then
  read -rp "Deploy KVO (Keysight Vision Orchestrator) alongside vController? [y/N]: " yn
  yn_lc=$(to_lower "$yn")
  if [[ "$yn_lc" == "y" ]] || [[ "$yn_lc" == "yes" ]]; then
    DEPLOY_KVO=true
  else
    DEPLOY_KVO=false
  fi
fi
ok "Deploy KVO: ${DEPLOY_KVO}"

# Deploy vPB?
if [[ -z "$DEPLOY_VPB" ]]; then
  read -rp "Deploy vPB alongside vController? [y/N]: " yn
  yn_lc=$(to_lower "$yn")
  if [[ "$yn_lc" == "y" ]] || [[ "$yn_lc" == "yes" ]]; then
    DEPLOY_VPB=true
  else
    DEPLOY_VPB=false
  fi
fi
ok "Deploy vPB: ${DEPLOY_VPB}"

# Instance counts. Only prompt if customer did NOT already specify via
# flags or env vars (i.e. the values are still at their hardcoded
# defaults of 1). Skip the entire block if they answer N to keep the
# simple-case flow short.
counts_already_set() {
  # Returns 0 (true) if any count is non-default OR was set via env var.
  [[ -n "${CLOUDLENS_VCONTROLLER_COUNT:-}" ]] && return 0
  [[ -n "${CLOUDLENS_KVO_COUNT:-}" ]]         && return 0
  [[ -n "${CLOUDLENS_VPB_COUNT:-}" ]]         && return 0
  (( CLMS_COUNT != 1 || KVO_COUNT != 1 || VPB_COUNT != 1 )) && return 0
  return 1
}
if ! counts_already_set; then
  echo
  echo "Instance counts: default is 1 of each product (simple demo / single-region)."
  echo "For HA, multi-region, or scale-out, you can deploy multiple of each."
  read -rp "Deploy multiple instances of any product? [y/N]: " yn
  yn_lc=$(to_lower "$yn")
  if [[ "$yn_lc" == "y" ]] || [[ "$yn_lc" == "yes" ]]; then
    read -rp "  vController count [1-3, default 1]: " n; CLMS_COUNT="${n:-1}"
    if [[ "$DEPLOY_KVO" == "true" ]]; then
      read -rp "  KVO count          [1-2, default 1]: " n; KVO_COUNT="${n:-1}"
    fi
    if [[ "$DEPLOY_VPB" == "true" ]]; then
      read -rp "  vPB count          [1-5, default 1]: " n; VPB_COUNT="${n:-1}"
      read -rp "  vPB ingress NICs   [1-3, default 1]: " n; VPB_INGRESS_NICS="${n:-1}"
      read -rp "  vPB egress NICs    [1-3, default 1]: " n; VPB_EGRESS_NICS="${n:-1}"
    fi
    # Re-validate against bounds now that values may have changed
    for v in "CLMS_COUNT:1:3" "KVO_COUNT:1:2" "VPB_COUNT:1:5" "VPB_INGRESS_NICS:1:3" "VPB_EGRESS_NICS:1:3"; do
      name="${v%%:*}"; rest="${v#*:}"; lo="${rest%%:*}"; hi="${rest##*:}"
      val="${!name}"
      if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < lo || val > hi )); then
        fail "$name must be an integer between $lo and $hi (got '$val')."
      fi
    done
    ok "Counts: vCtrl=${CLMS_COUNT} KVO=${KVO_COUNT} vPB=${VPB_COUNT} ingress=${VPB_INGRESS_NICS} egress=${VPB_EGRESS_NICS}"
  else
    ok "Using default: 1 of each."
  fi
fi

# Chain to sensor deployment?
if [[ -z "$CHAIN_SENSORS" ]]; then
  read -rp "Chain to sensor deployment after stack is up? [y/N]: " yn
  yn_lc=$(to_lower "$yn")
  if [[ "$yn_lc" == "y" ]] || [[ "$yn_lc" == "yes" ]]; then
    CHAIN_SENSORS=true
  else
    CHAIN_SENSORS=false
  fi
fi
ok "Chain sensors: ${CHAIN_SENSORS}"

# Now we know enough to probe quotas
# vController = 4 vCPU; KVO = +4 vCPU; both in DSv5 family
kvo_vcpu=0
[[ "$DEPLOY_KVO" == "true" ]] && kvo_vcpu=4
check_quota_family "standardDSv5Family" "$LOCATION" $((4 + kvo_vcpu))
if [[ "$DEPLOY_VPB" == "true" ]]; then
  check_quota_family "standardDSv3Family" "$LOCATION" 8
fi

# =====================================================================
# Phase 4: Marketplace terms acceptance
# =====================================================================
step "Phase 4: Marketplace terms acceptance"

accept_terms() {
  local publisher="$1" offer="$2" plan="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "az vm image terms accept --publisher ${publisher} --offer ${offer} --plan ${plan}"
    return 0
  fi

  # Try terms-show first. If it fails (broken az install, network blip,
  # etc), skip the optimization and just try the accept. The accept call
  # itself is idempotent: re-accepting an already-accepted plan returns
  # success and changes nothing.
  if az vm image terms show --publisher "$publisher" --offer "$offer" --plan "$plan" \
        --query accepted -o tsv 2>/dev/null | grep -q true; then
    ok "Already accepted: ${offer}/${plan}"
    return 0
  fi

  if az vm image terms accept --publisher "$publisher" --offer "$offer" --plan "$plan" >/dev/null 2>/tmp/accept-err; then
    ok "Accepted: ${offer}/${plan}"
  else
    warn "Could not accept terms for ${offer}/${plan} via this az install:"
    sed 's/^/    /' /tmp/accept-err >&2 | head -5
    note "Most likely: this offer was already accepted on this subscription,"
    note "or the local az install is broken. The deploy will fail at the VM"
    note "creation step if terms are NOT actually accepted - re-run then."
  fi
}

accept_terms "$CLMS_PUBLISHER" "$CLMS_OFFER" "$CLMS_PLAN"
if [[ "$DEPLOY_KVO" == "true" ]]; then
  accept_terms "$KVO_PUBLISHER" "$KVO_OFFER" "$KVO_PLAN"
fi
if [[ "$DEPLOY_VPB" == "true" ]]; then
  accept_terms "$VPB_PUBLISHER" "$VPB_OFFER" "$VPB_PLAN"
fi

# =====================================================================
# Phase 5: Resource group creation
# =====================================================================
step "Phase 5: Resource group"

rg_exists() {
  [[ "$DRY_RUN" == "true" ]] && return 1
  az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1
}

if rg_exists; then
  ok "Resource group ${RESOURCE_GROUP} already exists (reusing)"
else
  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "az group create --name ${RESOURCE_GROUP} --location ${LOCATION}"
  else
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
      --tags "deployedBy=cloudlens-stack" >/dev/null
  fi
  CREATED_RG=true
  ok "Created resource group ${RESOURCE_GROUP} in ${LOCATION}"
fi

# =====================================================================
# Phase 6: vController deployment (formerly CLMS)
# =====================================================================
step "Phase 6: Deploy vController (formerly CLMS)"

# Per-instance VM name: unsuffixed when count=1 (back-compat), -N when count>1
clms_vm_name_at() {
  if (( CLMS_COUNT == 1 )); then echo "$DEFAULT_CLMS_NAME"
  else echo "${DEFAULT_CLMS_NAME}-${1}"; fi
}

CLMS_PUBLIC_IPS=()
for i in $(seq 1 "$CLMS_COUNT"); do
  vm_name=$(clms_vm_name_at "$i")
  if (( CLMS_COUNT > 1 )); then
    step "  vController $i of $CLMS_COUNT: $vm_name"
  fi

  if [[ "$DRY_RUN" != "true" ]] && az vm show -g "$RESOURCE_GROUP" -n "$vm_name" >/dev/null 2>&1; then
    warn "$vm_name already exists in ${RESOURCE_GROUP} (reusing)"
    pip=$(run_az_capture network public-ip show -g "$RESOURCE_GROUP" -n "${vm_name}-pip" --query ipAddress -o tsv 2>/dev/null || echo "unknown")
  else
    note "Deploying ARM template: ${CLMS_TEMPLATE_URL} (instance $vm_name)"
    if [[ "$DRY_RUN" == "true" ]]; then
      dryrun_say "az deployment group create -g ${RESOURCE_GROUP} --template-uri ${CLMS_TEMPLATE_URL} --parameters vmName=${vm_name} adminPassword=<hidden> vmSize=${CLMS_VM_SIZE}"
      pip="203.0.113.$((10+i))"
    else
      az deployment group create \
        -g "$RESOURCE_GROUP" \
        -n "vcontroller-${vm_name}-$(date +%s)" \
        --template-uri "$CLMS_TEMPLATE_URL" \
        --parameters \
            vmName="$vm_name" \
            adminUsername="$ADMIN_USERNAME" \
            adminPassword="$ADMIN_PASSWORD" \
            vmSize="$CLMS_VM_SIZE" \
        --query 'properties.outputs' -o json > /tmp/clms-outputs.json
      pip=$(python3 -c "import json,sys; d=json.load(open('/tmp/clms-outputs.json')); print(d.get('vcontrollerPublicIp', d.get('clmsPublicIp', {})).get('value', 'unknown'))" 2>/dev/null || echo "unknown")
    fi
    DEPLOYED_CLMS=true
  fi
  CLMS_PUBLIC_IPS+=("$pip")
  ok "vController ${vm_name} at ${pip}"
done
# Keep the singleton var pointing at the first instance for back-compat with
# later phases (sensor wait, summary write, manual project-key prompt).
CLMS_PUBLIC_IP="${CLMS_PUBLIC_IPS[0]:-unknown}"

# =====================================================================
# Phase 7: Wait for vController init
# =====================================================================
step "Phase 7: Wait for vController initialization"

if [[ "$DRY_RUN" == "true" ]]; then
  dryrun_say "would poll https://${CLMS_PUBLIC_IP}:443 every 15s for up to 17 minutes"
else
  echo "vController needs ~15 minutes to initialize. Web UI on 443 typically responds in 60 seconds,"
  echo "with a further 2-minute settle for backend services."
  echo

  if [[ "$CLMS_PUBLIC_IP" == "unknown" ]]; then
    warn "No public IP available, skipping wait"
  else
    deadline=$(( $(date +%s) + 17*60 ))
    while (( $(date +%s) < deadline )); do
      remaining=$(( deadline - $(date +%s) ))
      printf "\r%s seconds remaining, probing port 443..." "$remaining"
      if (echo > /dev/tcp/"${CLMS_PUBLIC_IP}"/443) >/dev/null 2>&1; then
        echo
        ok "vController port 443 is open"
        echo "Settling 2 more minutes for backend init..."
        sleep 120
        break
      fi
      sleep 15
    done
    echo
  fi
fi

# =====================================================================
# Phase 8: KVO deployment (optional)
# =====================================================================
if [[ "$DEPLOY_KVO" == "true" ]]; then
  step "Phase 8: Deploy KVO (Keysight Vision Orchestrator)"

  kvo_vm_name_at() {
    if (( KVO_COUNT == 1 )); then echo "$DEFAULT_KVO_NAME"
    else echo "${DEFAULT_KVO_NAME}-${1}"; fi
  }

  KVO_PUBLIC_IPS=()
  for i in $(seq 1 "$KVO_COUNT"); do
    vm_name=$(kvo_vm_name_at "$i")
    if (( KVO_COUNT > 1 )); then
      step "  KVO $i of $KVO_COUNT: $vm_name"
    fi

    if [[ "$DRY_RUN" != "true" ]] && az vm show -g "$RESOURCE_GROUP" -n "$vm_name" >/dev/null 2>&1; then
      warn "$vm_name already exists, reusing"
      pip=$(run_az_capture network public-ip show -g "$RESOURCE_GROUP" -n "${vm_name}-pip" --query ipAddress -o tsv 2>/dev/null || echo "unknown")
    else
      note "Deploying ARM template: ${KVO_TEMPLATE_URL} (instance $vm_name)"
      if [[ "$DRY_RUN" == "true" ]]; then
        dryrun_say "az deployment group create -g ${RESOURCE_GROUP} --template-uri ${KVO_TEMPLATE_URL} --parameters vmName=${vm_name} adminPassword=<hidden> vmSize=${KVO_VM_SIZE}"
        pip="203.0.113.$((15+i))"
      else
        az deployment group create \
          -g "$RESOURCE_GROUP" \
          -n "kvo-${vm_name}-$(date +%s)" \
          --template-uri "$KVO_TEMPLATE_URL" \
          --parameters \
              vmName="$vm_name" \
              adminUsername="$ADMIN_USERNAME" \
              adminPassword="$ADMIN_PASSWORD" \
              vmSize="$KVO_VM_SIZE" \
          --query 'properties.outputs' -o json > /tmp/kvo-outputs.json
        pip=$(python3 -c "import json; print(json.load(open('/tmp/kvo-outputs.json'))['kvoPublicIp']['value'])" 2>/dev/null || echo "unknown")
      fi
      DEPLOYED_KVO=true
    fi
    KVO_PUBLIC_IPS+=("$pip")
    ok "KVO ${vm_name} at ${pip}"
  done
  KVO_PUBLIC_IP="${KVO_PUBLIC_IPS[0]:-unknown}"

  note "KVO web UI is reachable in about 60 seconds; full init ~15 minutes."
  note "Default UI login: admin / admin (change on first login)"
else
  step "Phase 8: KVO deployment (skipped)"
fi

# =====================================================================
# Phase 9: vPB deployment (optional)
# =====================================================================
if [[ "$DEPLOY_VPB" == "true" ]]; then
  step "Phase 9: Deploy vPB (${VPB_INGRESS_NICS} ingress + ${VPB_EGRESS_NICS} egress NIC(s) per instance)"

  vpb_vm_name_at() {
    if (( VPB_COUNT == 1 )); then echo "$DEFAULT_VPB_NAME"
    else echo "${DEFAULT_VPB_NAME}-${1}"; fi
  }

  VPB_PUBLIC_IPS=()
  for i in $(seq 1 "$VPB_COUNT"); do
    vm_name=$(vpb_vm_name_at "$i")
    if (( VPB_COUNT > 1 )); then
      step "  vPB $i of $VPB_COUNT: $vm_name"
    fi

    if [[ "$DRY_RUN" != "true" ]] && az vm show -g "$RESOURCE_GROUP" -n "$vm_name" >/dev/null 2>&1; then
      warn "$vm_name already exists, reusing"
      pip=$(run_az_capture network public-ip show -g "$RESOURCE_GROUP" -n "${vm_name}-mgmt-pip" --query ipAddress -o tsv 2>/dev/null || echo "unknown")
    else
      note "Deploying ARM template: ${VPB_TEMPLATE_URL} (instance $vm_name)"
      if [[ "$DRY_RUN" == "true" ]]; then
        dryrun_say "az deployment group create -g ${RESOURCE_GROUP} --template-uri ${VPB_TEMPLATE_URL} --parameters vmName=${vm_name} adminPassword=<hidden> vmSize=${VPB_VM_SIZE} ingressNicCount=${VPB_INGRESS_NICS} egressNicCount=${VPB_EGRESS_NICS}"
        pip="203.0.113.$((20+i))"
      else
        az deployment group create \
          -g "$RESOURCE_GROUP" \
          -n "vpb-${vm_name}-$(date +%s)" \
          --template-uri "$VPB_TEMPLATE_URL" \
          --parameters \
              vmName="$vm_name" \
              adminUsername="$ADMIN_USERNAME" \
              adminPassword="$ADMIN_PASSWORD" \
              vmSize="$VPB_VM_SIZE" \
              ingressNicCount="$VPB_INGRESS_NICS" \
              egressNicCount="$VPB_EGRESS_NICS" \
          --query 'properties.outputs' -o json > /tmp/vpb-outputs.json
        pip=$(python3 -c "import json; print(json.load(open('/tmp/vpb-outputs.json'))['vpbPublicIp']['value'])" 2>/dev/null || echo "unknown")
      fi
      DEPLOYED_VPB=true
    fi
    VPB_PUBLIC_IPS+=("$pip")
    ok "vPB ${vm_name} at ${pip} (SSH on port 9022)"
  done
  VPB_PUBLIC_IP="${VPB_PUBLIC_IPS[0]:-unknown}"

  note "vPB management SSH is reachable on port 9022 within ~5 minutes."
  note "Auto-bootstrap runs during deploy (CustomScript extension)."
  note "After deploy: ssh -p 9022 ${ADMIN_USERNAME}@<vpb-ip>, then 'sudo vpb' for the CLI."
else
  step "Phase 9: vPB deployment (skipped)"
fi

# =====================================================================
# Phase 10: Manual project key step
# =====================================================================
step "Phase 10: Get project key from vController"

cat <<EOM

vController is now reachable. To deploy sensors, you need a project key.

  1. Open the vController UI: https://${CLMS_PUBLIC_IP}
  2. Sign in with the default credentials: admin / Cl0udLens@dm!n
  3. You will be prompted to change the password on first login.
  4. Go to Projects -> Add Project, give it a name, then open the
     project and copy the API key.

EOM

PROJECT_KEY=""
if [[ "$CHAIN_SENSORS" == "true" ]]; then
  read -rp "Paste project key (or press Enter to skip sensor deployment): " PROJECT_KEY
  if [[ -z "$PROJECT_KEY" ]]; then
    warn "No project key supplied. Skipping sensor chain."
    CHAIN_SENSORS=false
  fi
fi

# =====================================================================
# Phase 11: Sensor chain (optional)
# =====================================================================
if [[ "$CHAIN_SENSORS" == "true" ]]; then
  step "Phase 11: Chain into sensor deployment"

  if [[ "$DRY_RUN" == "true" ]]; then
    dryrun_say "would generate customer_input.yaml and run bash quickstart.sh"
  else
    cat > customer_input.yaml <<YAML
# Auto-generated by deploy-stack.sh on $(date -u +%FT%TZ)
azure:
  subscription_id: "${SUB_ID}"
  tag_filters:
    cloudlens: "yes"
cloudlens:
  manager_ip_or_fqdn: "${CLMS_PUBLIC_IP}"
  project_key: "${PROJECT_KEY}"
  custom_tags: "DeployedBy=stack Region=${LOCATION}"
  registry_type: "insecure"
  ssl_verify: "no"
  auto_update: "yes"
connection:
  mode: "direct_public"
linux:
  ansible_user: "azureuser"
  ssh_key_file: "~/.ssh/id_rsa"
YAML
    ok "Wrote customer_input.yaml"

    if [[ -x quickstart.sh ]]; then
      ok "Launching quickstart.sh"
      bash quickstart.sh || warn "quickstart.sh exited non-zero (see ${LOG_FILE})"
    else
      warn "quickstart.sh not found in $(pwd); skipping. Run from repo root to chain."
    fi
  fi
else
  step "Phase 11: Sensor chain (skipped)"
fi

# =====================================================================
# Phase 12: Final summary
# =====================================================================
step "Phase 12: Final summary"

write_summary() {
  cat <<SUMMARY
========================================================================
CloudLens Stack Deployment Summary
Generated: $(date -u +%FT%TZ)
========================================================================

Subscription:       ${SUB_NAME} (${SUB_ID})
Resource group:     ${RESOURCE_GROUP}
Region:             ${LOCATION}

--- vController (formerly CLMS) ---
Name:               ${DEFAULT_CLMS_NAME}
Public IP:          ${CLMS_PUBLIC_IP}
Web UI:             https://${CLMS_PUBLIC_IP}
SSH:                ssh ${ADMIN_USERNAME}@${CLMS_PUBLIC_IP}
Default UI creds:   admin / Cl0udLens@dm!n  (change on first login)
OS-level user:      ${ADMIN_USERNAME}
OS-level password:  ${ADMIN_PASSWORD}

SUMMARY

  if [[ "$DEPLOY_KVO" == "true" ]]; then
    cat <<KSUMMARY
--- KVO (Keysight Vision Orchestrator) ---
Name:               ${DEFAULT_KVO_NAME}
Public IP:          ${KVO_PUBLIC_IP}
Web UI:             https://${KVO_PUBLIC_IP}
SSH:                ssh ${ADMIN_USERNAME}@${KVO_PUBLIC_IP}
Default UI creds:   see Keysight KVO documentation
OS-level user:      ${ADMIN_USERNAME}
OS-level password:  ${ADMIN_PASSWORD}
Purpose:            Centralized vPB fleet orchestration and configuration

KSUMMARY
  fi

  if [[ "$DEPLOY_VPB" == "true" ]]; then
    cat <<VSUMMARY
--- vPB ---
Name:               ${DEFAULT_VPB_NAME}
Public IP:          ${VPB_PUBLIC_IP}
Management SSH:     ssh ${ADMIN_USERNAME}@${VPB_PUBLIC_IP}
vPB CLI (two-hop):  ssh ${ADMIN_USERNAME}@${VPB_PUBLIC_IP}
                    then: ssh admin@localhost -p 2222 (password: ixia)
Note:               SSH is reachable 10 to 15 minutes after deploy

VSUMMARY
  fi

  cat <<EOM
--- Next steps ---
1. Open https://${CLMS_PUBLIC_IP} and change the default vController password
2. Create a project in the vController UI and copy the project key
EOM
  if [[ "$DEPLOY_KVO" == "true" ]]; then
    echo "3. Open https://${KVO_PUBLIC_IP} (KVO) and register your vController + vPB fleet"
    echo "4. To deploy sensors later:"
    echo "     curl -sSL ${REPO_RAW}/quickstart.sh | bash"
  else
    echo "3. To deploy sensors later:"
    echo "     curl -sSL ${REPO_RAW}/quickstart.sh | bash"
  fi
  cat <<EOM

--- Cleanup ---
Delete everything: az group delete -n ${RESOURCE_GROUP} --yes --no-wait

--- Log ---
Full deployment log: ${LOG_FILE}
========================================================================
EOM
}

write_summary | tee "$SUMMARY_FILE" >/dev/null

banner "Stack deployment complete"
echo
echo "Summary saved to:    ${SUMMARY_FILE}"
echo "Log saved to:        ${LOG_FILE}"
echo "vController UI:      https://${CLMS_PUBLIC_IP}"
[[ "$DEPLOY_KVO" == "true" ]] && echo "KVO UI:              https://${KVO_PUBLIC_IP}"
[[ "$DEPLOY_VPB" == "true" ]] && echo "vPB management:      ${VPB_PUBLIC_IP}"
echo
ok "Done."
trap - ERR
exit 0

} # End of curl|bash brace-wrap (see top of file)
