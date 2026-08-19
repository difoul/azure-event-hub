variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-event-hub-demo"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "swedencentral"
}

variable "container_app_name" {
  description = "Name of the Container App"
  type        = string
  default     = "event-hub-demo"
}

variable "container_image" {
  description = "Full public image reference to deploy, e.g. 'docker.io/myorg/myapp:latest'. The app must listen on port 8000 and expose GET /health. No registry credentials are required for public Docker Hub images."
  type        = string
}

variable "http_scale_threshold" {
  description = "Number of concurrent HTTP requests per replica that triggers a scale-out event."
  type        = number
  default     = 10

  validation {
    condition     = var.http_scale_threshold >= 1 && var.http_scale_threshold <= 1000
    error_message = "http_scale_threshold must be between 1 and 1000."
  }
}

variable "alert_email" {
  description = "Email address to receive alert notifications"
  type        = string
}

variable "cribl_image" {
  description = "Cribl Stream Docker Hub image. Pin to a specific version for reproducibility, e.g. 'cribl/cribl:4.9.0'."
  type        = string
  default     = "cribl/cribl:latest"
}

variable "enable_law" {
  description = "Deploy a Log Analytics Workspace (+ AMPLS private link) to retain ContainerAppHTTPLogs (Envoy ingress logs). Set to false when the stdout → Event Hub → Cribl pipeline is sufficient and Envoy-level HTTP logs are not required."
  type        = bool
  default     = false
}

variable "event_hub_capacity" {
  description = "Throughput units for the Event Hub namespace (1–20 for Standard). Auto-inflate can scale beyond this."
  type        = number
  default     = 1

  validation {
    condition     = var.event_hub_capacity >= 1 && var.event_hub_capacity <= 20
    error_message = "event_hub_capacity must be between 1 and 20."
  }
}

variable "eventhub_diagnostic_log_categories" {
  description = <<-EOT
    Resource log categories enabled on the Event Hub namespace's own diagnostic setting.

    These must be listed INDIVIDUALLY. Microsoft.EventHub/Namespaces has not onboarded to
    Azure Monitor category groups, so category_group = "allLogs" (which works for, say,
    Microsoft.App/managedEnvironments) is rejected by ARM with a BadRequest.

    An unsupported category name fails the same way, so confirm the exact set for your
    namespace before changing this:

      az monitor diagnostic-settings categories list --resource <namespace-resource-id> \
        --query "value[?categoryType=='Logs'].name" -o tsv

    The default covers the categories available on every tier. Two more exist but emit only
    on Premium and Dedicated namespaces — add "RuntimeAuditLogs" and "ApplicationMetricsLogs"
    there for data-plane audit trails and consumer lag. Depending on namespace configuration
    the API may also offer CustomerManagedKeyUserLogs, EventHubVNetConnectionEvent,
    DataDRLogs and DiagnosticErrorLogs; verify with the command above before adding them.
  EOT

  type = list(string)
  default = [
    "OperationalLogs",
    "ArchiveLogs",
    "AutoScaleLogs",
    "KafkaCoordinatorLogs",
    "KafkaUserErrorLogs",
  ]

  validation {
    condition     = length(var.eventhub_diagnostic_log_categories) > 0
    error_message = "At least one log category must be listed. An azurerm_monitor_diagnostic_setting with no enabled_log and no enabled_metric block is invalid."
  }

  validation {
    condition     = !contains(var.eventhub_diagnostic_log_categories, "allLogs")
    error_message = "\"allLogs\" is a category GROUP, not a category, and Microsoft.EventHub/Namespaces does not support category groups. List the individual categories instead."
  }
}

# ── Premium-tier Event Hub alerts (alerts_eventhub_premium.tf) ────────────────

variable "eventhub_premium_alerts_enabled" {
  description = "Deploy the Premium/Dedicated-tier Event Hub alerts in alerts_eventhub_premium.tf. These rules watch NamespaceCpuUsage and NamespaceMemoryUsage, which only emit on Premium and Dedicated namespaces — on a Standard namespace they are silent, so the alerts would never fire. Leave false while the namespace is Standard."
  type        = bool
  default     = false
}

