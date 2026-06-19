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
