# ── Diagnostic Settings ──────────────────────────────────────────────────────
#
# Environment level: routes ContainerAppConsoleLogs + ContainerAppSystemLogs
# to the Event Hub so Cribl Stream can consume them via the CriblListenRule SAS key.
#
# Container app level: metrics only — Azure does not support log categories at
# the individual container app level, only at the environment level.
#
# Note: ContainerAppHTTPLogs (ingress access logs) are NOT available via
# diagnostic settings — they are lake-only in Log Analytics. Query them directly
# from the Log Analytics Workspace created by the law module below.

resource "azurerm_monitor_diagnostic_setting" "container_app_env" {
  name                           = "diag-cae-to-eventhub"
  target_resource_id             = azurerm_container_app_environment.main.id
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics.id
  eventhub_name                  = azurerm_eventhub.main.name

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "container_app" {
  name                           = "diag-ca-to-eventhub"
  target_resource_id             = azurerm_container_app.main.id
  eventhub_authorization_rule_id = azurerm_eventhub_namespace_authorization_rule.diagnostics.id
  eventhub_name                  = azurerm_eventhub.main.name

  enabled_metric {
    category = "AllMetrics"
  }
}

# ── Log Analytics Workspace (optional) ───────────────────────────────────────
# Only deployed when var.enable_law = true. Provides a workspace to query
# ContainerAppHTTPLogs (Envoy ingress logs), which are lake-only and cannot be
# routed to Event Hub via diagnostic settings.
module "law" {
  count  = var.enable_law ? 1 : 0
  source = "./modules/law-secure"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_name      = "law-event-hub-demo"
  security_mode       = "hybrid"

  retention_in_days = 30
  daily_quota_gb    = -1

  subnet_id          = azurerm_subnet.private_endpoints.id
  virtual_network_id = azurerm_virtual_network.main.id

  enable_audit_diagnostics = true

  tags = local.common_tags
}
