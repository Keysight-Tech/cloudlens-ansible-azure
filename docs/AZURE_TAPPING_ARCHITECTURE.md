# Azure tapping: what is possible, and what is not

Read this before promising a customer an "AWS-equivalent" Azure deployment.

Short version: **Azure's native answer is Gateway Load Balancer service
chaining, and it is GA.** What Azure lacks is an out-of-band MIRROR equivalent
to AWS VPC Traffic Mirroring; its vTAP is a gated preview. So the visibility
story ports, but it changes shape from out-of-band to inline, and that changes
the failure mode. Do not present the AWS deck unchanged.

## The AWS path, for comparison

    workload -> AWS VPC Traffic Mirroring session -> collector SVM -> L2GRE -> vPB -> tool

AWS exposes traffic mirroring as a first-class, generally-available API. KVO
cuts one mirror session per tagged workload with no software on the workload at
all. That is what makes the AWS demo strong: Windows hosts are tapped with
nothing installed on them.

## Azure has THREE mechanisms. The Azure-native one is GWLB, and it is GA.

### 0. Azure Gateway Load Balancer service chaining: THE Azure-native answer

    internet -> Standard LB -> GWLB -> vPB (VXLAN hairpin) -> back to GWLB -> backend
                                    \-> mirrored copy -> tool

Documented by Keysight in **vPB User Guide chapter 3, "Azure Gateway Load
Balancer"** (CloudLens_vPB_UG_v3.16, 913-3000-01 Rev. ZG, pp. 42-47) and in
`CloudLens_vPB_Azure_GWLB_Deployment_Guide.docx`. The UG names three components:
CloudLens vPacketStack, the Azure GWLB, and a Virtual Machine Network Interface
(VMNI). GWLB distributes traffic across the vPBs by 5-tuple hash.

**This is generally available, not a preview**, and it is deployed and proven in
the CloudLensGwLB-rg resource group: dual vPB Active-Active across zones, GWLB
with VXLAN External VNI 900/port 10800 and Internal VNI 901/port 10801, a
Standard LB chained to it, two NGINX backends, a tool VM and a vLM.

**The critical difference from AWS, and say it to every customer: this is
INLINE, not a mirror.** AWS traffic mirroring is out of band, so a dead vPB
costs you visibility. On Azure GWLB the vPB sits in the service chain, so a
dead vPB costs you **the application**. Verified live on 2026-08-14: both vPBs
had a licence that expired 2026-08-05 23:59, their counters were frozen at
1,677 packets, and HTTP through the Standard LB timed out completely. The
architecture was intact; an expired licence took the customer path down.

Operational consequence: **monitor vPB licence expiry as a production alarm on
Azure**, and size the HA pair for the failure you actually have.

## The other two mechanisms

### 1. Azure vTAP: the out-of-band agentless equivalent. NOT AVAILABLE.

    workload -> Azure Virtual Network TAP -> vPB ingress -> vPB -> VXLAN -> tool

Note there is **no collector SVM in this path**: Azure vTAP mirrors straight to
the vPB's ingress interface. Keysight documents exactly this topology in
`Azure_vTAP_vPB_Suricata_Demo_Guide.docx` (vTAP -> vPB -> VXLAN -> Suricata).

**It is a Microsoft preview and it is gated.** Verified on the CloudLensPublic
subscription:

    az provider show -n Microsoft.Network --query "resourceTypes[].resourceType" | grep -i tap
    -> nothing. The virtualNetworkTaps resource type is not exposed at all.

Public-preview testing regions are `East US 2 EUAP` and `Central US EUAP`, which
are Microsoft canary regions. Onboarding goes through VTAP-Support@microsoft.com.

**So do not scope work against vTAP until a subscription is onboarded.** The
resource type has to appear in the provider before any of it can be automated.

### 2. Sensor-based tapping: available now, PROVEN 3/3, what this repo builds

    workload + CloudLens sensor -> vController -> collector/vHub -> vPB -> tool

The sensor does the tapping in the guest. Everything downstream of the sensor is
identical to AWS, because KVO's device-side objects are cloud-agnostic.

**Proven end to end on 2026-08-17**, verified in the vController's own registry
rather than Ansible's recap: three fixture VMs (Ubuntu 22.04, RHEL 9, Windows
Server 2022) discovered by tag, sensors installed per OS, all three registered
in the project:

    test-ubuntu-1   6.14.0-475
    test-rhel-1     6.14.0-475
    test-windows-1  registered

