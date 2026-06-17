#!/usr/bin/env bash
# =====================================================================
# NetRefer-style CloudLens Visibility Demo: end-to-end build
# =====================================================================
# Provisions everything a customer would have in a real deployment, then
# runs the CUSTOMER-FACING automation (deploy-stack.sh ARM templates +
# quickstart.sh Ansible) so the demo proves the production path works.
#
# Outcome:
#   - demo-prod-rg:      4 workload VMs (Ubuntu + Windows), cloudlens=yes
#   - demo-cloudlens-rg: vController + vPB (KVO reused from kvo-test-rg)
#   - demo-vectra-rg:    Vectra-mock receiver (nginx + tcpdump on UDP 4789)
#   - All sensors deployed via quickstart.sh Ansible automation
#   - run-demo.sh generated for live walkthrough
#
# Usage:
#   bash demo/setup-netrefer-demo.sh                     # full build
#   bash demo/setup-netrefer-demo.sh --skip-workloads    # reuse existing VMs
#   bash demo/setup-netrefer-demo.sh --skip-sensors      # don't run Ansible
#   bash demo/setup-netrefer-demo.sh --teardown          # nuke everything
#
# Teardown (~30s):
#   az group delete -n demo-prod-rg -n demo-cloudlens-rg -n demo-vectra-rg --yes --no-wait
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------
LOCATION="${DEMO_LOCATION:-eastus2}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROD_RG="demo-prod-rg"
CLOUDLENS_RG="demo-cloudlens-rg"
VECTRA_RG="demo-vectra-rg"
KVO_RG="kvo-test-rg"           # reuse the KVO already deployed earlier

PROD_VNET="prod-vnet"
PROD_SUBNET="workload-subnet"
PROD_VNET_CIDR="10.100.0.0/16"
PROD_SUBNET_CIDR="10.100.1.0/24"

VECTRA_VNET="vectra-vnet"
VECTRA_SUBNET="vectra-subnet"
VECTRA_VNET_CIDR="10.200.0.0/16"
VECTRA_SUBNET_CIDR="10.200.1.0/24"

ADMIN_USER="azureuser"
STATE_DIR="${HOME}/.netrefer-demo"
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
PASSWORD_FILE="${STATE_DIR}/admin_pw"

UBUNTU_IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
WIN_IMAGE="MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest"
VECTRA_IMAGE="$UBUNTU_IMAGE"

VPB_TEMPLATE="${REPO_ROOT}/deploy/vpb-marketplace.json"
VC_TEMPLATE="${REPO_ROOT}/deploy/clms-marketplace.json"

SKIP_WORKLOADS=false
SKIP_SENSORS=false
DO_TEARDOWN=false

# ---------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;34m'; C_R='\033[0;31m'; C_GR='\033[0;90m'; C_BD='\033[1m'; C_X='\033[0m'
else C_G=''; C_Y=''; C_B=''; C_R=''; C_GR=''; C_BD=''; C_X=''; fi
banner() { echo; echo -e "${C_B}╔═══════════════════════════════════════════════════════════════╗${C_X}"; printf "${C_B}║${C_X}  ${C_BD}%-61s${C_X}${C_B}║${C_X}\n" "$1"; echo -e "${C_B}╚═══════════════════════════════════════════════════════════════╝${C_X}"; }
step()   { echo; echo -e "${C_B}━━━ $1 ━━━${C_X}"; }
ok()     { echo -e "${C_G}✓${C_X} $1"; }
warn()   { echo -e "${C_Y}⚠${C_X} $1"; }
fail()   { echo -e "${C_R}✗${C_X} $1" >&2; exit 1; }
note()   { echo -e "${C_GR}→ $1${C_X}"; }

# ---------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-workloads) SKIP_WORKLOADS=true; shift ;;
    --skip-sensors)   SKIP_SENSORS=true; shift ;;
    --teardown)       DO_TEARDOWN=true; shift ;;
    -h|--help)
      sed -n '/^# Usage/,/^# Teardown/p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) fail "Unknown arg: $1" ;;
  esac
done

