variable "subscription_id" {
  description = "Azure subscription ID where KVO will be deployed."
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
  description = "Name of the KVO VM. Also used as a prefix for NIC, NSG, public IP, and (when creating) VNet."
  type        = string
  default     = "kvo"
}

variable "admin_username" {
  description = "Admin username for OS-level access on the KVO VM."
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Admin password for the KVO VM. Must be 12+ chars with mixed case, digit, and symbol."
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "VM size for the KVO VM. D4s_v5 (4 vCPU, 16 GB) suits most deployments."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition = contains([
      "Standard_D2s_v5",
      "Standard_D4s_v5",
      "Standard_D8s_v5",
      "Standard_D16s_v5"
    ], var.vm_size)
    error_message = "vm_size must be one of Standard_D2s_v5, Standard_D4s_v5, Standard_D8s_v5, or Standard_D16s_v5."
  }
}

variable "existing_vnet_name" {
  description = "Name of an existing VNet. Leave blank to create a new VNet."
  type        = string
  default     = ""
}

variable "existing_vnet_resource_group" {
  description = "Resource group containing the existing VNet. Leave blank to use the deployment resource group."
  type        = string
  default     = ""
}

variable "existing_subnet_name" {
  description = "Name of an existing subnet to attach the KVO NIC to. Leave blank to create a new subnet."
  type        = string
  default     = ""
}

variable "address_space" {
  description = "VNet address space, used only when creating a new VNet."
  type        = list(string)
  default     = ["10.60.0.0/16"]
}

variable "subnet_prefix" {
  description = "Subnet address prefix, used only when creating a new VNet/subnet."
  type        = list(string)
  default     = ["10.60.1.0/24"]
}

variable "tags" {
  description = "Tags applied to all created resources."
  type        = map(string)
  default     = {}
}
