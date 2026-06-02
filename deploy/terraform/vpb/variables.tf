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
  description = "VM size for the vPB VM. Must support accelerated networking on the data NICs."
  type        = string
  default     = "Standard_D4s_v3"

  validation {
    condition = contains([
      "Standard_D4s_v3",
      "Standard_D8s_v3",
      "Standard_D16s_v3"
    ], var.vm_size)
    error_message = "vm_size must be one of Standard_D4s_v3, Standard_D8s_v3, or Standard_D16s_v3. These sizes support accelerated networking required by the vPB data plane."
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
