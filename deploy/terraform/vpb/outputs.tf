output "vpb_public_ip" {
  description = "Public IP address of the vPB management NIC."
  value       = azurerm_public_ip.vpb_mgmt.ip_address
}

output "vpb_ssh_command" {
  description = "SSH command for OS-level access to the vPB management NIC."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.vpb_mgmt.ip_address}"
}

output "vpb_cli_access" {
  description = "Two-hop SSH instructions to reach the vPB CLI (default password: ixia)."
  value       = "Two-hop SSH: ssh ${var.admin_username}@${azurerm_public_ip.vpb_mgmt.ip_address}, then: ssh admin@localhost -p 2222 (password: ixia)"
}

output "next_step" {
  description = "What to do once vPB is up."
  value       = "Use the vPB CLI to configure ingress filters and match rules. See the Keysight CloudLens vPB documentation."
}

output "mgmt_private_ip" {
  description = "Private IP of the management NIC."
  value       = azurerm_network_interface.mgmt.private_ip_address
}

output "ingress_private_ip" {
  description = "Private IP of the ingress (mirror in) NIC."
  value       = azurerm_network_interface.ingress.private_ip_address
}

output "egress_private_ip" {
  description = "Private IP of the egress (mirror out) NIC."
  value       = azurerm_network_interface.egress.private_ip_address
}
