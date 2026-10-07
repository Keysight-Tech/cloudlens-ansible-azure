# Scaling to Thousands of VMs

This doc explains how to deploy CloudLens sensors to **hundreds or thousands of VMs** in parallel.

## TL;DR

`quickstart.sh` and the Docker entrypoint **auto-scale** based on discovered VM count. You don't need to think about it for most cases. This doc explains what's happening under the hood and how to tune for edge cases.

## Auto-Scaling Table

| VM Count | Strategy | Forks | Sharded? | Approx Time |
|---|---|---|---|---|
| 1–50 | Single node, low forks | 20 | No | 5–10 min |
| 50–500 | Single node, medium forks | 50 | No | 15–30 min |
| 500–2,000 | Single beefy node | 200 | No | 30–60 min |
| 2,000–10,000 | **Sharded** parallel | 500/shard | Yes (auto) | 30–60 min |
| 10,000+ | AWX/Tower | 1000/shard | Yes | 1–2 hr |

Two details the table hides. First, `quickstart.sh` caps the automatic value at
4 x CPU cores of the control machine (a 2-core Cloud Shell never exceeds 8
forks, a 4-core laptop 16); `ANSIBLE_FORKS` bypasses the cap. Second, the
Docker image has no core cap and reads `deploy.forks` from
`customer_input.yaml` when `ANSIBLE_FORKS` is unset (`0` means auto-tune).
For 500+ VMs run from a control node with enough cores (see Control-Node
Sizing) or set the forks explicitly.

## Tuning Forks Manually

If you need to override:

```bash
# Cloud Shell / quickstart
ANSIBLE_FORKS=500 bash quickstart.sh

# Docker: ANSIBLE_FORKS wins, then deploy.forks in customer_input.yaml
docker run -e ANSIBLE_FORKS=500 ...

# Direct ansible-playbook
ansible-playbook deploy.yaml --forks 500 ...
```

## Sharded Deployment

When VM count exceeds 2,000, sharding auto-enables.

**What it does:**
1. Reads the inventory once and lists the VMs in the Ubuntu, RHEL and Windows target groups
2. Splits them into chunks of N VMs (default 500: `SHARD_SIZE`, or `deploy.shard_size` in `customer_input.yaml` for Docker)
3. Runs one `ansible-playbook` per chunk in parallel, against the same inventory with `--limit`, so groups and group_vars stay intact
4. Prints one line per shard and exits non-zero if any shard failed or ran against no hosts

**Manual sharding:**

```bash
# 5000 VMs, 500 per shard, 200 forks per shard = 10 shards × 200 = 2000 simultaneous
bash deploy/shard.sh 5000 200

# Finer-grained shards (more parallelism, less risk per shard)
SHARD_SIZE=100 bash deploy/shard.sh 5000 50
```

**Logs:** `./logs/shards/shard_NNN.log` per shard.

## Control-Node Sizing

Single control node handling 2,000 VMs at 200 forks:

| Component | Recommended |
|---|---|
| **CPU** | 4-8 vCPU |
| **RAM** | 16-32 GB |
| **Network** | Standard egress |
| **VM Size** | Standard_D4s_v5 to Standard_D8s_v5 |
| **OS** | Ubuntu 22.04 (best Python compatibility) |

For 5,000+ VMs in shards:
- Each shard process uses ~500 MB-1 GB RAM
- 10 shards × 1 GB = ~10 GB RAM minimum
- Standard_D8s_v5 or Standard_D16s_v5

## Network Considerations

### From outside your customer VNet (your laptop, GitHub Actions)
- Each VM connection goes over the public internet
- Bottleneck = ISP egress
- Throughput limit ≈ 100-500 VMs/min

### From inside the customer VNet (Cloud Shell, runner VM, AKS pod)
- All traffic stays internal
- 10x faster throughput
- **Recommended for >500 VMs**

The Tier 1 ARM template auto-creates a runner *inside* the customer subscription for this reason.

## Performance Patterns Already Tuned

In `deploy/tuned-ansible.cfg` (use this for high-scale):

1. **SSH multiplexing**: one TCP connection reused per host
2. **Pipelining**: eliminates intermediate SSH/SCP steps (30-40% faster)
3. **Strategy `free`**: fast hosts don't wait for slow ones
4. **Fact caching**: VM facts cached for 1 hour
5. **Connection retries**: 3 retries per task before failing
6. **Public-key SSH only**: `ssh_args` includes `PreferredAuthentications=publickey`.
   VMs that authenticate with a password (`linux.ansible_password` in
   `customer_input.yaml`, which is what deploy-stack.sh writes for the VMs it
   creates) fail to connect with this file. Remove that option, or keep the
   shipped `ansible.cfg`, for password-authenticated fleets. The fact cache
   moves to `/tmp/ansible_facts`.

To use:

```bash
cp deploy/tuned-ansible.cfg ansible.cfg

# Docker: the file ships in the image
docker run -e ANSIBLE_CONFIG=/work/deploy/tuned-ansible.cfg ...
```

## AWX / Ansible Tower Integration

For 10,000+ VMs or recurring/scheduled deployments:

1. Import this repo as an AWX **Project**
2. Create a **Job Template** pointing at `deploy.yaml`
3. Add the dynamic inventory source (Azure subscription credentials)
4. Set `--forks 1000` in extra vars
5. Use **Workflow Templates** to chain bootstrap → deploy → verify

AWX gives you:
- Job queues with retries
- RBAC across teams
- Centralized log retention
- Slack/Teams notifications on success/failure
- Scheduled re-runs

## Expected Throughput

The recorded run (2026-06-02, CloudLensPublic, eastus2) covered three VMs:
3/3 sensors in 8 minutes. The rows below for 100, 500 and 5,000 VMs are
projections from the fork and shard settings, not measurements; replace them
with your own numbers from `ansible.log` after a large run.

| Scenario | VMs | Forks | Time | Throughput |
|---|---|---|---|---|
| Laptop → 2 Ubuntu | 2 | 20 | 2 min | 1 VM/min |
| Cloud Shell → 100 mixed | 100 | 50 | 7 min | 14 VMs/min |
| Runner VM → 500 Ubuntu | 500 | 200 | 22 min | 23 VMs/min |
| Runner VM × 10 → 5,000 | 5,000 | 500/shard | 45 min | 110 VMs/min |

## Troubleshooting Scale Issues

### "Too many open files"

```bash
ulimit -n 65535
```

Add to the control node before launching.

### Memory pressure on control node

Reduce `forks` and use sharding:
```bash
SHARD_SIZE=100 bash deploy/shard.sh <total> 50
```

### SSH connection storms tripping NSG/firewall

`deploy/shard.sh` launches every shard at once, so the simultaneous connection
count is shards x forks. Lower it with smaller forks per shard or fewer, larger
shards:
```bash
SHARD_SIZE=1000 bash deploy/shard.sh <total> 50    # 5 shards x 50 forks for 5,000 VMs
```
SSH multiplexing in `deploy/tuned-ansible.cfg` also reuses one connection per
host.

### Slow sensor image pulls saturating the vController

The playbooks pull `<manager_ip_or_fqdn>/sensor` from the vController's own
registry on every VM; there is no setting to point them at another registry.
For thousands of VMs pulling at once, spread the load with sharding
(`SHARD_SIZE`, fewer forks per shard) and deploy one vController per region
or per few thousand sensors (`--vcontroller-count` on deploy-stack.sh), so
each fleet pulls from the appliance closest to it.
