############################################
# Keysight Vision Orchestrator (KVO) Marketplace deployment
#
# Mirrors deploy/kvo-marketplace.json: single Linux VM from
# Azure Marketplace with VNet, public IP, NSG, and NIC.
############################################

locals {
  create_new_vnet       = var.existing_vnet_name == ""
  effective_vnet_name   = local.create_new_vnet ? "${var.vm_name}-vnet" : var.existing_vnet_name
  effective_vnet_rg     = var.existing_vnet_resource_group != "" ? var.existing_vnet_resource_group : var.resource_group_name
  effective_subnet_name = var.existing_subnet_name != "" ? var.existing_subnet_name : "kvo-subnet"

  pip_name = "${var.vm_name}-pip"
  nsg_name = "${var.vm_name}-nsg"
  nic_name = "${var.vm_name}-nic"
}

# Resource group: create or reference
resource "azurerm_resource_group" "this" {
  count = var.use_existing_rg ? 0 : 1

  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.use_existing_rg ? 1 : 0
  name  = var.resource_group_name
}

locals {
  rg_name     = var.use_existing_rg ? data.azurerm_resource_group.existing[0].name : azurerm_resource_group.this[0].name
  rg_location = var.use_existing_rg ? data.azurerm_resource_group.existing[0].location : azurerm_resource_group.this[0].location
}

# Public IP
resource "azurerm_public_ip" "kvo" {
  name                = local.pip_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.vm_name}-${substr(md5(local.rg_name), 0, 8)}"
  tags                = var.tags
}

# Network Security Group
resource "azurerm_network_security_group" "kvo" {
  name                = local.nsg_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = var.tags

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# VNet (create only when no existing VNet supplied)
resource "azurerm_virtual_network" "kvo" {
  count = local.create_new_vnet ? 1 : 0

  name                = local.effective_vnet_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "kvo" {
  count = local.create_new_vnet ? 1 : 0

  name                 = local.effective_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.kvo[0].name
  address_prefixes     = var.subnet_prefix
}

# Existing subnet lookup
data "azurerm_subnet" "existing" {
  count = local.create_new_vnet ? 0 : 1

  name                 = local.effective_subnet_name
  virtual_network_name = local.effective_vnet_name
  resource_group_name  = local.effective_vnet_rg
}

locals {
  subnet_id = local.create_new_vnet ? azurerm_subnet.kvo[0].id : data.azurerm_subnet.existing[0].id
}

# NIC
resource "azurerm_network_interface" "kvo" {
  name                = local.nic_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.kvo.id
  }
}

resource "azurerm_network_interface_security_group_association" "kvo" {
  network_interface_id      = azurerm_network_interface.kvo.id
  network_security_group_id = azurerm_network_security_group.kvo.id
}

# KVO VM from Azure Marketplace
resource "azurerm_linux_virtual_machine" "kvo" {
  name                            = var.vm_name
  resource_group_name             = local.rg_name
  location                        = local.rg_location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  computer_name                   = var.vm_name
  tags                            = var.tags

  network_interface_ids = [
    azurerm_network_interface.kvo.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "keysight-technologies-kvop"
    offer     = "keysight-vision-orchestrator"
    sku       = "keysight_vision_orchestrator_3-0-0_55"
    version   = "latest"
  }

  plan {
    name      = "keysight_vision_orchestrator_3-0-0_55"
    publisher = "keysight-technologies-kvop"
    product   = "keysight-vision-orchestrator"
  }

  boot_diagnostics {}

  depends_on = [
    azurerm_network_interface_security_group_association.kvo,
  ]
}
