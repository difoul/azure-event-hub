resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "main" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  display_name        = "${var.container_app_name} — Event Hub Monitoring"
  source_id           = "azure monitor"
  tags                = local.common_tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [

      # ── Parameters ──────────────────────────────────────────────────────────
      {
        type = 9
        content = {
          version                 = "KqlParameterItem/1.0"
          crossComponentResources = ["{Subscription}"]
          parameters = [
            {
              id         = "p0-subscription"
              version    = "KqlParameterItem/1.0"
              name       = "Subscription"
              label      = "Subscription"
              type       = 6
              isRequired = true
              typeSettings = {
                additionalSubscriptionIds = []
                includeAll               = false
              }
            },
            {
              id                      = "p1-container-app"
              version                 = "KqlParameterItem/1.0"
              name                    = "ContainerApp"
              label                   = "Container App"
              type                    = 5
              isRequired              = true
              multiSelect             = false
              query                   = "where type == 'microsoft.app/containerapps'\n| project id, name"
              crossComponentResources = ["{Subscription}"]
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = false
              }
            },
            {
              id                      = "p2-eventhub-namespace"
              version                 = "KqlParameterItem/1.0"
              name                    = "EventHubNamespace"
              label                   = "Event Hub Namespace"
              type                    = 5
              isRequired              = true
              multiSelect             = false
              query                   = "where type == 'microsoft.eventhub/namespaces'\n| project id, name"
              crossComponentResources = ["{Subscription}"]
              queryType               = 1
              resourceType            = "microsoft.resourcegraph/resources"
              typeSettings = {
                additionalResourceOptions = []
                showDefault               = false
              }
            },
            {
              id      = "p3-time-range"
              version = "KqlParameterItem/1.0"
              name    = "TimeRange"
              label   = "Time Range"
              type    = 4
              value   = { durationMs = 3600000 }
            }
          ]
        }
        name = "parameters"
      },

      # ── Section: Container App Infrastructure ────────────────────────────────
      {
        type    = 1
        content = { json = "## Container App — Infrastructure" }
        name    = "infra-header"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.app/containerapps"
          metricScope              = 0
          resourceIds              = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--UsageNanoCores"
            aggregation = 3
            splitBy     = null
          }]
          title = "CPU Usage — Maximum"
        }
        name = "cpu"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.app/containerapps"
          metricScope              = 0
          resourceIds              = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--WorkingSetBytes"
            aggregation = 4
            splitBy     = null
          }]
          title = "Memory Usage — Average"
        }
        name = "memory"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.app/containerapps"
          metricScope              = 0
          resourceIds              = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--Replicas"
            aggregation = 4
            splitBy     = null
          }]
          title = "Replica Count"
        }
        name = "replicas"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.app/containerapps"
          metricScope              = 0
          resourceIds              = ["{ContainerApp}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.app/containerapps"
            metric      = "microsoft.app/containerapps--RestartCount"
            aggregation = 1
            splitBy     = null
          }]
          title = "Container Restarts — Total"
        }
        name = "restarts"
      },

      # ── Section: Event Hub Pipeline ──────────────────────────────────────────
      {
        type    = 1
        content = { json = "## Event Hub — Log Pipeline" }
        name    = "eventhub-header"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.eventhub/namespaces"
          metricScope              = 0
          resourceIds              = ["{EventHubNamespace}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.eventhub/namespaces"
            metric      = "microsoft.eventhub/namespaces--IncomingMessages"
            aggregation = 1
            splitBy     = null
          }]
          title = "Incoming Messages — Total (diagnostic logs arriving)"
        }
        name = "eh-incoming"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.eventhub/namespaces"
          metricScope              = 0
          resourceIds              = ["{EventHubNamespace}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.eventhub/namespaces"
            metric      = "microsoft.eventhub/namespaces--OutgoingMessages"
            aggregation = 1
            splitBy     = null
          }]
          title = "Outgoing Messages — Total (Cribl consuming)"
        }
        name = "eh-outgoing"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.eventhub/namespaces"
          metricScope              = 0
          resourceIds              = ["{EventHubNamespace}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.eventhub/namespaces"
            metric      = "microsoft.eventhub/namespaces--ThrottledRequests"
            aggregation = 1
            splitBy     = null
          }]
          title = "Throttled Requests — Total (capacity pressure)"
        }
        name = "eh-throttled"
      },

      {
        type        = 10
        customWidth = "50"
        content = {
          version                  = "MetricsItem/2.0"
          size                     = 0
          chartType                = 2
          resourceType             = "microsoft.eventhub/namespaces"
          metricScope              = 0
          resourceIds              = ["{EventHubNamespace}"]
          timeContextFromParameter = "TimeRange"
          metrics = [{
            namespace   = "microsoft.eventhub/namespaces"
            metric      = "microsoft.eventhub/namespaces--IncomingBytes"
            aggregation = 1
            splitBy     = null
          }]
          title = "Incoming Bytes — Total"
        }
        name = "eh-bytes"
      }

    ]
    "$schema" = "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
  })
}
