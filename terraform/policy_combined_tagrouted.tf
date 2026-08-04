# ── Single-setting policy, TAG-ROUTED variant (prod / non-prod Event Hubs) ───
#
# Same single diagnostic setting (allLogs + AllMetrics) as policy_combined.tf,
# but ONE assignment routes each resource to a prod or non-prod Event Hub based
# on the `environment` tag of the resource's SUBSCRIPTION — no prod/non-prod
# management group split required. subscription() is a supported policy
# function and resolves in the context of the evaluated resource, so the
# expressions below read the containing subscription's tags at evaluation time.
#
#   * Tag value in diagnostics_prod_tag_values (default: pprod, prod) → prod hub.
#   * Anything else — dev, uat, unknown values, or a MISSING tag → non-prod hub.
#     Non-prod is the deliberate safe default: prod telemetry leaking into the
#     non-prod hub is worse than the reverse. tryGet() guards the missing-tag
#     case (a bare tags[] lookup on an untagged subscription throws, and a
#     failed function evaluation is treated as deny).
#   * The existenceCondition uses the SAME expression as the deployment, so
#     compliance is checked against the correct hub per subscription.
#   * Tag hygiene becomes load-bearing: whoever can edit subscription tags can
#     reroute telemetry. Pair with a policy governing the tag if adopted.
#   * Everything else is inherited from the combined policy's trade-offs (see
#     policy_combined.tf header): metric-emitting types only, single region,
#     new/updated resources only.
#
# Enabled with diagnostics_eventhub_tag_routing = true (on top of the usual
# diagnostics_policy_management_group_id + diagnostics_combined_policy_enabled).
# policy_combined.tf gates itself OFF when this variant is on, so exactly one
# of the two deploys. Non-prod hub = the single-hub locals (this project's hub
# by default); the prod hub must be supplied via
# diagnostics_prod_eventhub_auth_rule_id (+ optional diagnostics_prod_eventhub_name).

locals {
  diag_tagrouted_enabled = (
    local.diag_policy_enabled
    && var.diagnostics_combined_policy_enabled
    && var.diagnostics_eventhub_tag_routing
  )

  # Policy-language fragments (evaluated by the POLICY engine per resource, NOT
  # by Terraform). toLower() makes the tag-value comparison case-insensitive —
  # diagnostics_prod_tag_values must therefore be lowercase.
  diag_env_tag_lookup = "toLower(coalesce(tryGet(subscription().tags, parameters('environmentTagName')), '__untagged__'))"
  diag_is_prod_expr   = "contains(parameters('prodTagValues'), ${local.diag_env_tag_lookup})"

  # Hub selection expressions, shared by the existenceCondition and the DINE
  # deployment parameters so remediation and compliance always agree.
  diag_tagrouted_eh_rule_expr = "[if(${local.diag_is_prod_expr}, parameters('prodEventHubAuthorizationRuleId'), parameters('nonprodEventHubAuthorizationRuleId'))]"
  diag_tagrouted_eh_name_expr = "[if(${local.diag_is_prod_expr}, parameters('prodEventHubName'), parameters('nonprodEventHubName'))]"
}

resource "azurerm_policy_definition" "logs_metrics_to_eventhub_tagrouted" {
  count = local.diag_tagrouted_enabled ? 1 : 0

  name                = "deploy-logs-metrics-to-eventhub-tagrouted"
  display_name        = "Deploy allLogs + AllMetrics diagnostic setting to Event Hub (tag-routed)"
  description         = "DeployIfNotExists: streams allLogs and AllMetrics from supported resource types into a single diagnostic setting, routed to the prod or non-prod Event Hub by the subscription's environment tag."
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
    environmentTagName = {
      type         = "String"
      defaultValue = "environment"
      metadata = {
        displayName = "Subscription tag holding the environment"
        description = "Tag on the resource's SUBSCRIPTION whose value selects the Event Hub."
      }
    }
    prodTagValues = {
      type = "Array"
      metadata = {
        displayName = "Tag values routed to the prod Event Hub"
        description = "Lowercase environment tag values treated as production. All other values, and subscriptions missing the tag, route to the non-prod hub."
      }
    }
    prodEventHubAuthorizationRuleId = {
      type = "String"
      metadata = {
        displayName = "Prod Event Hub authorization rule ID"
        strongType  = "Microsoft.EventHub/Namespaces/AuthorizationRules"
      }
    }
    prodEventHubName = {
      type = "String"
      metadata = {
        displayName = "Prod Event Hub name"
      }
    }
    nonprodEventHubAuthorizationRuleId = {
      type = "String"
      metadata = {
        displayName = "Non-prod Event Hub authorization rule ID"
        strongType  = "Microsoft.EventHub/Namespaces/AuthorizationRules"
      }
    }
    nonprodEventHubName = {
      type = "String"
      metadata = {
        displayName = "Non-prod Event Hub name"
      }
    }
    resourceTypeList = {
      type = "Array"
      metadata = {
        displayName = "Resource types to target"
        description = "Resource types evaluated for the combined logs+metrics diagnostic setting. Must be metric-emitting types — AllMetrics fails on types without metrics."
      }
    }
    resourceLocations = {
      type = "Array"
      metadata = {
        displayName = "Resource locations this assignment serves"
        description = "Regions whose resources route to THIS assignment's Event Hubs. An Event Hub destination must be in the same region as the monitored resource, so each assignment carries exactly its own region — plus 'global' on the single primary assignment, to cover non-regional resources once."
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field = "type"
          in    = "[parameters('resourceTypeList')]"
        },
        # Region guard. resourceSelectors on the assignment does the same job,
        # but that is an assignment property anyone with write access can drop;
        # this one travels with the definition and cannot be removed by editing
        # an assignment. Without it, three regional assignments each match every
        # resource in the estate and fight over the same diagnostic setting.
        {
          field = "location"
          in    = "[parameters('resourceLocations')]"
        },
      ]
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
          equals = local.diag_tagrouted_eh_rule_expr
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
            # The hub expressions are resolved by the POLICY engine before the
            # deployment is submitted — the inner template above only ever sees
            # plain strings and is identical to the single-hub variant.
            parameters = {
              resourceScope               = { value = "[concat(field('type'), '/', field('fullName'))]" }
              diagnosticSettingName       = { value = "[parameters('diagnosticSettingName')]" }
              eventHubAuthorizationRuleId = { value = local.diag_tagrouted_eh_rule_expr }
              eventHubName                = { value = local.diag_tagrouted_eh_name_expr }
            }
          }
        }
      }
    }
  })
}

