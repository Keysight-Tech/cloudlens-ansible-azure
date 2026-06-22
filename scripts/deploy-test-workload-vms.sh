#!/usr/bin/env bash
# =====================================================================
# CloudLens: deploy 3 test workload VMs (Ubuntu + RHEL + Windows) for
# end-to-end sensor verification.
# =====================================================================
# Stands up 3 small VMs in a single resource group, each tagged with a
# custom discovery tag so you can verify deploy-stack.sh sensor
# deployment AND prove the dynamic-tag feature works (not hard-coded
# to cloudlens=yes).
#
# Usage:
#   bash deploy-test-workload-vms.sh
#   OR with overrides:
#   bash deploy-test-workload-vms.sh \
#        --resource-group test-sensors-rg \
#        --location eastus2 \
#        --tag-key monitoring --tag-value enabled \
#        --env prod
#
# After this script:
#   curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/deploy/deploy-stack.sh \
#     | bash -s -- --discovery-tag-key monitoring --discovery-tag-value enabled
# =====================================================================
set -euo pipefail
{

# ---- Overridable config ----
RG="${TESTVMS_RG:-cloudlens-test-vms-rg}"
LOCATION="${TESTVMS_LOCATION:-eastus2}"
DISCOVERY_TAG_KEY="${TESTVMS_TAG_KEY:-monitoring}"
DISCOVERY_TAG_VALUE="${TESTVMS_TAG_VALUE:-enabled}"
ENV_TAG="${TESTVMS_ENV:-prod}"
ADMIN_USER="${TESTVMS_ADMIN_USER:-azureuser}"
ADMIN_PASSWORD="${TESTVMS_ADMIN_PASSWORD:-}"
VNET_NAME="${TESTVMS_VNET:-test-vms-vnet}"
SUBNET_NAME="${TESTVMS_SUBNET:-test-vms-subnet}"
LINUX_VM_SIZE="${TESTVMS_LINUX_SIZE:-Standard_B2s}"   # Cheap, 2 vCPU 4GB
WIN_VM_SIZE="${TESTVMS_WIN_SIZE:-Standard_B2s}"

UBUNTU_VM="test-ubuntu-1"
RHEL_VM="test-rhel-1"
WIN_VM="test-windows-1"

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group) RG="$2"; shift 2 ;;
    --location)       LOCATION="$2"; shift 2 ;;
    --tag-key)        DISCOVERY_TAG_KEY="$2"; shift 2 ;;
    --tag-value)      DISCOVERY_TAG_VALUE="$2"; shift 2 ;;
    --env)            ENV_TAG="$2"; shift 2 ;;
    --admin-user)     ADMIN_USER="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -e/p' "$0" | head -n -1 | tail -n +2; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ---- helpers ----
C_GREEN='\033[0;32m'; C_BLUE='\033[0;34m'; C_RED='\033[0;31m'; C_YELLOW='\033[1;33m'; C_DIM='\033[2m'; C_RESET='\033[0m'
ok()   { echo -e "${C_GREEN}\xE2\x9C\x93${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}\xE2\x9A\xA0${C_RESET} $1"; }
fail() { echo -e "${C_RED}\xE2\x9C\x97${C_RESET} $1" >&2; exit 1; }
step() { echo -e "${C_BLUE}--- $1 ---${C_RESET}"; }

if ! command -v az >/dev/null 2>&1; then
  fail "Azure CLI not found. Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
fi
if ! az account show >/dev/null 2>&1; then
  warn "Azure auth missing or expired."
  echo "  Run: az login --use-device-code"
  exit 1
fi

# Prompt for password if not supplied
if [[ -z "$ADMIN_PASSWORD" ]]; then
  echo
  echo "All 3 VMs use the same admin password. 12+ chars, mixed case, digit, symbol."
  read -rsp "Admin password (or Enter to auto-generate): " ADMIN_PASSWORD; echo
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="TestPass$(date +%s)!Az"
    ok "Generated: $ADMIN_PASSWORD (save this)"
  fi
fi

SUB_NAME=$(az account show --query name -o tsv)

