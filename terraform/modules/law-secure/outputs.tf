output "workspace_id" {
  description = "Resource ID of the Log Analytics Workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "workspace_name" {
  description = "Name of the Log Analytics Workspace."
  value       = azurerm_log_analytics_workspace.this.name
}

output "workspace_customer_id" {
  description = "Workspace ID (customer ID) used in agent configuration."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "primary_shared_key" {
  description = "Primary shared key of the workspace. Prefer Managed Identity over this key."
  value       = azurerm_log_analytics_workspace.this.primary_shared_key
  sensitive   = true
}

output "ampls_id" {
  description = "Resource ID of the Azure Monitor Private Link Scope. Null when security_mode is 'open'."
  value       = local.create_private_link ? azurerm_monitor_private_link_scope.this[0].id : null
}

output "ampls_name" {
  description = "Name of the Azure Monitor Private Link Scope. Null when security_mode is 'open'."
  value       = local.create_private_link ? azurerm_monitor_private_link_scope.this[0].name : null
}

output "private_endpoint_id" {
  description = "Resource ID of the AMPLS private endpoint. Null when security_mode is 'open'."
  value       = local.create_private_link ? azurerm_private_endpoint.ampls[0].id : null
}

output "private_endpoint_ip" {
  description = "Private IP address of the AMPLS private endpoint. Null when not yet provisioned or security_mode is 'open'."
  value = try(
    local.create_private_link
    ? azurerm_private_endpoint.ampls[0].private_service_connection[0].private_ip_address
    : null,
    null
  )
}

output "dns_zone_ids" {
  description = "Map of private DNS zone resource IDs created by the module."
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.id }
}

output "security_mode" {
  description = "The active security mode for this workspace."
  value       = var.security_mode
}
