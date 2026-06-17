# SE Outreach Email Templates

Copy-paste templates for SE-to-prospect outreach. Three variants by
prospect profile. Each ends with the same call-to-action: 30-minute
live demo.

Pair with `docs/SE_DEMO_PLAYBOOK.md` for the demo itself.

---

## Variant A: Inline-averse prospect (most common)

Use when the prospect has already said "no inline" or "we are not
inserting anything into our production data path."

```
Subject: 30-min demo: Azure packet visibility without inline placement

Hi [Name],

You mentioned [last week / last call] that you need packet-level
visibility into your Azure workloads but cannot accept an inline
appliance in the production data path. That is exactly the constraint
CloudLens was built for.

Quick recap of what we can do:

- Host-resident sensor on every Linux + Windows VM, deployed in
  parallel via Ansible. Out-of-band by design - your application path
  never depends on us.
- Sensor encapsulates captured packets as VXLAN UDP/4789 and forwards
  to any tool that speaks VXLAN (Vectra, Corelight, ExtraHop, custom).
- No Azure vTAP requirement. Works in any Azure region today.
- One Ansible playbook covers 1 sensor or 5,000 sensors.

I have a live demo environment standing in eastus2 - four sensors
already registered, two Linux, two Windows. I can show you the full
flow end-to-end in 30 minutes:

  - The Marketplace-driven deploy your Ops team would actually do
  - Sensor inventory in CloudLens vController
  - Live config push from vController to sensors
  - VXLAN packets arriving at a tcpdump receiver in real-time
  - The honest blind-spots conversation (PaaS, double-TLS) and what
    covers each

What is your week looking like? I can run [Tue / Wed / Thu] at any
time that works for you.

Reference materials in advance:

- Architecture diagram: [attach PNG]
- Open-source runbook: https://keysight-tech.github.io/cloudlens-ansible-azure/
- Operations guide:
  https://github.com/Keysight-Tech/cloudlens-ansible-azure/blob/main/docs/OPERATIONS.md

Thanks,
[Your name]
[Your title]
Keysight Technologies
```

---

## Variant B: NDR-augmentation prospect

Use when the prospect already owns a tool (Vectra, ExtraHop, Corelight,
Darktrace) and the question is how to feed it from Azure.

```
Subject: Feed [their NDR] from Azure - 30-min demo

Hi [Name],

You said your [Vectra / Corelight / ExtraHop / Darktrace] cluster is
getting starved of Azure-side telemetry. That is the most common
question we get, and the architecture is straightforward.

The shape of the answer:

- CloudLens sensor on every Azure VM (Linux + Windows). One Ansible
  playbook. Scales to thousands of sensors without changing anything
  in your tool config.
- Sensors push VXLAN UDP/4789 directly to your existing tool. No
  middleware. No proxy. Your tool sees real packets.
- vPB (optional) sits between sensors and tool when you want
  deduplication, header-slicing, or fleet-wide LB to multiple tool
  nodes with session affinity.

I have a working lab with sensors on Linux + Windows VMs and a
VXLAN-receiving tool simulator. 30 minutes is enough to show:

  - Sensors deploying via Ansible (live)
  - Connection config push from vController (live)
  - VXLAN packets at the tool side, decoded (live)
  - The session-affinity LB story at the vPB layer (slide)

If you have [tool] running somewhere reachable, we can point a sensor
at it directly during the demo - real packets into your real console
within the 30 minutes.

What slot works for you?

Reference in advance:

- Architecture: [attach PNG]
- Runbook: https://keysight-tech.github.io/cloudlens-ansible-azure/

Thanks,
[Your name]
```

---

## Variant C: Hybrid IaaS+PaaS prospect

Use when the prospect has a complex Azure estate with both VMs and
PaaS objects (APIM, App Service, Functions, Front Door).

```
Subject: Visibility across your Azure IaaS + PaaS estate - the honest answer

Hi [Name],

You asked whether CloudLens can give you full visibility across your
Azure estate including PaaS objects. The honest answer has three
parts, and I want to walk you through all three in a 30-min demo.

Part 1: IaaS is solved.
Host sensor on every VM (Linux + Windows). Out-of-band. One Ansible
playbook. Tag-driven discovery. Same deploy on 1 VM or 5,000.

Part 2: PaaS is honest about platform limits.
Microsoft does not expose packets from APIM, App Service, Functions,
Front Door to anyone - not us, not any vendor. The best you can get
is what Azure exposes via Diagnostic Settings. We have a runbook
that pipes those through Event Hubs into your NDR as L7 transaction
records. Vectra and similar detection models work on this metadata.

Part 3: Where you really want packets in PaaS, there is one path -
migrate the API subset to APIM Self-Hosted Gateway running in AKS.
Then a CloudLens DaemonSet captures every packet. Strategic, not a
single-call decision, but a documented path.

I will show all three live in 30 minutes against a working lab and we
can talk about which of your specific services map to each path.

Best windows: [your availability]

In the meantime:

- Architecture diagram: [attach PNG]
- Public runbook: https://keysight-tech.github.io/cloudlens-ansible-azure/
- Operations doc:
  https://github.com/Keysight-Tech/cloudlens-ansible-azure/blob/main/docs/OPERATIONS.md

Thanks,
[Your name]
```

---

## Post-demo follow-up template

Send within 24 hours of the demo. The goal is to keep the technical
buyer warm while the procurement conversation starts.

```
Subject: Recap + next steps after today

Hi [Name],

Thanks for the time today. Quick recap of what we covered:

- The architecture (out-of-band sensors, VXLAN to your tool, no
  inline). [Attach diagram PNG]
- Live deploy via Ansible against tagged Azure VMs.
- Sensors registering to vController in under 90 seconds.
- Config push from vController to sensors, real-time.
- VXLAN packets at the tool side, decoded, with the original L2
  frame intact.

What I have for you in advance of the technical evaluation:

1. Public runbook with one-click Marketplace deploys:
   https://keysight-tech.github.io/cloudlens-ansible-azure/

2. The full operations guide, including every gotcha we have hit in
   real engagements:
   https://github.com/Keysight-Tech/cloudlens-ansible-azure/blob/main/docs/OPERATIONS.md

3. The Ansible repo for your security team to audit:
   https://github.com/Keysight-Tech/cloudlens-ansible-azure

Three concrete next steps to suggest:

  - Stand up a vController + one sensor in your own Azure subscription
    using the Marketplace cards on the site above. ~30 minutes,
    no Keysight commitment. We can pair on a screen-share if helpful.
  - Pick one of your PaaS services and let us scope a Diagnostic
    Settings -> Event Hub -> NDR path together. ~1 hour of joint
    architecture time.
  - Define the scale target (1k? 10k VMs?) so we can size the vPB
    cluster and discuss the LB strategy.

I am available [your slots] for any of these.

Thanks,
[Your name]
```

---

## What to attach to every prospect email

These three things in every initial outreach:

1. **PNG of the architecture diagram** (the vendor-neutral kit version)
   - File: `cloudlens-azure-visibility-demo-kit.png`
   - Lives in: this repo or your local `~/Downloads`

2. **Direct link to the operations doc**
   - https://github.com/Keysight-Tech/cloudlens-ansible-azure/blob/main/docs/OPERATIONS.md

3. **Direct link to the public site**
   - https://keysight-tech.github.io/cloudlens-ansible-azure/

Customers consistently say "I was able to read about CloudLens before
the call" is the thing that makes them comfortable buying. Lead with
the artifacts.
