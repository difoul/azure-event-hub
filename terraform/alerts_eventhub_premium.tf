# ── Premium-tier Event Hub Alerts ─────────────────────────────────────────────
#
# Alerts that only make sense on a Premium (or Dedicated) namespace. They are
# split out from alerts.tf because they are not portable across tiers: the two
# capacity metrics they rely on, NamespaceCpuUsage and NamespaceMemoryUsage, are
# documented as "for Premium SKU namespaces" and stay silent on Standard. A rule
# that can never fire is worse than no rule — it reads as coverage on a
# dashboard while watching nothing — hence the explicit enable flag.
#
# WHY PREMIUM NEEDS DIFFERENT RULES
#
# Standard sells throughput units: a hard 1 MB/s ingress throttle per TU, so
# headroom can be derived from IncomingBytes against a known ceiling. That is
# what alerts.tf's eventhub_throughput_headroom rule does.
#
# Premium sells processing units — isolated pods of CPU and memory. The quota
# table lists throughput per PU as "No limits per PU", because there is no
# throttle to hit; achievable throughput depends on payload size, partition
# count, producer/consumer counts and egress rate. There is therefore no byte
# ceiling to compute a percentage of, and the TU-derived rule in alerts.tf is
# meaningless here. Saturation shows up as CPU and memory pressure instead,
# which Premium exposes directly. Measured, not inferred.
#
# WHAT IS NOT DUPLICATED HERE
#
# The error and liveness rules in alerts.tf — ServerErrors, UserErrors,
# QuotaExceededErrors, ThrottledRequests, consumer lag and namespace deletion —
# are tier-independent and are deliberately NOT repeated in this file. They are
# scoped to azurerm_eventhub_namespace.main. If var.eventhub_premium_namespace_id
# points at a DIFFERENT namespace, that namespace has no error alerting until
# those rules are given a matching scope.

locals {
  # Fall back to this project's namespace so the flag alone is enough when the
  # namespace itself has been provisioned at Premium tier.
  eventhub_premium_namespace_id = coalesce(
    var.eventhub_premium_namespace_id,
    azurerm_eventhub_namespace.main.id,
  )

  # Premium allows 10,000 brokered connections per PU (Standard is a flat 5,000
  # regardless of TUs). Alert at 80% so there is room to add PUs before clients
  # start being refused outright.
  eventhub_premium_connection_threshold = 10000 * var.eventhub_premium_processing_units * 0.8
}

# ── Capacity: CPU ─────────────────────────────────────────────────────────────

# CPU is the primary saturation signal on a capacity-based tier. Microsoft's
# scaling guidance treats sustained CPU approaching 70% — absent other symptoms
# such as elevated server errors or falling successful requests — as the point
# at which a namespace is nearing its ceiling and PUs should be added.
#
# Maximum rather than Average: the Replica dimension means an Average would hide
# a single hot replica behind two healthy ones, and it is the hot replica that
# throttles clients. Aggregating to Maximum surfaces the worst replica.
#
# The 15-minute window deliberately ignores short spikes; PU changes are a
# capacity decision, not something to make on a one-minute transient.
resource "azurerm_monitor_metric_alert" "eventhub_premium_cpu" {
  count = var.eventhub_premium_alerts_enabled ? 1 : 0

  name                = "alert-eventhub-premium-cpu"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [local.eventhub_premium_namespace_id]
  description         = "Event Hub Premium namespace CPU is sustained above 70% — the namespace is approaching its capacity ceiling and processing units should be added"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "NamespaceCpuUsage"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 70
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }

  # Catches the most likely misconfiguration: enabling this file while it still
  # resolves to this project's Standard namespace. NamespaceCpuUsage does not
  # emit there, so every rule in this file would deploy clean and then sit
  # permanently silent.
  lifecycle {
    precondition {
      condition = (
        var.eventhub_premium_namespace_id != null ||
        azurerm_eventhub_namespace.main.sku == "Premium"
      )
      error_message = <<-EOT
        eventhub_premium_alerts_enabled is true but the alerts resolve to this project's
        Event Hub namespace, which is ${azurerm_eventhub_namespace.main.sku} tier. NamespaceCpuUsage and
        NamespaceMemoryUsage only emit on Premium and Dedicated namespaces, so these
        alerts would never fire.

        Either set eventhub_premium_namespace_id to the resource ID of an actual Premium
        namespace, or raise the sku on azurerm_eventhub_namespace.main. Note that Azure
        does not support migrating an existing Standard namespace to Premium — changing
        the sku means replacing the namespace.
      EOT
    }
  }
}

# ── Capacity: Memory ──────────────────────────────────────────────────────────

# Memory pressure is the other half of the picture and does not always track
# CPU. Large payloads, high partition counts and slow consumers force retention
# of more unflushed data, which shows up here first. Threshold sits above the
# CPU one because memory sitting high is normal for a healthy buffering broker,
# whereas high CPU is not.
resource "azurerm_monitor_metric_alert" "eventhub_premium_memory" {
  count = var.eventhub_premium_alerts_enabled ? 1 : 0

  name                = "alert-eventhub-premium-memory"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [local.eventhub_premium_namespace_id]
  description         = "Event Hub Premium namespace memory is sustained above 80% — check for oversized payloads, high partition counts or lagging consumers before adding processing units"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "NamespaceMemoryUsage"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}

# ── Capacity: Brokered Connections ────────────────────────────────────────────

# Replaces the flat 4,000 threshold in alerts.tf, which encodes the Standard
# tier's 5,000-connection cap. On Premium the cap scales with PUs at 10,000
# each, so that Standard threshold would page at a small fraction of real
# utilisation — at 8 PUs it would fire at 5% of the 80,000 available.
resource "azurerm_monitor_metric_alert" "eventhub_premium_active_connections" {
  count = var.eventhub_premium_alerts_enabled ? 1 : 0

  name                = "alert-eventhub-premium-active-connections"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [local.eventhub_premium_namespace_id]
  description         = "Event Hub Premium namespace is above 80% of its brokered-connection quota (10,000 per PU x ${var.eventhub_premium_processing_units} PU = ${10000 * var.eventhub_premium_processing_units})"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.common_tags

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "ActiveConnections"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = local.eventhub_premium_connection_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
