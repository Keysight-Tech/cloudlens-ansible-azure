#!/usr/bin/env bash
# =====================================================================
# CloudLens Ansible for Azure: One-Command Quickstart
# =====================================================================
# Works in: Azure Cloud Shell, Linux laptop, macOS, WSL
# Deploys CloudLens sensors to ALL Azure VMs tagged cloudlens=yes
# Supports: Ubuntu, RHEL, Windows VMs across resource groups & regions
# Scales: 1 VM to 5,000+ VMs (auto-tunes forks based on VM count)
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/quickstart.sh | bash
#   OR
#   ./quickstart.sh
# =====================================================================
set -euo pipefail

REPO_URL="https://github.com/Keysight-Tech/cloudlens-ansible-azure.git"
WORK_DIR="${CLOUDLENS_WORK_DIR:-$HOME/cloudlens-ansible-azure}"
BRANCH="${CLOUDLENS_BRANCH:-main}"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
banner() { echo -e "${C_BLUE}╔══════════════════════════════════════════════════════════════╗${C_RESET}"; echo -e "${C_BLUE}║  $1${C_RESET}"; echo -e "${C_BLUE}╚══════════════════════════════════════════════════════════════╝${C_RESET}"; }
ok()     { echo -e "${C_GREEN}✓${C_RESET} $1"; }
warn()   { echo -e "${C_YELLOW}⚠${C_RESET} $1"; }
fail()   { echo -e "${C_RED}✗${C_RESET} $1"; exit 1; }
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
  ok "Detected: Local machine ($(uname -s))"
fi

# =====================================================================
# Step 2: Install dependencies (idempotent)
# =====================================================================
step "Installing dependencies"

install_pkg() {
  local pkg="$1"
  if command -v "$pkg" >/dev/null 2>&1; then ok "$pkg installed"; return 0; fi
  if [[ "$IN_CLOUD_SHELL" == "true" ]]; then
    pip install --quiet --user "$pkg" || warn "Could not install $pkg"
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y -qq "$pkg"
  elif command -v brew >/dev/null 2>&1; then
    brew install -q "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y -q "$pkg"
  fi
}

# Azure CLI
if ! command -v az >/dev/null 2>&1; then
  warn "Azure CLI not found"
  if [[ "$IN_CLOUD_SHELL" == "false" ]]; then
    echo "Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
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
pip install --quiet ansible-core>=2.16 pywinrm requests-ntlm azure-identity azure-mgmt-compute azure-mgmt-network azure-mgmt-resource msgraph-core
ansible-galaxy collection install azure.azcollection ansible.windows community.windows --upgrade -q 2>&1 | tail -2

# Install azcollection's FULL Python requirements (azure-storage-blob,
# azure-storage-fileshare, azure-mgmt-notificationhubs, msgraph-sdk, ...).
# These are NOT optional - the azure_rm inventory plugin silently fails to
# load AzureCliCredential when any of them are missing, which manifests as
# "name 'AzureCliCredential' is not defined" with no useful hint.
REQ_FILE=~/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt
if [[ -f "$REQ_FILE" ]]; then
  pip install --quiet -r "$REQ_FILE" || warn "azcollection requirements partial install (some packages may be missing - inventory plugin may fail)"
fi

# Default to az-CLI auth source when a service principal env is not present.
# Without this, the Ansible azure_rm inventory plugin tries SP auth, fails,
# and exits with a misleading "name 'client_secret' is not defined" error.
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
  ok "Repo updated"
else
  git clone -q -b "$BRANCH" "$REPO_URL" "$WORK_DIR"
  ok "Repo cloned to $WORK_DIR"
fi
cd "$WORK_DIR"

# =====================================================================
# Step 4: Azure auth (Cloud Shell skips, others use SP)
# =====================================================================
step "Azure authentication"
if [[ "$IN_CLOUD_SHELL" == "true" ]]; then
  ok "Cloud Shell auto-authenticated (no SP needed)"
  export AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  export AZURE_TENANT="$(az account show --query tenantId -o tsv)"
