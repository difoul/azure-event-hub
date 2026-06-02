# ── Event Hub Namespace ───────────────────────────────────────────────────────
resource "azurerm_eventhub_namespace" "main" {
  name                     = "evhns-event-hub-demo"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  sku                      = "Standard"
  capacity                 = var.event_hub_capacity
  auto_inflate_enabled          = true
  maximum_throughput_units      = 20
  public_network_access_enabled = false
  tags                          = local.common_tags

  # Allow Azure Monitor diagnostic settings to bypass the firewall —
  # without this, diagnostic settings stop sending once network rules are enabled.
  network_rulesets {
    default_action                 = "Deny"
    trusted_service_access_enabled = true
    public_network_access_enabled  = false
    # trusted_service_access_enabled = true allows Azure Monitor diagnostic settings
    # to bypass the firewall without an IP rule. Cribl Stream reaches the hub via the
    # private endpoint in snet-private-endpoints (same VNet). On-premise Cribl instances
    # require ExpressRoute or VPN Gateway to resolve privatelink.servicebus.windows.net.
  }
}

# ── Event Hub Instance ────────────────────────────────────────────────────────
resource "azurerm_eventhub" "main" {
  name         = "evh-container-app-logs"
  namespace_id = azurerm_eventhub_namespace.main.id
  partition_count  = 4
  message_retention = 7
}

# ── SAS Policies (principle of least privilege) ───────────────────────────────

# Used by the azurerm_monitor_diagnostic_setting resource — Send only.
# Terraform reads the primary_connection_string via the ARM management plane
# (RBAC), not via the Event Hub SAS Manage right, so manage = false is correct.
resource "azurerm_eventhub_namespace_authorization_rule" "diagnostics" {
  name                = "DiagnosticsRule"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = azurerm_resource_group.main.name

  listen = false
  send   = true
  manage = false
}

# Used by Cribl Stream — Listen only, no send or manage access.
resource "azurerm_eventhub_namespace_authorization_rule" "cribl" {
  name                = "CriblListenRule"
  namespace_name      = azurerm_eventhub_namespace.main.name
  resource_group_name = azurerm_resource_group.main.name

  listen = true
  send   = false
  manage = false
}

# ── Consumer Group ────────────────────────────────────────────────────────────
# Dedicated consumer group for Cribl so it tracks its own offset independently.
# If a second consumer is added later, give it its own group.
resource "azurerm_eventhub_consumer_group" "cribl" {
  name                = "cribl"
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.main.name
  resource_group_name = azurerm_resource_group.main.name
}

# ── Private Endpoint ──────────────────────────────────────────────────────────
resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-eventhub"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.common_tags

  private_service_connection {
    name                           = "psc-eventhub"
    private_connection_resource_id = azurerm_eventhub_namespace.main.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "eventhub-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.eventhub.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.eventhub]
}

# ── Private DNS Zone ──────────────────────────────────────────────────────────
resource "azurerm_private_dns_zone" "eventhub" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "eventhub" {
  name                  = "link-eventhub"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.eventhub.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = local.common_tags
}
