# CloudLens Operations Guide

Single source of truth for every gotcha a customer or SE will hit when working
with **vController** (formerly CLMS), **KVO** (Keysight Vision Orchestrator),
and **vPB** (Virtual Packet Broker) from the Azure Marketplace.

If you hit any wall not described here, please open a PR adding it. The point
of this doc is that nobody should ever burn the same hour twice.

---

## 0. Configuration knobs for `deploy-stack.sh`

Every default in the bash one-liner is overridable. Full reference table is in [README.md "Configuration & overrides"](../README.md#configuration--overrides-bash-deploy-stacksh). Same precedence everywhere: **CLI flag wins over env var wins over hardcoded default**. Run `bash deploy/deploy-stack.sh --help` for the in-script version.

Most common knobs:

| What | Default | Env var | Flag |
|---|---|---|---|
| Resource group | `cloudlens-rg` | `CLOUDLENS_RG` | `--resource-group` |
| Region | `eastus2` | `CLOUDLENS_REGION` | `--location` |
| Admin CIDR (SSH 22, vPB SSH 9022, HTTPS 443) | `*` (asked interactively; your public /32 is offered) | `CLOUDLENS_ADMIN_CIDR` | `--admin-cidr` |
| Virtual network | `cloudlens-vnet`, built by the deploy | `CLOUDLENS_VNET_NAME` | `--vnet-name` (join a VNet you already run; it must hold `vcontroller-subnet`, `kvo-subnet`, `vpb-mgmt`, `vpb-ingress`, `vpb-egress`) |
| VNet resource group | the deploy's group | `CLOUDLENS_VNET_RG` | `--vnet-resource-group` |
| VNet address space | `10.50.0.0/16` (subnets a.b.1, 2, 10, 11, 12 .0/24) | `CLOUDLENS_VNET_CIDR` | `--vnet-cidr` |
| KVO count | `1` | `CLOUDLENS_KVO_COUNT` | `--kvo-count` (1-2) |
| Address sensors register on | public IP when the admin CIDR is `*`, private IP otherwise | `CLOUDLENS_SENSOR_MANAGER_ADDR` | n/a |
| Re-run against the same group | n/a | n/a | `--resume` |
| Print every az command, touch nothing | n/a | n/a | `--dry-run` |
| vController count | `1` | `CLOUDLENS_VCONTROLLER_COUNT` | `--vcontroller-count` |
| vPB count | `1` | `CLOUDLENS_VPB_COUNT` | `--vpb-count` |
| vPB ingress NICs | `1` | `CLOUDLENS_VPB_INGRESS_NICS` | `--vpb-ingress-nics` |
| vPB egress NICs | `1` | `CLOUDLENS_VPB_EGRESS_NICS` | `--vpb-egress-nics` |
| Rollback on failure | `false` | `CLOUDLENS_ROLLBACK_ON_FAIL` | `--rollback` |
| Discovery tag key | `cloudlens` | `CLOUDLENS_DISCOVERY_TAG_KEY` | `--discovery-tag-key` |
| Discovery tag value | `yes` | `CLOUDLENS_DISCOVERY_TAG_VALUE` | `--discovery-tag-value` |
| AKS pod tapping (Phase 13b) | off | `CLOUDLENS_DEPLOY_AKS`, `CLOUDLENS_AKS_CLUSTER`, `CLOUDLENS_AKS_SAMPLE`, `CLOUDLENS_AKS_MODE`, `CLOUDLENS_AKS_POD_SELECTOR`, `CLOUDLENS_AKS_SENSOR_IMAGE`, `CLOUDLENS_AKS_SENSOR_TAR`, `CLOUDLENS_AKS_SUBNET` | `--aks-cluster NAME`, `--aks-sample`, `--aks-mode daemonset\|sidecar`, `--aks-pod-selector REGEX`, `--aks-sensor-image URI`, `--aks-sensor-tar PATH` |

For end-to-end verification with a custom discovery tag, run `scripts/deploy-test-workload-vms.sh` first - it stands up Ubuntu + RHEL + Windows VMs tagged with your chosen pair, ready for a sensor-install test pass.

---

## 1. Quick reference: every port and credential you will touch

| Component | Public port(s) | Internal port(s) | Default UI cred | Default CLI cred | First-boot wait |
|---|---|---|---|---|---|
| **vController** | TCP 443 (web UI), TCP 22 (Linux SSH) | n/a | `admin / Cl0udLens@dm!n` (force-change on first login) | n/a | ~15 min |
| **KVO** | TCP 443 (web UI), TCP 22 (Linux SSH) | n/a | See Keysight KVO docs (operator must change immediately) | n/a | ~15 min |
| **vPB v3.15+** | TCP **9022** (Linux SSH on KCOS), TCP 443 (mgmt web), TCP 30101 (vpb-shim NodePort), UDP 4789 (VXLAN), UDP 10800-10801 (Keysight VXLAN) | n/a (CLI on 2222 REMOVED in 3.15) | n/a | n/a (managed entirely from KVO) | 10-15 min |
| **vPB v3.14 (legacy)** | TCP 22 (Linux SSH, not 9022), TCP 443, UDP 4789, UDP 10800-10801 | TCP 2222 (vPB CLI, localhost-only) | n/a | `admin / ixia` (force-change on first SSH) | 10-15 min |
| **Sensor** | n/a | n/a | n/a | n/a | <1 min |

### Why these are not the obvious defaults

- **vPB OS SSH is on port 9022, NOT port 22.** Keysight CloudLens OS (KCOS)
  binds sshd to 9022 on the public NIC. A connection to `:22` will time out
  forever even after the VM is fully up. The marketplace ARM template now
  opens 9022 in the NSG automatically (`AllowKCOSSsh` rule). This is the
  v3.15+ image; a v3.14 build listens on port 22, as the table shows.
- **vPB v3.15 moved the CLI inside a K8s pod.** v3.14 exposed a CLI on port
  2222 from inside the OS shell, reached via two-hop SSH (`ssh azureuser@vpb`
  on port 22, then `ssh admin@localhost -p 2222`). v3.15 stops that
  pod-external sshd; the CLI binary (`/usr/local/bin/xf-client`) now lives
  inside the `vpbsystem` K8s container. The marketplace ARM template installs
  a `/usr/local/bin/vpb` wrapper at deploy time so customers just type
  `sudo vpb` to land in `CloudLensVPB#`. Do NOT try `ssh -p 2222` on v3.15 -
  it will time out.
- **vController and KVO use port 22 normally.** Their web UIs gate a new
  session behind a EULA and a forced first-login password change, but neither
  needs a browser when you deploy with `deploy-stack.sh`: Phase 10 completes
  the vController password change over the REST API and records the result in
  `~/.cloudlens-vcontroller-creds-<resource-group>.json`, and Phases 12-14
  accept the KVO EULA over its API. A 405 from the vController API is not the
  EULA gate: nginx serves the web app about ten minutes before the API backend
  and answers 405 to every POST until the login route exists. Wait until a
  login attempt returns 400, 401 or 422 before calling the API. (The SSH
  "Permission denied" seen in the lab before first login is covered in
  section 2; it is an observation, not something the deploy script handles.)

---

## 2. How to SSH into each device

### vController (port 22)

```bash
ssh azureuser@<vcontroller-public-ip>
```

Password: whatever you set during ARM deployment (`adminPassword` parameter).

If you get "Permission denied (publickey,password)" with the correct password:
1. Open `https://<vcontroller-public-ip>` in a browser
2. Accept the EULA
3. Sign in `admin / Cl0udLens@dm!n` and complete the forced password change
4. Retry SSH

After step 4, SSH works for the rest of the VM's life.

### KVO (port 22)

Same flow as vController. The EULA + first-login is a one-time gate.

```bash
ssh azureuser@<kvo-public-ip>
```

### vPB (port 9022, then `sudo vpb` after bootstrap)

#### Step 1: SSH on port 9022 (NOT 22)

```bash
ssh azureuser@<vpb-mgmt-public-ip> -p 9022
# password: the adminPassword you set during the marketplace deploy
```

#### Step 2: Bootstrap (automatic with this repo's templates)

The vPB ARM template (`deploy/vpb-marketplace.json`, also nested by the
full-stack template) and the Terraform module (`enable_auto_bootstrap`,
default true) run `scripts/bootstrap-vpb.sh` through the CustomScript
extension at deploy time; its output is in `/var/log/cloudlens-bootstrap.log`
on the VM. Run the bootstrap by hand only when the image was deployed some
other way, or when that log shows it failed. Without it, two errors appear on
first SSH:

```
$ sudo kubectl get pods -A
The connection to the server localhost:8080 was refused

$ sudo vpb
sudo: vpb: command not found
```

Both come from the same root cause: the KCOS image puts kubeconfig at
`/etc/rancher/k3s/k3s.yaml` (k3s) or `/etc/kubernetes/admin.conf` (kubeadm),
and the vPB CLI runs inside a K8s pod, not as a host binary.

**To run it by hand**:

```bash
curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/scripts/bootstrap-vpb.sh | sudo bash
```

It:

1. Detects whether KCOS uses k3s or kubeadm and finds the right kubeconfig.
2. Waits for the K8s API to be reachable (up to 10 min) so you do not run
   the bootstrap before the cluster is ready.
3. Writes `/etc/profile.d/cloudlens-vpb-kubeconfig.sh` exporting
   `KUBECONFIG` system-wide, so every NEW shell gets a working kubectl.
4. Installs the `sudo vpb` wrapper at `/usr/local/bin/vpb`. The wrapper
   auto-detects the kubeconfig + the vpbsystem pod and `kubectl exec`s
   into the Keysight CLI.
5. Waits for the vpbsystem pod to reach Running, then prints the next-step
   commands.

#### Step 3: Log out, log back in, use it

```bash
exit
ssh azureuser@<vpb-mgmt-public-ip> -p 9022

sudo kubectl get pods -A          # cluster overview, no localhost:8080 error
sudo vpb                          # drops you into the CloudLensVPB# CLI
sudo vpb -c "show version"        # one-off CLI command, non-interactive
```

#### Why two SSH sessions

The `/etc/profile.d/` script that exports `KUBECONFIG` only loads at login.
The first SSH session does not have it; the second does. If you do not want
to re-login, run `source /etc/profile.d/cloudlens-vpb-kubeconfig.sh` in the
current shell instead.

#### Legacy two-hop SSH (vPB v3.14 and earlier)

```bash
ssh azureuser@<vpb-mgmt-public-ip>            # port 22 on v3.14, not 9022
ssh admin@localhost -p 2222                   # vPB CLI, localhost only
# default password: ixia (v3.14 forced a change on first login)
```

This two-hop pattern is gone in v3.15: the OS shell moved to port 9022 and
the CLI lives inside the K8s pod, not on port 2222. Use `sudo vpb` (after
bootstrap) instead.

---

#### If `ssh -p 9022` itself times out

1. **Check the NSG.** The vPB management NIC's NSG must allow inbound TCP/9022
   from your admin network. This repo's vPB template and Terraform module add
   the `AllowKCOSSsh` rule, scoped to the `adminSourceCidr` /
   `admin_source_cidr` value you gave (`--admin-cidr` on deploy-stack.sh). For
   a vPB deployed another way, add it with your own CIDR, never `*`:

   ```bash
   az network nsg rule create -g <rg> --nsg-name <vpb-nsg> \
     -n AllowKCOSSsh --priority 105 --protocol Tcp \
     --destination-port-ranges 9022 --source-address-prefixes <your-admin-cidr> \
     --access Allow --direction Inbound
   ```

2. **Check the VM is fully booted.** vPB needs 10-15 min after `provisioningState
   = Succeeded`. Confirm via:

   ```bash
   az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript \
     --scripts "uptime; ss -tnl | grep ':9022'"
   ```

   If port 9022 is not listening, KCOS is still initializing. Wait 5 more
   minutes and try again.

---

## 3. Default credentials cheat-sheet

| Where | Username | Initial password | When does it change |
|---|---|---|---|
| vController web UI | `admin` | `Cl0udLens@dm!n` on a fresh image. After `deploy-stack.sh`, the password Phase 10 set: read it from `~/.cloudlens-vcontroller-creds-<resource-group>.json` (mode 600) | Phase 10 rotates it over the API and verifies the new value. It uses `CLOUDLENS_VC_PASSWORD` if set, else the value an earlier run recorded in the creds file (`--resume`), else the stack's OS admin password. If Phase 10 fails, the factory default still applies |
| vController OS SSH | `azureuser` (or the `adminUsername` you passed) | ARM `adminPassword` parameter | Never (set at deploy time) |
| KVO web UI | `admin` | `admin` (KVO 3.0.1 User Guide ch. 2) | Change it on first login |
| KVO OS SSH | `azureuser` | ARM `adminPassword` parameter | Never |
| vPB OS SSH (port 9022) | `azureuser` when deployed from this repo's templates (Keysight's own Marketplace listing uses `keysight` with an SSH key) | ARM `adminPassword` parameter | Never |
| vPB CLI, v3.15+ | none: `sudo vpb` runs the CLI inside the vpbsystem pod | n/a | The CLI asks you to accept its own EULA once |
| vPB CLI, v3.14 and earlier (port 2222 from localhost) | `admin` | `ixia` | Forced on first SSH |
| Workload VMs (Linux) | `azureuser` | Set at deploy time | Never |
| Workload VMs (Windows) | `azureuser` | Set at deploy time | Never |

