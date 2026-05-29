# Deployment Guide

End-to-end customer deployment in 6 steps.

## Step 1 — Prerequisites

On your Ansible control machine (laptop or jumpbox):

```bash
# Azure CLI
brew install azure-cli                    # macOS
# OR: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash    # Ubuntu
# OR: see https://learn.microsoft.com/cli/azure/install-azure-cli

# Ansible
pip3 install ansible-core==2.16

# Collections
ansible-galaxy collection install -r requirements.yml
```

## Step 2 — Clone repo & create Service Principal

```bash
git clone https://github.com/Keysight-Tech/cloudlens-ansible-azure.git
cd cloudlens-ansible-azure

./scripts/setup_azure_sp.sh
# Follow prompts to login, select subscription, create SP
# Outputs: azure_sp_creds.json (DO NOT COMMIT)
#          scripts/load_sp_creds.sh (env export helper)

source scripts/load_sp_creds.sh
```

Verify credentials work:

```bash
az vm list --query "[].{name:name, rg:resourceGroup, location:location, os:storageProfile.osDisk.osType}" -o table
```

## Step 3 — Tag your VMs in Azure

Tag the VMs that should receive CloudLens sensors:

| Tag | Required Value |
|---|---|
| `cloudlens` | `yes` |
| `os` | `ubuntu` \| `rhel` \| `windows` |
| `env` | `prod` (or `dev`/`qa` — must match conditional_groups in `inventory/azure_rm.yaml`) |

Bulk-tag all Linux VMs in a resource group:

```bash
RG=customer-prod-rg

# Ubuntu VMs
for vm in $(az vm list -g $RG --query "[?storageProfile.imageReference.offer=='UbuntuServer' || storageProfile.imageReference.offer=='0001-com-ubuntu-server-jammy'].name" -o tsv); do
  az vm update --resource-group $RG --name $vm --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod
done

# Windows VMs
for vm in $(az vm list -g $RG --query "[?storageProfile.osDisk.osType=='Windows'].name" -o tsv); do
  az vm update --resource-group $RG --name $vm --set tags.cloudlens=yes tags.os=windows tags.env=prod
done
```

## Step 4 — Configure `customer_input.yaml`

```bash
cp customer_input.yaml.example customer_input.yaml
```

Edit `customer_input.yaml`:

```yaml
azure:
  subscription_id: "<YOUR_SUB_ID>"
  tenant_id: "<YOUR_TENANT_ID>"
  resource_groups:
    - "customer-prod-rg"
  locations:
    - "eastus2"

cloudlens:
  manager_ip_or_fqdn: "20.x.x.x"        # ← from CLMS deployment
  project_key: "<FROM_CLMS_UI>"          # ← Projects → API Keys
  custom_tags: "Env=Azure Region=eastus2 Customer=Acme"

linux:
  ansible_user: "azureuser"
  ssh_key_file: "~/.ssh/customer-prod.pem"

windows:
  ansible_user: "azureuser"
```

Set the Windows admin password env var (do NOT put it in the yaml):

```bash
export ANSIBLE_WINRM_PASSWORD='YourSecurePassword123!'
```

Place the Windows installer in `files/`:

```bash
cp /path/to/cloudlens-win-sensor-6.12.0.316.exe files/
```

## Step 5 — Dry run

Preview what will happen without making changes:

```bash
# Show what VMs the dynamic inventory will pick up
ansible-inventory -i inventory/azure_rm.yaml --graph

# Dry-run the deployment
ansible-playbook deploy.yaml \
  -e "@customer_input.yaml" \
  -i inventory/azure_rm.yaml \
  --check
```

## Step 6 — Deploy

```bash
./scripts/deploy.sh
```

Walks through:

1. Pre-flight checks (CLI tools, env vars, installer presence)
2. Inventory preview + confirmation prompt
3. WinRM bootstrap on Windows VMs (~30s per VM)
4. Sensor deployment in parallel across Ubuntu/RHEL/Windows
5. Health verification
6. Final summary with CLMS UI link

Expected output (per Linux VM):

```
TASK [Verify CloudLens Agent container is running] ******
ok: [20.85.x.x] => "CloudLens agent container 'cloudlens-agent' is running"
```

Expected output (per Windows VM):

```
TASK [Final status] ******
ok: [20.85.y.y] => "CloudLens Deployment
                    Service: RUNNING
                    Process: YES
                    Registry: PRESENT
                    Config: EXISTS
                    Result: SUCCESS"
```

## Post-Deployment Verification

1. **Log into CLMS UI** — sensors should appear within ~60s
2. **Filter by your `custom_tags`** — confirm all VMs are listed
3. **Send test traffic** from a tagged VM
4. **Verify traffic appears in your defined tool/probe**

## Troubleshooting

If something fails, check `ansible.log` and see `docs/TROUBLESHOOTING.md`.
