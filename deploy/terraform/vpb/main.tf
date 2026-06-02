############################################
# Keysight CloudLens Virtual Packet Broker (vPB) Marketplace deployment
#
# Mirrors deploy/vpb-marketplace.json: single Linux VM from Azure
# Marketplace with three NICs (management, ingress, egress) and
# accelerated networking + IP forwarding on the data plane NICs.
############################################

locals {
  create_new_vnet     = var.existing_vnet_name == ""
  effective_vnet_name = local.create_new_vnet ? "${var.vm_name}-vnet" : var.existing_vnet_name
  effective_vnet_rg   = var.existing_vnet_resource_group != "" ? var.existing_vnet_resource_group : var.resource_group_name

  mgmt_subnet_name    = local.create_new_vnet ? "vpb-mgmt" : var.existing_mgmt_subnet_name
  ingress_subnet_name = local.create_new_vnet ? "vpb-ingress" : var.existing_ingress_subnet_name
  egress_subnet_name  = local.create_new_vnet ? "vpb-egress" : var.existing_egress_subnet_name

  pip_name         = "${var.vm_name}-mgmt-pip"
  nsg_name         = "${var.vm_name}-mgmt-nsg"
  mgmt_nic_name    = "${var.vm_name}-mgmt-nic"
  ingress_nic_name = "${var.vm_name}-ingress-nic"
  egress_nic_name  = "${var.vm_name}-egress-nic"
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

# Management public IP
resource "azurerm_public_ip" "vpb_mgmt" {
  name                = local.pip_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.vm_name}-${substr(md5(local.rg_name), 0, 8)}"
  tags                = var.tags
}

# Management NSG: SSH, HTTPS, VXLAN (standard 4789 + Keysight 10800-10801)
resource "azurerm_network_security_group" "vpb_mgmt" {
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

  security_rule {
    name                       = "AllowVxlanStandard"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "4789"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowVxlanKeysight"
    priority                   = 210
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "10800-10801"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# VNet + three subnets (create only when no existing VNet supplied)
resource "azurerm_virtual_network" "vpb" {
  count = local.create_new_vnet ? 1 : 0

  name                = local.effective_vnet_name
  resource_group_name = local.rg_name
  location            = local.rg_location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "mgmt" {
  count = local.create_new_vnet ? 1 : 0

  name                 = local.mgmt_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vpb[0].name
  address_prefixes     = var.mgmt_subnet_prefix
}

resource "azurerm_subnet" "ingress" {
  count = local.create_new_vnet ? 1 : 0

  name                 = local.ingress_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vpb[0].name
  address_prefixes     = var.ingress_subnet_prefix
}

resource "azurerm_subnet" "egress" {
  count = local.create_new_vnet ? 1 : 0

  name                 = local.egress_subnet_name
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.vpb[0].name
  address_prefixes     = var.egress_subnet_prefix
}

# Existing subnet lookups
data "azurerm_subnet" "mgmt_existing" {
  count = local.create_new_vnet ? 0 : 1

  name                 = local.mgmt_subnet_name
  virtual_network_name = local.effective_vnet_name
  resource_group_name  = local.effective_vnet_rg
}

data "azurerm_subnet" "ingress_existing" {
  count = local.create_new_vnet ? 0 : 1

  name                 = local.ingress_subnet_name
  virtual_network_name = local.effective_vnet_name
  resource_group_name  = local.effective_vnet_rg
}

data "azurerm_subnet" "egress_existing" {
  count = local.create_new_vnet ? 0 : 1

  name                 = local.egress_subnet_name
  virtual_network_name = local.effective_vnet_name
  resource_group_name  = local.effective_vnet_rg
}

locals {
  mgmt_subnet_id    = local.create_new_vnet ? azurerm_subnet.mgmt[0].id : data.azurerm_subnet.mgmt_existing[0].id
  ingress_subnet_id = local.create_new_vnet ? azurerm_subnet.ingress[0].id : data.azurerm_subnet.ingress_existing[0].id
  egress_subnet_id  = local.create_new_vnet ? azurerm_subnet.egress[0].id : data.azurerm_subnet.egress_existing[0].id
}

# Management NIC: public IP, NSG, regular networking
resource "azurerm_network_interface" "mgmt" {
  name                           = local.mgmt_nic_name
  resource_group_name            = local.rg_name
  location                       = local.rg_location
  accelerated_networking_enabled = false
  ip_forwarding_enabled          = false
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.mgmt_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vpb_mgmt.id
  }
}

resource "azurerm_network_interface_security_group_association" "mgmt" {
  network_interface_id      = azurerm_network_interface.mgmt.id
  network_security_group_id = azurerm_network_security_group.vpb_mgmt.id
}

# Ingress NIC: accelerated networking + IP forwarding
resource "azurerm_network_interface" "ingress" {
  name                           = local.ingress_nic_name
  resource_group_name            = local.rg_name
  location                       = local.rg_location
  accelerated_networking_enabled = true
  ip_forwarding_enabled          = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.ingress_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# Egress NIC: accelerated networking + IP forwarding
resource "azurerm_network_interface" "egress" {
  name                           = local.egress_nic_name
  resource_group_name            = local.rg_name
  location                       = local.rg_location
  accelerated_networking_enabled = true
  ip_forwarding_enabled          = true
  tags                           = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.egress_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

# vPB VM from Azure Marketplace
resource "azurerm_linux_virtual_machine" "vpb" {
  name                            = var.vm_name
  resource_group_name             = local.rg_name
  location                        = local.rg_location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  computer_name                   = var.vm_name
  tags                            = var.tags

  # Order matters: management NIC first (primary), then ingress, then egress.
  network_interface_ids = [
    azurerm_network_interface.mgmt.id,
    azurerm_network_interface.ingress.id,
    azurerm_network_interface.egress.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "keysight-technologies-cloudlens"
    offer     = "keysight-cloudlens-virtual-packet-broker"
    sku       = "cloudlens-virtual-packet-broker-3-15-0_1"
    version   = "latest"
  }

  plan {
    name      = "cloudlens-virtual-packet-broker-3-15-0_1"
    publisher = "keysight-technologies-cloudlens"
    product   = "keysight-cloudlens-virtual-packet-broker"
  }

  boot_diagnostics {}

  depends_on = [
    azurerm_network_interface_security_group_association.mgmt,
  ]
}
