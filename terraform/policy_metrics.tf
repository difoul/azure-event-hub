# ── Metrics at scale via a single generic DeployIfNotExists policy ────────────
#
# Companion to policy_diagnostics.tf (which handles LOGS via the built-in
# allLogs initiative). The built-in initiatives don't configure platform
# metrics, and DCR metrics export covers only ~10 resource types — so to get
# ONE solution spanning every resource type, this defines a single custom DINE
# policy that deploys an AllMetrics diagnostic setting to the Event Hub.
#
# Why one policy works for all types: Microsoft.Insights/diagnosticSettings is
# an extension resource, so the embedded deployment targets the resource via
# `scope` ([field('id')]) instead of hardcoding the parent type. The `if`
# matches a parameterized resource-type list (var.diagnostics_metrics_resource_types)
# so only metric-emitting types are touched — listing a type without AllMetrics
# would otherwise produce failed remediations.
#
# Caveats (inherent to the diagnostic-settings route):
#   * Metric DIMENSIONS are dropped on export. Use DCR metrics export per-type
#     if you need dimensions (supports ~10 types only).
#   * Single region: the resource and Event Hub must share a region
#     (local.diag_resource_location), same constraint as the logs initiative.
#   * New/updated resources only — no remediation task, matching the logs setup.
#   * Writes a distinct diagnostic setting (setByPolicy-Metrics-EventHub) so it
#     coexists with the logs setting; Azure allows up to 5 per resource.
#
# Gated on the same var.diagnostics_policy_management_group_id and reuses the
# locals (diag_policy_enabled, diag_eh_auth_rule_id, diag_eh_name,
# diag_resource_location) defined in policy_diagnostics.tf.

resource "azurerm_policy_definition" "metrics_to_eventhub" {
  count = local.diag_policy_enabled ? 1 : 0

  name                = "deploy-metrics-to-eventhub"
  display_name        = "Deploy AllMetrics diagnostic settings to Event Hub"
  description         = "DeployIfNotExists: streams AllMetrics from supported resource types to the central Event Hub for Cribl."
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = var.diagnostics_policy_management_group_id

  metadata = jsonencode({
    category = "Monitoring"
  })

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["DeployIfNotExists", "AuditIfNotExists", "Disabled"]
      defaultValue  = "DeployIfNotExists"
      metadata = {
        displayName = "Effect"
        description = "Enable or disable execution of the policy."
      }
    }
    diagnosticSettingName = {
      type         = "String"
      defaultValue = "setByPolicy-Metrics-EventHub"
      metadata = {
        displayName = "Diagnostic setting name"
      }
    }
    eventHubAuthorizationRuleId = {
      type = "String"
      metadata = {
        displayName      = "Event Hub authorization rule ID"
        strongType       = "Microsoft.EventHub/namespaces/authorizationRules"
        assignPermission = true
      }
    }
    eventHubName = {
      type = "String"
      metadata = {
        displayName = "Event Hub name"
      }
    }
    resourceTypeList = {
      type = "Array"
      metadata = {
        displayName = "Resource types to target"
        description = "Resource types evaluated for the AllMetrics diagnostic setting."
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      field = "type"
      in    = "[parameters('resourceTypeList')]"
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        name = "[parameters('diagnosticSettingName')]"
        roleDefinitionIds = [
          # Log Analytics Contributor (diagnosticSettings/write) + Azure Event
          # Hubs Data Owner (data-plane write to the hub) — the same pair the
          # built-in EH diagnostic policies declare.
          "/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293",
          "/providers/Microsoft.Authorization/roleDefinitions/f526a384-b230-433a-b45c-95f59c4a2dec",
        ]
        existenceCondition = {
          field  = "Microsoft.Insights/diagnosticSettings/eventHubAuthorizationRuleId"
          equals = "[parameters('eventHubAuthorizationRuleId')]"
        }
        deployment = {
          properties = {
            mode = "incremental"
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                # Relative scope of the evaluated resource (<type>/<fullName>),
                # e.g. "Microsoft.KeyVault/vaults/myvault". This is how an
                # extension resource attaches generically without hardcoding the
                # parent type — a full resource ID is NOT valid for `scope`.
                resourceScope               = { type = "string" }
                diagnosticSettingName       = { type = "string" }
                eventHubAuthorizationRuleId = { type = "string" }
                eventHubName                = { type = "string" }
              }
              resources = [
                {
                  type       = "Microsoft.Insights/diagnosticSettings"
                  apiVersion = "2021-05-01-preview"
                  name       = "[parameters('diagnosticSettingName')]"
                  scope      = "[parameters('resourceScope')]"
                  properties = {
                    eventHubAuthorizationRuleId = "[parameters('eventHubAuthorizationRuleId')]"
                    eventHubName                = "[parameters('eventHubName')]"
                    metrics = [
                      {
                        category = "AllMetrics"
                        enabled  = true
                      }
                    ]
                  }
                }
              ]
            }
            parameters = {
              resourceScope               = { value = "[concat(field('type'), '/', field('fullName'))]" }
              diagnosticSettingName       = { value = "[parameters('diagnosticSettingName')]" }
              eventHubAuthorizationRuleId = { value = "[parameters('eventHubAuthorizationRuleId')]" }
              eventHubName                = { value = "[parameters('eventHubName')]" }
            }
          }
        }
      }
    }
  })
}

resource "azurerm_management_group_policy_assignment" "metrics_to_eventhub" {
  count = local.diag_policy_enabled ? 1 : 0

  name                 = "diag-metrics-to-evh"
  display_name         = "Deploy AllMetrics to Event Hub"
  description          = "Streams AllMetrics from supported resource types to the Event Hub for Cribl. Applies to new/updated resources in ${local.diag_resource_location}."
  management_group_id  = var.diagnostics_policy_management_group_id
  policy_definition_id = azurerm_policy_definition.metrics_to_eventhub[0].id
  location             = local.diag_resource_location

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    eventHubAuthorizationRuleId = { value = local.diag_eh_auth_rule_id }
    eventHubName                = { value = local.diag_eh_name }
    resourceTypeList            = { value = var.diagnostics_metrics_resource_types }
  })
}

# The policy identity needs the same roles declared in the policy's
# roleDefinitionIds: Log Analytics Contributor (write diagnostic settings) +
# Azure Event Hubs Data Owner (data-plane write to the hub). Granted at MG scope.
resource "azurerm_role_assignment" "metrics_policy" {
  for_each = local.diag_policy_enabled ? toset([
    "Log Analytics Contributor",
    "Azure Event Hubs Data Owner",
  ]) : toset([])

  scope                = var.diagnostics_policy_management_group_id
  role_definition_name = each.value
  principal_id         = azurerm_management_group_policy_assignment.metrics_to_eventhub[0].identity[0].principal_id
}
