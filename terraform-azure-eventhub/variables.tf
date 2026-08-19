# ------------------------------------------------------------------------------
# Base variables (shared by every module)
# ------------------------------------------------------------------------------

variable "application_code" {
  description = "Short application code, used to compose the resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,31}$", var.application_code))
    error_message = "application_code must be 1-31 lowercase alphanumeric characters (the composed namespace name must stay within 50 characters)."
  }
}

variable "environment" {
  description = "Environment. Drives the custom-role lookup (e.g. prd -> [PRD] ...)."
  type        = string

  validation {
    condition     = contains(["dev", "sim", "uat", "prd"], var.environment)
    error_message = "environment must be one of: dev, sim, uat, prd."
  }
}

variable "location" {
  description = "Azure region the Event Hubs namespace is deployed into. The Premium tier is not available in every region."
  type        = string
}

variable "object_index" {
  description = "3-digit object index. 000 means the module generates a random index."
  type        = string
  default     = "000"

  validation {
    condition     = can(regex("^[0-9]{3}$", var.object_index))
    error_message = "object_index must be exactly 3 digits."
  }
}

variable "target_resource_group_name" {
  description = "Existing resource group the module deploys into. The module never creates a resource group."
  type        = string
}

variable "company" {
  description = "Required governance tag."
  type        = string
}

variable "owner" {
  description = "Required governance tag."
  type        = string
}

variable "tags" {
  description = "Extra business tags. Cannot override governance or tracking tags."
  type        = map(string)
  default     = {}
}

variable "source_repo" {
  description = "Consumer repo that triggered the deploy. Set by the pipeline via TF_VAR_source_repo."
  type        = string
}

# ------------------------------------------------------------------------------
# Service-specific variables (Event Hubs Premium)
# ------------------------------------------------------------------------------

variable "processing_units" {
  description = <<-EOT
    Processing Units (PUs) for the Premium namespace. Only 1, 2, 4, 6, 8, 10, 12
    and 16 are accepted. PUs govern the namespace-wide budgets the module enforces:
    200 partitions per PU and 100 event hubs per PU. Auto-inflate is a Standard-tier
    mechanism and is disabled — Premium is scaled by changing this value.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 4, 6, 8, 10, 12, 16], var.processing_units)
    error_message = "processing_units must be one of: 1, 2, 4, 6, 8, 10, 12, 16."
  }
}

variable "event_hubs" {
  description = <<-EOT
    Event hubs to create in the namespace, keyed by hub name. The key is the hub
    name and part of the AMQP entity path, so renaming one replaces it and drops
    every consumer offset.

      - partition_count: 1-100 on Premium. Can be INCREASED in place, never
          decreased — a decrease forces a new hub. Also bounded namespace-wide
          at 200 partitions per PU.
      - message_retention: retention in days, 1-90 on Premium. Written as
          retention_description.retention_time_in_hours, because the resource's
          own message_retention argument caps at 7 days on a shared namespace.
      - cleanup_policy: "Delete" for time-based retention, "Compact" for log
          compaction (keeps the latest event per key). Immutable.
      - tombstone_retention_hours: only with cleanup_policy = "Compact".
      - consumer_groups: extra groups beyond $Default, max 100 per hub.
      - status: "Active", "Disabled" or "SendDisabled". Azure only accepts
          SendDisabled on an existing hub, so create it Active or Disabled first.
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
      can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$", name))
    ])
    error_message = "Event hub names must start with an alphanumeric character, may contain . _ -, and be 1-256 characters."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.partition_count >= 1 && hub.partition_count <= 100
    ])
    error_message = "event_hubs[*].partition_count must be between 1 and 100 on the Premium tier."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.message_retention >= 1 && hub.message_retention <= 90
    ])
    error_message = "event_hubs[*].message_retention must be between 1 and 90 days on the Premium tier."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      contains(["Delete", "Compact"], hub.cleanup_policy)
    ])
    error_message = "event_hubs[*].cleanup_policy must be either Delete or Compact."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      hub.cleanup_policy == "Compact" || hub.tombstone_retention_hours == null
    ])
    error_message = "event_hubs[*].tombstone_retention_hours only applies when cleanup_policy is Compact."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      length(hub.consumer_groups) <= 100
    ])
    error_message = "event_hubs[*].consumer_groups is limited to 100 groups per hub on the Premium tier."
  }

  validation {
    condition = alltrue([
      for name, hub in var.event_hubs :
      contains(["Active", "Disabled", "SendDisabled"], hub.status)
    ])
    error_message = "event_hubs[*].status must be one of: Active, Disabled, SendDisabled."
  }
}