Registration needs only the vController's public IP, so the per-product VNet
isolation that blocks Marketplace vPB adoption does NOT affect this path. The
Windows installer exe is deliberately not in the repo (66 MB, gitignored):
copy it into files/ first, as DEPLOYMENT_GUIDE.md says, or the play fails at
"Transfer CloudLens installer". Running the chain from macOS also needs the
Darwin fork-safety export, which quickstart.sh now sets itself.

**The honest trade:** it needs software on each monitored VM. Say so plainly to a
customer rather than letting them assume the AWS agentless story carries over.
The sensors' DATA path (sensor -> collector/vHub -> tool) is a separate leg and
is not yet exercised in this lab: no collector is deployed on Azure here.

## What this means for the automation

KVO's schema DOES have `AzurePresence` and `AzureConfiguration`, verified live:

    CloudConfigType:             VDS, K8s, NSX, CustomCloudConfig, Aws, Azure, OpenStack
    CloudPresenceImplementation: AwsPresence, AzurePresence, OpenStackPresence, ...

`_AzurePresenceInput` takes a service principal (`clientId`, `tenantId`,
`clientSecret`), `subscriptionId`, `location`, and the vnet by name plus its
resource group. `_AzureConfigurationInput` mirrors the AWS one: management,
ingress and egress interfaces given as subnet + NSG names, a `cloudlensIp` the
collectors register to, and availability zones carrying instance size and
min/max. The full dump is in `docs/schema/kvo_azure_schema.txt`.

So a KVO Azure Cloud Config CAN be built and a collector CAN be deployed. What
it cannot do on a non-onboarded subscription is source traffic agentlessly,
because there is no vTAP to feed it.

### Phases that port unchanged (KVO API only, no cloud specifics)

| Phase | Script | Ports as-is |
|---|---|---|
| KVO licensing | `scripts/kvo_license.py` | yes |
| Adopt vController + Cloud Config | `scripts/kvo_adopt_clms.py` | yes |
| Adopt the vPB | `scripts/vpb_kvo_adopt.py` | yes |
| vPB traffic path + policy | `scripts/vpb_wire_path.py` | yes |

These four are byte-identical to the AWS repo's copies and are kept in sync
deliberately. `vpb_wire_path.py` carries the egress fix: the egress tool must be
**REMOTE / reachableFrom DEVICE_CONFIG** with an IP on the egress port, or the
vPB inspects traffic and forwards none of it.

### Phase that does NOT port

`kvo_aws_mirror.py` is AWS-specific end to end: `AwsPresence`, VPC traffic mirror
targets/filters/sessions, and the AWS-side verification. Its Azure counterpart
depends on which mechanism above is available, so it is deliberately not
written yet rather than written against an API nobody can call.

## The one number that settles any deployment

Whatever the mechanism, the proof is the same: packets arriving at the tool.

    scripts/prove_traffic_aws.sh --help

On Azure the equivalent check is a tcpdump on the tool VM for the encapsulation
in use (VXLAN UDP/4789 for the vTAP demo topology, L2GRE proto 47 for the
sensor/collector topology). **Confirm which encapsulation your path uses before
setting the filter**: an SE playbook that said VXLAN on a GRE path captured
nothing and the demo looked broken while the tap worked perfectly.


## Marketplace vPB on Azure: adoption blocked inside the image (2026-08-17)

Phases 1-13 of the deploy run unattended. Phase 14 (adopt the vPB) reaches the
device, clears its EULA, and writes the KVO target, and then fails INSIDE the
Marketplace image (3.15.0-1):

    vpb-shim CrashLoopBackOff:  panic: Could not read mgmt IP address

The vpbsystem's interface inventory contains ONLY the data ports (eth1/eth2).
No management interface exists, `interface eth0|mgmt0|mgmt` are all rejected
(the CLI configures discovered interfaces, it cannot create them), and a
reboot does not re-register it. The shim is the component that announces to
KVO, so the device can never appear, regardless of network reachability
(verified open: TCP 443 vPB -> KVO over VNet peering).

The mgmt interface is written by first-boot provisioning. Our ARM template
passes no customData; whether the image requires it, and in what format, is
undocumented. The question is with Keysight, stated in full in the team memory
and commit 3eb1008.

Until that answers, the Marketplace-image path stops at phase 13 on Azure. The
GWLB architecture (chapter above) is unaffected: its vPBs are the Linux
installer build, not this image, and have carried real traffic.
