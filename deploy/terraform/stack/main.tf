############################################
# CloudLens Stack: vController + KVO + vPB from one tfvars
# (vController is the new name for what used to be called CLMS)
#
# Design:
#   - Stack creates (or reuses) the resource group.
#   - When shared_vnet = true, stack also creates the VNet and all
#     subnets (clms, kvo, vpb-mgmt, vpb-ingress, vpb-egress), then
#     points the child modules at the existing VNet.
#   - When shared_vnet = false, each child module creates its own VNet.
#   - deploy_kvo = false skips the KVO module entirely.
#   - deploy_vpb = false skips the vPB module entirely.
############################################

locals {
  # The stack manages the RG when use_existing_rg = false.
  manage_rg = !var.use_existing_rg

  # Default subnet names match what the child modules use internally.
  clms_subnet_name        = "clms-subnet"
  kvo_subnet_name         = "kvo-subnet"
  vpb_mgmt_subnet_name    = "vpb-mgmt"
  vpb_ingress_subnet_name = "vpb-ingress"
  vpb_egress_subnet_name  = "vpb-egress"

  shared_vnet_name = "cloudlens-stack-vnet"
}

# ---------------------------------------------------------------------
# Resource group (stack-owned)
# ---------------------------------------------------------------------
resource "azurerm_resource_group" "stack" {
  count = local.manage_rg ? 1 : 0

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "stack_existing" {
  count = local.manage_rg ? 0 : 1
  name  = var.resource_group_name
}

locals {
  rg_name     = local.manage_rg ? azurerm_resource_group.stack[0].name : data.azurerm_resource_group.stack_existing[0].name
  rg_location = local.manage_rg ? azurerm_resource_group.stack[0].location : data.azurerm_resource_group.stack_existing[0].location
}

# ---------------------------------------------------------------------
# Shared VNet + subnets (only when shared_vnet = true)
# ---------------------------------------------------------------------
resource "azurerm_virtual_network" "shared" {
  count = var.shared_vnet ? 1 : 0

  name                = local.shared_vnet_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "clms" {
  count = var.shared_vnet ? 1 : 0

  name                 = local.clms_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.shared[0].name
  address_prefixes     = var.clms_subnet_prefix
}

resource "azurerm_subnet" "kvo" {
  count = var.shared_vnet && var.deploy_kvo ? 1 : 0

  name                 = local.kvo_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.shared[0].name
  address_prefixes     = var.kvo_subnet_prefix
}

resource "azurerm_subnet" "vpb_mgmt" {
  count = var.shared_vnet && var.deploy_vpb ? 1 : 0

  name                 = local.vpb_mgmt_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.shared[0].name
  address_prefixes     = var.vpb_mgmt_subnet_prefix
}

resource "azurerm_subnet" "vpb_ingress" {
  count = var.shared_vnet && var.deploy_vpb ? 1 : 0

  name                 = local.vpb_ingress_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.shared[0].name
  address_prefixes     = var.vpb_ingress_subnet_prefix
}

resource "azurerm_subnet" "vpb_egress" {
  count = var.shared_vnet && var.deploy_vpb ? 1 : 0

  name                 = local.vpb_egress_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.shared[0].name
  address_prefixes     = var.vpb_egress_subnet_prefix
}

# ---------------------------------------------------------------------
# CLMS module
# ---------------------------------------------------------------------
module "clms" {
  source = "../clms"

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  location            = var.location
  resource_group_name = local.rg_name
  use_existing_rg     = true # stack owns the RG

  vm_name        = var.clms_vm_name
  admin_username = var.admin_username
  admin_password = var.admin_password
  vm_size        = var.clms_vm_size

  # When shared, point at the VNet + subnet we created above.
  existing_vnet_name           = var.shared_vnet ? azurerm_virtual_network.shared[0].name : ""
  existing_vnet_resource_group = var.shared_vnet ? local.rg_name : ""
  existing_subnet_name         = var.shared_vnet ? azurerm_subnet.clms[0].name : ""

  address_space = var.address_space
  subnet_prefix = var.clms_subnet_prefix

  tags = var.tags
}

# ---------------------------------------------------------------------
# KVO module (optional)
# ---------------------------------------------------------------------
module "kvo" {
  count  = var.deploy_kvo ? 1 : 0
  source = "../kvo"

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  location            = var.location
  resource_group_name = local.rg_name
  use_existing_rg     = true # stack owns the RG

  vm_name        = var.kvo_vm_name
  admin_username = var.admin_username
  admin_password = var.admin_password
  vm_size        = var.kvo_vm_size

  existing_vnet_name           = var.shared_vnet ? azurerm_virtual_network.shared[0].name : ""
  existing_vnet_resource_group = var.shared_vnet ? local.rg_name : ""
  existing_subnet_name         = var.shared_vnet ? azurerm_subnet.kvo[0].name : ""

  address_space = var.address_space
  subnet_prefix = var.kvo_subnet_prefix

  tags = var.tags
}

# ---------------------------------------------------------------------
# vPB module (optional)
# ---------------------------------------------------------------------
module "vpb" {
  count  = var.deploy_vpb ? 1 : 0
  source = "../vpb"

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  location            = var.location
  resource_group_name = local.rg_name
  use_existing_rg     = true # stack owns the RG

  vm_name        = var.vpb_vm_name
  admin_username = var.admin_username
  admin_password = var.admin_password
  vm_size        = var.vpb_vm_size

  existing_vnet_name           = var.shared_vnet ? azurerm_virtual_network.shared[0].name : ""
  existing_vnet_resource_group = var.shared_vnet ? local.rg_name : ""
  existing_mgmt_subnet_name    = var.shared_vnet ? azurerm_subnet.vpb_mgmt[0].name : ""
  existing_ingress_subnet_name = var.shared_vnet ? azurerm_subnet.vpb_ingress[0].name : ""
  existing_egress_subnet_name  = var.shared_vnet ? azurerm_subnet.vpb_egress[0].name : ""

  address_space         = var.address_space
  mgmt_subnet_prefix    = var.vpb_mgmt_subnet_prefix
  ingress_subnet_prefix = var.vpb_ingress_subnet_prefix
  egress_subnet_prefix  = var.vpb_egress_subnet_prefix

  tags = var.tags
}
