# CloudLens Ansible — Azure Deployment

Automated deployment of Keysight CloudLens sensor agents across **Azure Linux and Windows VMs** at scale.

**One command, fills in customer-specific inputs once, deploys to every VM in the resource group.**

```
Internet → Customer fills customer_input.yaml → ./deploy.sh
                                                     │
                                                     ▼
                            ┌──────────────────────────────────────┐
                            │  Azure Dynamic Inventory             │
                            │  (azure_rm plugin, tag-based groups) │
                            └────────────┬─────────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              ▼                          ▼                          ▼
     ┌────────────────┐         ┌────────────────┐         ┌────────────────┐
     │   Ubuntu VMs   │         │  RHEL/CentOS   │         │  Windows VMs   │
     │  Docker engine │         │  Docker/Podman │         │  WinRM + MSI   │
     │  Sensor image  │         │  Auto-detect   │         │  Silent install│
     └────────────────┘         └────────────────┘         └────────────────┘
              │                          │                          │
              └──────────────────────────┼──────────────────────────┘
                                         ▼
                            ┌──────────────────────────────────────┐
                            │  CloudLens Manager (CLMS)            │
                            │  All sensors auto-register           │
                            └──────────────────────────────────────┘
```

---

## Features

- **Single-file customer input** — fill in `customer_input.yaml`, run one command, done
- **Azure dynamic inventory** — auto-discovers VMs by tag, resource group, or location
- **OS auto-detection** — Ubuntu, RHEL/CentOS (Docker or Podman), Windows MSI
- **WinRM bootstrap** — auto-enables WinRM on Windows VMs via Azure VM Run Command (no manual setup)
- **Idempotent** — re-running detects healthy installs and skips reinstall
- **Cleanup playbooks** — full removal across OS families
- **Scales to thousands of VMs** — parallel execution (default 20 forks, tunable)

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Ansible | ≥ 2.16 | `pip3 install ansible-core==2.16` |
| Azure CLI | latest | [Microsoft docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |
| Python | 3.8+ | system |
| `azure.azcollection` | latest | `ansible-galaxy collection install azure.azcollection` |
| `community.windows` | latest | `ansible-galaxy collection install community.windows` |
| Azure Service Principal | with `Reader` + `Virtual Machine Contributor` on target RGs |

Install all required collections at once:

```bash
ansible-galaxy collection install -r requirements.yml
```

---

## Quick Start (5 Steps)

### 1. Clone the repo

```bash
git clone https://github.com/Keysight-Tech/cloudlens-ansible-azure.git
cd cloudlens-ansible-azure
```

### 2. Create an Azure Service Principal

```bash
./scripts/setup_azure_sp.sh
# Outputs SP credentials — save them as env vars or in ~/.azure/credentials
```

Or manually:

```bash
az ad sp create-for-rbac \
  --name "cloudlens-ansible-sp" \
  --role "Virtual Machine Contributor" \
  --scopes "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RG_NAME>"
```

Export the credentials:

```bash
export AZURE_SUBSCRIPTION_ID=...
export AZURE_TENANT=...
export AZURE_CLIENT_ID=...
export AZURE_SECRET=...
```

### 3. Tag your VMs

For dynamic discovery, tag the target VMs in Azure:

| Tag | Required Values |
|---|---|
| `cloudlens` | `yes` |
| `os` | `ubuntu` \| `rhel` \| `windows` |
| `env` | `prod` \| `dev` \| `qa` (your choice) |

Bulk-tag example:

```bash
az resource tag \
  --tags cloudlens=yes os=ubuntu env=prod \
  --ids $(az vm list -g <RG> --query "[?storageProfile.osDisk.osType=='Linux'].id" -o tsv)
```

### 4. Fill in `customer_input.yaml`

```bash
cp customer_input.yaml.example customer_input.yaml
# Edit:
#   - cloudlens_manager_ip
#   - project_key
#   - azure subscription_id, resource_groups, locations
#   - custom_tags
#   - Windows admin credentials (or Key Vault reference)
```

### 5. Deploy

```bash
./scripts/deploy.sh
```

That runs:

1. WinRM bootstrap on all Windows VMs (Azure VM Run Command)
2. Dynamic inventory build via `azure_rm` plugin
3. Sensor deploy across Ubuntu / RHEL / Windows in parallel
4. Health verification on every VM
5. Final report — success count, failed VMs (if any), logs

---

## Repository Structure

```
.
├── README.md                          # This file
├── LICENSE
├── ansible.cfg                        # Forks=20, SSH multiplexing, log path
├── requirements.yml                   # Ansible collections
├── customer_input.yaml.example        # Customer fills this out
├── deploy.yaml                        # Master deploy sequence
├── cleanup.yaml                       # Master cleanup sequence
│
├── playbooks/
│   ├── bootstrap_windows_winrm.yaml   # Azure-specific: enables WinRM via az vm run-command
│   ├── ubuntu.yaml                    # Ubuntu sensor deploy (Docker)
│   ├── redhat.yaml                    # RHEL sensor deploy (Docker or Podman auto-detect)
│   ├── windows.yaml                   # Windows sensor deploy (MSI via WinRM)
│   ├── ubuntu_cleanup.yaml
│   ├── redhat_cleanup.yaml
│   └── windows_cleanup.yaml
│
├── inventory/
│   ├── azure_rm.yaml                  # Azure dynamic inventory (tag-keyed groups)
│   └── group_vars/
│       ├── all.yaml                   # Centralized CloudLens config
│       ├── ubuntu_prod_vms.yaml
│       ├── redhat_prod_vms.yaml
│       └── windows_prod_vms.yaml      # WinRM connection vars
│
├── vars/
│   └── cloudlens.yaml                 # Container/installer defaults
│
├── scripts/
│   ├── deploy.sh                      # Wizard wrapper — reads customer_input.yaml
│   ├── cleanup.sh                     # Cleanup wrapper
│   ├── setup_azure_sp.sh              # Service Principal creation helper
│   └── bootstrap_winrm.sh             # Standalone WinRM enabler (via Azure CLI)
│
├── files/                             # Place CloudLens Windows installer here
│   └── .gitkeep                       # (Installer is NOT committed — pulled separately)
│
└── docs/
    ├── ARCHITECTURE.md
    ├── DEPLOYMENT_GUIDE.md
    └── TROUBLESHOOTING.md
```

---

## How Azure Dynamic Inventory Works

`inventory/azure_rm.yaml` uses the `azure_rm` plugin with **tag-keyed groups**:

```yaml
plugin: azure.azcollection.azure_rm
include_vm_resource_groups:
  - "{{ resource_groups }}"   # from customer_input.yaml
keyed_groups:
  - prefix: os
    key: tags.os              # creates groups like "os_ubuntu", "os_windows"
  - prefix: env
    key: tags.env             # creates "env_prod", "env_dev"
conditional_groups:
  ubuntu_prod_vms: "'ubuntu' in (tags.os|default('')) and tags.env == 'prod'"
  redhat_prod_vms: "'rhel' in (tags.os|default('')) and tags.env == 'prod'"
  windows_prod_vms: "'windows' in (tags.os|default('')) and tags.env == 'prod'"
hostnames:
  - public_ipv4_addresses   # or private_ipv4_addresses if using Bastion
```

When you tag a VM `cloudlens=yes os=ubuntu env=prod`, it auto-joins `ubuntu_prod_vms` and existing `playbooks/ubuntu.yaml` runs against it. **Zero playbook edits required.**

---

## Windows WinRM Bootstrap (Azure-Specific)

Most Azure Windows VMs ship without WinRM enabled. The `bootstrap_windows_winrm.yaml` playbook uses **Azure VM Run Command** (no WinRM needed yet) to:

1. Enable WinRM listener (`winrm quickconfig -force`)
2. Configure NTLM authentication
3. Open NSG rules 5985/5986
4. Verify connectivity

```bash
ansible-playbook playbooks/bootstrap_windows_winrm.yaml \
  -e "@customer_input.yaml" \
  -i inventory/azure_rm.yaml
```

Done once per VM. After that, all subsequent runs use WinRM directly.

---

## Customer Input Schema

`customer_input.yaml.example` (sanitized):

```yaml
# === Azure Environment ===
azure:
  subscription_id: "00000000-0000-0000-0000-000000000000"
  tenant_id: "00000000-0000-0000-0000-000000000000"
  resource_groups:
    - "customer-prod-rg"
    - "customer-prod-windows-rg"
  locations:
    - "eastus2"

# === CloudLens Configuration ===
cloudlens:
  manager_ip_or_fqdn: "clms.customer.example.com"   # or public IP
  project_key: "<PROJECT_KEY_FROM_CLMS>"
  custom_tags: "Env=Azure Region=eastus2 Customer=Acme"
  registry_type: "insecure"                          # or "secure" if signed registry
  ssl_verify: "no"

# === Linux SSH ===
linux:
  ansible_user: "azureuser"
  ssh_key_file: "~/.ssh/id_rsa"

# === Windows WinRM ===
windows:
  ansible_user: "azureuser"
  ansible_password: "<set via env var $ANSIBLE_WINRM_PASSWORD>"
  installer_path: "files/cloudlens-win-sensor-6.12.0.316.exe"

# === Deployment Behavior ===
deploy:
  forks: 20                # parallel VMs
  auto_update: "yes"
  log_max_size: "50m"
  log_max_file: "5"
```

---

## Commands Reference

| Command | What it does |
|---|---|
| `./scripts/deploy.sh` | Full bootstrap + deploy (recommended) |
| `./scripts/cleanup.sh` | Remove sensors from all VMs |
| `ansible-inventory -i inventory/azure_rm.yaml --graph` | Show discovered VMs grouped by OS |
| `ansible-playbook deploy.yaml -i inventory/azure_rm.yaml --limit ubuntu_prod_vms` | Deploy to one group only |
| `ansible-playbook deploy.yaml -i inventory/azure_rm.yaml --check` | Dry-run |
| `ansible-playbook deploy.yaml -i inventory/azure_rm.yaml --tags verify` | Re-verify deployment health |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Unable to find Service Principal` | SP env vars not exported | `source scripts/load_sp_creds.sh` |
| `Empty inventory — no hosts matched` | VMs not tagged correctly | `az resource tag --tags cloudlens=yes os=ubuntu env=prod ...` |
| Windows tasks fail with `WinRM not configured` | Bootstrap step skipped | Run `playbooks/bootstrap_windows_winrm.yaml` first |
| `Docker daemon not running` (Ubuntu/RHEL) | systemd service masked | `sudo systemctl unmask docker && systemctl start docker` |
| Sensor not appearing in CLMS | Wrong project key or firewall blocking | Verify project key, check NSG rules for outbound 443 to CLMS |

See `docs/TROUBLESHOOTING.md` for the full table.

---

## License

Copyright © Keysight Technologies. Internal use authorized.

---

## Maintainer

Brine-Ndam Ketum — CloudLens Engineering, Keysight Technologies
