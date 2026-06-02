output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "container_apps_subnet_id" {
  value = azurerm_subnet.container_apps.id
}


output "container_app_url" {
  value = "https://${azurerm_container_app.main.ingress[0].fqdn}"
}

output "acr_login_server" {
  description = "ACR login server — use this as the image prefix when pushing: <acr_login_server>/<image>:<tag>"
  value       = azurerm_container_registry.main.login_server
}

# ── Event Hub ─────────────────────────────────────────────────────────────────

output "eventhub_namespace_fqdn" {
  description = "FQDN of the Event Hub namespace — used in Cribl Stream Azure Event Hubs source configuration"
  value       = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
}

output "eventhub_name" {
  description = "Event Hub instance name — used in Cribl Stream Azure Event Hubs source configuration"
  value       = azurerm_eventhub.main.name
}

output "eventhub_consumer_group" {
  description = "Consumer group dedicated to Cribl Stream"
  value       = azurerm_eventhub_consumer_group.cribl.name
}

output "eventhub_cribl_connection_string" {
  description = "SAS connection string for Cribl Stream (Listen-only). Use this in the Cribl Azure Event Hubs source."
  value       = azurerm_eventhub_namespace_authorization_rule.cribl.primary_connection_string
  sensitive   = true
}

output "cribl_ui_url" {
  description = "Cribl Stream web UI URL."
  value       = "https://${azurerm_container_app.cribl.ingress[0].fqdn}"
}

output "cribl_admin_password" {
  description = "Cribl Stream admin password (username: admin)."
  value       = random_password.cribl_admin.result
  sensitive   = true
}

output "eventhub_private_endpoint_ip" {
  description = "Private IP of the Event Hub private endpoint — for on-premise DNS override if not using Azure Private DNS Zones."
  value       = azurerm_private_endpoint.eventhub.private_service_connection[0].private_ip_address
}

# ── Log Analytics ─────────────────────────────────────────────────────────────

output "log_analytics_workspace_id" {
  description = "Log Analytics Workspace ID — used to query ContainerAppHTTPLogs (ingress access logs). Null when enable_law = false."
  value       = one(module.law[*].workspace_customer_id)
}

output "ampls_id" {
  description = "AMPLS resource ID. Null when enable_law = false."
  value       = one(module.law[*].ampls_id)
}

output "law_security_mode" {
  description = "Active security mode for the Log Analytics Workspace. Null when enable_law = false."
  value       = one(module.law[*].security_mode)
}

output "workbook_id" {
  value       = azurerm_application_insights_workbook.main.id
  description = "Azure Portal: Monitor → Workbooks → Event Hub Monitoring"
}
