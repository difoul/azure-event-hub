resource "azurerm_monitor_action_group" "email" {
  name                = "ag-event-hub-demo"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "eventhubdm"
  tags                = local.common_tags

  email_receiver {
    name          = "alert-email"
    email_address = var.alert_email
  }
}

# ── Container App: Infrastructure Alerts ─────────────────────────────────────

# CPU > 80% of 0.5 vCPU allocation (400,000,000 nanocores)
resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "alert-cpu-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App CPU usage above 80% of allocated 0.5 vCPU"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 400000000
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# CPU sustained > 70% over 15 minutes — early warning before spike alert fires
resource "azurerm_monitor_metric_alert" "cpu_sustained" {
  name                = "alert-cpu-sustained"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App CPU average above 70% of allocated 0.5 vCPU for 15 minutes"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "UsageNanoCores"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 350000000
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Memory > 80% of 1Gi allocation (858,993,459 bytes)
resource "azurerm_monitor_metric_alert" "memory" {
  name                = "alert-memory-high"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App memory usage above 80% of allocated 1Gi"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "WorkingSetBytes"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 858993459
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

resource "azurerm_monitor_metric_alert" "restarts" {
  name                = "alert-container-restarts"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_container_app.main.id]
  description         = "Container App has restarted at least once"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# ── Container App: Activity Log Alerts ───────────────────────────────────────

resource "azurerm_monitor_activity_log_alert" "container_app_deleted" {
  name                = "alert-container-app-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container App was deleted — trigger recovery runbook"
  tags                = local.common_tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/containerApps/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

resource "azurerm_monitor_activity_log_alert" "environment_deleted" {
  name                = "alert-environment-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Container Apps Environment was deleted — full stack recovery required"
  tags                = local.common_tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.App/managedEnvironments/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# ── Event Hub: Pipeline Health Alert ─────────────────────────────────────────

# Throttled requests indicate the namespace is at capacity — scale up throughput units
# or investigate Cribl consumer lag (unconsumed messages cause back-pressure).
resource "azurerm_monitor_metric_alert" "eventhub_throttled" {
  name                = "alert-eventhub-throttled"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub is throttling requests — namespace may be undersized or Cribl consumer is lagging"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "ThrottledRequests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Consumer lag: messages are arriving but Cribl is not consuming them.
# Two criteria must both be true to fire, which eliminates false positives during
# quiet periods when both IncomingMessages and OutgoingMessages are zero.
resource "azurerm_monitor_metric_alert" "eventhub_consumer_lag" {
  name                = "alert-eventhub-consumer-lag"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub has incoming messages but Cribl consumer is not consuming — consumer may be down or lagging"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "IncomingMessages"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10
  }

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "OutgoingMessages"
    aggregation      = "Total"
    operator         = "LessThanOrEqual"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
