output "id" {
  description = "Resource ID of the Event Hubs namespace."
  value       = azurerm_eventhub_namespace.this.id
}

output "name" {
  description = "Composed Event Hubs namespace name."
  value       = local.name
}

output "fqdn" {
  description = "Data-plane hostname of the namespace, for AMQP and Kafka clients."
  value       = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
}

output "processing_units" {
  description = "Processing Units assigned to the namespace."
  value       = azurerm_eventhub_namespace.this.capacity
}

output "partition_budget" {
  description = "Partitions used against the namespace-wide Premium budget of 200 per Processing Unit."
  value = {
    used      = local.total_partitions
    available = local.partition_budget
  }
}

output "event_hub_ids" {
  description = "Map of event hub name to resource ID."
  value       = { for name, hub in azurerm_eventhub.this : name => hub.id }
}

output "event_hub_partition_ids" {
  description = "Map of event hub name to the list of its partition identifiers."
  value       = { for name, hub in azurerm_eventhub.this : name => hub.partition_ids }
}

output "consumer_group_ids" {
  description = "Map of '<hub>/<group>' to consumer group resource ID."
  value       = { for key, group in azurerm_eventhub_consumer_group.this : key => group.id }
}

output "identity_principal_id" {
  description = "Principal ID of the module's user-assigned identity. Null unless encryption is enabled — the identity exists only to reach the CMK."
  value       = var.encryption.enabled ? azurerm_user_assigned_identity.this[0].principal_id : null
}

output "private_endpoint_dns" {
  description = "FQDN + private IP pairs for external Private DNS registration, across all endpoints."
  value       = flatten([for pe in azurerm_private_endpoint.this : pe.custom_dns_configs])
}
