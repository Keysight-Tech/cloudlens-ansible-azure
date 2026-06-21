output "vpb_public_ip" {
  description = "Public IP address of the vPB management NIC."
  value       = azurerm_public_ip.vpb_mgmt.ip_address
}

output "vpb_ssh_command" {
  description = "SSH command for OS-level access (port 9022, KCOS layout)."
  value       = "ssh -p 9022 ${var.admin_username}@${azurerm_public_ip.vpb_mgmt.ip_address}"
}

output "vpb_cli_access" {
  description = "vPB CLI access after auto-bootstrap completes."
  value       = "After deploy completes, SSH in and run: sudo vpb. The CustomScript extension auto-installed kubeconfig + the /usr/local/bin/vpb wrapper. Bootstrap log: /var/log/cloudlens-bootstrap.log on the VM."
}

output "next_step" {
  description = "What to do once vPB is up."
  value       = "vPB is ready. Bootstrap ran automatically via VM extension during deploy. SSH in: ssh -p 9022 ${var.admin_username}@${azurerm_public_ip.vpb_mgmt.ip_address}. Then: sudo kubectl get pods -A and sudo vpb. Configure ingress filters via sudo vpb. See docs/OPERATIONS.md."
}

output "mgmt_private_ip" {
  description = "Private IP of the management NIC."
  value       = azurerm_network_interface.mgmt.private_ip_address
}

output "ingress_private_ips" {
  description = "Private IPs of every ingress NIC (one per count.index)."
  value       = [for nic in azurerm_network_interface.ingress : nic.private_ip_address]
}

output "egress_private_ips" {
  description = "Private IPs of every egress NIC (one per count.index)."
  value       = [for nic in azurerm_network_interface.egress : nic.private_ip_address]
}

output "ingress_nic_names" {
  description = "Names of every ingress NIC."
  value       = [for nic in azurerm_network_interface.ingress : nic.name]
}

output "egress_nic_names" {
  description = "Names of every egress NIC."
  value       = [for nic in azurerm_network_interface.egress : nic.name]
}