`deploy-stack.sh` generates one 16-character OS password (upper, lower, digit,
symbol) for every VM it creates and writes it to `cloudlens-deploy-summary.txt`;
the demo orchestrator does the same into `~/.cloudlens-demo/admin_pw`. The
vController web UI password is separate and lives in the creds file above.

---

## 4. Adopting vPB and vController into KVO

This is the premium "single pane of glass" workflow that turns three separately
deployed VMs into one fleet view.

**Automated path.** `deploy-stack.sh --with-kvo` does all of this: Phase 12
activates the KVO licences (`scripts/kvo_license.py`, which accepts the KVO
EULA and waits up to ten minutes for a KVO that is still booting), Phase 13
adopts the vController and creates its Cloud Config (`scripts/kvo_adopt_clms.py`,
custom cloud `cloudlens-azure`), Phase 14 adopts the vPB
(`scripts/vpb_kvo_adopt.py`) and Phase 15 prints the `scripts/vpb_wire_path.py`
command for the traffic path, which needs the vPB data ports up first. Read
`docs/AZURE_TAPPING_ARCHITECTURE.md` for where Phase 14 stops on the current
Marketplace image. The steps below are the manual equivalent.

### 4a. Prerequisites

- KVO is deployed and you have completed the EULA + first-login on its web UI.
- A KVO user with role `KVO User` exists (e.g. `clms@keysight.com`).
- The KVO can reach the vPB and the vController on their private IPs.
  `deploy-stack.sh` guarantees this: it puts all three in one virtual network
  (`cloudlens-vnet`, five subnets, or the VNet you name with `--vnet-name`), so
  no peering is needed. Peering is only required when the appliances were
  deployed one by one from the portal buttons into separate VNets:

  ```bash
  KVO_VNET_ID=$(az network vnet show -g <kvo-rg> -n <kvo-vnet> --query id -o tsv)
  TARGET_VNET_ID=$(az network vnet show -g <target-rg> -n <target-vnet> --query id -o tsv)

  az network vnet peering create -g <target-rg> --vnet-name <target-vnet> \
    -n <name>-to-kvo --remote-vnet "$KVO_VNET_ID" --allow-vnet-access
  az network vnet peering create -g <kvo-rg> --vnet-name <kvo-vnet> \
    -n kvo-to-<name> --remote-vnet "$TARGET_VNET_ID" --allow-vnet-access
  ```

