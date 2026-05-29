# Architecture

## Overview

CloudLens Ansible Azure deploys the **CloudLens sensor agent** to Azure VMs at scale, using:

- **Azure dynamic inventory** (`azure_rm` plugin) — discovers VMs by tag
- **OS-specific playbooks** — Ubuntu, RHEL/CentOS, Windows
- **WinRM bootstrap** — uses Azure VM Run Command (no manual setup)
- **Idempotent installs** — re-runs detect healthy sensors and skip

## Deployment Flow

```
1. Customer fills customer_input.yaml
       │
       ▼
2. ./scripts/deploy.sh
       │
       ├──► Pre-flight checks (Azure CLI, Ansible, SP creds)
       │
       ├──► ansible-inventory --graph
       │         Discovers VMs by tag (cloudlens=yes)
       │         Auto-groups by OS (ubuntu/rhel/windows)
       │
       ├──► bootstrap_windows_winrm.yaml
       │         Uses az vm run-command (no WinRM yet)
       │         Enables WinRM, opens NSG port 5985
       │
       ├──► ubuntu.yaml (parallel, forks=20)
       │         Installs Docker if missing
       │         Configures insecure-registry to CLMS
       │         Runs cloudlens-agent container with NET_RAW caps
       │
       ├──► redhat.yaml (parallel)
       │         Auto-detects Docker vs Podman
       │         Installs whichever is missing
       │         Runs container with same caps
       │
       └──► windows.yaml (parallel)
                 Checks if already healthy → skip
                 Otherwise: copies MSI → silent install
                 Verifies service, process, registry, config
```

## Container Runtime Pattern (Linux)

Sensors run with these capabilities (required for packet capture):

```
NET_BROADCAST, SYS_ADMIN, SYS_MODULE, SYS_RESOURCE, NET_RAW, NET_ADMIN
```

Volumes mounted:

| Mount | Purpose |
|---|---|
| `/lib/modules:/lib/modules` | Kernel modules access |
| `/var/log/cloudlens:/var/log/cloudlens` | Persistent sensor logs |
| `/var/tmp/cloudtap:/var/cloudtap` | Capture spool |
| `/:/host` | Read-only host filesystem for metadata |
| `/var/run/docker.sock:/var/run/docker.sock` | Container metadata (Ubuntu only) |

## Windows Install Pattern

MSI silent install with key parameters:

```
msiexec /i cloudlens-win-sensor-X.Y.Z.exe /quiet \
  Server="<CLMS_IP>" \
  Project_Key="<KEY>" \
  SSL_Verify="no" \
  Auto_Update="yes" \
  Custom_Tags="Env=Azure ..."
```

Idempotent checks:
1. Registry → `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*CloudLens*`
2. Service → `Get-Service CloudLens`
3. Process → matches `*CloudLens*`
4. Config → `C:\ProgramData\CloudLens\Config\agent.yml` exists

All four must pass → skip reinstall. Any failure → uninstall + reinstall.

## Azure-Specific Considerations

| Concern | Approach |
|---|---|
| **WinRM disabled by default** | Bootstrap via Azure VM Run Command (works without WinRM) |
| **Public vs private IPs** | Default uses public IPs. For Bastion: set `hostnames: private_ipv4_addresses` in `azure_rm.yaml` |
| **NSG rules** | Bootstrap auto-opens 5985 (WinRM). For Linux, SSH (22) is assumed open. |
| **Accelerated Networking** | No special handling required for sensor agents — only relevant for vPB (separate repo) |
| **Multi-region** | Add multiple `locations` to `customer_input.yaml`. Each VM is targeted regardless of region. |
| **Managed Identity** | Currently uses Service Principal. Managed Identity support: set `auth_source: msi` in `azure_rm.yaml` and run from an Azure VM. |

## Security Boundaries

- **Service Principal** scoped to specific resource groups (least privilege)
- **WinRM passwords** read from env vars only — never committed
- **Customer input file** git-ignored
- **Sensor talks to CLMS over HTTPS** (port 443) — outbound only, no inbound exposure

## Scaling

Tested patterns:

| VMs | Forks | Approx. Duration |
|---|---|---|
| 10 | 10 | ~3 min |
| 100 | 20 | ~8 min |
| 500 | 50 | ~25 min |
| 1000 | 100 | ~50 min |

Tune via `customer_input.yaml` → `deploy.forks` or `ansible.cfg` → `forks`.
