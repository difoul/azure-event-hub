# ── Storage: Cribl config persistence ────────────────────────────────────────
# Without persistent storage, all Cribl configuration (sources, pipelines,
# routes, destinations) is lost every time the container restarts. Azure Files
# mounted at /opt/cribl/config-volume keeps config across restarts and redeployments.

resource "random_id" "cribl_storage" {
  byte_length = 4
}

resource "azurerm_storage_account" "cribl" {
  name                     = "stcribl${random_id.cribl_storage.hex}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.common_tags

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    virtual_network_subnet_ids = [azurerm_subnet.container_apps.id]
  }
}

resource "azurerm_storage_share" "cribl" {
  name               = "cribl-config"
  storage_account_id = azurerm_storage_account.cribl.id
  quota              = 5
}

# Register the Azure Files share with the Container Apps Environment so
# Container Apps can reference it by name in volume mounts.
resource "azurerm_container_app_environment_storage" "cribl" {
  name                         = "cribl-config"
  container_app_environment_id = azurerm_container_app_environment.main.id
  account_name                 = azurerm_storage_account.cribl.name
  share_name                   = azurerm_storage_share.cribl.name
  access_key                   = azurerm_storage_account.cribl.primary_access_key
  access_mode                  = "ReadWrite"
}

# ── Cribl Admin Password ──────────────────────────────────────────────────────
resource "random_password" "cribl_admin" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}|"
}

# ── Cribl Stream Container App ────────────────────────────────────────────────
resource "azurerm_container_app" "cribl" {
  name                         = "cribl-stream"
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  revision_mode                = "Single"

  secret {
    name  = "cribl-admin-password"
    value = random_password.cribl_admin.result
  }

  secret {
    name  = "cribl-connection-string"
    value = azurerm_eventhub_namespace_authorization_rule.cribl.primary_connection_string
  }

  template {
    # Single instance — Cribl Stream single-node mode.
    # Scaling to multiple replicas requires Cribl Stream distributed mode (leader/worker).
    min_replicas = 1
    max_replicas = 1

    container {
      name  = "cribl"
      image = var.cribl_image
      cpu   = 1.0
      memory = "2Gi"

      env {
        name        = "CRIBL_ADMIN_PASSWORD"
        secret_name = "cribl-admin-password"
      }

      # CRIBL_VOLUME_DIR tells Cribl where to persist its config.
      # This must match the volume mount path below.
      env {
        name  = "CRIBL_VOLUME_DIR"
        value = "/opt/cribl/config-volume"
      }

      # Pre-populate the Event Hub connection string as an env var so it is
      # available to paste into the Cribl UI without needing to run terraform output.
      env {
        name        = "AZURE_EVENTHUB_CONNECTION_STRING"
        secret_name = "cribl-connection-string"
      }

      volume_mounts {
        name = "cribl-config"
        path = "/opt/cribl/config-volume"
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/api/v1/health"
        port      = 9000

        initial_delay           = 15
        interval_seconds        = 30
        timeout                 = 5
        failure_count_threshold = 3
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/api/v1/health"
        port      = 9000

        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }

    volume {
      name         = "cribl-config"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.cribl.name
    }
  }

  ingress {
    external_enabled = true
    target_port      = 9000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  tags = local.common_tags
}
