# Troubleshooting

## Inventory / Discovery Issues

### `Empty inventory, no hosts matched`

**Cause:** VMs aren't tagged correctly, or SP doesn't have read access.

**Check:**

```bash
# Verify SP can list VMs
az vm list --query "[].name" -o tsv

# Check tags on a specific VM
az vm show -g <RG> -n <VM> --query tags

# Show dynamic inventory groups
ansible-inventory -i inventory/azure_rm.yaml --graph
```

**Fix:**

```bash
az vm update -g <RG> -n <VM> --set tags.cloudlens=yes tags.os=ubuntu tags.env=prod
```

### `Unable to find Service Principal` / `AuthenticationFailed` / `name 'client_secret' is not defined`

**Cause:** the inventory plugin is trying service-principal auth without the
variables, or the az login session has expired.

**Fix (Cloud Shell, laptop, quickstart.sh):** no service principal is needed.
`az login`, then run `quickstart.sh`, which sets `ANSIBLE_AZURE_AUTH_SOURCE=cli`
when no `AZURE_CLIENT_ID` is in the environment. For a manual ansible-playbook
run, export that variable yourself.

**Fix (Docker, CI, scripts/deploy.sh):** these need a service principal.
`bash scripts/setup_azure_sp.sh` creates one and writes `scripts/load_sp_creds.sh`
(git-ignored, it holds the secret); then:

```bash
source scripts/load_sp_creds.sh
# Verify:
echo $AZURE_SUBSCRIPTION_ID
echo $AZURE_CLIENT_ID
```

## Linux Deployment Issues

### Docker install fails on Ubuntu

**Cause:** Malformed sources list from prior failed run.

**Fix:** Playbook auto-removes `/etc/apt/sources.list.d/download_docker_com_linux_ubuntu.list`. If still failing, manually:

```bash
ssh azureuser@<vm> "sudo rm /etc/apt/sources.list.d/download_docker_com*.list && sudo apt update"
```

### `docker pull` returns `unauthorized` or `x509: certificate signed by unknown authority`

**Cause:** CLMS uses self-signed cert and registry is not configured as insecure.

**Fix:** In `customer_input.yaml`:

```yaml
cloudlens:
  registry_type: "insecure"
  ssl_verify: "no"
```

Or for production with a signed CA:

```yaml
cloudlens:
  registry_type: "secure"
  local_ca_path: "files/cloudlenscerts.crt"   # relative to the repo root; with Docker, mount files/
  ssl_verify: "yes"
```

### Container starts but sensor doesn't appear in CLMS

**Check container logs:**

```bash
ssh azureuser@<vm> "docker logs cloudlens-agent --tail 50"
```

Common causes:
- The VM is inside (or peered to) the vController's VNet and `manager_ip_or_fqdn`
  is the vController's PUBLIC IP while the admin CIDR is narrowed. Azure
  SNATs VNet-to-public traffic, so the NSG sees a source outside the admin
  CIDR and drops it. Use the PRIVATE IP (deploy-stack.sh writes it and the
  summary shows it as "Sensors register on"; `CLOUDLENS_SENSOR_MANAGER_ADDR`
  overrides). A VM with no route to the private IP must use the public IP and
  its egress IP must be inside the admin CIDR (`--admin-cidr`, or the
  `adminSourceCidr` template parameter).
- Wrong `project_key` (vController > Projects > API Keys; deploy-stack.sh
  Phase 10 creates project `cloudlens-autopilot` and prints its key)
- VM cannot reach the vController on port 443 (check NSG outbound rules, and
  `curl -kv https://<address>/` from the VM)
- DNS does not resolve the vController FQDN (use the IP instead)

## RHEL/Podman Issues

### `podman: SELinux denied` on volume mounts

**Fix:** Playbook adds `--security-opt label=disable`. If you want SELinux enforced, modify `playbooks/redhat.yaml` to use `:z` mount option instead.

### Auto-detection picks Podman but Docker is preferred

**Force Docker:**

```bash
ansible-playbook deploy.yaml \
  -e "@customer_input.yaml" \
  -e "install_docker=true" \
  -i inventory/azure_rm.yaml
```

## Windows / WinRM Issues

### `kerberos: authGSS_clientStep failed` or `WinRM not configured`

