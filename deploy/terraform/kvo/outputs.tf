output "kvo_public_ip" {
  description = "Public IP address of the KVO VM."
  value       = azurerm_public_ip.kvo.ip_address
}

output "kvo_ui_url" {
  description = "HTTPS URL for the KVO web UI."
  value       = "https://${azurerm_public_ip.kvo.ip_address}"
}

output "default_credentials" {
  description = "Default KVO web UI credentials. Refer to Keysight KVO documentation."
  value       = "See Keysight KVO documentation"
}

output "next_step" {
  description = "What to do once KVO is up."
  value       = "After KVO initializes (about 15 minutes), open the UI and register your vController and vPB fleet for centralized orchestration."
}

output "ssh_command" {
  description = "SSH command for OS-level access to the KVO VM."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.kvo.ip_address}"
}
