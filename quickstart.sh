#!/usr/bin/env bash
# =====================================================================
# CloudLens Ansible for Azure: One-Command Quickstart
# =====================================================================
# Works in: Azure Cloud Shell, Linux laptop, macOS, WSL
# Deploys CloudLens sensors to ALL Azure VMs matched by tag filters
# Supports: Ubuntu, RHEL, Windows VMs across resource groups and regions
# Scales: 1 VM to 5,000+ VMs (auto-tunes forks from VM count + CPU cores)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/quickstart.sh | bash
#   OR
#   bash quickstart.sh
#
# Everything below is overridable via environment variable. Nothing is
# hardcoded that a customer would reasonably want to change.
# =====================================================================
set -euo pipefail

# ---- Overridable runtime config ----
REPO_URL="${CLOUDLENS_REPO_URL:-https://github.com/Keysight-Tech/cloudlens-ansible-azure.git}"
WORK_DIR="${CLOUDLENS_WORK_DIR:-$HOME/cloudlens-ansible-azure}"
BRANCH="${CLOUDLENS_BRANCH:-main}"
INVENTORY="${CLOUDLENS_INVENTORY:-inventory/azure_rm.yaml}"
PLAYBOOK="${CLOUDLENS_PLAYBOOK:-deploy.yaml}"
ASSUME_YES="${CLOUDLENS_ASSUME_YES:-false}"

# ---- Helpers ----
C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_DIM='\033[2m'; C_RESET='\033[0m'
banner() { echo -e "${C_BLUE}╔══════════════════════════════════════════════════════════════╗${C_RESET}"; echo -e "${C_BLUE}║  $1${C_RESET}"; echo -e "${C_BLUE}╚══════════════════════════════════════════════════════════════╝${C_RESET}"; }
ok()     { echo -e "${C_GREEN}✓${C_RESET} $1"; }
warn()   { echo -e "${C_YELLOW}⚠${C_RESET} $1"; }
fail()   { echo -e "${C_RED}✗${C_RESET} $1"; exit 1; }
note()   { echo -e "${C_DIM}  $1${C_RESET}"; }
step()   { echo -e "${C_BLUE}━━━ $1 ━━━${C_RESET}"; }

# =====================================================================
# Step 1: Detect environment
# =====================================================================
banner "CloudLens Ansible for Azure: Deployment Quickstart"
echo

IN_CLOUD_SHELL=false
if [[ -n "${AZUREPS_HOST_ENVIRONMENT:-}" ]] || [[ "${ACC_CLOUD:-}" == "PROD" ]] || [[ -d /usr/cloudshell ]]; then
  IN_CLOUD_SHELL=true
  ok "Detected: Azure Cloud Shell (zero local install needed)"
else
  ok "Detected: Local machine ($(uname -s) $(uname -m))"
fi

CPU_CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
note "CPU cores available: $CPU_CORES"

# =====================================================================
# Step 2: Install dependencies (idempotent)
# =====================================================================
step "Installing dependencies"

# Azure CLI presence check
if ! command -v az >/dev/null 2>&1; then
  warn "Azure CLI not found"
  if [[ "$IN_CLOUD_SHELL" == "false" ]]; then
    echo "  Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
    fail "Install Azure CLI and re-run"
  fi
fi
ok "Azure CLI present"

# Python venv for Ansible
if [[ ! -d "$WORK_DIR/.venv" ]]; then
  mkdir -p "$WORK_DIR"
  python3 -m venv "$WORK_DIR/.venv"
  "$WORK_DIR/.venv/bin/pip" install --quiet --upgrade pip
fi
source "$WORK_DIR/.venv/bin/activate"

# Quote 'ansible-core>=2.16' so bash does not interpret >= as a redirect
pip install --quiet \
  'ansible-core>=2.16' \
  pywinrm \
  requests-ntlm \
  azure-identity \
  azure-mgmt-compute \
  azure-mgmt-network \
  azure-mgmt-resource \
  msgraph-core

ansible-galaxy collection install azure.azcollection ansible.windows community.windows --upgrade -q 2>&1 | tail -2

# azcollection's FULL Python requirements are NOT optional. The azure_rm
# inventory plugin silently fails to load AzureCliCredential when any of
# them are missing, which manifests as "name 'AzureCliCredential' is not
# defined" with no useful hint.
REQ_FILE="$HOME/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt"
if [[ -f "$REQ_FILE" ]]; then
  pip install --quiet -r "$REQ_FILE" || warn "azcollection requirements partial install (inventory plugin may fail)"
