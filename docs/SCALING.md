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

## Tuning Forks Manually

If you need to override:

```bash
# Cloud Shell / quickstart
ANSIBLE_FORKS=500 bash quickstart.sh

# Docker
docker run -e ANSIBLE_FORKS=500 ...

# Direct ansible-playbook
ansible-playbook deploy.yaml --forks 500 ...
```

## Sharded Deployment

When VM count exceeds 2,000, sharding auto-enables.

**What it does:**
1. Generates one flat inventory dump
2. Splits into chunks of N VMs (default 500)
3. Launches each chunk as an independent `ansible-playbook` run in parallel
4. Aggregates results at the end

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

To use:

```bash
cp deploy/tuned-ansible.cfg ansible.cfg
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

## Real-World Throughput

Measured against the smoke test environment (Azure eastus2):

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

Use sharding to spread connection attempts over time:
```bash
SHARD_DELAY=10 bash deploy/shard.sh ...    # 10 sec between shard launches
```

### Slow Docker image pulls saturating CLMS

CLMS registry can serve ~50 concurrent pulls comfortably. For thousands of VMs pulling at once:
- Pre-stage the image to an Azure Container Registry replica
- Set `image.repository` in customer_input.yaml to the closer ACR
