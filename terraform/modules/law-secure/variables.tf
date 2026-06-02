# -----------------------------------------------------------------------
# Core
# -----------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the resource group where all resources will be deployed."
  type        = string
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
}

variable "tags" {
  description = "Map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}

# -----------------------------------------------------------------------
# Log Analytics Workspace
# -----------------------------------------------------------------------
variable "workspace_name" {
  description = "Name of the Log Analytics Workspace."
  type        = string
}

variable "sku" {
  description = "SKU of the Log Analytics Workspace. Use 'PerGB2018' for pay-as-you-go."
  type        = string
  default     = "PerGB2018"

  validation {
    condition     = contains(["Free", "PerGB2018", "PerNode", "Premium", "Standalone", "Standard"], var.sku)
    error_message = "Must be one of: Free, PerGB2018, PerNode, Premium, Standalone, Standard."
  }
}

variable "retention_in_days" {
  description = "Number of days to retain data. Must be between 30 and 730."
  type        = number
  default     = 90

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "Retention must be between 30 and 730 days."
  }
}

variable "daily_quota_gb" {
  description = "Daily ingestion quota in GB. Set to -1 for unlimited."
  type        = number
  default     = -1
}

# -----------------------------------------------------------------------
# Security mode
# -----------------------------------------------------------------------
variable "security_mode" {
  description = <<-EOT
    Security mode controlling public network access and AMPLS setup:
      - "open"    : No private link. Public ingestion and query allowed. (Dev/test only)
      - "hybrid"  : AMPLS with private ingestion. Public query allowed. (Recommended for most prod)
      - "private" : AMPLS with private ingestion and private query. Requires VPN/ExpressRoute. (Maximum security)
  EOT
  type        = string
  default     = "hybrid"

  validation {
    condition     = contains(["open", "hybrid", "private"], var.security_mode)
    error_message = "security_mode must be one of: open, hybrid, private."
  }
}

# -----------------------------------------------------------------------
# Networking — required when security_mode is "hybrid" or "private"
# -----------------------------------------------------------------------
variable "subnet_id" {
  description = "ID of the subnet where the AMPLS private endpoint will be placed. Required when security_mode is 'hybrid' or 'private'."
  type        = string
  default     = null
}

variable "virtual_network_id" {
  description = "ID of the virtual network for private DNS zone links. Required when security_mode is 'hybrid' or 'private'."
  type        = string
  default     = null
}

variable "private_endpoint_name" {
  description = "Override the default name for the AMPLS private endpoint."
  type        = string
  default     = null
}

variable "ampls_name" {
  description = "Override the default name for the Azure Monitor Private Link Scope."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------
# Encryption
# -----------------------------------------------------------------------
variable "cmk_key_vault_key_id" {
  description = "Key Vault key ID for customer-managed key encryption. Requires a dedicated cluster. Leave null to use Microsoft-managed keys."
  type        = string
  default     = null
  sensitive   = true
}

# -----------------------------------------------------------------------
# Diagnostic audit logging
# -----------------------------------------------------------------------
variable "enable_audit_diagnostics" {
  description = "Send workspace audit logs (queries and data access) to itself for compliance tracking."
  type        = bool
  default     = true
}
