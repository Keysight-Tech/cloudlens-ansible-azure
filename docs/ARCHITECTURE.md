# Architecture

## Overview

CloudLens Ansible Azure deploys the CloudLens appliance stack (vController, KVO, vPB) and the **CloudLens sensor agent** to Azure VMs at scale, using:

- **Azure dynamic inventory** (`azure_rm` plugin) to discover VMs by tag
- **OS-specific playbooks** for Ubuntu, RHEL/CentOS, and Windows
- **WinRM bootstrap** via Azure VM Run Command (no manual setup)
- **Idempotent installs**, so re-runs detect healthy sensors and skip

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
                 Otherwise: copies the installer .exe → silent install
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
| `/var/tmp/cloudtap:/var/cloudtap` | Capture spool (RHEL/Podman and RHEL/Docker only) |
| `/:/host` | Host filesystem for metadata (mounted read-write) |
| `/var/run/docker.sock:/var/run/docker.sock` | Container metadata (Ubuntu only) |

## Windows Install Pattern

The installer executable is copied to `C:\temp` and run silently:

```
cloudlens-win-sensor-X.Y.Z.exe /install /quiet \
  Server="<vController address>" \
  Project_Key="<KEY>" \
  SSL_Verify="no" \
  Auto_Update="yes" \
  Custom_Tags="Env=Azure ..."
```