variable "eventhub_premium_namespace_id" {
  description = "Resource ID of the Premium (or Dedicated) Event Hub namespace to watch. Defaults to this project's namespace when null, which is only correct if that namespace has been recreated at Premium tier — Azure does NOT support migrating a Standard namespace to Premium, so in practice a Premium namespace is a separate resource and this should be set explicitly."
  type        = string
  default     = null
}

variable "eventhub_premium_processing_units" {
  description = "Processing units (PUs) assigned to the Premium namespace. Premium bills and scales in PUs rather than throughput units, and the brokered-connection quota is 10,000 per PU — this value is what turns that per-PU quota into an absolute alert threshold. Ignored unless eventhub_premium_alerts_enabled is true."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 6, 8, 10, 12, 16], var.eventhub_premium_processing_units)
    error_message = "eventhub_premium_processing_units must be one of the purchasable PU counts: 1, 2, 4, 6, 8, 10, 12, 16. Note that 3, 5, 7 and anything above 16 are not offered."
  }
}

# ── Diagnostic-settings-at-scale policy (policy_diagnostics.tf) ────────────────

variable "diagnostics_policy_management_group_id" {
  description = "Full resource ID of the management group to assign the 'Enable allLogs to Event Hub' initiative to, e.g. '/providers/Microsoft.Management/managementGroups/<mg-name>'. Leave null to skip the assignment entirely."
  type        = string
  default     = null
}

variable "diagnostics_policy_event_hub_auth_rule_id" {
  description = "Namespace-level Event Hub authorization rule ID (Send right) the policy writes into each diagnostic setting. Defaults to this project's DiagnosticsRule when null."
  type        = string
  default     = null
}

variable "diagnostics_policy_event_hub_name" {
  description = "Target Event Hub instance name for policy-deployed diagnostic settings. Defaults to this project's hub when null."
  type        = string
  default     = null
}

variable "diagnostics_policy_resource_location" {
  description = "Azure region the Event Hub initiative targets. The Event Hub destination only supports a single region, so only resources in this region get diagnostic settings. Must match the Event Hub namespace region. Defaults to var.location when null."
  type        = string
  default     = null
}

variable "diagnostics_regions" {
  description = <<-EOT
    Per-region Event Hub targets for the diagnostics policies. An Event Hub destination must
    sit in the SAME region as the monitored resource, so one policy assignment is created per
    entry, each filtered to its own region via resourceSelectors. Map key = Azure region name
    (e.g. "switzerlandnorth"). Leave empty to keep the legacy single-region behaviour driven by
    diagnostics_policy_resource_location.

    Exactly one entry must set primary = true. That region additionally covers non-regional
    ("global") resources, which have no same-region constraint — marking more than one primary
    would deploy competing settings to the same global resource.
  EOT

  type = map(object({
    # Suffix for the policy assignment name. MG assignment names cap at 24 chars.
    short                  = string
    primary                = optional(bool, false)
    nonprod_auth_rule_id   = string
    nonprod_event_hub_name = optional(string)
    # Required only when diagnostics_eventhub_tag_routing = true.
    prod_auth_rule_id   = optional(string)
    prod_event_hub_name = optional(string)
  }))
  default = {}

  validation {
    condition     = length(var.diagnostics_regions) == 0 || length([for c in var.diagnostics_regions : c if c.primary]) == 1
    error_message = "Exactly one entry in diagnostics_regions must set primary = true; it carries the 'global' (non-regional) resources."
  }

  validation {
    condition     = alltrue([for c in var.diagnostics_regions : length(c.short) > 0 && length(c.short) <= 6])
    error_message = "diagnostics_regions[*].short must be 1-6 characters — management group policy assignment names are capped at 24."
  }

  validation {
    condition     = length(distinct([for c in var.diagnostics_regions : c.short])) == length(var.diagnostics_regions)
    error_message = "diagnostics_regions[*].short must be unique; it is what makes each per-region assignment name distinct."
  }

  validation {
    condition     = alltrue([for r in keys(var.diagnostics_regions) : r == lower(r) && !can(regex("\\s", r))])
    error_message = "diagnostics_regions keys must be lowercase Azure region names with no spaces, e.g. 'switzerlandnorth'."
  }
}

