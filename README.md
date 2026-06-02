# CloudLens Ansible — Azure Deployment

**Deploy CloudLens sensors to any Azure VM in under 60 seconds — Linux, Windows, and at scale.**

![Tested on Azure](https://img.shields.io/badge/Tested%20on-Azure-0078D4?logo=microsoft-azure)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04-E95420?logo=ubuntu)
![RHEL](https://img.shields.io/badge/RHEL-7%2F8%2F9-EE0000?logo=redhat)
![Windows](https://img.shields.io/badge/Windows-Server%202022-0078D4?logo=windows)
![Sensors deployed](https://img.shields.io/badge/Sensors%20deployed-3%2F3-22C55E)
![License](https://img.shields.io/badge/License-Keysight-D4AF37)

![CloudLens Ansible Demo](docs/assets/deploy-demo.svg)

<p align="center">
  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FKeysight-Tech%2Fcloudlens-ansible-azure%2Fmain%2Fdeploy%2Farm-template.json"><img src="https://img.shields.io/badge/▶_Deploy_to_Azure-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white" alt="Deploy to Azure"/></a>
  <a href="https://shell.azure.com"><img src="https://img.shields.io/badge/☁_Cloud_Shell-005A9E?style=for-the-badge&logo=azure-pipelines&logoColor=white" alt="Cloud Shell"/></a>
  <a href="https://github.com/Keysight-Tech/cloudlens-ansible-azure/pkgs/container/cloudlens-ansible-azure"><img src="https://img.shields.io/badge/🐳_Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker"/></a>
</p>

---

## Which path?

![Decision Tree](docs/assets/decision-tree.svg)

All three paths run the same Ansible engine — same playbooks, same automation. Pick the entry point that matches where you work.

---

## Supported VM Scenarios

![VM Compatibility Matrix](docs/assets/scenario-matrix.svg)

| OS / Topology | Public IP direct | Private + Jumpbox | Azure Bastion | Cloud Shell |
|---|:---:|:---:|:---:|:---:|
| Ubuntu 20.04 / 22.04 / 24.04 | ✓ | ✓ | ✓ | ✓ |
| RHEL 7 / 8 / 9 | ✓ | ✓ | ✓ | ✓ |
| CentOS / Rocky / AlmaLinux | ✓ | ✓ | ✓ | ✓ |
| Windows Server 2019 / 2022 | ✓ | (planned) | (planned) | ✓ |

---

## Architecture

![Architecture](docs/assets/architecture-diagram.svg)

A single Ansible control point authenticates to Azure, discovers VMs by tag, and routes each host to the OS-specific playbook lane (Ubuntu, RHEL, Windows). Every sensor self-registers with CloudLens Manager (CLMS) on first start. No manual per-VM steps, no inventory files to maintain.

---

## The 3 Deployment Paths

### 🌐 Tier 1: One-Click from Azure Portal

> Deploy directly from the Azure Portal — no local tools, no CLI, no SSH keys.

<p>
  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FKeysight-Tech%2Fcloudlens-ansible-azure%2Fmain%2Fdeploy%2Farm-template.json"><img src="https://img.shields.io/badge/▶_Deploy_to_Azure-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white" alt="Deploy to Azure"/></a>
</p>

<details>
<summary>How it works</summary>

- Provisions an ephemeral Ubuntu runner VM in your subscription
- Runner authenticates via Managed Identity (no Service Principal to create)
- Auto-discovers tagged VMs, deploys sensors, self-destructs after 1 hour
- Zero local tools required — runs entirely from your browser

</details>

### ☁️ Tier 2: Azure Cloud Shell

> Already logged into Azure in your browser — run a single curl command.

```bash
curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/quickstart.sh | bash
```

<details>
<summary>How it works</summary>

- Cloud Shell is pre-authenticated to Azure — no Service Principal needed
- Wizard prompts for CLMS IP and project key
- Auto-tunes Ansible forks based on discovered VM count
- All state lives in your Cloud Shell home directory; nothing installed locally

</details>

### 🐳 Tier 3: Docker (local PC or CI/CD)

> Run from your laptop, a CI runner, or any container host. Reproducible, hermetic, version-pinned.

```bash
docker run --rm -it \
  -v $(pwd)/customer_input.yaml:/work/customer_input.yaml \
  -v $HOME/.ssh:/root/.ssh:ro \
  -e AZURE_SUBSCRIPTION_ID -e AZURE_TENANT \
  -e AZURE_CLIENT_ID -e AZURE_SECRET \
  ghcr.io/keysight-tech/cloudlens-ansible-azure:latest
```

<details>
<summary>How it works</summary>

- Pinned container image with Ansible, Azure collections, and all Python deps baked in
- Mounts your `customer_input.yaml` and SSH keys read-only
- Service Principal credentials passed via env vars (use `scripts/setup_azure_sp.sh` to create one)
- Works identically on macOS, Windows, Linux, GitHub Actions, GitLab CI, Jenkins

</details>

---

## Prerequisites — Tag Your VMs

The dynamic inventory discovers VMs by Azure tag. Apply these three tags to every target VM:

| Tag | Required Value |
|---|---|
| `cloudlens` | `yes` |
| `os` | `ubuntu` \| `rhel` \| `windows` |
| `env` | `prod` (or `dev`, `qa`) |

Bulk-tag a resource group:

```bash
# All Ubuntu VMs in a resource group
for vm in $(az vm list -g <RG> --query "[?storageProfile.imageReference.offer=='0001-com-ubuntu-server-jammy'].name" -o tsv); do
  az vm update -g <RG> -n $vm --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod
done

# All RHEL VMs in a resource group
for vm in $(az vm list -g <RG> --query "[?storageProfile.imageReference.publisher=='RedHat'].name" -o tsv); do
  az vm update -g <RG> -n $vm --set tags.cloudlens=yes tags.os=rhel tags.env=prod
done

# All Windows VMs in a resource group
for vm in $(az vm list -g <RG> --query "[?storageProfile.osDisk.osType=='Windows'].name" -o tsv); do
  az vm update -g <RG> -n $vm --set tags.cloudlens=yes tags.os=windows tags.env=prod
done
```

---

## Scaling — From 1 VM to 5,000+

| VM Count | Auto Forks | Sharded? | Approx Time |
|---|---|---|---|
| 1–50 | 20 | No | 5–10 min |
| 50–500 | 50 | No | 15–30 min |
| 500–2,000 | 200 | No | 30–60 min |
| 2,000–10,000 | 500/shard | Yes (auto) | 30–60 min |
| 10,000+ | 1000/shard | AWX | 1–2 hr |

Auto-tunes based on discovered VM count. See [docs/SCALING.md](docs/SCALING.md) for details.

---

## Verified Against Real Azure

| Scenario | Result | Time |
|---|---|---|
| Ubuntu 22.04 (private IP via jumpbox) | ✓ Sensor running | 4 min |
| Ubuntu 22.04 (private IP via jumpbox) | ✓ Sensor running | 4 min |
| Windows Server 2022 (WinRM direct) | ✓ Sensor running | 6 min |
| CLMS 6.14.141 registration | ✓ All 3 sensors registered | <1 min |
| **End-to-end** | **3/3 success** | **8 min** |

Date verified: 2026-06-02. Subscription: CloudLensPublic (eastus2).

---

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---|---|---|
| Inventory finds 0 VMs | Tags missing | `az vm update --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod` |
| SSH "Permission denied" | Public key not on target | Bootstrap via `az vm run-command invoke` |
| WinRM timeout | WinRM disabled on Windows VM | Run `playbooks/bootstrap_windows_winrm.yaml` |
| `apt_pkg.Error: Signed-By` | Stale Docker apt source | Playbook auto-cleans on next run |
| Sensor not in CLMS UI | Wrong project key | Check CLMS → Projects → API Keys |

Full reference: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — Internal architecture and traffic flow
- [docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) — Step-by-step customer guide
- [docs/SCALING.md](docs/SCALING.md) — Scale to thousands of VMs
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — Common issues and fixes

## Related Repositories

- [cloudlens-vpb-azure-gwlb](https://github.com/Keysight-Tech/cloudlens-vpb-azure-gwlb) — Virtual Packet Broker HA behind Azure Gateway Load Balancer

## Getting Help

- [GitHub Issues](https://github.com/Keysight-Tech/cloudlens-ansible-azure/issues) — bug reports and feature requests
- Keysight CloudLens engineering — contact your account team

## License

Keysight Technologies. See [LICENSE](LICENSE).

---

**Version:** v1.0.0 — June 2026
