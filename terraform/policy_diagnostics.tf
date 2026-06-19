# ── Diagnostic Settings at scale via Azure Policy ────────────────────────────
#
# Instead of hand-writing one azurerm_monitor_diagnostic_setting per resource
# (see monitoring.tf), this assigns the built-in DeployIfNotExists initiative
# "Enable allLogs category group resource logging for supported resources to
# Event Hub" (140 per-resource-type policies) to a management group. Any
# supported resource created/updated under that MG automatically gets a
# diagnostic setting streaming its allLogs category group to the Event Hub.
#
# Scope:        management group (var.diagnostics_policy_management_group_id)
# Breadth:      allLogs category group (every log category, not just audit)
# Remediation:  none — DeployIfNotExists fires on resource create/update only.
#               Existing resources stay untouched until changed, or until a
#               remediation task is run manually (see notes at bottom).
#
# IMPORTANT — logs only, single region:
#   * This initiative configures resource LOGS. Platform METRICS (AllMetrics)
#     are NOT covered by the built-in category-group initiatives; metrics at
#     scale require custom DINE policies per resource type.
#   * The Event Hub destination supports a single region. Only resources in
#     var.diagnostics_policy_resource_location receive settings. To cover other
#     regions, assign this initiative again per region, each pointing at a hub
#     in that region.

locals {
  diag_policy_enabled = var.diagnostics_policy_management_group_id != null

  diag_eh_auth_rule_id = coalesce(
    var.diagnostics_policy_event_hub_auth_rule_id,
    azurerm_eventhub_namespace_authorization_rule.diagnostics.id,
  )
  diag_eh_name = coalesce(
    var.diagnostics_policy_event_hub_name,
    azurerm_eventhub.main.name,
  )
  diag_resource_location = coalesce(
    var.diagnostics_policy_resource_location,
    var.location,
  )
}

# Built-in initiative (policy set). Referenced by display name so we don't pin a
# GUID; the definition is tenant-global and available without a count guard.
data "azurerm_policy_set_definition" "diag_to_eventhub" {
  display_name = "Enable allLogs category group resource logging for supported resources to Event Hub"
}

resource "azurerm_management_group_policy_assignment" "diag_to_eventhub" {
  count = local.diag_policy_enabled ? 1 : 0

  name                 = "diag-alllogs-to-evh"
  display_name         = "Enable allLogs resource logging to Event Hub"
  description          = "DeployIfNotExists: streams the allLogs category group from supported resources to the central Event Hub for Cribl. Applies to new/updated resources in ${local.diag_resource_location}."
  management_group_id  = var.diagnostics_policy_management_group_id
  policy_definition_id = data.azurerm_policy_set_definition.diag_to_eventhub.id

  # Required because the DeployIfNotExists effect needs a managed identity to
  # create the diagnostic settings. location pins where that identity lives.
  location = local.diag_resource_location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    eventHubAuthorizationRuleId = { value = local.diag_eh_auth_rule_id }
    eventHubName                = { value = local.diag_eh_name }
    resourceLocation            = { value = local.diag_resource_location }
  })
}

# The policy's managed identity must hold the roles listed in the initiative's
# roleDefinitionIds to deploy diagnostic settings to Event Hub. The built-in
# category-group EH policies declare Log Analytics Contributor (control plane:
# diagnosticSettings/write) AND Azure Event Hubs Data Owner (data plane: needed
# to write a setting that targets the hub). Monitoring Contributor is NOT enough
# — it lacks the Event Hubs data-plane right. Granted at the MG scope so it
# covers every resource the initiative may target.
resource "azurerm_role_assignment" "diag_policy" {
  for_each = local.diag_policy_enabled ? toset([
    "Log Analytics Contributor",
    "Azure Event Hubs Data Owner",
  ]) : toset([])

  scope                = var.diagnostics_policy_management_group_id
  role_definition_name = each.value
  principal_id         = azurerm_management_group_policy_assignment.diag_to_eventhub[0].identity[0].principal_id
}

# ── Applying to existing resources (optional, manual) ────────────────────────
# This assignment only auto-deploys to new/updated resources. To backfill
# existing resources later, trigger a compliance scan then create one
# remediation task per inner policy, e.g.:
#
#   az policy state trigger-scan --scope <mg-scope>
#   for ref in $(az policy set-definition show \
#       --name <initiative-guid> \
#       --query "policyDefinitions[].policyDefinitionReferenceId" -o tsv); do
#     az policy remediation create \
#       --name "remediate-$ref" \
#       --policy-assignment diag-alllogs-to-evh \
#       --definition-reference-id "$ref" \
#       --resource-discovery-mode ReEvaluateCompliance \
#       --management-group <mg-name>
#   done
