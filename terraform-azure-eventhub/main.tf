data "azurerm_client_config" "current" {}

# ------------------------------------------------------------------------------
# Naming, tagging and derived locals
# ------------------------------------------------------------------------------

resource "random_integer" "index" {
  count = var.object_index == "000" ? 1 : 0
  min   = 1
  max   = 999
}

# The namespace name is globally unique (<name>.servicebus.windows.net), so the
# 3-digit index alone is not enough — a short random suffix carries the entropy.
resource "random_string" "suffix" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  type        = "evhns"    # baked per module
  module_name = "eventhub" # baked per module

  object_index = var.object_index == "000" ? format("%03d", random_integer.index[0].result) : var.object_index

  name_raw = "${local.type}-${var.application_code}-${var.environment}-${local.object_index}"

  # Event Hubs namespaces allow hyphens and fit the standard pattern; only the
  # global-uniqueness suffix is added.
  name = "${local.name_raw}-${random_string.suffix.result}"

  # The suffix VALUE is unknown at plan, but its LENGTH is not — computing the
  # budget from lengths keeps the precondition evaluable at plan time.
  name_length = length(local.type) + 1 + length(var.application_code) + 1 + length(var.environment) + 1 + 3 + 1 + 4

  # Event Hubs exposes a single "namespace" sub-resource for private endpoints.
  default_subresources = ["namespace"]
  pe_targets = length(var.networking.private_endpoints) > 0 ? var.networking.private_endpoints : {
    for s in local.default_subresources : s => { private_ip_address = null }
  }

  # Premium budgets are namespace-wide and scale with Processing Units.
  total_partitions = sum(concat([0], [for hub in var.event_hubs : hub.partition_count]))
  partition_budget = var.processing_units * 200
  event_hub_budget = var.processing_units * 100

  # Flatten hub -> consumer groups into one map so adding a group never
  # re-addresses the others.
  consumer_groups = {
    for pair in flatten([
      for hub_name, hub in var.event_hubs : [
        for group in hub.consumer_groups : {
          key           = "${hub_name}/${group}"
          eventhub_name = hub_name
          name          = group
        }
      ]
    ]) : pair.key => pair
  }

  governance_tags = {
    company = var.company
    owner   = var.owner
  }

  tracking_tags = {
    managed_by     = "terraform"
    source_repo    = var.source_repo
    module_name    = local.module_name
    module_version = trimspace(file("${path.module}/VERSION"))
    deployed_by    = data.azurerm_client_config.current.object_id
  }

  # merge order: a caller's tags cannot override a governance or tracking tag.
  all_tags = merge(var.tags, local.governance_tags, local.tracking_tags)
}

# ------------------------------------------------------------------------------
# Identity and self-grant — created only for CMK, and before the namespace, so
# the key is reachable at the moment encryption is applied.
# ------------------------------------------------------------------------------

data "azurerm_role_definition" "kv_crypto_user" {
  count = var.encryption.enabled ? 1 : 0
  name  = "[${upper(var.environment)}] Key Vault Crypto User"
}

resource "azurerm_user_assigned_identity" "this" {
  count               = var.encryption.enabled ? 1 : 0
  name                = "id-${local.name}"
  location            = var.location
  resource_group_name = var.target_resource_group_name
  tags                = local.all_tags
}

resource "azurerm_role_assignment" "cmk" {
  count = var.encryption.enabled ? 1 : 0

  # An ARM resource ID scoped on the key itself — not the vault, not the version.
  scope              = var.encryption.key_resource_id
  role_definition_id = data.azurerm_role_definition.kv_crypto_user[0].id
  principal_id       = azurerm_user_assigned_identity.this[0].principal_id
}

# ------------------------------------------------------------------------------
# Event Hubs namespace (Premium)
# ------------------------------------------------------------------------------

