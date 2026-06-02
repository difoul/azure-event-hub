# -----------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------
locals {
  # Determine public access flags from security_mode
  public_ingestion_enabled = var.security_mode == "open" ? "Enabled" : "Disabled"
  public_query_enabled     = var.security_mode == "private" ? "Disabled" : "Enabled"

  # Whether to create AMPLS and private endpoint resources
  create_private_link = var.security_mode != "open"

  # AMPLS access mode — "PrivateOnly" prevents data exfiltration
  ampls_query_access_mode     = var.security_mode == "private" ? "PrivateOnly" : "Open"
  ampls_ingestion_access_mode = var.security_mode != "open" ? "PrivateOnly" : "Open"

  ampls_name            = coalesce(var.ampls_name, "ampls-${var.workspace_name}")
  private_endpoint_name = coalesce(var.private_endpoint_name, "pe-ampls-${var.workspace_name}")

  # DNS zones required for Azure Monitor private link
  # Reference: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
  dns_zones = local.create_private_link ? {
    oms         = "privatelink.oms.opinsights.azure.com"
    ods         = "privatelink.ods.opinsights.azure.com"
    agentsvc    = "privatelink.agentsvc.azure-automation.net"
    monitor     = "privatelink.monitor.azure.com"
    blob        = "privatelink.blob.core.windows.net"
  } : {}
}

# -----------------------------------------------------------------------
# Log Analytics Workspace
# -----------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = var.workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  retention_in_days   = var.retention_in_days

  daily_quota_gb = var.daily_quota_gb > 0 ? var.daily_quota_gb : null

  # Block / allow public network access based on security_mode
  internet_ingestion_enabled = local.public_ingestion_enabled == "Enabled"
  internet_query_enabled     = local.public_query_enabled == "Enabled"

  # CMK — only set when a key ID is provided
  dynamic "identity" {
    for_each = var.cmk_key_vault_key_id != null ? [1] : []
    content {
      type = "SystemAssigned"
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------
# Azure Monitor Private Link Scope (AMPLS)
# Only created when security_mode is "hybrid" or "private"
# -----------------------------------------------------------------------
resource "azurerm_monitor_private_link_scope" "this" {
  count = local.create_private_link ? 1 : 0

  name                = local.ampls_name
  resource_group_name = var.resource_group_name

  ingestion_access_mode = local.ampls_ingestion_access_mode
  query_access_mode     = local.ampls_query_access_mode

  tags = var.tags
}

# Attach the Log Analytics Workspace to the AMPLS
resource "azurerm_monitor_private_link_scoped_service" "law" {
  count = local.create_private_link ? 1 : 0

  name                = "scoped-${var.workspace_name}"
  resource_group_name = var.resource_group_name
  scope_name          = azurerm_monitor_private_link_scope.this[0].name
  linked_resource_id  = azurerm_log_analytics_workspace.this.id
}

# -----------------------------------------------------------------------
# Private DNS Zones
# Required for correct DNS resolution from within the VNet
# -----------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each = local.dns_zones

  name                = each.value
  resource_group_name = var.resource_group_name

  tags = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.dns_zones

  name                  = "link-${each.key}-${var.workspace_name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = var.virtual_network_id
  registration_enabled  = false

  tags = var.tags
}

# -----------------------------------------------------------------------
# Private Endpoint — connects the VNet to the AMPLS
# -----------------------------------------------------------------------
resource "azurerm_private_endpoint" "ampls" {
  count = local.create_private_link ? 1 : 0

  name                = local.private_endpoint_name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id

  lifecycle {
    precondition {
      condition     = var.subnet_id != null
      error_message = "subnet_id is required when security_mode is '${var.security_mode}'. Provide the subnet ID for the AMPLS private endpoint."
    }
    precondition {
      condition     = var.virtual_network_id != null
      error_message = "virtual_network_id is required when security_mode is '${var.security_mode}'. Provide the VNet ID for private DNS zone links."
    }
  }

  private_service_connection {
    name                           = "psc-${local.ampls_name}"
    private_connection_resource_id = azurerm_monitor_private_link_scope.this[0].id
    is_manual_connection           = false
    subresource_names              = ["azuremonitor"]
  }

  # Auto-register DNS A records in all required private DNS zones
  dynamic "private_dns_zone_group" {
    for_each = local.create_private_link ? [1] : []
    content {
      name = "ampls-dns-group"
      private_dns_zone_ids = [
        for z in azurerm_private_dns_zone.this : z.id
      ]
    }
  }

  tags = var.tags

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.this,
    azurerm_monitor_private_link_scoped_service.law,
  ]
}

# -----------------------------------------------------------------------
# Diagnostic Settings — audit log ingestion to the workspace itself
# Captures LAQueryLogs and DataIngestion events for compliance
# -----------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "audit" {
  count = var.enable_audit_diagnostics ? 1 : 0

  name                       = "diag-audit-${var.workspace_name}"
  target_resource_id         = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "Audit"
  }

  enabled_log {
    category = "SummaryLogs"
  }

  # Metrics intentionally omitted — audit setting captures query/ingestion audit events only
}