fi

# Default to az-CLI auth source when no service principal env is present.
# Without this the inventory plugin tries SP auth, fails, and exits with
# a misleading "name 'client_secret' is not defined" error.
if [[ -z "${AZURE_CLIENT_ID:-}${ARM_CLIENT_ID:-}" ]]; then
  export ANSIBLE_AZURE_AUTH_SOURCE=cli
  note "Using Azure CLI auth (ANSIBLE_AZURE_AUTH_SOURCE=cli)"
fi
ok "Ansible + Azure collections installed"

# =====================================================================
# Step 3: Clone repo
# =====================================================================
step "Fetching CloudLens Ansible repo"
if [[ -d "$WORK_DIR/.git" ]]; then
  cd "$WORK_DIR" && git fetch -q && git reset -q --hard "origin/$BRANCH"
  ok "Repo updated to origin/$BRANCH"
else
  git clone -q -b "$BRANCH" "$REPO_URL" "$WORK_DIR"
  ok "Repo cloned to $WORK_DIR"
fi
cd "$WORK_DIR"

# =====================================================================
# Step 4: Azure authentication (auto-detect)
# =====================================================================
step "Azure authentication"
if [[ "$IN_CLOUD_SHELL" == "true" ]]; then
  ok "Cloud Shell auto-authenticated"
elif [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
  ok "Service Principal env vars already set"
elif [[ -f azure_sp_creds.json ]]; then
  ok "Loading SP from azure_sp_creds.json"
  export AZURE_CLIENT_ID=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['appId'])")
  export AZURE_SECRET=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['password'])")
  export AZURE_TENANT=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['tenant'])")
elif az account show >/dev/null 2>&1; then
  ok "Using existing az login session"
else
  warn "No Azure credentials found"
  echo "  Run one of:"
  echo "    az login --use-device-code            # personal / interactive"
  echo "    bash scripts/setup_azure_sp.sh        # service principal"
  fail "Authenticate to Azure and re-run"
fi

# Auto-discover subscription + tenant from active session
AUTO_SUB="$(az account show --query id -o tsv 2>/dev/null || echo '')"
AUTO_TENANT="$(az account show --query tenantId -o tsv 2>/dev/null || echo '')"
AUTO_SUB_NAME="$(az account show --query name -o tsv 2>/dev/null || echo '')"

if [[ -n "$AUTO_SUB" ]]; then
  export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-$AUTO_SUB}"
  export AZURE_TENANT="${AZURE_TENANT:-$AUTO_TENANT}"
  ok "Active subscription: $AUTO_SUB_NAME ($AUTO_SUB)"
fi

# =====================================================================
# Step 5: Customer input (env first, prompt only what is missing)
# =====================================================================
step "Gathering deployment configuration"
if [[ -f customer_input.yaml ]]; then
  ok "Using existing customer_input.yaml"
else
  cp customer_input.yaml.example customer_input.yaml

  # Pull from env when set; only prompt for what is still missing
  VCTRL_IP="${CLOUDLENS_MANAGER_IP:-}"
  PROJ_KEY="${CLOUDLENS_PROJECT_KEY:-}"
  CTAGS="${CLOUDLENS_CUSTOM_TAGS:-}"

  if [[ -z "$VCTRL_IP" ]]; then
    read -rp "vController IP or FQDN: " VCTRL_IP
  fi
  if [[ -z "$PROJ_KEY" ]]; then
    read -rp "Project key (vController > Projects > API Keys): " PROJ_KEY
  fi
  if [[ -z "$CTAGS" ]]; then
    read -rp "Custom tags [Env=Azure Customer=Acme]: " CTAGS
    CTAGS="${CTAGS:-Env=Azure Customer=Acme}"
  fi

  # Write all three placeholders. Python avoids portable-sed pain on macOS.
  python3 - "$VCTRL_IP" "$PROJ_KEY" "$CTAGS" "$AZURE_SUBSCRIPTION_ID" "$AZURE_TENANT" <<'PY'
import sys, pathlib
p = pathlib.Path("customer_input.yaml")
t = p.read_text()
ip, key, tags, sub, tenant = sys.argv[1:6]
t = t.replace("clms.customer.example.com", ip)
t = t.replace("REPLACE_WITH_PROJECT_KEY", key)
t = t.replace("Env=Azure Region=eastus2 Customer=Acme", tags)
if sub:
    t = t.replace("00000000-0000-0000-0000-000000000000", sub, 1)
