# Keysight CloudLens Azure Visibility : SE Demo Playbook

A reusable 30-minute demonstration for any enterprise prospect evaluating
Azure network visibility. Built and stress-tested against a real Azure
subscription. Customize the talking points per industry; the technical
flow stays the same.

This guide is for **field SEs** running customer or prospect demos. Pair
it with `docs/OPERATIONS.md` for the underlying technical reference.

---

## When to run this

Pull this kit out for any prospect who fits one of these patterns:

- "We need packet-level visibility into Azure VMs but Azure vTAP is
  unavailable in our region."
- "We want to feed NDR (Vectra, ExtraHop, Corelight, Darktrace) from
  Azure workloads without inserting an inline appliance."
- "Our security team needs traffic mirroring but Cloud Ops will not
  approve anything that touches the production data path."
- "We are running a hybrid Linux + Windows workload estate on Azure and
  need a single sensor strategy."

If you hear any of those, this kit gives them a live answer in 30 min.

---

## The story you are telling

In one sentence: **"Drop a CloudLens sensor on every Azure VM, register
it to vController in 90 seconds, mirror every packet to your tool as
VXLAN. No inline placement, no Azure vTAP needed, works in any region."**

Three things the prospect will care about:

| Concern | The CloudLens answer |
|---|---|
| Inline risk | Sensors are out-of-band by design - production never depends on Keysight |
| Region availability | vTAP-free. Works in any Azure region today |
| Scale | One Ansible playbook covers 1 sensor or 5,000 sensors |
| Mixed OS estate | Same sensor on Ubuntu, RHEL, Windows. One inventory, one workflow |
| Tool agnostic | VXLAN UDP/4789 to any tool that speaks VXLAN (Vectra, Corelight, ExtraHop, custom) |

---

## The 30-minute demo structure

| Minute | What you do | What the prospect sees |
|---|---|---|
| 0-3 | Frame the problem, share the diagram | Architecture diagram, the three "no's" |
| 3-8 | Show the public site, click Deploy to Azure | Marketplace wizard, vController + KVO + vPB cards |
| 8-15 | Show your live demo environment, walk through the sensor inventory | 4 sensors registered (2 Ubuntu, 2 Windows), green status |
| 15-22 | Click through vController: create a Connection to a tool | Live config push to sensors |
| 22-27 | Switch to the tool side, tcpdump streams real VXLAN packets | Live capture, inner L2 frames decoded |
| 27-30 | Close with the upgrade path | KVO single-pane, eBPF kTLS for payload, APIM SHG for PaaS visibility |

The whole thing runs against `kvo-test-rg` in Azure subscription
`CloudLensPublic`. Nothing needs to be torn down between demos.

---

## What is already deployed in the lab (reuse for every demo)

All resources live in `kvo-test-rg` in the `CloudLensPublic` Azure
subscription, in `eastus2`.

| Component | Public IP | Private IP | Notes |
|---|---|---|---|
| KVO | `20.230.15.87` | `10.60.1.4` | EULA accepted, admin user set |
| vController | `20.122.11.40` | `10.60.10.4` | Project `cloudlens-demo` active |
| vPB | `40.75.119.109` | `10.60.20.4` (mgmt) | v3.15.0-1, KVO adoption is a known issue (see OPERATIONS.md) |
| Vectra mock | `52.251.127.107` | `10.60.40.4` | nginx + tcpdump ready for UDP/4789 |
| app01-ubuntu | `172.172.73.189` | `10.60.30.4` | Sensor running, registered |
| app02-ubuntu | `20.14.133.93` | `10.60.30.5` | Sensor running, registered |
| win01 | `20.110.207.206` | `10.60.30.6` | Sensor running, registered |
| win02 | `20.119.222.251` | `10.60.30.7` | Sensor running, registered |

Shared admin password lives at `~/.netrefer-demo-v2/admin_pw` (yes the
folder name is historical; do not rename it without updating scripts).

---

## Pre-demo checklist (do 30 minutes before the call)

1. **Confirm Azure auth is fresh**

   ```bash
   /opt/homebrew/bin/az account show --query "{name:name,user:user.name}" -o tsv
   ```

   Should return `CloudLensPublic brine-ndam.ketum@keysight.com`. If
   expired, run `az login --use-device-code` and re-auth.