# ------------------------------------------------------------------------------
# Standard interface: networking (Bronze)
# ------------------------------------------------------------------------------

variable "networking" {
  description = <<-EOT
    Private networking. Endpoints are never registered in a Private DNS zone —
    DNS is wired externally from the private_endpoint_dns output.
      - subnet_id: subnet for the private endpoint(s) (app-owned)
      - private_endpoints: which sub-resources to expose privately, keyed by
          sub-resource name, each with an optional static IP. Leave empty and the
          module creates the standard set ("namespace") with a dynamic IP.
          Event Hubs exposes only the "namespace" sub-resource.
      - integration_subnet_id: unused by Event Hubs (PE-only service). Leave null.
  EOT
  type = object({
    subnet_id = string
    private_endpoints = optional(map(object({
      private_ip_address = optional(string)
    })), {})
    integration_subnet_id = optional(string)
  })

  validation {
    condition = alltrue([
      for k in keys(var.networking.private_endpoints) : k == "namespace"
    ])
    error_message = "Event Hubs only supports the \"namespace\" sub-resource in private_endpoints."
  }

  validation {
    condition = alltrue([
      for pe in values(var.networking.private_endpoints) :
      pe.private_ip_address == null || can(cidrhost("${pe.private_ip_address}/32", 0))
    ])
    error_message = "Each private_endpoints[*].private_ip_address must be a valid IP address."
  }

  validation {
    condition     = var.networking.integration_subnet_id == null
    error_message = "networking.integration_subnet_id does not apply to Event Hubs (PE-only). Leave it null."
  }
}

# ------------------------------------------------------------------------------
# Standard interface: encryption (Bronze)
# ------------------------------------------------------------------------------

variable "encryption" {
  description = <<-EOT
    Customer-managed key (CMK) encryption. Leave disabled for Microsoft-managed keys.
    key_id accepts either form:
      - Versionless: https://<vault>.vault.azure.net/keys/<name>           -> key auto-rotates
      - Versioned:   https://<vault>.vault.azure.net/keys/<name>/<version> -> key is pinned
    See this module's README for Event Hubs' rotation behavior.

    key_resource_id is the ARM resource ID of the same key
    (/subscriptions/.../providers/Microsoft.KeyVault/vaults/<vault>/keys/<key>),
    from the keys module's key_resource_id output. Required whenever encryption
    is enabled, because this module self-grants on the key and a role assignment
    scope cannot use the URI above.

    Event Hubs only accepts CMK on an EMPTY namespace, so the module creates the
    identity, the grant and the encryption before any event hub. CMK cannot be
    removed afterwards without recreating the namespace.
  EOT
  type = object({
    enabled         = optional(bool, false)
    key_id          = optional(string)
    key_resource_id = optional(string)
  })
  default = { enabled = false }

  validation {
    condition     = !var.encryption.enabled || try(var.encryption.key_id, null) != null
    error_message = "encryption.key_id is required when encryption.enabled is true."
  }

  validation {
    condition = (
      !var.encryption.enabled ||
      can(regex("^https://[^/]+/keys/[^/]+(/[^/]+)?$", var.encryption.key_id))
    )
    error_message = "encryption.key_id must be a Key Vault or Managed HSM key URI (https://<vault>/keys/<name>[/<version>])."
  }

  validation {
    condition = (
      !var.encryption.enabled ||
      can(regex("/providers/Microsoft.KeyVault/vaults/[^/]+/keys/[^/]+$", try(var.encryption.key_resource_id, "")))
    )
    error_message = "encryption.key_resource_id must be the ARM resource ID of the key (use the keys module's key_resource_id output)."
  }
}

# ------------------------------------------------------------------------------
# Supporting interface: lock
# ------------------------------------------------------------------------------

variable "lock" {
  description = <<-EOT
    Optional resource lock to prevent accidental deletion.
      - enabled: create the management lock
      - level: CanNotDelete or ReadOnly
  EOT
  type = object({
    enabled = optional(bool, false)
    level   = optional(string, "CanNotDelete")
  })
  default = { enabled = false }

  validation {
    condition     = contains(["CanNotDelete", "ReadOnly"], var.lock.level)
    error_message = "lock.level must be one of: CanNotDelete, ReadOnly."
  }
}
