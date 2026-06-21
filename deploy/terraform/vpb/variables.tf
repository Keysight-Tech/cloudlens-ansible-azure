variable "subscription_id" {
  description = "Azure subscription ID where vPB will be deployed."
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID. Leave blank to use the default tenant from your Azure CLI login or environment."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region for the deployment."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Name of the resource group to create (or use, if use_existing_rg is true)."
  type        = string
  default     = "rg-cloudlens"
}

variable "use_existing_rg" {
  description = "Set true to deploy into an existing resource group instead of creating a new one."
  type        = bool
  default     = false
}

variable "vm_name" {
  description = "Name of the vPB VM. Also used as a prefix for NICs, NSG, public IP, and (when creating) VNet."
  type        = string
  default     = "vpb"
}

variable "admin_username" {
  description = "Admin username for OS-level access on the vPB VM."
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Admin password for the vPB VM. Must be 12+ chars with mixed case, digit, and symbol."
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "VM size for the vPB VM. Must support accelerated networking AND 3+ NICs (management, ingress, egress). Standard_D4s_v3 is excluded because it only supports 2 NICs."
  type        = string
  default     = "Standard_D8s_v3"

  validation {
    condition = contains([
      "Standard_D8s_v3",
      "Standard_D16s_v3"
    ], var.vm_size)
    error_message = "vm_size must be Standard_D8s_v3 or Standard_D16s_v3. These sizes support both accelerated networking and the 3 NICs required by vPB."
  }
}

variable "existing_vnet_name" {
  description = "Name of an existing VNet. Leave blank to create a new VNet with three subnets."
  type        = string
  default     = ""
}

variable "existing_vnet_resource_group" {
  description = "Resource group containing the existing VNet. Leave blank to use the deployment resource group."
  type        = string
  default     = ""
}

variable "existing_mgmt_subnet_name" {
  description = "Existing management subnet name. Required when existing_vnet_name is set."
  type        = string
  default     = ""
}

variable "existing_ingress_subnet_name" {
  description = "Existing ingress subnet name. Required when existing_vnet_name is set."
  type        = string
  default     = ""
}

variable "existing_egress_subnet_name" {
  description = "Existing egress subnet name. Required when existing_vnet_name is set."
  type        = string
  default     = ""
}

variable "address_space" {
  description = "VNet address space, used only when creating a new VNet."
  type        = list(string)
  default     = ["10.50.0.0/16"]
}

variable "mgmt_subnet_prefix" {
  description = "Management subnet prefix, used only when creating a new VNet."
  type        = list(string)
  default     = ["10.50.2.0/24"]
}

variable "ingress_subnet_prefix" {
  description = "Ingress (mirror traffic in) subnet prefix, used only when creating a new VNet."
  type        = list(string)
  default     = ["10.50.3.0/24"]
}

variable "egress_subnet_prefix" {
  description = "Egress (mirror traffic out) subnet prefix, used only when creating a new VNet."
  type        = list(string)
  default     = ["10.50.4.0/24"]
}

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default     = {}
}

variable "ingress_nic_count" {
  description = "Number of ingress NICs (receive mirror traffic). Default 1. Use 2-3 for fan-in from multiple sources. Total NICs (1 mgmt + ingress + egress) must fit the VM size NIC quota: D8s_v3=4 max, D16s_v3=8 max."
  type        = number
  default     = 1

  validation {
    condition     = var.ingress_nic_count >= 1 && var.ingress_nic_count <= 3
    error_message = "ingress_nic_count must be between 1 and 3."
  }
}

variable "egress_nic_count" {
  description = "Number of egress NICs (forward to monitoring tools). Default 1. Use 2-3 for fan-out to multiple tools. Total NICs (1 mgmt + ingress + egress) must fit the VM size NIC quota."
  type        = number
  default     = 1

  validation {
    condition     = var.egress_nic_count >= 1 && var.egress_nic_count <= 3
    error_message = "egress_nic_count must be between 1 and 3."
  }
}

variable "enable_auto_bootstrap" {
  description = "Run scripts/bootstrap-vpb.sh automatically after VM provisioning via Azure CustomScript extension. Installs system-wide KUBECONFIG and /usr/local/bin/vpb wrapper so SSH-in just works. Disable for air-gapped or custom-bootstrap scenarios."
  type        = bool
  default     = true
}

variable "bootstrap_script_url" {
  description = "URL to the bootstrap script invoked by the CustomScript extension. Override only if you fork the repo."
  type        = string
  default     = "https://raw.githubusercontent.com/Keysight-Tech/cloudlens-ansible-azure/main/scripts/bootstrap-vpb.sh"
}
