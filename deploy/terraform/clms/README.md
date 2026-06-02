# CLMS Terraform Module

Terraform module that deploys a single Keysight CloudLens Manager (CLMS) VM from the Azure Marketplace, mirroring the `deploy/clms-marketplace.json` ARM template. Same marketplace image, same outputs, but IaC-friendly for pipelines, version control, and repeatable deployments.

## Prerequisites

- Azure CLI logged in (`az login`) OR Service Principal environment variables set (`ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`)
- Terraform 1.5.0 or newer
- Marketplace terms accepted for the CLMS image (see command at the bottom)

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set subscription_id and admin_password
terraform init && terraform apply
```

After ~15 minutes the CLMS UI is reachable at the `clms_ui_url` output.

## Customization

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | (required) | Azure subscription ID |
| `tenant_id` | `""` | Azure tenant ID, blank uses default |
| `location` | `eastus2` | Azure region |
| `resource_group_name` | `rg-cloudlens` | Resource group name |
| `use_existing_rg` | `false` | Reuse existing RG instead of creating |
| `vm_name` | `clms` | VM name and resource prefix |
| `admin_username` | `azureuser` | OS admin user |
| `admin_password` | (required) | OS admin password, 12+ chars, complex |
| `vm_size` | `Standard_D4s_v5` | VM size (D2/D4/D8/D16 s_v5 allowed) |
| `existing_vnet_name` | `""` | Existing VNet to attach to (blank creates new) |
| `existing_vnet_resource_group` | `""` | RG of existing VNet |
| `existing_subnet_name` | `""` | Existing subnet to attach the NIC to |
| `address_space` | `["10.50.0.0/16"]` | New VNet address space |
| `subnet_prefix` | `["10.50.1.0/24"]` | New subnet prefix |
| `tags` | `{}` | Tags applied to every resource |

## Output

After `terraform apply` completes:

| Output | Meaning |
|---|---|
| `clms_public_ip` | Public IP of the CLMS VM |
| `clms_ui_url` | HTTPS URL for the CLMS web UI |
| `default_credentials` | `admin / Cl0udLens@dm!n` (change on first login) |
| `next_step` | What to do once CLMS is up (create project, copy key) |
| `ssh_command` | SSH command for OS-level access |

## Accept marketplace terms (one time per subscription)

```bash
az vm image terms accept \
  --publisher keysight-technologies-cloudlens \
  --offer keysight-cloudlens-manager \
  --plan clms-6-13-0_76
```