if tenant:
    t = t.replace("00000000-0000-0000-0000-000000000000", tenant, 1)
p.write_text(t)
PY
  ok "customer_input.yaml generated (subscription + tenant auto-filled)"
fi

# Extract values back out for the rest of the script
VCONTROLLER_IP="$(python3 -c "import yaml,sys; print(yaml.safe_load(open('customer_input.yaml'))['cloudlens']['manager_ip_or_fqdn'])" 2>/dev/null || echo '')"

# =====================================================================
# Step 6: Discover VMs (robust JSON parse, not fragile graph regex)
# =====================================================================
step "Discovering tagged VMs"

INV_JSON="$(ansible-inventory -i "$INVENTORY" --list 2>/dev/null || echo '{}')"
VM_COUNT="$(printf '%s' "$INV_JSON" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("_meta",{}).get("hostvars",{})))')"

if (( VM_COUNT == 0 )); then
  ansible-inventory -i "$INVENTORY" --graph 2>&1 | head -20
  fail "No VMs matched the tag filters in customer_input.yaml.
  Tag your VMs:
    az vm update -g <RG> -n <VM> --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod"
fi
ok "$VM_COUNT VMs discovered"

# Show the OS breakdown (debug-friendly)
printf '%s' "$INV_JSON" | python3 -c '
import json, sys, collections
d = json.load(sys.stdin)
hv = d.get("_meta", {}).get("hostvars", {})
osc = collections.Counter()
for h, v in hv.items():
    osd = (v.get("os_disk", {}) or {}).get("os_type") or v.get("os_profile", {}).get("admin_username", "?")
    osc[osd] += 1
for k, v in osc.items():
    print(f"  - {k}: {v}")
' 2>/dev/null || true

# Auto-tune forks from VM count AND CPU cores (whichever is more constraining)
if   (( VM_COUNT <= 50 ));    then BASE_FORKS=20
elif (( VM_COUNT <= 500 ));   then BASE_FORKS=50
elif (( VM_COUNT <= 2000 ));  then BASE_FORKS=200
else                                BASE_FORKS=500
fi

# Cap parallelism at 4x CPU cores to avoid IO thrash on small boxes
CORE_CAP=$(( CPU_CORES * 4 ))
if (( BASE_FORKS > CORE_CAP )); then BASE_FORKS=$CORE_CAP; fi

FORKS="${ANSIBLE_FORKS:-$BASE_FORKS}"

USE_SHARD=false
if (( VM_COUNT > 2000 )); then
  USE_SHARD=true
  note "Auto-enabling SHARDED mode (VM count > 2000)"
fi

# =====================================================================
# Step 7: Pre-flight summary + confirm
# =====================================================================
step "Pre-flight summary"
echo "  Subscription   : ${AUTO_SUB_NAME:-?} ($AZURE_SUBSCRIPTION_ID)"
echo "  vController    : $VCONTROLLER_IP"
echo "  VMs in scope   : $VM_COUNT"
echo "  Parallel forks : $FORKS  (cap: $CORE_CAP from $CPU_CORES cores)"
echo "  Sharded run    : $USE_SHARD"
echo "  Inventory      : $INVENTORY"
echo "  Playbook       : $PLAYBOOK"
echo

if [[ "$ASSUME_YES" != "true" ]] && [[ "$ASSUME_YES" != "1" ]] && [[ "$ASSUME_YES" != "yes" ]]; then
  read -rp "Proceed with deployment? [y/N] " confirm
  [[ "${confirm,,}" == "y" ]] || { warn "Cancelled"; exit 0; }
fi

# =====================================================================
# Step 8: Deploy
# =====================================================================
step "Deploying CloudLens sensors"
export ANSIBLE_FORKS="$FORKS"
export ANSIBLE_HOST_KEY_CHECKING=False
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES   # macOS WinRM forks fix

if [[ "$USE_SHARD" == "true" ]]; then
  bash deploy/shard.sh "$VM_COUNT" "$FORKS"
else
  ansible-playbook -i "$INVENTORY" "$PLAYBOOK" -e "@customer_input.yaml" --forks "$FORKS"
fi

# =====================================================================
# Step 9: Verify + report
# =====================================================================
step "Deployment complete"
banner "Done. Log into vController to verify sensors"
echo
echo "  vController UI : https://$VCONTROLLER_IP"
echo "  Sensors        : $VM_COUNT registered (expected)"
echo "  Cleanup        : bash scripts/cleanup.sh"
echo