# NB: management group policy assignment names are capped at 24 characters.
resource "azurerm_management_group_policy_assignment" "logs_metrics_to_eventhub_tagrouted" {
  for_each = local.diag_tagrouted_enabled ? local.diag_regions : {}

  name                 = local.diag_tagrouted_assignment_names[each.key]
  display_name         = "Deploy allLogs + AllMetrics to Event Hub (tag-routed, ${each.key})"
  description          = "Streams allLogs and AllMetrics into a single diagnostic setting per resource in ${each.key}${each.value.primary ? " (+ non-regional resources)" : ""}. Hub selected by the subscription's '${var.diagnostics_environment_tag_name}' tag: ${join("/", var.diagnostics_prod_tag_values)} → prod hub, everything else (incl. untagged) → non-prod hub."
  management_group_id  = var.diagnostics_policy_management_group_id
  policy_definition_id = azurerm_policy_definition.logs_metrics_to_eventhub_tagrouted[0].id
  location             = each.key

  identity {
    type = "SystemAssigned"
  }

  # Second layer of the region guard (the first is the `location` condition in
  # the definition's policy rule). Filtering here means out-of-region resources
  # are never evaluated, so the compliance dashboard shows real problems only.
  resource_selectors {
    name = "region"
    selectors {
      kind = "resourceLocation"
      in   = each.value.locations
    }
  }

  parameters = jsonencode({
    environmentTagName                 = { value = var.diagnostics_environment_tag_name }
    prodTagValues                      = { value = var.diagnostics_prod_tag_values }
    prodEventHubAuthorizationRuleId    = { value = each.value.prod_auth_rule_id }
    prodEventHubName                   = { value = each.value.prod_event_hub_name }
    nonprodEventHubAuthorizationRuleId = { value = each.value.nonprod_auth_rule_id }
    nonprodEventHubName                = { value = each.value.nonprod_event_hub_name }
    resourceTypeList                   = { value = var.diagnostics_metrics_resource_types }
    resourceLocations                  = { value = each.value.locations }
  })

  lifecycle {
    precondition {
      condition     = each.value.prod_auth_rule_id != null
      error_message = "diagnostics_eventhub_tag_routing requires a prod Event Hub Send rule for every region: set prod_auth_rule_id on each diagnostics_regions entry (or diagnostics_prod_eventhub_auth_rule_id in single-region mode)."
    }
  }
}

# Policy identity needs the roles declared in roleDefinitionIds: Log Analytics
# Contributor (write diagnostic settings) + Azure Event Hubs Data Owner
# (data-plane write to the hub). Granted at MG scope.
resource "azurerm_role_assignment" "tagrouted_policy" {
  for_each = local.diag_tagrouted_enabled ? local.diag_region_role_pairs : {}

  scope                = var.diagnostics_policy_management_group_id
  role_definition_name = each.value.role
  principal_id         = azurerm_management_group_policy_assignment.logs_metrics_to_eventhub_tagrouted[each.value.region].identity[0].principal_id
}

# Each region's identity must also write to that region's PROD namespace, which
# may live outside the assigned management group. Grant Data Owner directly on
# the namespace (derived from the auth rule ID). Harmless overlap if the
# namespace is inside the MG anyway.
resource "azurerm_role_assignment" "tagrouted_policy_prod_hub" {
  for_each = local.diag_tagrouted_enabled ? {
    for region, cfg in local.diag_regions : region => cfg
    if cfg.prod_auth_rule_id != null
  } : {}

  scope                = regex("^(.+)/authorizationRules/[^/]+$", each.value.prod_auth_rule_id)[0]
  role_definition_name = "Azure Event Hubs Data Owner"
  principal_id         = azurerm_management_group_policy_assignment.logs_metrics_to_eventhub_tagrouted[each.key].identity[0].principal_id
}
