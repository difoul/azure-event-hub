# -----------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------
locals {
  # Premium budgets are namespace-wide and scale with PUs
  total_partitions = sum(concat([0], [for hub in var.event_hubs : hub.partition_count]))
  partition_budget = var.processing_units * 200
  event_hub_budget = var.processing_units * 100

  create_private_endpoint = var.private_endpoint_subnet_id != null
  create_dns_zone         = local.create_private_endpoint && var.private_dns_zone_ids == null

  private_endpoint_name = coalesce(var.private_endpoint_name, "pe-${var.namespace_name}")

  # Flatten hub -> consumer groups into a single map for for_each.
  # Key is "<hub>/<group>" so adding a group never re-addresses the others.
  consumer_groups = {
    for pair in flatten([
      for hub_name, hub in var.event_hubs : [
        for group in hub.consumer_groups : {
          key           = "${hub_name}/${group}"
          eventhub_name = hub_name
          name          = group
        }
      ]
    ]) : pair.key => pair
  }
}

# -----------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------
resource "azurerm_eventhub_namespace" "this" {
  name                = var.namespace_name
  resource_group_name = var.resource_group_name
  location            = var.location

  sku      = "Premium"
  capacity = var.processing_units

  # Auto-inflate is a Standard-tier mechanism — Premium scales by setting PUs.
  auto_inflate_enabled = false

  minimum_tls_version           = var.minimum_tls_version
  local_authentication_enabled  = var.local_authentication_enabled
  public_network_access_enabled = var.public_network_access_enabled

  network_rulesets {
    default_action                 = var.public_network_access_enabled ? "Allow" : "Deny"
    public_network_access_enabled  = var.public_network_access_enabled
    trusted_service_access_enabled = var.trusted_service_access_enabled

    # ip_rule and virtual_network_rule are list attributes on this provider
    # version, not nested blocks — build them with a comprehension.
    ip_rule = [
      for ip in var.ip_rules : {
        ip_mask = ip
        action  = "Allow"
      }
    ]

    virtual_network_rule = [
      for subnet_id in var.virtual_network_subnet_ids : {
        subnet_id                                       = subnet_id
        ignore_missing_virtual_network_service_endpoint = false
      }
    ]
  }

  dynamic "identity" {
    for_each = var.identity_type != null ? [1] : []
    content {
      type         = var.identity_type
      identity_ids = var.identity_type == "UserAssigned" ? var.identity_ids : null
    }
  }

  tags = var.tags

  lifecycle {
    # Per-hub validation cannot see processing_units, so the namespace-wide
    # Premium budgets are enforced here instead.
    precondition {
      condition     = local.total_partitions <= local.partition_budget
      error_message = "Premium allows 200 partitions per PU: ${local.total_partitions} requested, ${local.partition_budget} available at ${var.processing_units} PU(s). Raise processing_units or shrink partition counts."
    }

    precondition {
      condition     = length(var.event_hubs) <= local.event_hub_budget
      error_message = "Premium allows 100 event hubs per PU: ${length(var.event_hubs)} requested, ${local.event_hub_budget} available at ${var.processing_units} PU(s)."
    }

    precondition {
      condition     = var.identity_type != "UserAssigned" || length(var.identity_ids) > 0
      error_message = "identity_ids must be set when identity_type is 'UserAssigned'."
    }

    precondition {
      condition     = var.public_network_access_enabled || length(var.ip_rules) == 0
      error_message = "ip_rules are only evaluated when public_network_access_enabled is true."
    }
  }
}

# -----------------------------------------------------------------------
# Event Hubs
# -----------------------------------------------------------------------
resource "azurerm_eventhub" "this" {
  for_each = var.event_hubs

  name            = each.key
  namespace_id    = azurerm_eventhub_namespace.this.id
  partition_count = each.value.partition_count
  status          = each.value.status

  # Retention is driven entirely through retention_description. message_retention
  # is deliberately left unset: it caps at 7 days on a shared parent namespace,
  # and setting both fields is what produces perpetual diffs.
  retention_description {
    cleanup_policy                    = each.value.cleanup_policy
    retention_time_in_hours           = each.value.cleanup_policy == "Delete" ? each.value.message_retention * 24 : null
    tombstone_retention_time_in_hours = each.value.cleanup_policy == "Compact" ? each.value.tombstone_retention_hours : null
  }
}

# -----------------------------------------------------------------------
# Consumer groups
# Each consumer tracks its own offset — give every consumer its own group.
# -----------------------------------------------------------------------
resource "azurerm_eventhub_consumer_group" "this" {
  for_each = local.consumer_groups

  name                = each.value.name
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.this[each.value.eventhub_name].name
  resource_group_name = var.resource_group_name
}

# -----------------------------------------------------------------------
# Namespace authorization rules (SAS)
# -----------------------------------------------------------------------
resource "azurerm_eventhub_namespace_authorization_rule" "this" {
  for_each = var.namespace_authorization_rules

  name                = each.key
  namespace_name      = azurerm_eventhub_namespace.this.name
  resource_group_name = var.resource_group_name

  listen = each.value.listen
  send   = each.value.send
  manage = each.value.manage
}

# -----------------------------------------------------------------------
# Private endpoint + DNS
# Created only when private_endpoint_subnet_id is supplied.
# -----------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  count = local.create_dns_zone ? 1 : 0

  name                = "privatelink.servicebus.windows.net"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  count = local.create_dns_zone ? 1 : 0

  name                  = "link-${var.namespace_name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[0].name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = false
  tags                  = var.tags

  lifecycle {
    precondition {
      condition     = var.virtual_network_id != null
      error_message = "virtual_network_id is required when private_endpoint_subnet_id is set and private_dns_zone_ids is null."
    }
  }
}

resource "azurerm_private_endpoint" "this" {
  count = local.create_private_endpoint ? 1 : 0

  name                = local.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.namespace_name}"
    private_connection_resource_id = azurerm_eventhub_namespace.this.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "eventhub-dns-group"
    private_dns_zone_ids = local.create_dns_zone ? [azurerm_private_dns_zone.this[0].id] : var.private_dns_zone_ids
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}
