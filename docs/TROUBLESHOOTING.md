# Troubleshooting

## Inventory / Discovery Issues

### `Empty inventory — no hosts matched`

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

### `Unable to find Service Principal` / `AuthenticationFailed`

**Cause:** SP credentials not exported.

**Fix:**

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
  local_ca_path: "files/cloudlenscerts.crt"   # place CA bundle here
  ssl_verify: "yes"
```

### Container starts but sensor doesn't appear in CLMS

**Check container logs:**

```bash
ssh azureuser@<vm> "docker logs cloudlens-agent --tail 50"
```

Common causes:
- Wrong `project_key` (check CLMS → Projects)
- VM can't reach CLMS on port 443 (check NSG outbound rules)
- DNS doesn't resolve CLMS FQDN (use IP instead)

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

### `MSI install fails with exit code 1603`

**Cause:** Generic install failure. Check the MSI log on the VM:

```powershell
Get-Content C:\Windows\Temp\MSI*.log | Select-String "Error"
```

Most common: wrong CLMS IP/project key.

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

### Bastion-only access (no public IPs)

Switch dynamic inventory to private IPs:

```yaml
# inventory/azure_rm.yaml
hostnames:
  - private_ipv4_addresses
```

Then run Ansible from a jumpbox INSIDE the VNet, or configure SSH ProxyCommand via Bastion in `~/.ssh/config`.

## Cleanup / Re-deployment

### Re-run is slow because of healthy-check loops

The playbook detects healthy installs and skips reinstall. To force a clean redeploy:

```bash
./scripts/cleanup.sh                    # remove sensors
./scripts/deploy.sh                     # deploy fresh
```

### Cleanup leaves Docker installed

By default, cleanup only removes the sensor — not Docker. To remove Docker too:

```bash
ansible-playbook cleanup.yaml \
  -e "@customer_input.yaml" \
  -e "remove_docker=true" \
  -i inventory/azure_rm.yaml
```

## Where to get help

- Check `ansible.log` (project root) for full debug output
- Run with `-vvv` for verbose: `ansible-playbook deploy.yaml -e "@customer_input.yaml" -i inventory/azure_rm.yaml -vvv`
- Open a GitHub issue with `ansible.log` excerpt + sanitized `customer_input.yaml`