**Cause:** WinRM bootstrap was skipped or failed.

**Fix:** Run bootstrap explicitly:

```bash
ansible-playbook playbooks/bootstrap_windows_winrm.yaml \
  -e "@customer_input.yaml" \
  -i inventory/azure_rm.yaml
```

Or for a single VM:

```bash
./scripts/bootstrap_winrm.sh <RG> <VM_NAME>
```

### `Connection timeout on port 5985`

**Cause:** NSG rule for WinRM not open from your IP.

**Fix:**

```bash
MY_IP=$(curl -s ifconfig.me)
az network nsg rule create \
  --resource-group <RG> \
  --nsg-name <VM_NAME>-nsg \
  --name AllowWinRM-FromMe \
  --priority 1011 \
  --source-address-prefixes $MY_IP \
  --destination-port-ranges 5985 \
  --access Allow --protocol Tcp --direction Inbound
```

### Installer exits with a non-zero code (1603 or other)

**Cause:** generic install failure. The playbook runs the exe with
`/install /quiet Server=... Project_Key=...` and accepts exit codes 0, 3010
and 1641. Check the installer log it leaves in `C:\temp` (the playbook deletes
it after a successful run) and the sensor's own log folder:

```powershell
Get-ChildItem C:\temp -Filter "*cloudlens*.log*" | Get-Content | Select-String "Error"
Get-Content C:\ProgramData\CloudLens\Logs\*.log -Tail 50
Test-Path C:\ProgramData\CloudLens\Config\agent.yml   # False = install never configured the sensor
```

Most common: wrong vController address or project key.

### Sensor service exits immediately after install

**Check Windows event log:**

```powershell
Get-EventLog -LogName Application -Source "CloudLens*" -Newest 20 | Format-List
```

Common cause: TLS handshake failure to CLMS. Verify outbound 443 reachability:

```powershell
Test-NetConnection -ComputerName <CLMS_IP> -Port 443
```

## Network / Connectivity Issues

### VMs in different VNets/subscriptions

The dynamic inventory pulls VMs from all RGs you list. Make sure each VM can reach CLMS:

```bash
# From the VM
curl -kv https://<CLMS_IP>/health
```

If CLMS is in a different VNet:
- VNet peering, OR
- ExpressRoute / VPN, OR
- CLMS public IP with NSG allowing your VM subnets

### Private-only VMs (no public IPs)

Nothing to change in the inventory: `inventory/azure_rm.yaml` already uses a
VM's private IP when it has no public one. Reach them through a Linux jumpbox
in the VNet by setting, in `customer_input.yaml`:

```yaml
connection:
  mode: "jumpbox"
  jumpbox_host: "<jumpbox public IP>"
  jumpbox_user: "azureuser"
  jumpbox_ssh_key: "~/.ssh/id_rsa"
```

`inventory/group_vars/all.yaml` turns this into an SSH `ProxyJump`. Or run
Ansible from a VM inside the VNet (Cloud Shell with a VNet-injected session, a
runner VM, or the Docker image on a jumpbox). Azure Bastion is not a supported
connection mode. Windows VMs still need a reachable WinRM port 5985.

## Cleanup / Re-deployment

### Re-run is slow because of healthy-check loops

The playbook detects healthy installs and skips reinstall. To force a clean redeploy:

```bash
# Cloud Shell / laptop
bash scripts/cleanup.sh                 # remove sensors (prompts first)
bash quickstart.sh                      # deploy fresh

# Docker: same mounts and env as the deploy command, with the mode changed
docker run ... ghcr.io/keysight-tech/cloudlens-ansible-azure:latest cleanup
docker run ... ghcr.io/keysight-tech/cloudlens-ansible-azure:latest deploy

# scripts/deploy.sh is the service-principal variant and needs
# AZURE_SUBSCRIPTION_ID, AZURE_TENANT, AZURE_CLIENT_ID and AZURE_SECRET exported
```

### Cleanup leaves Docker installed

By default, cleanup only removes the sensor, not Docker. To remove Docker too:

```bash
ansible-playbook cleanup.yaml \
  -e "@customer_input.yaml" \
  -e "remove_docker=true" \
  -i inventory/azure_rm.yaml
```

