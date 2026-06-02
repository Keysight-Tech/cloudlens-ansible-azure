# CloudLens Ansible — Azure Deployment

Automated deployment of Keysight CloudLens sensor agents across **Azure Linux and Windows VMs** at scale.

Supports **Ubuntu, RHEL/CentOS, Windows Server**. Discovers VMs by Azure tags. Scales from 1 VM to 5,000+ in parallel.

---

## ⚡ Quick Start — Three Ways to Deploy

Pick the path that fits your team:

### 1. 🌐 Click-to-Deploy from Azure Portal (zero install)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FKeysight-Tech%2Fcloudlens-ansible-azure%2Fmain%2Fdeploy%2Farm-template.json)

Provisions an ephemeral Ubuntu runner that discovers your tagged VMs, deploys sensors, then self-destructs after 1 hour. **Zero tools needed on your machine.**

### 2. ☁️ Azure Cloud Shell (browser-based)

Open [Azure Cloud Shell](https://shell.azure.com), then paste:

```bash
curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/quickstart.sh | bash
```

Cloud Shell is already authenticated to Azure — no Service Principal needed. The wizard prompts for CLMS IP and project key, then deploys.

### 3. 🐳 Docker (local PC, CI/CD, anywhere)

```bash
docker run --rm -it \
  -v $(pwd)/customer_input.yaml:/work/customer_input.yaml \
  -v $HOME/.ssh:/root/.ssh:ro \
  -v $(pwd)/files:/work/files:ro \
  -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT \
  -e AZURE_CLIENT_ID -e AZURE_SECRET \
  -e ANSIBLE_WINRM_PASSWORD \
  ghcr.io/keysight-tech/cloudlens-ansible-azure:latest
```

No Python or Ansible on your machine — just Docker. Works on macOS, Windows, Linux, CI/CD runners.

---

## 🎯 What This Does

```
Internet → Customer fills customer_input.yaml → ./quickstart.sh
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

## 🏷️ Customer Prerequisites — Tag Your VMs

Apply these tags to every VM that should receive a CloudLens sensor:

| Tag | Required Value |
|---|---|
| `cloudlens` | `yes` |
| `os` | `ubuntu` \| `rhel` \| `windows` |
| `env` | `prod` (or `dev`, `qa`) |

Bulk-tag a resource group:

```bash
# All Ubuntu VMs in an RG
for vm in $(az vm list -g <RG> --query "[?storageProfile.imageReference.offer=='0001-com-ubuntu-server-jammy'].name" -o tsv); do
  az vm update -g <RG> -n $vm --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod
done

# All Windows VMs in an RG
for vm in $(az vm list -g <RG> --query "[?storageProfile.osDisk.osType=='Windows'].name" -o tsv); do
  az vm update -g <RG> -n $vm --set tags.cloudlens=yes tags.os=windows tags.env=prod
done
```

---

## 📊 Scaling — From 1 VM to 5,000+

`quickstart.sh` and the Docker entrypoint **auto-tune** Ansible forks based on discovered VM count:

| VM Count | Forks | Strategy | Wall Time |
|---|---|---|---|
| 1–50 | 20 | Single control node | 5–10 min |
| 50–500 | 50 | Single control node | 15–30 min |
| 500–2,000 | 200 | Single control node, tuned | 30–60 min |
| 2,000–10,000 | 500 per shard | **Sharded** (auto-enabled) | 30–60 min |
| 10,000+ | 1000 per shard | AWX/Tower integration | 1–2 hr |

### How Sharding Works

When VM count > 2,000, deployment auto-shards:

```
5,000 VMs ÷ 500 per shard = 10 shards in parallel
Each shard: 500 VMs × 500 forks
Total Ansible workers: 5,000 simultaneous
```

Each shard is independent — failures isolate to that shard. Logs aggregated at end.

Manual shard launch:
```bash
bash deploy/shard.sh 5000 500          # 5000 VMs, 500 forks per shard
SHARD_SIZE=250 bash deploy/shard.sh 5000  # finer-grained shards
```

---

## 🔐 Authentication

| Deployment Path | Auth Method |
|---|---|
| Azure Portal click-deploy | Managed Identity (auto-assigned to runner) |
| Cloud Shell | Inherits your Azure CLI login (no SP needed) |
| Docker / local | Service Principal env vars (`scripts/setup_azure_sp.sh`) |

To create a Service Principal:
```bash
bash scripts/setup_azure_sp.sh
source scripts/load_sp_creds.sh
```

---

## 📁 Repository Layout

```
cloudlens-ansible-azure/
├── quickstart.sh                ← Tier 2 entry (Cloud Shell + local)
├── Dockerfile                    ← Tier 3 container image
├── deploy/
│   ├── arm-template.json        ← Tier 1 Azure Portal one-click
│   ├── shard.sh                  ← Sharded deployment for thousands
│   └── tuned-ansible.cfg         ← High-scale forks/pipelining
├── customer_input.yaml.example   ← Customer config schema
├── inventory/
│   ├── azure_rm.yaml             ← Dynamic inventory (Azure tags)
│   └── group_vars/               ← OS-specific connection vars
├── playbooks/
│   ├── ubuntu.yaml               ← Ubuntu sensor deployment
│   ├── redhat.yaml               ← RHEL auto-detect Docker/Podman
│   ├── windows.yaml              ← Windows MSI silent install
│   ├── bootstrap_windows_winrm.yaml  ← Enables WinRM via Azure Run Command
│   └── *_cleanup.yaml            ← Removal playbooks
├── scripts/
│   ├── setup_azure_sp.sh         ← Service Principal helper
│   ├── docker-entrypoint.sh      ← Container CMD router
│   └── *.sh                       ← Other helpers
└── docs/
    ├── DEPLOYMENT_GUIDE.md
    ├── SCALING.md
    ├── ARCHITECTURE.md
    └── TROUBLESHOOTING.md
```

---

## ⚙️ How It Works — The Engine

Regardless of deployment tier, the same engine runs:

1. **Authenticate** — Managed Identity / Cloud Shell login / Service Principal
2. **Discover** — `azure_rm` inventory plugin scans for `cloudlens=yes` tagged VMs
3. **Group** — Auto-groups by `os` and `env` tags
4. **Connect**
   - Linux VMs → SSH (jumpbox or direct, configurable)
   - Windows VMs → WinRM (Azure Run Command bootstraps WinRM if disabled)
5. **Deploy**
   - Ubuntu: install Docker → pull sensor → `docker run` with `NET_RAW` caps
   - RHEL: auto-detect Docker/Podman → install → deploy container
   - Windows: copy installer → silent MSI install → verify service
6. **Verify** — Each playbook validates the sensor is running before exiting
7. **Auto-tune scale** — Fork count + sharding based on VM count

---

## 📖 Documentation

- [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) — Step-by-step customer guide
- [docs/SCALING.md](docs/SCALING.md) — Scale to thousands of VMs
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Internal architecture
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — Common issues

---

## 🧪 Verified Against Real Azure

Smoke-tested deployment to:
- 2× Ubuntu 22.04 VMs (private IPs via SSH jumpbox)
- 1× Windows Server 2022 (WinRM direct via public IP, bootstrapped via Azure Run Command)
- CLMS 6.14.141 deployed in same VNet
- Sensors registered, project key validated, containers running

---

## 🛟 Support

Issues or questions: [GitHub Issues](https://github.com/Keysight-Tech/cloudlens-ansible-azure/issues)

For internal Keysight engineering: contact CloudLens engineering team.