2. **Confirm all 4 sensors are still healthy**

   ```bash
   sshpass -p "$(cat ~/.netrefer-demo-v2/admin_pw)" ssh \
     -o StrictHostKeyChecking=no azureuser@172.172.73.189 \
     'sudo docker ps --filter name=cloudlens-agent --format "{{.Names}}: {{.Status}}"'
   ```

   Expect `cloudlens-agent: Up N hours`.

3. **Open these tabs in your browser**

   - `https://20.122.11.40` (vController)
   - `https://keysight-tech.github.io/cloudlens-ansible-azure/` (public
     site for the marketplace click-through demo)
   - `https://github.com/Keysight-Tech/cloudlens-ansible-azure/blob/main/docs/OPERATIONS.md`
     (operator gotchas)

4. **Pre-warm vController**: log in once so the EULA + password change is
   out of the way for the live call. Open the Sensors view so the 4
   green agents are visible the moment you screen-share.

5. **Start tcpdump on vectra-mock** in a background terminal so packets
   are pre-buffered:

   ```bash
   sshpass -p "$(cat ~/.netrefer-demo-v2/admin_pw)" ssh \
     azureuser@52.251.127.107 \
     'sudo nohup timeout 1800 tcpdump -i any -nn -w /tmp/vxlan-capture.pcap udp port 4789 > /tmp/tcpdump.log 2>&1 &'
   ```

---

## The demo, beat by beat

### Beat 1 (0:00 - 0:03) : Frame the problem

Open your draw.io diagram (`cloudlens-azure-visibility-demo-kit.drawio`)
in a browser. The architecture has three layers:

- Sensors on every IaaS VM (Linux + Windows)
- vPB cluster in a peered observation VNet (out-of-band)
- PaaS Diagnostic Settings to Event Hubs to ingest L7 metadata

Say: **"This is the architecture. No inline anything. No Azure vTAP.
Works in any region. Let me show you the live build."**

### Beat 2 (0:03 - 0:08) : The customer-facing deploy path

Open https://keysight-tech.github.io/cloudlens-ansible-azure/. Scroll to
the prereq cards (vController, KVO, vPB). Hover over the Deploy to Azure
buttons. Say: **"This is what your team clicks. One Azure Marketplace
deploy per component. The ARM templates are open source - go pick at
them."**

If they care about IaC: also click the `Prefer Terraform?` disclosure.

### Beat 3 (0:08 - 0:15) : The live lab

Switch to vController (`https://20.122.11.40`). Show the `cloudlens-demo`
project. Click Sensors. Four green sensors:

| Hostname | OS | Status |
|---|---|---|
| app01-ubuntu | Linux | Connected |
| app02-ubuntu | Linux | Connected |
| win01 | Windows | Connected |
| win02 | Windows | Connected |

Say: **"These four agents were deployed in 4 minutes by a single Ansible
playbook. Same playbook scales to 5,000 VMs."**

If they ask "how does Ansible know which VMs are which OS?" - open the
inventory YAML and show the tag-based discovery:

```bash
cat inventory/azure_rm.yaml | head -25
```

Point out the `cloudlens=yes` tag filter and the OS-based grouping.

### Beat 4 (0:15 - 0:22) : Push a Connection

In vController, navigate to Tools > Add Tool:

- Name: `tool-mock`
- IP: `10.60.40.4` (the vectra-mock VM)
- Encapsulation: VXLAN
- Port: 4789
- VNI: 4242

Save. Then Connections > New Connection:

- Source: pick all 4 sensors
- Destination: `tool-mock`
- Filter: leave blank
- Activate

Say: **"This is the only screen the security team touches. Define a
tool, point sensors at it, click activate. Sensors get the new config
within 10 seconds."**

### Beat 5 (0:22 - 0:27) : The packets arrive

Switch to a terminal that is SSHed to vectra-mock. Run:

```bash
sudo wc -c /tmp/vxlan-capture.pcap        # file growing
sudo tcpdump -nn -r /tmp/vxlan-capture.pcap -c 5
```

Expected output: VXLAN UDP/4789 packets with an inner IP layer. Decode
shows the original L2 frames carrying the workload traffic.