## Stack deploy and image issues

### quickstart.sh warns `galaxy.ansible.com unreachable; continuing`

Harmless: the three collections (azure.azcollection, ansible.windows,
community.windows) were already installed and the install is only a refresh.
If one is missing the script stops and names it; fix the proxy, certificate or
route to galaxy.ansible.com and re-run.

### `[license] KVO not ready yet (...); retrying in 15 s`

A KVO that just booted or just accepted its EULA answers 502/503 while
Keycloak starts. `kvo_license.py` waits up to ten minutes, re-accepting the
EULA each attempt. Only `auth failed` after that wait is a real failure.

### Phase 13 `[kvo-adopt] CLMS login failed (HTTP 401)`

The vController web password is not the VM's OS password. Phase 10 rotated it
and recorded it in `~/.cloudlens-vcontroller-creds-<resource-group>.json`;
Phase 13 reads that file. A file left in the same group by a previous
vController (it names a different address) is ignored and the factory default
is sent instead. Set `CLOUDLENS_VC_PASSWORD` to pass a known value, or
complete the first login in the UI and re-run with `--resume`.

### Phase 13 `[kvo-adopt] adopt failed: ... NatsError: Request timed out`

KVO reached the adoption API but its discovery of the vController timed out.
Deploys before 2026-10-07 handed KVO the vController's public IP; with a
narrowed admin CIDR that address is refused from inside the VNet, because
Azure SNATs VNet-to-public traffic and it arrives from a source outside the
CIDR. Phase 13 now discovers by the private address
(`kvo_adopt_clms.py --clms-internal-ip`), so re-run with `--resume`. By hand:
KVO > Inventory > CloudLens Manager > Discover, with the private IP. Inside
the VNet Azure's default `AllowVnetInBound` rule admits the traffic; if a
policy NSG adds a deny rule below the defaults, allow TCP 443 to the
vController and TCP 7443 to the KVO from `VirtualNetwork` (the templates
create those rules as `AllowHTTPSFromVNet` and `AllowKvoFromVNet`).

### Phase 13b `The AKS tapping step did not complete`

The rest of the run continues; the line under the warning prints the exact
`scripts/deploy-aks-tapping.sh` command to re-run the step alone. The cause
is the engine's exit code: 3 no cluster access (`az aks get-credentials`
failed or kubectl cannot reach the API server), 4 no sensor image (pass
`--aks-sensor-image URI` or `--aks-sensor-tar PATH`; the default is the
newest `CloudLens-Sensor-*.tar` under `~/Downloads`), 5 the cluster or node
pool creation failed (quota, or the subnet is not in the shared VNet), 6 the
DaemonSet never became ready or the pods never registered. Check with:

```bash
kubectl --kubeconfig ~/.kube/cloudlens-aks-<cluster> -n cloudlens get pods -o wide
```

A pod that is `Running` but not registering names the vController address it
uses in its log; a cluster in the shared VNet must use the private address.

### `Missing sudo password` on Linux VMs created with password authentication

SSH works but `become` fails. Set `linux.ansible_password` in
`customer_input.yaml`; `inventory/group_vars/ubuntu_prod_vms.yaml` and
`inventory/group_vars/redhat_prod_vms.yaml` pass it as `ansible_become_pass` too.

### Docker: `customer_input.yaml is a directory, not your file`

Docker created an empty folder because the file you mounted did not exist.
Delete that folder, `cd` to the folder that holds `customer_input.yaml`, and
mount it with `-v "$(pwd)/customer_input.yaml:/work/customer_input.yaml:ro"`.

### Shard summary says `FAILED, ran against no hosts`

The shard's `--limit` matched nothing: the discovery tags or
`azure.tag_filters` changed between inventory rendering and the run, or the
VMs are not in the ubuntu/redhat/windows_prod_vms groups. Check
`./logs/shards/shard_NNN.log` and `ansible-inventory --graph`.

## Where to get help

- Check `ansible.log` (project root) for full debug output
- Run with `-vvv` for verbose: `ansible-playbook deploy.yaml -e "@customer_input.yaml" -i inventory/azure_rm.yaml -vvv`
- Open a GitHub issue with `ansible.log` excerpt + sanitized `customer_input.yaml`
