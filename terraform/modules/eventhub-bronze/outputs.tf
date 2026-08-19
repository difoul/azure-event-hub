output "namespace_id" {
  description = "Resource ID of the Event Hubs namespace."
  value       = azurerm_eventhub_namespace.this.id
}

output "namespace_name" {
  description = "Name of the Event Hubs namespace."
  value       = azurerm_eventhub_namespace.this.name
}

output "namespace_fqdn" {
  description = "Fully qualified hostname of the namespace, for AMQP/Kafka clients."
  value       = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
}

output "processing_units" {
  description = "Processing Units assigned to the namespace."
  value       = azurerm_eventhub_namespace.this.capacity
}

output "partition_budget" {
  description = "Partitions used versus the namespace-wide Premium budget (200 per PU)."
  value = {
    used      = local.total_partitions
    available = local.partition_budget
  }
}

output "event_hub_ids" {
  description = "Map of Event Hub name to resource ID."
  value       = { for name, hub in azurerm_eventhub.this : name => hub.id }
}

output "event_hub_partition_ids" {
  description = "Map of Event Hub name to the list of its partition identifiers."
  value       = { for name, hub in azurerm_eventhub.this : name => hub.partition_ids }
}

output "consumer_group_ids" {
  description = "Map of '<hub>/<group>' to consumer group resource ID."
  value       = { for key, group in azurerm_eventhub_consumer_group.this : key => group.id }
}

output "authorization_rule_ids" {
  description = "Map of namespace authorization rule name to resource ID. Use these in diagnostic settings rather than passing connection strings around."
  value       = { for name, rule in azurerm_eventhub_namespace_authorization_rule.this : name => rule.id }
}

output "authorization_rule_primary_connection_strings" {
  description = "Map of namespace authorization rule name to primary connection string."
  value       = { for name, rule in azurerm_eventhub_namespace_authorization_rule.this : name => rule.primary_connection_string }
  sensitive   = true
}

output "private_endpoint_id" {
  description = "Resource ID of the namespace private endpoint. Null when private_endpoint_subnet_id was not set."
  value       = local.create_private_endpoint ? azurerm_private_endpoint.this[0].id : null
}

output "private_endpoint_ip" {
  description = "Private IP address of the namespace private endpoint. Null when not created or not yet provisioned."
  value = try(
    local.create_private_endpoint
    ? azurerm_private_endpoint.this[0].private_service_connection[0].private_ip_address
    : null,
    null
  )
}

output "private_dns_zone_id" {
  description = "Resource ID of the private DNS zone created by the module. Null when an existing zone was supplied or no private endpoint was created."
  value       = local.create_dns_zone ? azurerm_private_dns_zone.this[0].id : null
}

output "identity_principal_id" {
  description = "Principal ID of the namespace system-assigned identity. Null when identity_type is not 'SystemAssigned'."
  value       = var.identity_type == "SystemAssigned" ? azurerm_eventhub_namespace.this.identity[0].principal_id : null
}