resource "azurerm_eventhub_namespace" "this" {
  name                = local.name
  location            = var.location
  resource_group_name = var.target_resource_group_name

  sku      = "Premium"
  capacity = var.processing_units

  # Forbidden configurations, enforced here.
  public_network_access_enabled = false
  minimum_tls_version           = "1.2"
  local_authentication_enabled  = false # Entra ID only; no SAS keys on this namespace.
  auto_inflate_enabled          = false # a Standard-tier mechanism; Premium scales by PU.

  network_rulesets {
    default_action                 = "Deny"
    public_network_access_enabled  = false
    trusted_service_access_enabled = true
  }

  dynamic "identity" {
    for_each = var.encryption.enabled ? [1] : []
    content {
      type         = "UserAssigned"
      identity_ids = [azurerm_user_assigned_identity.this[0].id]
    }
  }

  tags = local.all_tags

  lifecycle {
    precondition {
      condition     = local.name_length <= 50
      error_message = "Composed namespace name '${local.name_raw}-<suffix>' is ${local.name_length} characters, over the 50-character limit; shorten application_code."
    }

    # Per-variable validation cannot see processing_units, so the two
    # namespace-wide Premium budgets are checked here.
    precondition {
      condition     = local.total_partitions <= local.partition_budget
      error_message = "Premium allows 200 partitions per PU: ${local.total_partitions} requested, ${local.partition_budget} available at ${var.processing_units} PU(s). Raise processing_units or shrink partition counts."
    }

    precondition {
      condition     = length(var.event_hubs) <= local.event_hub_budget
      error_message = "Premium allows 100 event hubs per PU: ${length(var.event_hubs)} requested, ${local.event_hub_budget} available at ${var.processing_units} PU(s)."
    }
  }
}

# ------------------------------------------------------------------------------
# Customer-managed key
#
# Azure rejects encryption on a namespace that already contains event hubs, so
# this lands between the namespace and the hubs. key_vault_key_ids takes the
# data-plane key URI; encryption.key_resource_id (the ARM ID) is only ever used
# as the role assignment scope above.
# ------------------------------------------------------------------------------

resource "azurerm_eventhub_namespace_customer_managed_key" "this" {
  count = var.encryption.enabled ? 1 : 0

  eventhub_namespace_id     = azurerm_eventhub_namespace.this.id
  key_vault_key_ids         = [var.encryption.key_id]
  user_assigned_identity_id = azurerm_user_assigned_identity.this[0].id

  depends_on = [azurerm_role_assignment.cmk]
}

# ------------------------------------------------------------------------------
# Event hubs and their consumer groups
# ------------------------------------------------------------------------------

resource "azurerm_eventhub" "this" {
  for_each = var.event_hubs

  name            = each.key
  namespace_id    = azurerm_eventhub_namespace.this.id
  partition_count = each.value.partition_count
  status          = each.value.status

  # Retention is driven entirely through retention_description. The resource's
  # message_retention argument caps at 7 days on a shared parent namespace, and
  # setting both is what produces a perpetual diff.
  retention_description {
    cleanup_policy                    = each.value.cleanup_policy
    retention_time_in_hours           = each.value.cleanup_policy == "Delete" ? each.value.message_retention * 24 : null
    tombstone_retention_time_in_hours = each.value.cleanup_policy == "Compact" ? each.value.tombstone_retention_hours : null
  }

  # The namespace must still be empty when the CMK is applied.
  depends_on = [azurerm_eventhub_namespace_customer_managed_key.this]
}

resource "azurerm_eventhub_consumer_group" "this" {
  for_each = local.consumer_groups

  name                = each.value.name
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.this[each.value.eventhub_name].name
  resource_group_name = var.target_resource_group_name
}

# ------------------------------------------------------------------------------
# Private endpoint(s) — no Private DNS zone group; DNS is wired externally.
# ------------------------------------------------------------------------------

resource "azurerm_private_endpoint" "this" {
  for_each            = local.pe_targets
  name                = "pe-${local.name}-${each.key}"
  location            = var.location
  resource_group_name = var.target_resource_group_name
  subnet_id           = var.networking.subnet_id

  private_service_connection {
    name                           = "psc-${local.name}-${each.key}"
    private_connection_resource_id = azurerm_eventhub_namespace.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  dynamic "ip_configuration" {
    for_each = each.value.private_ip_address != null ? [1] : []
    content {
      name               = "ipconfig-${each.key}"
      private_ip_address = each.value.private_ip_address
      subresource_name   = each.key
      member_name        = each.key
    }
  }

  tags = local.all_tags
  # No private_dns_zone_group — DNS is registered externally from the
  # private_endpoint_dns output.
}

# ------------------------------------------------------------------------------
# Optional management lock
# ------------------------------------------------------------------------------

resource "azurerm_management_lock" "this" {
  for_each = var.lock.enabled ? { this = var.lock } : {}

  name       = "lock-${local.name}"
  scope      = azurerm_eventhub_namespace.this.id
  lock_level = each.value.level
  notes      = "Managed by the eventhub module."
}