echo
step "Test workload VMs - configuration"
echo "  Subscription:      $SUB_NAME"
echo "  Resource group:    $RG"
echo "  Location:          $LOCATION"
echo "  Discovery tag:     $DISCOVERY_TAG_KEY=$DISCOVERY_TAG_VALUE"
echo "  Env tag:           $ENV_TAG"
echo "  Linux VM size:     $LINUX_VM_SIZE"
echo "  Windows VM size:   $WIN_VM_SIZE"
echo "  VMs to create:     $UBUNTU_VM (Ubuntu 22.04), $RHEL_VM (RHEL 9), $WIN_VM (Win Server 2022)"
echo
read -rp "Proceed? [y/N]: " yn
yn_lc=$(echo "$yn" | tr '[:upper:]' '[:lower:]')
[[ "$yn_lc" == "y" || "$yn_lc" == "yes" ]] || { warn "Aborted"; exit 0; }

# ---- create resources ----
step "Resource group"
if az group show -n "$RG" >/dev/null 2>&1; then
  ok "Reusing existing $RG"
else
  az group create -n "$RG" -l "$LOCATION" --output none
  ok "Created $RG in $LOCATION"
fi

step "VNet + subnet + NSG"
az network vnet create -g "$RG" -n "$VNET_NAME" \
  --address-prefix 10.10.0.0/16 \
  --subnet-name "$SUBNET_NAME" --subnet-prefix 10.10.1.0/24 \
  --output none 2>/dev/null || true
ok "VNet $VNET_NAME / subnet $SUBNET_NAME"

NSG="${VNET_NAME}-nsg"
az network nsg create -g "$RG" -n "$NSG" --output none 2>/dev/null || true
for rule in "AllowSSH:22:Tcp:100" "AllowWinRM:5985:Tcp:110" "AllowRDP:3389:Tcp:120"; do
  IFS=":" read -r name port proto pri <<<"$rule"
  az network nsg rule create -g "$RG" --nsg-name "$NSG" -n "$name" \
    --priority "$pri" --protocol "$proto" --destination-port-ranges "$port" \
    --access Allow --direction Inbound --source-address-prefixes "*" \
    --output none 2>/dev/null || true
done
ok "NSG opened: SSH(22), WinRM(5985), RDP(3389)"

# ---- create the 3 VMs in parallel ----
step "Provisioning 3 VMs in parallel (~3-5 min)"

create_linux() {
  local name="$1" image="$2" os="$3"
  az vm create -g "$RG" -n "$name" \
    --image "$image" --size "$LINUX_VM_SIZE" \
    --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" --nsg "$NSG" \
    --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASSWORD" \
    --authentication-type password \
    --public-ip-sku Standard \
    --tags "${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}" "os=${os}" "env=${ENV_TAG}" "workload=test" \
    --no-wait
}

create_win() {
  az vm create -g "$RG" -n "$WIN_VM" \
    --image "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest" \
    --size "$WIN_VM_SIZE" \
    --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" --nsg "$NSG" \
    --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASSWORD" \
    --public-ip-sku Standard \
    --tags "${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}" "os=windows" "env=${ENV_TAG}" "workload=test" \
    --no-wait
}

create_linux "$UBUNTU_VM" "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest" "ubuntu"
create_linux "$RHEL_VM" "RedHat:RHEL:9-lvm:latest" "rhel"
create_win

ok "Provisioning started in background. Waiting..."

for vm in "$UBUNTU_VM" "$RHEL_VM" "$WIN_VM"; do
  if az vm wait -g "$RG" -n "$vm" --created --interval 15 --timeout 600 >/dev/null 2>&1; then
    ip=$(az vm show -g "$RG" -n "$vm" -d --query publicIps -o tsv 2>/dev/null)
    ok "$vm ready at $ip"
  else
    warn "$vm timed out waiting for create (may still be provisioning)"
  fi
done

step "All 3 test VMs provisioned + tagged"
az vm list -g "$RG" --query "[].{name:name, location:location, tags:tags}" -o jsonc

step "Next step - run deploy-stack.sh with your custom tag"
echo
echo "  curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/deploy/deploy-stack.sh | \\"
echo "    bash -s -- --discovery-tag-key ${DISCOVERY_TAG_KEY} --discovery-tag-value ${DISCOVERY_TAG_VALUE}"
echo
echo "  In Phase 10 you should see:"
echo "    Workload VMs tagged ${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}: 3"
echo
echo "Cleanup when done:"
echo "  az group delete -n $RG --yes --no-wait"
echo

}   # End of brace-wrap for curl|bash safety
