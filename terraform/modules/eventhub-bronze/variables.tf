# -----------------------------------------------------------------------
# Core
# -----------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the resource group where all resources will be deployed."
  type        = string
}

variable "location" {
  description = "Azure region for all resources. The Premium tier is not available in every region."
  type        = string
}

variable "tags" {
  description = "Map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------
# Namespace
# -----------------------------------------------------------------------
variable "namespace_name" {
  description = "Name of the Event Hubs namespace. Must be globally unique — it becomes <name>.servicebus.windows.net."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{4,48}[a-zA-Z0-9]$", var.namespace_name))
    error_message = "Namespace name must be 6-50 characters, start with a letter, end with a letter or digit, and contain only letters, digits and hyphens."
  }
}

variable "processing_units" {
  description = <<-EOT
    Processing Units (PUs) for the Premium namespace. Only 1, 2, 4, 6, 8, 10,
    12 and 16 are accepted. PUs govern the namespace-wide partition budget
    (200 per PU) and the event hub budget (100 per PU). Auto-inflate does not
    apply to the Premium tier — PUs are scaled explicitly.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 6, 8, 10, 12, 16], var.processing_units)
    error_message = "processing_units must be one of: 1, 2, 4, 6, 8, 10, 12, 16."
  }
}

variable "minimum_tls_version" {
  description = "Minimum TLS version accepted by the namespace. The Premium tier requires 1.2 or greater."
  type        = string
  default     = "1.2"

  validation {
    condition     = contains(["1.2"], var.minimum_tls_version)
    error_message = "The Premium tier supports TLS 1.2 only."
  }
}

variable "local_authentication_enabled" {
  description = <<-EOT
    Allow SAS (shared access signature) authentication on the namespace.
    Set to false to force Entra ID / RBAC only — note this breaks any consumer
    that authenticates with a connection string, including Azure Monitor
    diagnostic settings that target an authorization rule.
  EOT
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------
# Event Hubs
# -----------------------------------------------------------------------
variable "event_hubs" {
  description = <<-EOT
    Map of Event Hub instances to create in the namespace, keyed by hub name.
    The key is used verbatim as the Event Hub name — it is part of the AMQP
    entity path, so renaming forces replacement and drops consumer offsets.

    Attributes per hub:
      - partition_count           : 1-100 on Premium. Can be INCREASED in place,
                                    never decreased (a decrease forces a new
                                    Event Hub). The namespace-wide cap is
                                    200 partitions per PU.
      - message_retention         : Retention in days, 1-90 on Premium. Rendered
                                    as retention_description.retention_time_in_hours,
                                    because message_retention alone caps at
                                    7 days on a shared parent namespace.
      - cleanup_policy            : "Delete" for time-based retention, or
                                    "Compact" for log compaction (keeps the
                                    latest event per key). Immutable — changing
                                    it forces a new Event Hub.
      - tombstone_retention_hours : Only used when cleanup_policy = "Compact".
      - consumer_groups           : Extra consumer groups beyond $Default,
                                    max 100 per hub on Premium.
      - status                    : "Active", "Disabled" or "SendDisabled".
                                    A hub must be created Active or Disabled;
                                    SendDisabled can only be set on update.

    Example:
      event_hubs = {
        "evh-container-app-logs" = {
          partition_count   = 8
          message_retention = 30
          consumer_groups   = ["cribl"]
        }
        "evh-cdc-state" = {
          partition_count           = 4
          message_retention         = 90
          cleanup_policy            = "Compact"
          tombstone_retention_hours = 24
        }
      }
  EOT

  type = map(object({
    partition_count           = number
    message_retention         = number
    cleanup_policy            = optional(string, "Delete")
    tombstone_retention_hours = optional(number, null)
    consumer_groups           = optional(list(string), [])
    status                    = optional(string, "Active")
  }))

  default = {}

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.partition_count >= 1 && hub.partition_count <= 100
    ])
    error_message = "partition_count must be between 1 and 100 on the Premium tier."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.message_retention >= 1 && hub.message_retention <= 90
    ])
    error_message = "message_retention must be between 1 and 90 days on the Premium tier."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      contains(["Delete", "Compact"], hub.cleanup_policy)
    ])
    error_message = "cleanup_policy must be either 'Delete' or 'Compact'."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.cleanup_policy == "Compact" || hub.tombstone_retention_hours == null
    ])
    error_message = "tombstone_retention_hours is only valid when cleanup_policy = 'Compact'."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      length(hub.consumer_groups) <= 100
    ])
    error_message = "A Premium Event Hub supports at most 100 consumer groups."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      contains(["Active", "Disabled", "SendDisabled"], hub.status)
    ])
    error_message = "status must be one of: Active, Disabled, SendDisabled."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$", name))
    ])
    error_message = "Event Hub names must start with an alphanumeric character, may contain . _ -, and be 1-256 characters."
  }
}

