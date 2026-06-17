# CloudLens Operations Guide

Single source of truth for every gotcha a customer or SE will hit when working
with **vController** (formerly CLMS), **KVO** (Keysight Vision Orchestrator),
and **vPB** (Virtual Packet Broker) from the Azure Marketplace.

If you hit any wall not described here, please open a PR adding it. The point
of this doc is that nobody should ever burn the same hour twice.

---

## 1. Quick reference: every port and credential you will touch

| Component | Public port(s) | Internal port(s) | Default UI cred | Default CLI cred | First-boot wait |
|---|---|---|---|---|---|
| **vController** | TCP 443 (web UI), TCP 22 (Linux SSH) | n/a | `admin / Cl0udLens@dm!n` (force-change on first login) | n/a | ~15 min |
| **KVO** | TCP 443 (web UI), TCP 22 (Linux SSH) | n/a | See Keysight KVO docs (operator must change immediately) | n/a | ~15 min |
| **vPB v3.15+** | TCP **9022** (Linux SSH on KCOS), TCP 443 (mgmt web), TCP 30101 (vpb-shim NodePort), UDP 4789 (VXLAN), UDP 10800-10801 (Keysight VXLAN) | n/a (CLI on 2222 REMOVED in 3.15) | n/a | n/a (managed entirely from KVO) | 10-15 min |
| **vPB v3.14 (legacy)** | TCP 22, TCP 443, UDP 4789, UDP 10800-10801 | TCP 2222 (vPB CLI, localhost-only) | n/a | `admin / ixia` (force-change on first SSH) | 10-15 min |
| **Sensor** | n/a | n/a | n/a | n/a | <1 min |

### Why these are not the obvious defaults

- **vPB OS SSH is on port 9022, NOT port 22.** Keysight CloudLens OS (KCOS)
  binds sshd to 9022 on the public NIC. A connection to `:22` will time out
  forever even after the VM is fully up. The marketplace ARM template now
  opens 9022 in the NSG automatically (`AllowKCOSSsh` rule).
- **vPB v3.15 moved the CLI inside a K8s pod.** v3.14 exposed a CLI on port
  2222 from inside the OS shell, reached via two-hop SSH (`ssh azureuser@vpb
  -p 9022` then `ssh admin@localhost -p 2222`). v3.15 stops that pod-external
  sshd; the CLI binary (`/usr/local/bin/xf-client`) now lives inside the
  `vpbsystem` K8s container. The marketplace ARM template installs a
  `/usr/local/bin/vpb` wrapper at deploy time so customers just type
  `sudo vpb` to land in `CloudLensVPB#`. Do NOT try `ssh -p 2222` on v3.15 -
  it will time out.
- **vController and KVO use port 22 normally**, but their web UI gates new
  sessions behind a EULA + first-login password change. Until you complete
  both in the browser, the REST API returns 405 and SSH returns "Permission
  denied" even with the correct credentials. The first manual UI session is
  unavoidable for these images.

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

### vPB (port 9022, two-hop into CLI)

```bash
# Step 1: OS shell on port 9022 (NOT 22)
ssh azureuser@<vpb-mgmt-public-ip> -p 9022

# Step 2: from inside the OS shell, hop to the Keysight CLI
ssh admin@localhost -p 2222
# default password: ixia
# vPB will FORCE you to change it on first login
```

If `ssh -p 9022` returns "Operation timed out":

1. **Check the NSG.** The vPB management NIC's NSG must allow inbound TCP/9022.
   If you deployed via the latest marketplace ARM template (`vpb-marketplace.json`
   v1.1+), this rule is included. For custom deployments:

   ```bash
   az network nsg rule create -g <rg> --nsg-name <vpb-nsg> \
     -n AllowKCOSSsh --priority 105 --protocol Tcp \
     --destination-port-ranges 9022 --source-address-prefixes "*" \
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
| vController web UI | `admin` | `Cl0udLens@dm!n` | Forced on first login |
| vController OS SSH | `azureuser` (or whatever you passed to ARM) | ARM `adminPassword` parameter | Never (set at deploy time) |
| KVO web UI | `admin` | See Keysight KVO docs | Forced on first login |
| KVO OS SSH | `azureuser` | ARM `adminPassword` parameter | Never |
| vPB OS SSH (port 9022) | `azureuser` | ARM `adminPassword` parameter | Never |
| vPB CLI (port 2222 from localhost) | `admin` | `ixia` | Forced on first SSH |
| Workload VMs (Linux) | `azureuser` | Set at deploy time | Never |
| Workload VMs (Windows) | `azureuser` | Set at deploy time | Never |

Keep all four passwords in sync via your password manager. The demo
orchestrator generates one shared password (16 chars, upper+lower+digit+symbol)
and reuses it everywhere so you only have to remember one.

---

## 4. Adopting vPB and vController into KVO

This is the premium "single pane of glass" workflow that turns three separately
deployed VMs into one fleet view.

### 4a. Prerequisites

- KVO is deployed and you have completed the EULA + first-login on its web UI.
- A KVO user with role `KVO User` exists (e.g. `clms@keysight.com`).
- The vPB and vController VNets are peered with the KVO VNet (so KVO can
  reach them on private IPs). If they are in separate Azure resource groups,
  create the bidirectional VNet peering before adoption.

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
- IP: KVO private IP (e.g. `10.60.1.4`)
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

**Step 3: Tell vPB where KVO lives**

Enter the `kvo` submode and set the KVO IP. Use the **private IP** if the
two VNets are peered (recommended), otherwise the public IP.

```text
CloudLensVPB# kvo
CloudLensVPB-kvo# ip 10.60.1.4
CloudLensVPB-kvo# port 443
CloudLensVPB-kvo# enable
CloudLensVPB-kvo# exit
CloudLensVPB#
```

If your build does not accept `kvo` as a verb, type `?` at the
`CloudLensVPB#` prompt to see what it does accept. On 3.14 builds it is
`management-server`; on some 3.15 builds it is `orchestrator`. The submode
fields (`ip`, `port`, `enable`) are the same across all three.