### 4b. Point vController at KVO

In the vController web UI:

`Settings > Management Server`

Enter:
- IP: KVO private IP (for a stack deploy, the address in kvo-subnet: 10.50.2.x with the default --vnet-cidr; the standalone KVO template's own VNet uses 10.60.1.x)
- Port: 443
- Credentials: the KVO user you created

Save. The vController device will heartbeat to KVO within ~30s and appear
in KVO under `Devices > Adoptable`.

### 4c. Add vPB to KVO (full 6-step walkthrough)

This is the entire flow from "just clicked Deploy on the marketplace" to
"vPB shows up as Adopted in KVO". Six commands. Do them in order.

**Step 1: SSH into the vPB OS shell** (port **9022**, not 22)

```bash
ssh azureuser@<vpb-public-ip> -p 9022
# password: the adminPassword you set during the marketplace deploy
```

**Step 2: Enter the vPB CLI**

```bash
sudo vpb
```

You will see the Keysight EULA prompt the first time only:

```
YOU MUST ACCEPT THE KEYSIGHT SOFTWARE END USER LICENSE AGREEMENT (EULA) BEFORE PROCEEDING.
Do you want to display the EULA here now?
Please indicate: [y/n] n
I have read the Keysight Software End User License Agreement and I agree to its terms.
Please indicate: [y/n] y
CloudLensVPB#
```

If `sudo vpb` is "command not found" on an older marketplace image, install
the wrapper once:

```bash
curl -sSL https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/scripts/vpb-cli-wrapper.sh \
  | sudo tee /usr/local/bin/vpb > /dev/null
sudo chmod +x /usr/local/bin/vpb
```

**Step 3: Tell vPB where KVO lives, plus credentials**

Enter the `kvo` submode and set the IP, port, KVO user, and password. Use
the KVO **private IP** (for a stack deploy, the address in kvo-subnet:
10.50.2.x with the default --vnet-cidr; the standalone KVO template's own
VNet uses 10.60.1.x). Always set
credentials - without them, vPB shows `disconnected` even after `enable`
because it cannot authenticate to KVO during the registration handshake.

```text
CloudLensVPB# kvo
CloudLensVPB-kvo# ip <kvo-private-ip>
CloudLensVPB-kvo# port 443
CloudLensVPB-kvo# username clms@keysight.com
CloudLensVPB-kvo# password <kvo-user-password>
CloudLensVPB-kvo# enable
CloudLensVPB-kvo# exit
CloudLensVPB#
```

If your build does not accept `kvo` as a verb, type `?` at the
`CloudLensVPB#` prompt to see what it does accept. On 3.14 builds it is
`management-server`; on some 3.15 builds it is `orchestrator`. The submode
fields (`ip`, `port`, `username`, `password`, `enable`) are the same across
all three. If `username` is not a verb, try `user` or `auth`.

**KVO side check.** Before this works, KVO must have:
- `Live Settings > Remote Access URL` set to `https://<kvo-private-ip>`
- A user (e.g. `clms@keysight.com`) created under `User Management` with the
  `KVO User` role or higher

Both happen one time at KVO bootstrap.

**Known issue (Marketplace vPB image 3.15.0-1 in Azure, recorded 2026-08-17).**
Even with everything above configured, `show kvo` stays `disconnected`
because the image's `vpb-shim` pod, the component that announces the device to
KVO, crash-loops with `Could not read mgmt IP address`: the vpbsystem
interface inventory holds only the data ports (eth1/eth2) and no management
interface, and the CLI cannot create one. Network reachability is not the
cause; TCP 443 from the vPB to the KVO was verified open. The evidence and the
open question to Keysight are in `docs/AZURE_TAPPING_ARCHITECTURE.md`
("Marketplace vPB on Azure: adoption blocked inside the image").

**Workaround:** the out-of-band path (sensors -> vPB -> tool) works without
KVO adoption; configure the vPB directly from `sudo vpb` and ignore the KVO
status. The GWLB architecture is unaffected: its vPBs are the Linux installer
build, not this image.

If you need KVO adoption, open a Keysight TAC ticket with `show version`, the
management NIC's NSG rules, and
`sudo kubectl logs -n default <pod> -c vpb-shim`.

**Step 4: Confirm vPB is talking to KVO**

```text
CloudLensVPB# show kvo
```

You should see status transition to `connected` within ~30 seconds. If it
stays `disconnected`:
- If the vPB and KVO sit in separate VNets, check the peering is
  bidirectional (a stack deploy shares one VNet, so skip this)
- Confirm the vPB-mgmt NSG allows outbound to KVO on TCP/443
- Confirm KVO's NSG allows inbound on TCP/443 from the vPB subnet

**Step 5: Adopt in KVO**

In the KVO UI (`https://<kvo-ip>`):

- Left nav: `Inventory > Adopt Auto Discovered Device`
- The vPB now appears in the `Devices Available` table
- Check the box next to it, click `Ok`

**Step 6: Activate the license**

KVO UI: `Inventory > Licenses` (or `Live Settings > License Information`),
select the vPB, apply the **vPB** license credit. The
`License Manager Error` warning that appeared on the CLI disappears within
~30 seconds.

Same flow for **vController**: in the vController web UI, go to
`Settings > Management Server`, enter the KVO private IP (for a stack deploy,
the address in kvo-subnet: 10.50.2.x with the default --vnet-cidr; the
standalone KVO template's own VNet uses 10.60.1.x) + port `443`, save, then
adopt in KVO.

---

### Legacy: vPB v3.14 and earlier

```text
ssh azureuser@<vpb-public-ip>                # port 22 on v3.14
ssh admin@localhost -p 2222                   # CLI on 2222 (removed in v3.15)
admin> management-server set ip <kvo-private-ip>
admin> management-server enable
```

If you are on v3.14 (now end-of-life), upgrade to v3.15 to get the new
`sudo vpb` wrapper and the KVO-driven adoption flow.

### 4d. Adopt + license in KVO

In the KVO web UI:

1. `Devices > Adoptable`: both vController and vPB now appear
2. Select each, click `Adopt`
3. `Licenses > Activate`: apply the vController license to vController and
   the vPB license to vPB

Once both show as `Adopted` and `Licensed`, KVO becomes the single point of
configuration for both devices.

---

## 5. vPB out-of-band traffic configuration for out-of-band visibility demo

Once vPB is adopted and licensed, KVO owns the ports and
`scripts/vpb_wire_path.py` builds the path (Phase 15 of deploy-stack.sh prints
the exact command). Without KVO, configure the vPB directly from `sudo vpb`.
The prompt is `CloudLensVPB#` on every documented build (v3.14 and v3.15);
the `admin>` notation below is not from the User Guide, and the UG's own form
is a subcommand mode (`interface eth1`, then `ingress-filter vxlan ...`, then
`exit`). Type `?` at the prompt and check each verb against the vPB User
Guide CLI reference before pasting:

```text
admin> hostname vpb-demo
admin> eth1 ingress-mode ip,arp,icmp
admin> eth1 ingress-filter vxlan port 4789 strip   # terminate sensor VXLAN
admin> eth2 ingress-mode ip,arp,icmp

# Forwarding tunnel: receive on eth1, re-encapsulate to tool on eth2
admin> vxlan vectra-fwd egress eth2 dst <vectra-ip> vni 4242 port 4789

# Match rule: any packet ingress eth1 forwards to the vectra tunnel
admin> match-rule vectra priority 100 any ingress eth1 -> vxlan vectra-fwd

admin> write memory
admin> show running-config
admin> show statistics
```

This is the **out-of-band** pattern documented in the architecture diagram.
For the GWLB hairpin pattern (inline, a separate use case), see the
`cloudlens-vpb-azure-gwlb` repository under Keysight-Tech on GitHub and
`docs/AZURE_TAPPING_ARCHITECTURE.md` in this repo.

---

## 6. Troubleshooting matrix

| Symptom | Cause | Fix |
|---|---|---|
| `ssh azureuser@vpb -p 22` times out | KCOS does not expose 22 publicly | Use port 9022 (v3.15+ image; a v3.14 build is on 22) |
| `ssh azureuser@vpb -p 9022` times out | NSG missing `AllowKCOSSsh` rule | Add NSG rule (see section 2) |
| `ssh azureuser@vpb -p 9022` fails after NSG fix | KCOS still initializing | Wait 10-15 min after `provisioningState = Succeeded` |
| `ssh admin@localhost -p 2222` "connection refused" inside OS shell | v3.14 and earlier: the vPB CLI service is not up yet. v3.15+: nothing listens on 2222; the CLI lives inside the vpbsystem pod | v3.14: wait for the vpbsystem container to be running (`docker ps` on the generic installer, `kubectl get pods --all-namespaces` showing every pod `Running` on a Kubernetes install), then retry. v3.15+: run `sudo vpb` (section 2) |
| vController REST API returns 405 | nginx is serving the web app but the API backend is not up yet (about 10 min after boot), or the call targets a path that does not exist on this product | Wait until POST /cloudlens/api/v1/identity/login answers 400, 401 or 422; use the /cloudlens/api/v1 families |
| vController SSH "Permission denied" with right password | Seen in the lab before the first web UI login (section 2) | Complete the EULA and first-login password change in the browser once, then retry |
| KVO `Devices > Adoptable` empty | vPB/vController cannot reach KVO (separate VNets without peering, or the Marketplace vPB image's missing management interface) | Deploy with deploy-stack.sh, which puts all three in one VNet; for separate VNets add peering; for the image defect see AZURE_TAPPING_ARCHITECTURE.md |
| KVO adoption shows `Licensed` but vPB does not forward traffic | License is for vController only | Activate the **vPB** license, not the vController one |
| `nc -zv vpb-public-ip 4789` succeeds but no packets at Vectra | Match rule missing or tunnel target wrong | `show running-config` + `show statistics` to verify |
| Workload VM SSH "no route" to vController | Missing VNet peering | Peer prod VNet to vController VNet |
| Sensor cannot resolve the vController by name | No DNS for the appliance; the sensor needs a raw address | Set `cloudlens.manager_ip_or_fqdn` to the IP, not a name |
| Sensor never registers, `docker logs cloudlens-agent` shows the manager unreachable | With a narrowed admin CIDR the vController NSG refuses its public IP from inside the VNet (Azure SNATs VNet-to-public traffic) | Use the private IP: deploy-stack.sh writes it into customer_input.yaml and the summary shows it as "Sensors register on"; `CLOUDLENS_SENSOR_MANAGER_ADDR` overrides it. A VNet with no route to the private IP must use the public IP and sit inside the admin CIDR |
| `[license] KVO not ready yet ... retrying in 15 s` repeats | KVO's Keycloak answers 502/503 for a few minutes after boot or after the EULA | Normal: kvo_license.py waits up to 10 minutes and re-accepts the EULA on each attempt; only a failure after that is real |
| Phase 13 `[kvo-adopt] CLMS login failed (HTTP 401)` | The vController application password differs from the VM's OS password | The value is in `~/.cloudlens-vcontroller-creds-<rg>.json` (Phase 10); set `CLOUDLENS_VC_PASSWORD` to override, or re-run with --resume after completing the first login |
| quickstart.sh warns `galaxy.ansible.com unreachable; continuing` | Proxy, TLS or no route to Galaxy | Harmless when azure.azcollection, ansible.windows and community.windows are already installed; otherwise the run stops and names the missing collection |
| teardown keeps the VNet and the group | A NIC from another resource group still uses a CloudLens subnet (a workload you placed in cloudlens-vnet) | Expected: the teardown deletes only the CloudLens resources and reports the NIC; remove it first if you want the group gone |
| Phase 13 `[kvo-adopt] adopt failed: Cannot get discover CloudLens vController from CloudLens service: NatsError: Request timed out` | KVO was given the vController's public address (deploys before 2026-10-07 did that), which a narrowed admin CIDR refuses from inside the VNet because Azure SNATs VNet-to-public traffic | Re-run with `--resume`: `kvo_adopt_clms.py --clms-internal-ip` now discovers by the private address. By hand: KVO > Inventory > CloudLens Manager > Discover with the private IP. If a policy NSG denies VNet traffic below Azure's defaults, also allow TCP 443 (vController) and TCP 7443 (KVO) from `VirtualNetwork` |
| Phase 13b `The AKS tapping step did not complete: ...` | The engine's exit code says why: 3 no cluster access (`az aks get-credentials` / kubectl), 4 no sensor image (`--aks-sensor-image` or `--aks-sensor-tar`), 5 cluster or node pool creation failed, 6 the DaemonSet never became ready or the pods never registered | The line under it prints the exact `scripts/deploy-aks-tapping.sh` command to re-run alone; `kubectl --kubeconfig ~/.kube/cloudlens-aks-<cluster> -n cloudlens get pods -o wide` and the pods' logs show whether they reach the vController |

---

## 7. NSG rules required per device (for ARM/Terraform users)

| Device | Inbound rules the templates create | Source |
|---|---|---|
| **vController mgmt NIC** | TCP/22 (SSH), TCP/443 (web) from the admin CIDR; TCP/443 also from `VirtualNetwork` (`AllowHTTPSFromVNet`: the KVO, the sensors and AKS pods reach it on its private address) | `adminSourceCidr` (ARM) / `admin_source_cidr` (Terraform) / `--admin-cidr` (deploy-stack.sh); default `*`, narrow it |
| **KVO mgmt NIC** | TCP/22 (SSH), TCP/443 (web) from the admin CIDR; TCP/443 (`AllowHTTPSFromVNet`) and TCP/7443 (`AllowKvoFromVNet`, the gRPC connection the vController opens to KVO) from `VirtualNetwork` | same admin CIDR |
| **vPB mgmt NIC** | TCP/22, TCP/9022 (KCOS SSH), TCP/443 (mgmt web) from the admin CIDR, TCP/443 also from `VirtualNetwork` (`AllowHTTPSFromVNet`); UDP/4789 (standard VXLAN) and UDP/10800-10801 (Keysight VXLAN, used by the GWLB hairpin) from `sensorSourcePrefix` / `sensor_source_prefix` (default `VirtualNetwork`: this VNet, peered VNets and gateway-reached ranges) | as stated |
| **vPB ingress and egress NICs** | No NSG is attached to these NICs or their subnets by the templates; Azure then allows all traffic to them. Add a subnet NSG yourself if policy requires one | n/a |
| **Workload VMs** | TCP/22 (Linux), TCP/5985+5986 (Windows WinRM), TCP/3389 (Windows RDP) | operator IP only |

Azure's default `AllowVnetInBound` rule (priority 65000) already admits every port between VNet addresses, so the `VirtualNetwork` rules change nothing on a stock NSG: they name the in-VNet ports the appliances need and keep them open where a policy adds a deny rule below the defaults. The admin CIDR matters for the public addresses: from inside the VNet those arrive SNATed, outside the CIDR, which is why adoption, sensor registration and AKS pods all use private addresses.

---

## 7a. Operator gotchas when running quickstart.sh from your laptop

The customer-facing path is **Cloud Shell** (`curl quickstart.sh | bash`) where
Azure CLI auth is automatic and Python deps land in a clean venv. SE operators
running the same flow from a laptop sometimes hit these:

| Symptom | Cause | Fix |
|---|---|---|
| `name 'AzureCliCredential' is not defined` from azure_rm inventory | The azcollection's `requirements.txt` did NOT fully install (silent pip failure) | `pip install -r ~/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt` and look at every line |
| `name 'client_secret' is not defined` from azure_rm inventory | Plugin defaults to SP auth but no SP env vars are set | `export ANSIBLE_AZURE_AUTH_SOURCE=cli` (quickstart.sh v1.1+ does this for you when no SP is in env) |
| `ModuleNotFoundError: No module named 'azure.storage.blob'` | azcollection requirements include packages outside the headline list | Same as the first row: install the full `requirements.txt` |
| `ERROR! A worker was found in a dead state` on macOS for Windows VMs | macOS `fork()` safety check + pywinrm | quickstart.sh exports `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` itself on Darwin; when running ansible-playbook by hand, export it first |
| `ansible-galaxy` fails with a TLS or connection error to galaxy.ansible.com | Proxy, expired certificate or no route | quickstart.sh continues with a warning when azure.azcollection, ansible.windows and community.windows are already installed, and stops naming the missing one otherwise |
| `az vm run-command invoke` errors with `keyvault DATA_KEYVAULT` | The Azure CLI install is broken (often a pyenv + pip-installed azure-cli mismatch) | Use the Homebrew `az` binary (`/opt/homebrew/bin/az`) instead of the pyenv-shimmed one |
| `Permission denied (publickey,password)` when SSHing to Linux VMs with a known-good password | Trailing newline in the password file you `cat`'d | `cat pwfile \| tr -d '\n'` or check `wc -c pwfile` matches the password length exactly |
| WinRM is open in NSG but Ansible says timeout | The VM's Windows Firewall has its own block | `az vm run-command invoke ... --command-id RunPowerShellScript --scripts 'winrm quickconfig -force; Enable-PSRemoting -Force; New-NetFirewallRule -DisplayName WinRM-HTTP -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow'` |

These are exactly what we hit during the lab build. quickstart.sh now handles
the azcollection requirements, the auth source, the macOS fork-safety export
and a Galaxy outage automatically; the rest are operator-environment specific
so they live here in OPERATIONS.md.

---

## 8. The runbook scripts

| Script | Purpose |
|---|---|
| `quickstart.sh` | Customer-facing one-command sensor deploy. Reads `customer_input.yaml`, renders the inventory from its tag filters, auto-tunes forks, runs `deploy.yaml`. |
| `deploy/deploy-stack.sh` | The curl-pipe-bash stack deploy, 16 phases plus 13b: one shared VNet, vController + KVO (optional) + vPB via the ARM templates, automatic project key and vController password rotation, sensor chain, KVO licensing, vController adoption by its private address, AKS pod tapping (`--aks-cluster` / `--aks-sample`), vPB adoption, traffic path, summary. `--resume`, `--dry-run`, `--admin-cidr`, `--vnet-name`. |
| `deploy/teardown-stack.sh` | One command back down: audits the group (`--audit`), releases every licence on the group's KVO before deleting, asks before any licence loss, deletes the group only when the deploy created it and nothing else is inside, keeps a VNet that a NIC from another group still uses. |
| `deploy/*-marketplace.json` + `*-createUiDefinition.json` | What the site's Deploy to Azure buttons open in the portal: the full stack, or vController, KVO and vPB one at a time. `deploy/arm-template.json` is the sensors-only runner VM. |
| `deploy/shard.sh` | Splits more than 2,000 VMs into shards and runs one playbook per shard. |
| `scripts/vcontroller_project_key.py` | Phase 10: waits for the vController API, completes the forced first-login password change to a known value, records it in the creds file before and verifies it after, creates the project and prints its key. |
| `scripts/kvo_license.py` | Phase 12 and the teardown: activates, lists and releases KVO licences; waits for a booting KVO. |
| `scripts/kvo_adopt_clms.py` | Phase 13: adopts the vController into KVO by its private address (`--clms-internal-ip`) and creates its Cloud Config. |
| `scripts/deploy-aks-tapping.sh` | Phase 13b, also standalone: the AKS rail. Finds or creates the cluster (Azure CNI on the shared VNet), pushes the sensor tar to an ACR attached to the cluster, applies the sensor DaemonSet (or renders sidecar snippets), adds the optional sample app and verifies the pods register. Exit codes 0 done, 2 bad input, 3 no cluster access, 4 no sensor image, 5 cluster creation failed, 6 deployment failed. |
| `scripts/kvo_k8s_config.py`, `scripts/kvo_common.py` | Phase 13b with KVO: creates the Kubernetes presence (`k8s-<cluster>`), its Cloud Config and pod collection, and writes the project key the DaemonSet registers with. |
| `scripts/vpb_kvo_adopt.py` | Phase 14: points the vPB at KVO and adopts it; `--azure-rg/--azure-vm` drive the CLI through the VM agent with no SSH key. |
| `scripts/vpb_wire_path.py` | Phase 15: C2DL -> vPB ingress -> egress -> tool with a monitoring policy; the egress tool must be REMOTE with an IP on the egress port. |
| `scripts/render_azure_inventory.py` | Turns `customer_input.yaml` tag filters, resource groups and locations into the inventory quickstart.sh and the Docker image use. |
| `scripts/bootstrap-vpb.sh`, `scripts/vpb-cli-wrapper.sh` | vPB first-boot bootstrap (run by the template's CustomScript extension) and the `sudo vpb` wrapper. |
| `scripts/deploy-test-workload-vms.sh` | Three disposable tagged VMs (Ubuntu, RHEL, Windows) for an end-to-end sensor test. |
| `scripts/setup_azure_sp.sh`, `scripts/docker-entrypoint.sh` | Service principal for Docker/CI; the image entrypoint (deploy, cleanup, inventory, shard, shell). |
| `demo/setup-azure-visibility-demo.sh`, `demo/teardown.sh` | SE demo: workload VMs + vController + vPB + Vectra mock + peerings, then quickstart.sh. `demo/teardown.sh` runs `az group delete`, which strands any licences on a KVO in those groups; release them first or use `deploy/teardown-stack.sh`. |

---

## 9. Where to file feedback

- Site issues → https://github.com/Keysight-Tech/cloudlens-ansible-azure/issues
- vController / vPB / KVO product issues → Keysight TAC
- This document → open a PR; the goal is that this file grows with every new
  gotcha discovered in the field.