# -----------------------------------------------------------------------
# Authorization rules (namespace scope)
# -----------------------------------------------------------------------
variable "namespace_authorization_rules" {
  description = <<-EOT
    Namespace-level SAS policies, keyed by rule name. Grant the narrowest set
    of rights each consumer needs — Terraform reads connection strings through
    the ARM management plane (RBAC), so manage = false is correct for rules
    that only send or listen.

    Example:
      namespace_authorization_rules = {
        DiagnosticsRule = { listen = false, send = true,  manage = false }
        CriblListenRule = { listen = true,  send = false, manage = false }
      }
  EOT
  type = map(object({
    listen = optional(bool, false)
    send   = optional(bool, false)
    manage = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, rule in var.namespace_authorization_rules :
      rule.listen || rule.send || rule.manage
    ])
    error_message = "Each authorization rule must grant at least one of listen, send or manage."
  }

  validation {
    condition = alltrue([
      for name, rule in var.namespace_authorization_rules :
      !rule.manage || (rule.listen && rule.send)
    ])
    error_message = "Azure requires listen and send to be true when manage is true."
  }
}

# -----------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------
variable "public_network_access_enabled" {
  description = "Allow the namespace to be reached over the public internet. Defaults to false — reach the namespace over a private endpoint."
  type        = bool
  default     = false
}

variable "trusted_service_access_enabled" {
  description = <<-EOT
    Allow trusted Microsoft services to bypass the namespace firewall. Required
    for Azure Monitor diagnostic settings to keep delivering once network rules
    are enabled — without it, diagnostic settings silently stop sending.
  EOT
  type        = bool
  default     = true
}

variable "ip_rules" {
  description = "List of public IPs or CIDR ranges allowed through the namespace firewall. Only evaluated when public_network_access_enabled is true."
  type        = list(string)
  default     = []
}

variable "virtual_network_subnet_ids" {
  description = "Subnet IDs allowed through the namespace firewall via service endpoints. Prefer a private endpoint over service endpoints for new designs."
  type        = list(string)
  default     = []
}

variable "private_endpoint_subnet_id" {
  description = "Subnet ID where the namespace private endpoint is placed. Leave null to skip private endpoint creation."
  type        = string
  default     = null
}

variable "private_endpoint_name" {
  description = "Override the default name for the namespace private endpoint."
  type        = string
  default     = null
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    Existing privatelink.servicebus.windows.net zone IDs to register the private
    endpoint in. Leave null to have the module create and link its own zone —
    use the existing-zone path when DNS is centrally managed in a hub VNet.
  EOT
  type        = list(string)
  default     = null
}

variable "virtual_network_id" {
  description = "VNet ID to link the module-created private DNS zone to. Required when private_endpoint_subnet_id is set and private_dns_zone_ids is null."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------
# Identity
# -----------------------------------------------------------------------
variable "identity_type" {
  description = "Managed identity for the namespace: null, 'SystemAssigned' or 'UserAssigned'. Needed for identity-based integrations such as customer-managed key encryption."
  type        = string
  default     = null

  validation {
    condition     = var.identity_type == null || contains(["SystemAssigned", "UserAssigned"], coalesce(var.identity_type, "SystemAssigned"))
    error_message = "identity_type must be null, 'SystemAssigned' or 'UserAssigned'."
  }
}

variable "identity_ids" {
  description = "User Assigned Managed Identity IDs. Required when identity_type is 'UserAssigned'."
  type        = list(string)
  default     = []
}
