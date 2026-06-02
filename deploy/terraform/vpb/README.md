# vPB Terraform Module

Terraform module that deploys a Keysight CloudLens Virtual Packet Broker (vPB) VM from the Azure Marketplace, mirroring the `deploy/vpb-marketplace.json` ARM template. Three NICs (management, ingress, egress), accelerated networking and IP forwarding enabled on the data plane NICs, NSG rules for SSH, HTTPS, and VXLAN (standard 4789 plus Keysight 10800-10801).

## Prerequisites

- Azure CLI logged in (`az login`) OR Service Principal environment variables set (`ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`)
- Terraform 1.5.0 or newer
- Marketplace terms accepted for the vPB image (see command at the bottom)

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set subscription_id and admin_password
terraform init && terraform apply
```

The vPB needs ~5 to 10 minutes after VM creation before SSH access works.

## Customization

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | (required) | Azure subscription ID |
| `tenant_id` | `""` | Azure tenant ID, blank uses default |
| `location` | `eastus2` | Azure region |
| `resource_group_name` | `rg-cloudlens` | Resource group name |
| `use_existing_rg` | `false` | Reuse existing RG instead of creating |
| `vm_name` | `vpb` | VM name and resource prefix |
| `admin_username` | `azureuser` | OS admin user |
| `admin_password` | (required) | OS admin password, 12+ chars, complex |
| `vm_size` | `Standard_D8s_v3` | VM size (D8/D16 s_v3; D4s_v3 only supports 2 NICs so it is excluded) |
| `existing_vnet_name` | `""` | Existing VNet (blank creates new) |
| `existing_vnet_resource_group` | `""` | RG of existing VNet |
| `existing_mgmt_subnet_name` | `""` | Existing management subnet |
| `existing_ingress_subnet_name` | `""` | Existing ingress subnet |
| `existing_egress_subnet_name` | `""` | Existing egress subnet |
| `address_space` | `["10.50.0.0/16"]` | New VNet address space |
| `mgmt_subnet_prefix` | `["10.50.2.0/24"]` | New management subnet prefix |
| `ingress_subnet_prefix` | `["10.50.3.0/24"]` | New ingress subnet prefix |
| `egress_subnet_prefix` | `["10.50.4.0/24"]` | New egress subnet prefix |
| `tags` | `{}` | Tags applied to every resource |

## Output

After `terraform apply` completes:

| Output | Meaning |
|---|---|
| `vpb_public_ip` | Public IP of the management NIC |
| `vpb_ssh_command` | OS-level SSH command |
| `vpb_cli_access` | Two-hop SSH into the vPB CLI |
| `next_step` | Configuration guidance |
| `mgmt_private_ip` | Management NIC private IP |
| `ingress_private_ip` | Ingress NIC private IP |
| `egress_private_ip` | Egress NIC private IP |

## Accept marketplace terms (one time per subscription)

```bash
az vm image terms accept \
  --publisher keysight-technologies-cloudlens \
  --offer keysight-cloudlens-virtual-packet-broker \
  --plan cloudlens-virtual-packet-broker-3-15-0_1
```
