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

# ── Event Hub Namespace Self-Diagnostics ─────────────────────────────────────
#
# The namespace's own resource logs go to Log Analytics, NOT to the Event Hub.
# Routing them through the hub they describe is self-referential: a namespace
# outage would take down the very pipeline carrying the evidence of that outage.
# LAW is an independent failure domain, so the logs survive to be read.
#
# Consequence: this only deploys when var.enable_law = true. Without a workspace
# there is no independent sink to send to, and the loop is the only alternative.
#
# Categories are listed individually rather than via category_group = "allLogs".
# Microsoft.EventHub/Namespaces has NOT onboarded to Azure Monitor category
# groups, so ARM rejects "allLogs" with a BadRequest. This differs from the
# Container App Environment setting above, where Microsoft.App/managedEnvironments
# does support groups — the two are not interchangeable, and the working pattern
# there is not a safe template here.
#
# The categories that matter on this namespace are OperationalLogs
# (management-plane operations) and AutoScaleLogs (auto-inflate decisions,
# relevant since auto_inflate_enabled = true). RuntimeAuditLogs and
# ApplicationMetricsLogs — the data-plane categories giving per-client
# send/receive audit trails and consumer lag — are PREMIUM/DEDICATED ONLY and so
# are not in the default list. See var.eventhub_diagnostic_log_categories.
resource "azurerm_monitor_diagnostic_setting" "eventhub_namespace" {
  count = var.enable_law ? 1 : 0

  name                       = "diag-evhns-to-law"
  target_resource_id         = azurerm_eventhub_namespace.main.id
  log_analytics_workspace_id = one(module.law[*].workspace_id)

  # Resource-specific tables (AZMSOperationalLogs, AZMSAutoscaleLogs,
  # AZMSArchiveLogs, ...) instead of dumping everything into the shared
  # AzureDiagnostics table. Each category gets a typed schema with real columns,
  # which makes the KQL far simpler and cheaper to query.
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = toset(var.eventhub_diagnostic_log_categories)

    content {
      category = enabled_log.value
    }
  }

  # Platform metrics are already queryable from the metrics store for 93 days
  # without this. Sending them to LAW buys longer retention and the ability to
  # join metrics against the log categories above in a single KQL query.
  enabled_metric {
    category = "AllMetrics"
  }
}
