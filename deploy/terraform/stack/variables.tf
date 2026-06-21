###############################################################################
# CloudLens Stack module: shared flat variable surface
#
# These variables are forwarded to the nested clms and (optionally) vpb
# modules. The goal is "one tfvars file, both VMs."
###############################################################################

variable "subscription_id" {
  description = "Azure subscription ID where the stack will be deployed."
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID. Leave blank to use the default tenant from your Azure CLI login or AZURE_TENANT_ID env var."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region for both CLMS and vPB."
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Resource group for the whole stack. Created if it does not exist."
  type        = string
  default     = "cloudlens-rg"
}

variable "use_existing_rg" {
  description = "Set true to deploy into an existing resource group instead of creating one."
  type        = bool
  default     = false
}

variable "admin_username" {
  description = "Admin username for OS-level access on both VMs."
  type        = string
  default     = "azureuser"
}

variable "admin_password" {
  description = "Admin password used for both CLMS and vPB. Must be 12+ chars, mixed case, digit, symbol."
  type        = string
  sensitive   = true
}

###############################################################################
# CLMS knobs
###############################################################################

variable "clms_vm_name" {
  description = "Name of the CLMS VM."
  type        = string
  default     = "clms"
}

variable "clms_vm_size" {
  description = "VM size for CLMS. Allowed: Standard_D2s_v5, Standard_D4s_v5, Standard_D8s_v5, Standard_D16s_v5."
  type        = string
  default     = "Standard_D4s_v5"
}

###############################################################################
# KVO knobs (Keysight Vision Orchestrator)
###############################################################################

variable "deploy_kvo" {
  description = "Toggle for KVO. Set true to deploy Keysight Vision Orchestrator alongside vController."
  type        = bool
  default     = false
}

variable "kvo_vm_name" {
  description = "Name of the KVO VM."
  type        = string
  default     = "kvo"
}

variable "kvo_vm_size" {
  description = "VM size for KVO. Allowed: Standard_D2s_v5, Standard_D4s_v5, Standard_D8s_v5, Standard_D16s_v5."
  type        = string
  default     = "Standard_D4s_v5"
}

###############################################################################
# vPB knobs
###############################################################################

variable "deploy_vpb" {
  description = "Toggle for vPB. Set false to deploy CLMS only."
  type        = bool
  default     = true
}

variable "vpb_vm_name" {
  description = "Name of the vPB VM."
  type        = string
  default     = "vpb"
}

variable "vpb_vm_size" {
  description = "VM size for vPB. Allowed: Standard_D8s_v3 (max 4 NICs) or Standard_D16s_v3 / D32s_v3 (max 8 NICs). Pick the larger sizes for multi-NIC deploys (>3 total)."
  type        = string
  default     = "Standard_D8s_v3"
}

variable "vpb_ingress_nic_count" {
  description = "Number of vPB ingress NICs (1-3). Default 1. Use 2-3 for fan-in from multiple mirror sources. Total NICs (1 + ingress + egress) must fit the VM size."
  type        = number
  default     = 1

  validation {
    condition     = var.vpb_ingress_nic_count >= 1 && var.vpb_ingress_nic_count <= 3
    error_message = "vpb_ingress_nic_count must be between 1 and 3."
  }
}

variable "vpb_egress_nic_count" {
  description = "Number of vPB egress NICs (1-3). Default 1. Use 2-3 for fan-out to multiple monitoring tools."
  type        = number
  default     = 1

  validation {
    condition     = var.vpb_egress_nic_count >= 1 && var.vpb_egress_nic_count <= 3
    error_message = "vpb_egress_nic_count must be between 1 and 3."
  }
}

variable "vpb_enable_auto_bootstrap" {
  description = "Run scripts/bootstrap-vpb.sh automatically after VM provisioning via Azure CustomScript extension. Installs KUBECONFIG system-wide and the sudo vpb wrapper so SSH-in just works. Disable for air-gapped scenarios."
  type        = bool
  default     = true
}

###############################################################################
# Networking
###############################################################################

variable "shared_vnet" {
  description = "If true, both VMs share a single VNet (with distinct subnets). If false, each VM gets its own VNet. Defaults to true for the simplest one-shot stack."
  type        = bool
  default     = true
}

variable "address_space" {
  description = "VNet CIDR. Used for the shared VNet or the CLMS VNet when shared_vnet is false."
  type        = list(string)
  default     = ["10.50.0.0/16"]
}

variable "clms_subnet_prefix" {
  description = "Subnet for vController (formerly CLMS)."
  type        = list(string)
  default     = ["10.50.1.0/24"]
}

variable "kvo_subnet_prefix" {
  description = "Subnet for KVO (used when deploy_kvo is true)."
  type        = list(string)
  default     = ["10.50.5.0/24"]
}

variable "vpb_mgmt_subnet_prefix" {
  description = "vPB management subnet (used when deploy_vpb is true)."
  type        = list(string)
  default     = ["10.50.2.0/24"]
}

variable "vpb_ingress_subnet_prefix" {
  description = "vPB ingress (mirror in) subnet."
  type        = list(string)
  default     = ["10.50.3.0/24"]
}

variable "vpb_egress_subnet_prefix" {
  description = "vPB egress (mirror out) subnet."
  type        = list(string)
  default     = ["10.50.4.0/24"]
}

variable "tags" {
  description = "Tags applied to every created resource."
  type        = map(string)
  default = {
    project = "cloudlens"
    stack   = "clms-plus-vpb"
  }
}
