###############################################################################
# Stack outputs: surface child module outputs at the top level
###############################################################################

output "resource_group" {
  description = "Resource group holding the full stack."
  value       = local.rg_name
}

output "region" {
  description = "Azure region the stack is deployed in."
  value       = local.rg_location
}

###############################################################################
# CLMS
###############################################################################

output "clms_public_ip" {
  description = "Public IP of the CLMS VM."
  value       = module.clms.clms_public_ip
}

output "clms_ui_url" {
  description = "HTTPS URL for the CLMS web UI."
  value       = module.clms.clms_ui_url
}

output "clms_ssh_command" {
  description = "SSH command for OS-level access to the CLMS VM."
  value       = module.clms.ssh_command
}

output "clms_default_credentials" {
  description = "Default CLMS web UI credentials. Change immediately on first login."
  value       = module.clms.default_credentials
}

###############################################################################
# vPB (conditional)
###############################################################################

output "vpb_public_ip" {
  description = "Public IP of the vPB management NIC. Null when deploy_vpb is false."
  value       = var.deploy_vpb ? module.vpb[0].vpb_public_ip : null
}

output "vpb_ssh_command" {
  description = "SSH command for OS-level access on vPB. Null when deploy_vpb is false."
  value       = var.deploy_vpb ? module.vpb[0].vpb_ssh_command : null
}

output "vpb_cli_access" {
  description = "Two-hop SSH instructions to reach the vPB CLI."
  value       = var.deploy_vpb ? module.vpb[0].vpb_cli_access : null
}

output "vpb_private_ips" {
  description = "Private IPs of the three vPB NICs (management, ingress, egress)."
  value = var.deploy_vpb ? {
    mgmt    = module.vpb[0].mgmt_private_ip
    ingress = module.vpb[0].ingress_private_ip
    egress  = module.vpb[0].egress_private_ip
  } : null
}

###############################################################################
# Hand-off
###############################################################################

output "next_step" {
  description = "What to do once the stack is up."
  value       = "Open ${module.clms.clms_ui_url}, sign in with admin / Cl0udLens@dm!n, change the password, create a project, and copy the project key. Then run quickstart.sh to deploy sensors to your tagged VMs."
}