if [[ "$DO_TEARDOWN" == "true" ]]; then
  banner "Tearing down NetRefer demo"
  for rg in "$PROD_RG" "$CLOUDLENS_RG" "$VECTRA_RG"; do
    if az group show -n "$rg" >/dev/null 2>&1; then
      az group delete -n "$rg" --yes --no-wait
      ok "deleted $rg"
    else
      note "absent: $rg"
    fi
  done
  ok "Teardown initiated. KVO and your other resource groups are untouched."
  exit 0
fi

# ---------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------
banner "NetRefer Demo: end-to-end CloudLens visibility build"

step "Phase 0: Pre-flight"
command -v az >/dev/null || fail "az CLI not found"
az account show --query "{name:name, user:user.name}" -o tsv | head -1 | awk '{print "subscription: " $1 "  signed in as: " $2}'
SUB_ID=$(az account show --query id -o tsv)
ok "Subscription confirmed"

[[ -f ~/.ssh/id_rsa.pub ]] || fail "~/.ssh/id_rsa.pub missing — run ssh-keygen first"
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)
ok "SSH public key ready"

# Generate or load the shared admin password
if [[ -f "$PASSWORD_FILE" ]]; then
  ADMIN_PW=$(cat "$PASSWORD_FILE")
  ok "Reusing stored admin password (${STATE_DIR}/admin_pw)"
