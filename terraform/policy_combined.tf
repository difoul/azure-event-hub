# ── Logs + Metrics in ONE diagnostic setting (single-setting alternative) ─────
#
# ALTERNATIVE to running policy_diagnostics.tf (built-in allLogs initiative) +
# policy_metrics.tf (custom AllMetrics policy) side by side. Those two write TWO
# diagnostic settings per resource, consuming 2 of Azure's 5-setting cap. This
# file collapses both into a SINGLE custom DeployIfNotExists policy that writes
# ONE diagnostic setting carrying both `logs: [allLogs]` and `metrics: [AllMetrics]`.
#
# Disabled by default and gated on its own toggle so it never double-deploys
# alongside the other two. To test: set diagnostics_combined_policy_enabled=true
# AND ensure the other two assignments are NOT also applied to the same scope
# (otherwise resources get duplicate settings → defeats the purpose / hits the cap).
#
# ── The trade-off the team needs to weigh ────────────────────────────────────
#   * SCOPE IS THE METRIC-EMITTING TYPE LIST. AllMetrics fails remediation on
#     types that emit no metrics, so the `if` can only target metric-emitting
#     types (var.diagnostics_metrics_resource_types). Log-only resource types
#     (in MG but not in that list) get NOTHING from this policy — they would
#     still need the built-in logs initiative. So this is "one setting per
#     metric-emitting resource", not "one policy for the entire estate".
#   * allLogs is a category GROUP, generic across types — a metric-emitting type
#     with no log categories simply exports no logs (the setting still applies).
#   * You give up the Microsoft-MAINTAINED built-in logs initiative and own the
#     logs half here too.
#   * Same single-region constraint and new/updated-only behaviour (no
#     remediation task) as the other two.
#
# Reuses the locals from policy_diagnostics.tf (diag_policy_enabled,
# diag_eh_auth_rule_id, diag_eh_name, diag_resource_location) and the same
# var.diagnostics_metrics_resource_types as policy_metrics.tf.

locals {
  diag_combined_enabled = local.diag_policy_enabled && var.diagnostics_combined_policy_enabled
}

resource "azurerm_policy_definition" "logs_metrics_to_eventhub" {
  count = local.diag_combined_enabled ? 1 : 0

  name                = "deploy-logs-metrics-to-eventhub"
  display_name        = "Deploy allLogs + AllMetrics diagnostic setting to Event Hub"
  description         = "DeployIfNotExists: streams allLogs and AllMetrics from supported resource types to the central Event Hub for Cribl, in a single diagnostic setting."
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
      defaultValue = "setByPolicy-LogsMetrics-EventHub"
      metadata = {
        displayName = "Diagnostic setting name"
      }
    }
    eventHubAuthorizationRuleId = {
      type = "String"
      metadata = {
        displayName       = "Event Hub authorization rule ID"
        strongType        = "Microsoft.EventHub/Namespaces/AuthorizationRules"
        assignPermissions = true
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
        description = "Resource types evaluated for the combined logs+metrics diagnostic setting. Must be metric-emitting types — AllMetrics fails on types without metrics."
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
          # Hubs Data Owner (data-plane write to the hub) — same pair as the
          # logs and metrics policies.
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
                # Relative scope (<type>/<fullName>) — how an extension resource
                # attaches generically without hardcoding the parent type.
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
                    # Both halves in ONE setting. allLogs is a generic category
                    # group; AllMetrics is the generic metrics category.
                    logs = [
                      {
                        categoryGroup = "allLogs"
                        enabled       = true
                      }
                    ]
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

resource "azurerm_management_group_policy_assignment" "logs_metrics_to_eventhub" {
  count = local.diag_combined_enabled ? 1 : 0

  name                 = "diag-logs-metrics-to-evh"
  display_name         = "Deploy allLogs + AllMetrics to Event Hub"
  description          = "Streams allLogs and AllMetrics from supported resource types to the Event Hub for Cribl in a single diagnostic setting. Applies to new/updated resources in ${local.diag_resource_location}."
  management_group_id  = var.diagnostics_policy_management_group_id
  policy_definition_id = azurerm_policy_definition.logs_metrics_to_eventhub[0].id
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

# Policy identity needs the roles declared in roleDefinitionIds: Log Analytics
# Contributor (write diagnostic settings) + Azure Event Hubs Data Owner
# (data-plane write to the hub). Granted at MG scope.
resource "azurerm_role_assignment" "combined_policy" {
  for_each = local.diag_combined_enabled ? toset([
    "Log Analytics Contributor",
    "Azure Event Hubs Data Owner",
  ]) : toset([])

  scope                = var.diagnostics_policy_management_group_id
  role_definition_name = each.value
  principal_id         = azurerm_management_group_policy_assignment.logs_metrics_to_eventhub[0].identity[0].principal_id
}