An existing installation is removed first through its registered UninstallString (msiexec /x for MSI-registered builds, `/uninstall /quiet` for exe builds).

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
| **Public vs private IPs** | Each VM is reached on its public IP when it has one, otherwise on its private IP (`hostvar_expressions` in `inventory/azure_rm.yaml`). Private-only VMs are reached through a jumpbox (`connection.mode: jumpbox` in `customer_input.yaml`) or by running from inside Azure (Cloud Shell, a peered VM). Azure Bastion is not a connection mode. `deploy-stack.sh` forces public addresses when it detects it is running outside Azure. |
| **NSG rules** | Bootstrap auto-opens 5985 (WinRM). For Linux, SSH (22) is assumed open. |
| **Accelerated Networking** | Not needed for sensor agents. The vPB templates in `deploy/` enable it on the vPB's ingress and egress NICs (the management NIC runs without it); the three-NIC layout is why Standard_D8s_v3 is the minimum vPB size. |
| **Multi-region** | Add multiple `locations` to `customer_input.yaml`. Each VM is targeted regardless of region. |
| **Authentication** | Three sources, picked automatically: service principal env vars (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT`, `AZURE_CLIENT_ID`, `AZURE_SECRET`, created by `scripts/setup_azure_sp.sh`); an `az login` session or Azure Cloud Shell (`quickstart.sh` sets `ANSIBLE_AZURE_AUTH_SOURCE=cli` when no service principal is present); or, in Docker, the service principal or a mounted `~/.azure` login. Managed identity is not wired into the inventory today. |

## Appliance stack

`deploy/deploy-stack.sh`, the portal's full-stack template (`deploy/stack-marketplace.json`) and the Terraform stack module deploy the appliances the sensors report to. The bash deploy builds one virtual network, `cloudlens-vnet` (10.50.0.0/16 by default, `--vnet-cidr`), with five subnets: `vcontroller-subnet` (a.b.1.0/24), `kvo-subnet` (a.b.2.0/24), `vpb-mgmt` (a.b.10.0/24), `vpb-ingress` (a.b.11.0/24) and `vpb-egress` (a.b.12.0/24), and places every appliance in it, so the vController, KVO and vPB reach each other on private addresses. `--vnet-name` joins a VNet you already run; it must already hold those five subnets. A re-run adopts the `<vcontroller>-vnet` an older deploy built.

Each appliance NSG admits SSH 22, vPB SSH 9022 and HTTPS 443 from the admin source CIDR (`--admin-cidr`, asked interactively with your public /32 offered; `*` opens them to the internet). Inside the virtual network nothing is restricted: Azure's default `AllowVnetInBound` rule admits traffic between VNet addresses (this VNet, peered VNets and on-premises ranges behind a gateway), and the templates and Terraform modules add explicit `AllowHTTPSFromVNet` (443, all three appliances) and `AllowKvoFromVNet` (7443 on the KVO: the gRPC connection the vController opens to it, KVO User Guide ports list) rules so the in-VNet ports the appliances need are named and survive a policy that adds a deny rule below the defaults. What a narrowed admin CIDR does block is the appliances' public addresses from inside the VNet (Azure SNATs VNet-to-public traffic, so it arrives from a source outside the CIDR); that is why the deploy adopts the vController into KVO by its private address and points in-VNet sensors and AKS pods at it. Mirrored traffic reaches the vPB ingress as VXLAN (UDP 4789 and 10800-10801) from `VirtualNetwork`. The templates open no GRE port; the Azure vPB path is VXLAN.

Azure-native tapping is Gateway Load Balancer service chaining (vPB User Guide chapter 3). It is generally available and inline: the vPB sits in the data path, so a stopped or unlicensed vPB stops the application, not only the visibility, and vPB licence expiry is a production alarm. Azure Virtual Network TAP, the out-of-band equivalent of AWS VPC Traffic Mirroring, is a gated Microsoft preview. The sensor path in this document is what the repo builds today; see docs/AZURE_TAPPING_ARCHITECTURE.md.

Kubernetes pods are tapped by the same sensor, packaged for AKS. Phase 13b (`--aks-cluster NAME` or `--aks-sample`) runs after the vController adoption: with KVO it creates the Kubernetes presence first (`k8s-<cluster>`, its own vController project and Cloud Config), then `scripts/deploy-aks-tapping.sh` applies the sensor DaemonSet keyed to that presence (Keysight's chart pre-rendered in `deploy/kubernetes/cloudlens-sensor-daemonset.yaml`, applied with kubectl) from an ACR the deploy creates and attaches to the cluster. A cluster on Azure CNI in the shared VNet reaches the vController on its private address. The pod sensors follow the same tool path as the VM sensors. Proven live on 2026-10-07: two nodes, two sensors, KVO's presence reporting both.

`deploy/teardown-stack.sh` audits the group and asks for confirmation; once confirmed it offers to release the KVO licences while the KVO is still alive, then deletes the CloudLens resources, or the whole group when the deploy created it and nothing else lives in it.

## Security Boundaries

- **Service Principal** created by `scripts/setup_azure_sp.sh` with Virtual Machine Contributor and Reader on the whole subscription; narrow the `--scopes` to the workload resource groups yourself when policy requires it. `azure.resource_groups` in `customer_input.yaml` limits discovery, not the credential.
- **WinRM passwords** are read from env vars only, never committed
- **Customer input file** git-ignored
- **Sensor talks to CLMS over HTTPS** (port 443), outbound only, with no inbound exposure
- **AKS pod sensors** run as a privileged DaemonSet in the `cloudlens` namespace (what the Keysight chart needs to see every pod on a node); the image sits in an ACR attached to the cluster with AcrPull, and `--aks-pod-selector` limits which pods the KVO collection taps

## Scaling

Measured runs (forks set explicitly):

| VMs | Forks | Approx. Duration |
|---|---|---|
| 10 | 10 | ~3 min |
| 100 | 20 | ~8 min |
| 500 | 50 | ~25 min |
| 1000 | 100 | ~50 min |

`quickstart.sh` and the Docker entrypoint pick the fork count from the number of discovered VMs: 20 up to 50 VMs, 50 up to 500, 200 up to 2,000, then 500 per shard with sharding enabled automatically above 2,000 VMs. `quickstart.sh` additionally caps the value at four times the control node's CPU cores; the Docker entrypoint does not. `ANSIBLE_FORKS` overrides the choice in both; `deploy.forks` in `customer_input.yaml` is read by the Docker entrypoint only; `forks = 20` in `ansible.cfg` applies to a bare `ansible-playbook` run. Timings and control-node sizing are in docs/SCALING.md.
