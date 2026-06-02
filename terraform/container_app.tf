resource "azurerm_container_app_environment" "main" {
  name                     = "cae-event-hub-demo"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  logs_destination         = "azure-monitor"
  infrastructure_subnet_id = azurerm_subnet.container_apps.id
  zone_redundancy_enabled  = true
  tags                     = local.common_tags

  lifecycle {
    ignore_changes = [
      infrastructure_resource_group_name,
      workload_profile,
    ]
  }
}

resource "azurerm_container_app" "main" {
  name                         = var.container_app_name
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.main.admin_password
  }

  registry {
    server               = azurerm_container_registry.main.login_server
    username             = azurerm_container_registry.main.admin_username
    password_secret_name = "acr-password"
  }

  template {
    min_replicas = 2
    max_replicas = 5

    container {
      name   = var.container_app_name
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      liveness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000

        initial_delay           = 5
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000

        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }

    http_scale_rule {
      name                = "http-scaling"
      concurrent_requests = tostring(var.http_scale_threshold)
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = local.common_tags
}
