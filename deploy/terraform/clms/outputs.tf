output "clms_public_ip" {
  description = "Public IP address of the CLMS VM."
  value       = azurerm_public_ip.clms.ip_address
}

output "clms_ui_url" {
  description = "HTTPS URL for the CLMS web UI."
  value       = "https://${azurerm_public_ip.clms.ip_address}"
}

output "default_credentials" {
  description = "Default CLMS web UI credentials. Change immediately after first login."
  value       = "admin / Cl0udLens@dm!n (change on first login)"
}

output "next_step" {
  description = "What to do once CLMS is up."
  value       = "After CLMS initializes (about 15 minutes), open the UI, create a project, and copy the project key. Then return to the Ansible site to deploy sensors."
}

output "ssh_command" {
  description = "SSH command for OS-level access to the CLMS VM."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.clms.ip_address}"
}