**Step 4: Confirm vPB is talking to KVO**

```text
CloudLensVPB# show kvo
```

You should see status transition to `connected` within ~30 seconds. If it
stays `disconnected`:
- Check VNet peering between the vPB and KVO subnets is bidirectional
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
`Settings > Management Server`, enter KVO IP `10.60.1.4` + port `443`,
save, then adopt in KVO.

---

### Legacy: vPB v3.14 and earlier

```text
ssh azureuser@<vpb-public-ip>                # port 22 on v3.14
ssh admin@localhost -p 2222                   # CLI on 2222 (removed in v3.15)
admin> management-server set ip 10.60.1.4
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

## 5. vPB out-of-band traffic configuration for NetRefer-style demo

Once vPB is adopted and licensed, the actual packet broker config:

```text
admin> hostname vpb-netrefer
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
For the GWLB hairpin pattern (a separate use case), see
`Azure_GWLB_VPB/docs/cloudlens-vpb-gwlb-ha-architecture.drawio`.

---

## 6. Troubleshooting matrix

| Symptom | Cause | Fix |
|---|---|---|
| `ssh azureuser@vpb -p 22` times out | KCOS does not expose 22 publicly | Use port 9022 |
| `ssh azureuser@vpb -p 9022` times out | NSG missing `AllowKCOSSsh` rule | Add NSG rule (see section 2) |
| `ssh azureuser@vpb -p 9022` fails after NSG fix | KCOS still initializing | Wait 10-15 min after `provisioningState = Succeeded` |
| `ssh admin@localhost -p 2222` "connection refused" inside OS shell | vPB internal service not up | Wait for `kubectl get pods --all-namespaces` to show all pods `Running` |
| vController REST API returns 405 | EULA + first-login not yet completed in UI | Complete via browser once |
| vController SSH "Permission denied" with right password | Same as above | Complete UI EULA + password change |
| KVO `Devices > Adoptable` empty | vPB/vController cannot reach KVO | Verify VNet peering and NSGs |
| KVO adoption shows `Licensed` but vPB does not forward traffic | License is for vController only | Activate the **vPB** license, not the vController one |
| `nc -zv vpb-public-ip 4789` succeeds but no packets at Vectra | Match rule missing or tunnel target wrong | `show running-config` + `show statistics` to verify |
| Workload VM SSH "no route" to vController | Missing VNet peering | Peer prod VNet to vController VNet |
| Workload VM cannot resolve `<vpb-private-ip>` from sensor | No DNS, sensor uses raw IP | Confirm `cloudlens.manager_ip_or_fqdn` is the raw IP, not a name |

---

## 7. NSG rules required per device (for ARM/Terraform users)

| Device | Inbound rules required |
|---|---|
| **vController mgmt NIC** | TCP/22 (SSH), TCP/443 (web) from operator IP only |
| **KVO mgmt NIC** | TCP/22 (SSH), TCP/443 (web) from operator IP only |
| **vPB mgmt NIC** | TCP/9022 (KCOS SSH), TCP/443 (mgmt web), UDP/4789 (standard VXLAN), UDP/10800-10801 (Keysight VXLAN, used by GWLB hairpin) |
| **vPB ingress NIC** | UDP/4789 from sensor source VNets (peered) |
| **vPB egress NIC** | None inbound; outbound to tool only |
| **Workload VMs** | TCP/22 (Linux), TCP/5985+5986 (Windows WinRM), TCP/3389 (Windows RDP) from operator IP only |

---

## 8. The runbook scripts

| Script | Purpose |
|---|---|
| `quickstart.sh` | Customer-facing one-command sensor deploy. Reads `customer_input.yaml`, runs `deploy.yaml` Ansible playbook. |
| `deploy/deploy-stack.sh` | End-to-end Azure stack deploy: vController + KVO (optional) + vPB + sensors. The "Deploy to Azure" button on the site uses this. |
| `demo/setup-netrefer-demo.sh` | NetRefer-style demo orchestrator: workload VMs + vController + KVO + vPB + Vectra mock + peerings, then runs `quickstart.sh`. |
| `demo/teardown.sh` | Nuke the demo (three RGs). `--include-kvo` to also drop `kvo-test-rg`. |
| `scripts/vcontroller_project_key.py` | Programmatic project + API key retrieval against the vController REST API (used by the demo orchestrator). |

---

## 9. Where to file feedback

- Site issues → https://github.com/Keysight-Tech/cloudlens-ansible-azure/issues
- vController / vPB / KVO product issues → Keysight TAC
- This document → open a PR; the goal is that this file grows with every new
  gotcha discovered in the field.