variable "diagnostics_combined_policy_enabled" {
  description = "Opt in to the SINGLE-SETTING alternative (policy_combined.tf): one custom DeployIfNotExists policy that writes allLogs + AllMetrics into ONE diagnostic setting per resource, instead of the two separate settings produced by the built-in logs initiative + the metrics policy. When true, do NOT also assign those two to the same scope or resources get duplicate settings. Targets var.diagnostics_metrics_resource_types. Requires diagnostics_policy_management_group_id to be set."
  type        = bool
  default     = false
}

variable "diagnostics_eventhub_tag_routing" {
  description = "Opt in to the TAG-ROUTED variant of the combined policy (policy_combined_tagrouted.tf): one MG assignment that routes each resource's diagnostic setting to the prod or non-prod Event Hub based on the resource's SUBSCRIPTION environment tag, instead of one hub per assignment. Replaces the single-hub combined policy when true (policy_combined.tf gates itself off). Requires diagnostics_combined_policy_enabled = true and diagnostics_prod_eventhub_auth_rule_id; the non-prod hub reuses diagnostics_policy_event_hub_auth_rule_id / this project's hub."
  type        = bool
  default     = false
}

variable "diagnostics_environment_tag_name" {
  description = "Name of the subscription tag whose value selects the Event Hub in tag-routing mode."
  type        = string
  default     = "environment"
}

variable "diagnostics_prod_tag_values" {
  description = "Subscription environment-tag values routed to the PROD Event Hub. Must be lowercase — the policy lowercases the tag value before comparing. Any other value, and subscriptions missing the tag, route to the non-prod hub (safe default)."
  type        = list(string)
  default     = ["pprod", "prod"]

  validation {
    condition     = alltrue([for v in var.diagnostics_prod_tag_values : v == lower(v)])
    error_message = "diagnostics_prod_tag_values must be lowercase; the policy compares against a lowercased tag value."
  }
}

variable "diagnostics_prod_eventhub_auth_rule_id" {
  description = "Namespace-level authorization rule ID (Send right) on the PROD Event Hub namespace, used by the tag-routed combined policy. Required when diagnostics_eventhub_tag_routing = true."
  type        = string
  default     = null
}

variable "diagnostics_prod_eventhub_name" {
  description = "Event Hub instance name inside the prod namespace for tag-routed diagnostic settings. Defaults to the same hub name as the non-prod side when null."
  type        = string
  default     = null
}

variable "diagnostics_metrics_resource_types" {
  description = "Resource types the metrics-to-Event-Hub DeployIfNotExists policy targets (policy_metrics.tf). Defaults to common metric-emitting types. Keep this to types that support the AllMetrics category — listing a type that has no metrics produces failed remediations. Extend or trim to match your estate."
  type        = list(string)
  default = [
    "Microsoft.App/managedEnvironments",
    "Microsoft.KeyVault/vaults",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Sql/servers/databases",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.Cache/Redis",
    "Microsoft.EventHub/namespaces",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Network/loadBalancers",
    "Microsoft.Network/publicIPAddresses",
    "Microsoft.Compute/virtualMachines",
    "Microsoft.Compute/virtualMachineScaleSets",
    "Microsoft.Web/sites",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.DBforPostgreSQL/flexibleServers",
    "Microsoft.DBforMySQL/flexibleServers",
    "Microsoft.ApiManagement/service",
    "Microsoft.CognitiveServices/accounts",
    "Microsoft.SignalRService/SignalR",
  ]
}
