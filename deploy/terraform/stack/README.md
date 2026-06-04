# CloudLens Stack Terraform Module

One tfvars, both VMs. This module wraps the `clms` and `vpb` modules
into a single deployable stack with a shared VNet and resource group.

## Quick start

```bash
cd deploy/terraform/stack
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set subscription_id and admin_password
terraform init
terraform apply
```

Outputs include the CLMS UI URL, the vPB management IP, and the
default credentials.

## CLMS only

Set `deploy_vpb = false` in `terraform.tfvars`. The vPB module and its
three subnets will be skipped.

## Existing VNet

The shared-VNet flow is the simplest, but if you already have a VNet
you want to use, set `shared_vnet = false`. Each child module will then
create its own VNet (CLMS gets a 1-subnet VNet, vPB gets a 3-subnet
VNet). For "bring your own VNet" with an existing VNet by name, edit
`main.tf` to pass `existing_vnet_name` through to the child modules.

## What gets created

When the defaults are used:

| Resource | Count | Notes |
| --- | --- | --- |
| Resource group | 1 | `cloudlens-rg` |
| Virtual network | 1 | `cloudlens-stack-vnet` 10.50.0.0/16 |
| Subnets | 4 | clms-subnet, vpb-mgmt, vpb-ingress, vpb-egress |
| Public IPs | 2 | one for CLMS, one for vPB management |
| NSGs | 2 | one per VM with the right rules baked in |
| NICs | 4 | 1 for CLMS, 3 for vPB (mgmt / ingress / egress) |
| VMs | 2 | CLMS D4s_v5, vPB D8s_v3 |

## Cleanup

```bash
terraform destroy
```

Or just delete the resource group:

```bash
az group delete -n cloudlens-rg --yes --no-wait
```
