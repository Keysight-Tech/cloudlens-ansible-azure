# Deployment Guide

End-to-end customer deployment in 6 steps, for a sensors-only rollout against a vController you already run. Two shortcuts exist: `deploy/deploy-stack.sh` deploys the vController (plus KVO and vPB), creates the project key itself, writes `customer_input.yaml` and runs the sensor install, so none of the steps below are typed by hand; and `quickstart.sh` performs Steps 1, 4 and 6 from an `az login` session or Azure Cloud Shell without a service principal. The Docker image (README, Tier 3) runs the same playbooks from a laptop or CI runner. Use `deploy/teardown-stack.sh` to remove an appliance stack; it releases the KVO licences first and asks before deleting.

## Step 1: Prerequisites

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

## Step 2: Clone the repo and create a Service Principal

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

## Step 3: Tag your VMs in Azure

Tag the VMs that should receive CloudLens sensors:

| Tag | Required Value |
|---|---|
| `cloudlens` | `yes` |
| `os` | `ubuntu` \| `rhel` \| `windows` |
| `env` | `prod` (the deploy targets the `*_prod_vms` groups; VMs tagged `env=dev` land in `*_dev_vms` and are only reached by passing `-e target_group=ubuntu_dev_vms` and so on to each playbook; there is no `qa` group) |

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

## Step 4: Configure `customer_input.yaml`

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
  # Private IP when the workload VMs are in, or peered to, the vController's
  # VNet and the admin CIDR is narrowed (the public IP is refused from inside
  # the VNet). Public IP only when the admin CIDR is * or the VMs' egress IPs
  # are inside it. The deploy summary prints it as "Sensors register on".
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

Download the Windows installer from the vController and place it in `files/`:

```bash
cp /path/to/cloudlens-win-sensor-6.13.0.359.exe files/
```

If your file has another version in its name, add it to `customer_input.yaml`:

```yaml
windows:
  ansible_user: "azureuser"
  installer_path: "files/cloudlens-win-sensor-<version>.exe"
  installer_filename: "cloudlens-win-sensor-<version>.exe"
```

The file is git-ignored (`files/*.exe`).

## Step 5: Dry run

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

## Step 6: Deploy

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

1. **Log into the CLMS UI.** Sensors should appear within ~60s.
2. **Filter by your `custom_tags`** to confirm all VMs are listed.
3. **Send test traffic** from a tagged VM.
4. **Verify traffic appears in your defined tool or probe.**

## Troubleshooting

If something fails, check `ansible.log` and see `docs/TROUBLESHOOTING.md`.
