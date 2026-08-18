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

# ── Event Hub: Error Metrics ─────────────────────────────────────────────────

# ServerErrors does NOT usually mean an Azure platform fault. It means requests
# are reaching the namespace and being rejected because a limit is being crossed
# — throughput, connection count, partition load or message size. The metric
# carries only a count, never a reason, so investigate via the OperationalLogs /
# AZMSOperationalLogs table (requires enable_law = true).
resource "azurerm_monitor_metric_alert" "eventhub_server_errors" {
  name                = "alert-eventhub-server-errors"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub is rejecting requests with server errors — a service-side limit (throughput, connections, partition load, message size) is being crossed"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "ServerErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# QuotaExceededErrors is the unambiguous "you are out of capacity" signal —
# unlike ServerErrors it has exactly one cause. Auto-inflate absorbs throughput
# growth up to maximum_throughput_units = 20; past that this is what fires.
resource "azurerm_monitor_metric_alert" "eventhub_quota_exceeded" {
  name                = "alert-eventhub-quota-exceeded"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub requests are failing on exceeded quotas — auto-inflate has likely hit maximum_throughput_units"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "QuotaExceededErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# UserErrors counts client-side (HTTP 4xx-equivalent) failures and errors raised
# while processing messages. Threshold is deliberately NOT zero: normal consumer
# rebalancing produces ReceiverDisconnection exceptions that Azure classifies as
# user errors, so a >0 alert here would page on healthy Cribl restarts. 25 over
# 15 minutes distinguishes a genuine auth/serialisation fault from that churn.
resource "azurerm_monitor_metric_alert" "eventhub_user_errors" {
  name                = "alert-eventhub-user-errors"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub client-side errors are elevated beyond normal consumer rebalancing — check Cribl credentials, consumer group offsets and payload sizes"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "UserErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 25
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# ── Event Hub: Capacity Guardrails ───────────────────────────────────────────

# Standard tier caps a namespace at 5,000 concurrent AMQP connections. Firing at
# 4,000 leaves headroom to react before new consumers are refused outright.
# This is a leading indicator; ServerErrors is what fires once the cap is hit.
resource "azurerm_monitor_metric_alert" "eventhub_active_connections" {
  name                = "alert-eventhub-active-connections"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub namespace is approaching the Standard-tier limit of 5,000 concurrent AMQP connections"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "ActiveConnections"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 4000
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# Throughput-unit headroom. Azure exposes no "TU utilisation" metric, so it is
# derived from ingress volume: 1 TU = 1 MB/s in, and maximum_throughput_units is
# 20, giving a ceiling of 20 * 1048576 * 300 = 6,291,456,000 bytes per 5 min.
# This fires at 80% of that ceiling.
#
# Why this matters despite auto_inflate_enabled = true: auto-inflate scales only
# up to maximum_throughput_units and never past it, and it does not scale back
# down. Once ingress reaches 20 TU there is no automatic remedy left — the hard
# ceiling has to be raised by hand. This alert is the warning before that point;
# QuotaExceededErrors is the confirmation that it was missed.
#
# Threshold is intentionally hard-coded against maximum_throughput_units = 20
# rather than var.event_hub_capacity, which is only the *starting* TU count.
resource "azurerm_monitor_metric_alert" "eventhub_throughput_headroom" {
  name                = "alert-eventhub-throughput-headroom"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hub ingress is above 80% of the 20 throughput-unit ceiling — auto-inflate is close to exhausted and maximum_throughput_units must be raised manually"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "IncomingBytes"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5033164800
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

# ── Event Hub: Activity Log Alert ────────────────────────────────────────────

# Deleting the namespace destroys every diagnostic setting pointing at it across
# the estate — including the ones the policies in policy_*.tf deploy at scale.
# Metric alerts cannot catch this: a deleted namespace simply stops emitting.
resource "azurerm_monitor_activity_log_alert" "eventhub_namespace_deleted" {
  name                = "alert-eventhub-namespace-deleted"
  resource_group_name = azurerm_resource_group.main.name
  location            = "Global"
  scopes              = [azurerm_resource_group.main.id]
  description         = "Event Hub namespace was deleted — every diagnostic setting targeting it is now orphaned and the log pipeline is down"
  tags                = local.common_tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.EventHub/namespaces/delete"
    level          = "Critical"
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