elif [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
  ok "Service Principal env vars already set"
elif [[ -f azure_sp_creds.json ]]; then
  ok "Loading SP from azure_sp_creds.json"
  export AZURE_CLIENT_ID=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['appId'])")
  export AZURE_SECRET=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['password'])")
  export AZURE_TENANT=$(python3 -c "import json; print(json.load(open('azure_sp_creds.json'))['tenant'])")
  export AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
else
  warn "No Service Principal credentials found"
  echo "Run: bash scripts/setup_azure_sp.sh"
  exit 1
fi

# =====================================================================
# Step 5: Get customer input
# =====================================================================
step "Gathering deployment configuration"
if [[ -f customer_input.yaml ]]; then
  ok "Using existing customer_input.yaml"
else
  echo "No customer_input.yaml found. Starting interactive setup:"
  cp customer_input.yaml.example customer_input.yaml
  read -rp "CLMS IP or FQDN: " clms_ip
  read -rp "Project key: " proj_key
  read -rp "Custom tags (e.g. 'Env=Azure Customer=Acme'): " ctags
  read -rp "Resource group(s) comma-separated (or leave blank for ALL): " rgs
  sed -i.bak "s|REPLACE_WITH_PROJECT_KEY|$proj_key|; s|clms.customer.example.com|$clms_ip|; s|Env=Azure Region=eastus2 Customer=Acme|$ctags|" customer_input.yaml
  rm -f customer_input.yaml.bak
  ok "customer_input.yaml created"
fi

# =====================================================================
# Step 6: Discover VMs + auto-tune scale
# =====================================================================
step "Discovering tagged VMs"
ansible-inventory -i inventory/azure_rm.yaml --graph 2>&1 | tee /tmp/cl_inv.txt | head -30

VM_COUNT=$(grep -c -E "^  \|  \|--" /tmp/cl_inv.txt || echo 0)
ok "$VM_COUNT VMs discovered with cloudlens=yes tag"

if (( VM_COUNT == 0 )); then
  fail "No VMs found. Tag your VMs:
  az vm update -g <RG> -n <VM> --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod"
fi

# Auto-tune forks based on scale
if   (( VM_COUNT <= 50 ));    then FORKS=20
elif (( VM_COUNT <= 500 ));   then FORKS=50
elif (( VM_COUNT <= 2000 ));  then FORKS=200
else                                FORKS=500
fi

# Use shard mode for thousands
USE_SHARD=false
if (( VM_COUNT > 2000 )); then
  USE_SHARD=true
  ok "Auto-enabling SHARDED mode (VM count > 2000)"
fi

echo
echo "Scale plan: $VM_COUNT VMs, $FORKS parallel forks $([ "$USE_SHARD" == "true" ] && echo ', sharded')"
echo

# =====================================================================
# Step 7: Confirmation
# =====================================================================
read -rp "Proceed with deployment to $VM_COUNT VMs? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { warn "Cancelled"; exit 0; }

# =====================================================================
# Step 8: Deploy
# =====================================================================
step "Deploying CloudLens sensors"

if [[ "$USE_SHARD" == "true" ]]; then
  bash deploy/shard.sh "$VM_COUNT" "$FORKS"
else
  export ANSIBLE_FORKS="$FORKS"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES   # macOS
  ansible-playbook -i inventory/azure_rm.yaml deploy.yaml -e "@customer_input.yaml" --forks "$FORKS"
fi

# =====================================================================
# Step 9: Verify + report
# =====================================================================
step "Deployment complete: verifying"

CLMS_IP=$(grep -E "^\s*manager_ip_or_fqdn:" customer_input.yaml | awk '{print $2}' | tr -d '"')
banner "Done. Log into CLMS to verify sensors"
echo
echo "  CLMS UI:    https://$CLMS_IP"
echo "  Sensors:    $VM_COUNT registered (expected)"
echo "  Filter by:  custom_tag=$(grep custom_tags customer_input.yaml | awk -F'"' '{print $2}')"
echo "  Cleanup:    bash scripts/cleanup.sh"
echo