Say: **"Real packets, real-time. No inline appliance. No NSG
side-effect. The workload VMs do not know they are being mirrored."**

### Beat 6 (0:27 - 0:30) : Close + roadmap

Three honest upsell cards:

1. **KVO** for single pane of glass across many vPBs and many vControllers
2. **eBPF kTLS hook** for TLS payload visibility on Linux (no cert
   distribution, no MITM)
3. **APIM Self-Hosted Gateway in AKS + CloudLens K8s DaemonSet** for
   full-packet visibility into Azure PaaS APIs that the platform image
   does not let you tap

Hand them three artifacts:

- The draw.io diagram (PNG + PDF in their email)
- A link to https://keysight-tech.github.io/cloudlens-ansible-azure/
- The PR-ready GitHub repo for their security team to audit

---

## If the prospect asks any of these...

**Q: "What if a vPB dies?"**
A: Production keeps serving. Sensors just stop pushing mirror. No
customer impact. Run vPB Active-Active in two AZs for ~10s failover.

**Q: "Can you do GWLB?"**
A: Yes - dual vPB hairpin with 5-tuple LB. See
`Azure_GWLB_VPB/docs/cloudlens-vpb-gwlb-ha-architecture.drawio`. This
demo uses out-of-band because most customers reject inline.

**Q: "What about east-west between two PaaS services?"**
A: Honest answer: Microsoft does not expose those packets to anyone.
We give you the adjacent telemetry (per-app Diagnostic Settings, Event
Hubs forwarder) which feeds detection models like a flow record. For
true packet-level on tier-1 APIs, the only path is migrating those
specific APIs to APIM Self-Hosted Gateway in AKS - which is a real,
documented path and we have the runbook.

**Q: "Why is vPB v3.15 saying License Manager Error?"**
A: KVO adoption auto-licenses on adopt. We have a documented quirk in
Azure peered VNets - see OPERATIONS.md section 4c. Out-of-band data
path works regardless.

**Q: "Can we audit your code?"**
A: All open source.
https://github.com/Keysight-Tech/cloudlens-ansible-azure - PRs welcome.

**Q: "What if we already own ExtraHop / Corelight / Darktrace?"**
A: Anything that accepts VXLAN UDP/4789 works. The vectra-mock in our
demo is just a tcpdump-on-port-4789 - your tool is the same shape, but
with a real NDR engine instead of tcpdump.

---

## The 5-minute resync after every demo

The lab is built to be idempotent. After a demo:

```bash
# Stop any test traffic generators
sshpass -p "$(cat ~/.netrefer-demo-v2/admin_pw)" ssh \
  azureuser@172.172.73.189 'pkill -f "while true; do curl"' || true

# Clear the tcpdump capture (so the next demo starts at 0 bytes)
sshpass -p "$(cat ~/.netrefer-demo-v2/admin_pw)" ssh \
  azureuser@52.251.127.107 'sudo truncate -s 0 /tmp/vxlan-capture.pcap'

# In vController UI: delete the Connection you created (Tools stays)
# This stops sensors from pushing mirror, so the next demo starts dark
```

Sensors stay registered, project stays alive, lab is ready for the next
prospect call.

---

## Teardown (only if you want to nuke everything)

Costs run ~$30/day with the full lab up. If the demo cycle pauses for
more than two weeks, tear down to save cost; rebuild in 30 min when
needed.

```bash
bash demo/teardown.sh                # nukes 3 RGs
bash demo/teardown.sh --include-kvo  # also drops kvo-test-rg
```

To rebuild fresh:

```bash
bash demo/setup-azure-visibility-demo.sh
```

That orchestrator deploys everything from scratch, generates a new
shared password, and prints all the IPs in a state file.

---

## Where this came from

This kit was built and stress-tested in June 2026 against a real
prospect engagement. The kit survived a hardware-image migration (vPB
v3.14 to v3.15), a CLMS-to-vController rebrand, a KVO marketplace
launch, and the discovery of several Keysight v3.15 documentation gaps.

Every wall hit during the original build is documented in
`docs/OPERATIONS.md`. Every command in this playbook has been run live.

Author the next chapter when you take it to your next prospect.
