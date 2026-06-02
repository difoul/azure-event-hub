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