else
  ADMIN_PW=$(python3 -c "
import secrets, string
alpha = string.ascii_letters; digits = string.digits; syms = '!@#\$%^&*'
pw = (secrets.choice(string.ascii_uppercase) + secrets.choice(string.ascii_lowercase) +
      secrets.choice(digits) + secrets.choice(syms) +
      ''.join(secrets.choice(alpha+digits+syms) for _ in range(12)))
print(pw)")
  umask 077
  echo "$ADMIN_PW" > "$PASSWORD_FILE"
  ok "Generated admin password, saved to ${PASSWORD_FILE} (mode 600)"
fi

# ---------------------------------------------------------------------
# Phase 1: Resource groups
# ---------------------------------------------------------------------
step "Phase 1: Resource groups"
for rg in "$PROD_RG" "$CLOUDLENS_RG" "$VECTRA_RG"; do
  if az group show -n "$rg" >/dev/null 2>&1; then
    ok "exists: $rg"
  else
    az group create -n "$rg" -l "$LOCATION" \
      --tags purpose=netrefer-demo deployedBy=cloudlens-demo >/dev/null
    ok "created: $rg"
  fi
done

# ---------------------------------------------------------------------
# Phase 2: Marketplace terms (vController + vPB; KVO already accepted)
# ---------------------------------------------------------------------
step "Phase 2: Accept marketplace terms"
accept() {
  if az vm image terms show --publisher "$1" --offer "$2" --plan "$3" \
       --query accepted -o tsv 2>/dev/null | grep -q true; then
    ok "already accepted: $2 / $3"
  else
    az vm image terms accept --publisher "$1" --offer "$2" --plan "$3" >/dev/null
    ok "accepted: $2 / $3"
  fi
}
accept keysight-technologies-cloudlens keysight-cloudlens-vcontroller    cloudlens-vcontroller-6-14-0_89
accept keysight-technologies-cloudlens keysight-cloudlens-virtual-packet-broker cloudlens-virtual-packet-broker-3-15-0_1

# ---------------------------------------------------------------------
# Phase 3: Workload VMs (Ubuntu x2 + Windows x2)
# ---------------------------------------------------------------------
if [[ "$SKIP_WORKLOADS" == "true" ]]; then
  step "Phase 3: Workload VMs (skipped via --skip-workloads)"
else
  step "Phase 3: Workload VNet + 4 VMs (parallel)"

  if ! az network vnet show -g "$PROD_RG" -n "$PROD_VNET" >/dev/null 2>&1; then
    az network vnet create -g "$PROD_RG" -n "$PROD_VNET" \
      --address-prefix "$PROD_VNET_CIDR" \
      --subnet-name "$PROD_SUBNET" \
      --subnet-prefix "$PROD_SUBNET_CIDR" >/dev/null
    ok "vnet created: $PROD_VNET"
  else
    ok "vnet exists: $PROD_VNET"
  fi

  # Open NSG: SSH from this machine, WinRM, internal-only outbound to vPB
  MY_IP="$(curl -fsSL https://api.ipify.org)"/32
  if ! az network nsg show -g "$PROD_RG" -n workload-nsg >/dev/null 2>&1; then
    az network nsg create -g "$PROD_RG" -n workload-nsg >/dev/null
    az network nsg rule create -g "$PROD_RG" --nsg-name workload-nsg \
      -n AllowSSH --priority 100 --protocol Tcp --destination-port-ranges 22 \
      --source-address-prefixes "$MY_IP" --access Allow --direction Inbound >/dev/null
    az network nsg rule create -g "$PROD_RG" --nsg-name workload-nsg \
      -n AllowWinRM --priority 110 --protocol Tcp --destination-port-ranges 5985 5986 \
      --source-address-prefixes "$MY_IP" --access Allow --direction Inbound >/dev/null
    az network nsg rule create -g "$PROD_RG" --nsg-name workload-nsg \
      -n AllowRDP --priority 120 --protocol Tcp --destination-port-ranges 3389 \
      --source-address-prefixes "$MY_IP" --access Allow --direction Inbound >/dev/null
    ok "NSG created (SSH/WinRM/RDP from $MY_IP only)"
  fi
  az network vnet subnet update -g "$PROD_RG" --vnet-name "$PROD_VNET" \
    -n "$PROD_SUBNET" --network-security-group workload-nsg >/dev/null
  ok "NSG attached to workload subnet"

  vm_exists() { az vm show -g "$PROD_RG" -n "$1" >/dev/null 2>&1; }

  deploy_ubuntu() {
    local name="$1"
    vm_exists "$name" && { ok "exists: $name"; return; }
    az vm create -g "$PROD_RG" -n "$name" \
      --image "$UBUNTU_IMAGE" --size Standard_B2s \
      --admin-username "$ADMIN_USER" \
      --ssh-key-values ~/.ssh/id_rsa.pub \
      --vnet-name "$PROD_VNET" --subnet "$PROD_SUBNET" \
      --public-ip-sku Standard \
      --tags cloudlens=yes os=ubuntu env=prod purpose=netrefer-demo \
      --nsg "" --no-wait
    ok "deploying (async): $name"
  }
  deploy_windows() {
    local name="$1"
    vm_exists "$name" && { ok "exists: $name"; return; }
    az vm create -g "$PROD_RG" -n "$name" \
      --image "$WIN_IMAGE" --size Standard_B2s \
      --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PW" \
      --vnet-name "$PROD_VNET" --subnet "$PROD_SUBNET" \
      --public-ip-sku Standard \
      --tags cloudlens=yes os=windows env=prod purpose=netrefer-demo \
      --nsg "" --no-wait
    ok "deploying (async): $name"
  }

  deploy_ubuntu app01-ubuntu
  deploy_ubuntu app02-ubuntu
  deploy_windows win01
  deploy_windows win02

  note "Waiting for all 4 workload VMs to finish (parallel)..."
  az vm wait --created --ids \
    $(az vm list -g "$PROD_RG" --query "[].id" -o tsv) \
    >/dev/null
  ok "All 4 workload VMs running"

  # Enable WinRM on Windows VMs via Run Command (HTTP only, demo trust model)
  for w in win01 win02; do
    if vm_exists "$w"; then
      note "Enabling WinRM on $w (Run Command)..."
      az vm run-command invoke -g "$PROD_RG" -n "$w" \
        --command-id RunPowerShellScript \
        --scripts "winrm quickconfig -force; winrm set winrm/config/service '@{AllowUnencrypted=\"true\"}'; winrm set winrm/config/service/auth '@{Basic=\"true\"}'" \
        >/dev/null 2>&1 || warn "WinRM bootstrap on $w returned non-zero (continuing)"
    fi
  done
  ok "Windows WinRM bootstrapped"
fi

# ---------------------------------------------------------------------
# Phase 4: vController (formerly CLMS)
# ---------------------------------------------------------------------
step "Phase 4: vController (uses the same ARM template customers click on the site)"
if az vm show -g "$CLOUDLENS_RG" -n vcontroller >/dev/null 2>&1; then
  ok "vController already deployed"
else
  note "Deploying vController via deploy/clms-marketplace.json (~15 min)..."
  az deployment group create \
    -g "$CLOUDLENS_RG" \
    -n "vcontroller-$(date +%s)" \
    --template-file "$VC_TEMPLATE" \
    --parameters \
        vmName=vcontroller \
        adminUsername="$ADMIN_USER" \
        adminPassword="$ADMIN_PW" \
        vmSize=Standard_D4s_v5 \
        addressSpace=10.150.0.0/16 \
        subnetPrefix=10.150.1.0/24 \
    --query "{state:properties.provisioningState, ip:properties.outputs.clmsPublicIp.value}" -o tsv | head -1
  ok "vController deployed"
fi
VC_IP=$(az network public-ip show -g "$CLOUDLENS_RG" -n vcontroller-pip --query ipAddress -o tsv)
ok "vController IP: $VC_IP"
ok "vController UI: https://$VC_IP  (admin / Cl0udLens@dm!n)"

# ---------------------------------------------------------------------
# Phase 5: vPB
# ---------------------------------------------------------------------
step "Phase 5: vPB (parallel deploy, ~10 min)"
if az vm show -g "$CLOUDLENS_RG" -n vpb >/dev/null 2>&1; then
  ok "vPB already deployed"
else
  note "Deploying vPB via deploy/vpb-marketplace.json..."
  az deployment group create \
    -g "$CLOUDLENS_RG" \
    -n "vpb-$(date +%s)" \
    --template-file "$VPB_TEMPLATE" \
    --parameters \
        vmName=vpb \
        adminUsername="$ADMIN_USER" \
        adminPassword="$ADMIN_PW" \
        vmSize=Standard_D8s_v3 \
        addressSpace=10.150.0.0/16 \
        mgmtSubnetPrefix=10.150.2.0/24 \
        ingressSubnetPrefix=10.150.3.0/24 \
        egressSubnetPrefix=10.150.4.0/24 \
        existingVnetName=vcontroller-vnet \
    --query "{state:properties.provisioningState}" -o tsv
  ok "vPB deployed"
fi
VPB_MGMT_IP=$(az network public-ip show -g "$CLOUDLENS_RG" -n vpb-mgmt-pip --query ipAddress -o tsv 2>/dev/null || echo "pending")
ok "vPB mgmt IP: $VPB_MGMT_IP"

# ---------------------------------------------------------------------
# Phase 6: Vectra mock receiver
# ---------------------------------------------------------------------
step "Phase 6: Vectra mock receiver (Ubuntu + tcpdump on UDP/4789)"
if az vm show -g "$VECTRA_RG" -n vectra-mock >/dev/null 2>&1; then
  ok "Vectra mock exists"
else
  if ! az network vnet show -g "$VECTRA_RG" -n "$VECTRA_VNET" >/dev/null 2>&1; then
    az network vnet create -g "$VECTRA_RG" -n "$VECTRA_VNET" \
      --address-prefix "$VECTRA_VNET_CIDR" \
      --subnet-name "$VECTRA_SUBNET" --subnet-prefix "$VECTRA_SUBNET_CIDR" >/dev/null
    ok "vectra vnet created"
  fi

  CLOUD_INIT=$(mktemp)
  cat > "$CLOUD_INIT" <<'CI'
#cloud-config
package_update: true
packages:
  - tcpdump
  - nginx
runcmd:
  - systemctl enable --now nginx
  - mkdir -p /var/log/vxlan
  - bash -c "nohup tcpdump -i eth0 -nn -w /var/log/vxlan/vxlan.pcap udp port 4789 > /var/log/vxlan/tcpdump.log 2>&1 &"
  - echo '<h1>Vectra Mock - VXLAN UDP/4789 listener live</h1>' > /var/www/html/index.html
CI

  MY_IP="$(curl -fsSL https://api.ipify.org)"/32
  az vm create -g "$VECTRA_RG" -n vectra-mock \
    --image "$VECTRA_IMAGE" --size Standard_B2s \
    --admin-username "$ADMIN_USER" --ssh-key-values ~/.ssh/id_rsa.pub \
    --vnet-name "$VECTRA_VNET" --subnet "$VECTRA_SUBNET" \
    --public-ip-sku Standard \
    --custom-data "$CLOUD_INIT" \
    --nsg-rule SSH \
    --tags purpose=netrefer-demo role=vectra-mock >/dev/null
  rm -f "$CLOUD_INIT"
  ok "vectra-mock deployed"
fi
VECTRA_IP=$(az network public-ip show -g "$VECTRA_RG" -n vectra-mockPublicIP --query ipAddress -o tsv 2>/dev/null \
  || az vm list-ip-addresses -g "$VECTRA_RG" -n vectra-mock --query "[].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
ok "Vectra mock IP: $VECTRA_IP"

# ---------------------------------------------------------------------
# Phase 7: VNet peering so sensors can reach vPB
# ---------------------------------------------------------------------
step "Phase 7: VNet peering (workload <-> cloudlens-stack)"
peer_exists() { az network vnet peering show -g "$1" --vnet-name "$2" -n "$3" >/dev/null 2>&1; }
PROD_VNET_ID=$(az network vnet show -g "$PROD_RG" -n "$PROD_VNET" --query id -o tsv)
CL_VNET_ID=$(az network vnet show -g "$CLOUDLENS_RG" -n vcontroller-vnet --query id -o tsv)
if ! peer_exists "$PROD_RG" "$PROD_VNET" prod-to-cloudlens; then
  az network vnet peering create -g "$PROD_RG" --vnet-name "$PROD_VNET" -n prod-to-cloudlens \
    --remote-vnet "$CL_VNET_ID" --allow-vnet-access >/dev/null
  ok "peering created: prod -> cloudlens"
fi
if ! peer_exists "$CLOUDLENS_RG" vcontroller-vnet cloudlens-to-prod; then
  az network vnet peering create -g "$CLOUDLENS_RG" --vnet-name vcontroller-vnet -n cloudlens-to-prod \
    --remote-vnet "$PROD_VNET_ID" --allow-vnet-access >/dev/null
  ok "peering created: cloudlens -> prod"
fi

# ---------------------------------------------------------------------
# Phase 8: Project key + sensor deployment (the customer-facing path)
# ---------------------------------------------------------------------
if [[ "$SKIP_SENSORS" == "true" ]]; then
  step "Phase 8: Sensor deployment (skipped via --skip-sensors)"
else
  step "Phase 8: CloudLens sensor deployment via quickstart.sh"

  # Fully automated project-key retrieval. The helper is opt-in --insecure
  # ONLY because we are reaching a vController we provisioned moments ago, by
  # public IP, from the operator machine. Production usage of the same helper
  # should pass --ca-bundle once the vController cert is trusted.
  note "Asking vController for a project key (scripts/vcontroller_project_key.py)..."
  PROJECT_KEY=$(VCONTROLLER_NEW_PASS="$ADMIN_PW" \
    python3 "${REPO_ROOT}/scripts/vcontroller_project_key.py" \
        --host "$VC_IP" \
        --project "netrefer-demo" \
        --insecure 2>&1 1>/tmp/.project_key.out; cat /tmp/.project_key.out)
  rm -f /tmp/.project_key.out
  if [[ -z "$PROJECT_KEY" ]]; then
    warn "Automated key retrieval failed; falling back to manual paste"
    cat <<EOM

  Manual fallback:
  1. Open https://${VC_IP}, sign in admin / Cl0udLens@dm!n (or change-to password)
  2. Projects -> Add Project, name it "netrefer-demo"
  3. Open the project, copy the API key
EOM
    read -rp "Paste the project key (or press Enter to skip): " PROJECT_KEY
  else
    ok "Project key retrieved automatically"
  fi

  if [[ -z "$PROJECT_KEY" ]]; then
    warn "Skipping sensor deployment"
  else
    cat > "${REPO_ROOT}/customer_input.yaml" <<YAML
# Auto-generated by demo/setup-netrefer-demo.sh on $(date -u +%FT%TZ)
azure:
  subscription_id: "${SUB_ID}"
  tag_filters:
    cloudlens: "yes"
  resource_groups:
    - "${PROD_RG}"
cloudlens:
  manager_ip_or_fqdn: "${VC_IP}"
  project_key: "${PROJECT_KEY}"
  custom_tags: "Customer=NetRefer Env=Demo Region=${LOCATION}"
  registry_type: "insecure"
  ssl_verify: "no"
  auto_update: "yes"
connection:
  mode: "direct_public"
linux:
  ansible_user: "${ADMIN_USER}"
  ssh_key_file: "~/.ssh/id_rsa"
windows:
  ansible_user: "${ADMIN_USER}"
  ansible_password: "${ADMIN_PW}"
  connection: "winrm"
  port: 5985
  transport: "ntlm"
YAML
    ok "customer_input.yaml written"

    note "Running quickstart.sh (Ansible automation)..."
    (cd "$REPO_ROOT" && bash quickstart.sh || warn "quickstart.sh exited non-zero (see log)")
    ok "Sensor deployment finished"
  fi
fi

# ---------------------------------------------------------------------
# Phase 9: Generate run-demo.sh for the live walkthrough
# ---------------------------------------------------------------------
step "Phase 9: Generate run-demo.sh"
cat > "${REPO_ROOT}/demo/run-demo.sh" <<DEMO
#!/usr/bin/env bash
# Live walkthrough script - generated $(date -u +%FT%TZ)
set -e

VC_UI="https://${VC_IP}"
KVO_UI="https://20.230.15.87"
VECTRA_IP="${VECTRA_IP}"
VPB_MGMT="${VPB_MGMT_IP}"
APP_VM_IP=\$(az network public-ip show -g ${PROD_RG} -n app01-ubuntuPublicIP --query ipAddress -o tsv 2>/dev/null)

echo "=== NetRefer CloudLens Visibility Demo ==="
echo ""
echo "Slide 1 - The architecture"
open "https://keysight-tech.github.io/cloudlens-ansible-azure/"
sleep 4

echo "Slide 2 - The vController UI (4 sensors registered)"
open "\$VC_UI"
sleep 4

echo "Slide 3 - The KVO UI (centralized vPB fleet mgmt)"
open "\$KVO_UI"
sleep 4

echo "Slide 4 - The packet path. tcpdump from Vectra mock as we generate traffic:"
ssh -o StrictHostKeyChecking=no ${ADMIN_USER}@\$VECTRA_IP \\
  "sudo tcpdump -i eth0 -nn -c 30 udp port 4789" &
TCPDUMP_PID=\$!
sleep 3

echo "Slide 5 - Generate traffic from a workload VM"
ssh -o StrictHostKeyChecking=no ${ADMIN_USER}@\$APP_VM_IP \\
  "for i in {1..15}; do curl -s -o /dev/null https://www.bing.com; sleep 1; done"

wait \$TCPDUMP_PID 2>/dev/null || true
echo ""
echo "Punchline: same flow seen on the workload VM AND on the Vectra mock."
echo "Out-of-band. No vTAP. No GWLB. Session affinity by 5-tuple hash at the vPB."
DEMO
chmod +x "${REPO_ROOT}/demo/run-demo.sh"
ok "run-demo.sh generated"

# ---------------------------------------------------------------------
# Phase 10: Final summary
# ---------------------------------------------------------------------
banner "Demo build COMPLETE"
cat <<EOM

UIs to open:
  vController:   https://${VC_IP}    (admin / Cl0udLens@dm!n)
  KVO:           https://20.230.15.87
  Vectra mock:   http://${VECTRA_IP}

SSH:
  ssh ${ADMIN_USER}@${VC_IP}          # vController VM
  ssh ${ADMIN_USER}@${VECTRA_IP}      # Vectra mock
  ssh ${ADMIN_USER}@<workload-ip>     # any app01-ubuntu / app02-ubuntu

OS passwords stashed at:
  ${PASSWORD_FILE}    (mode 600)

Live walkthrough:
  bash demo/run-demo.sh

Teardown (~30s):
  bash demo/setup-netrefer-demo.sh --teardown

Cost estimate:
  vController D4s_v5     ~\$5/day
  KVO D4s_v5             ~\$5/day  (kvo-test-rg, separate)
  vPB D8s_v3             ~\$15/day
  4x B2s workload VMs    ~\$5/day
  Vectra mock B2s        ~\$1/day
  Public IPs             ~\$0.50/day
  Total                  ~\$30/day until teardown
EOM
