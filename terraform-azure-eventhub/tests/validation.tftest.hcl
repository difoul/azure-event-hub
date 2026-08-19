mock_provider "azurerm" {}

variables {
  application_code           = "myapp"
  environment                = "dev"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-dev-001"
  company                    = "contoso"
  owner                      = "platform-team"
  source_repo                = "test"
  networking                 = { subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-pe" }
}

# ------------------------------------------------------------------------------
# Defaults and the fullest configuration — these catch wiring mistakes that no
# single validation rule would.
# ------------------------------------------------------------------------------

run "defaults_plan_cleanly" {
  command = plan
}

run "full_configuration_plans_cleanly" {
  command = plan

  variables {
    object_index     = "007"
    processing_units = 2

    event_hubs = {
      "evh-app-logs" = {
        partition_count   = 8
        message_retention = 30
        consumer_groups   = ["analytics", "archive"]
      }
      "evh-cdc-state" = {
        partition_count           = 4
        message_retention         = 90
        cleanup_policy            = "Compact"
        tombstone_retention_hours = 24
      }
      "evh-drained" = {
        partition_count   = 2
        message_retention = 1
        status            = "Disabled"
      }
    }

    networking = {
      subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-pe"
      private_endpoints = { namespace = { private_ip_address = "10.0.1.10" } }
    }

    encryption = {
      enabled         = true
      key_id          = "https://kv-myapp-dev.vault.azure.net/keys/cmk"
      key_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-kv/providers/Microsoft.KeyVault/vaults/kv-myapp-dev/keys/cmk"
    }

    lock = { enabled = true, level = "CanNotDelete" }
  }
}

# ------------------------------------------------------------------------------
# Base variables
# ------------------------------------------------------------------------------

run "rejects_unknown_environment" {
  command = plan

  variables {
    environment = "prod" # the valid value is prd
  }

  expect_failures = [var.environment]
}

run "rejects_non_three_digit_object_index" {
  command = plan

  variables {
    object_index = "12"
  }

  expect_failures = [var.object_index]
}

run "rejects_uppercase_application_code" {
  command = plan

  variables {
    application_code = "MyApp"
  }

  expect_failures = [var.application_code]
}

run "rejects_application_code_over_budget" {
  command = plan

  variables {
    application_code = "abcdefghijklmnopqrstuvwxyz0123456789"
  }

  expect_failures = [var.application_code]
}

# ------------------------------------------------------------------------------
# Service-specific: Premium tier limits
# ------------------------------------------------------------------------------

run "rejects_invalid_processing_units" {
  command = plan

  variables {
    processing_units = 3 # only 1, 2, 4, 6, 8, 10, 12, 16 exist
  }

  expect_failures = [var.processing_units]
}

run "rejects_partition_count_above_premium_limit" {
  command = plan

  variables {
    event_hubs = {
      "evh-app-logs" = {
        partition_count   = 101
        message_retention = 1
      }
    }
  }

  expect_failures = [var.event_hubs]
}

run "rejects_retention_above_premium_limit" {
  command = plan

  variables {
    event_hubs = {
      "evh-app-logs" = {
        partition_count   = 1
        message_retention = 91
      }
    }
  }

  expect_failures = [var.event_hubs]
}

run "rejects_unknown_cleanup_policy" {
  command = plan

  variables {
    event_hubs = {
      "evh-app-logs" = {
        partition_count   = 1
        message_retention = 1
        cleanup_policy    = "Truncate"
      }
    }
  }

  expect_failures = [var.event_hubs]
}

run "rejects_tombstone_retention_without_compaction" {
  command = plan

  variables {
    event_hubs = {
      "evh-app-logs" = {
        partition_count           = 1
        message_retention         = 1
        tombstone_retention_hours = 24
      }
    }
  }

  expect_failures = [var.event_hubs]
}

run "rejects_partitions_over_namespace_budget" {
  command = plan

  variables {
    processing_units = 1 # 200-partition budget
    event_hubs = {
      "evh-one"   = { partition_count = 100, message_retention = 1 }
      "evh-two"   = { partition_count = 100, message_retention = 1 }
      "evh-three" = { partition_count = 4, message_retention = 1 }
    }
  }

  expect_failures = [azurerm_eventhub_namespace.this]
}

# ------------------------------------------------------------------------------
# Interfaces
# ------------------------------------------------------------------------------

run "rejects_unsupported_private_endpoint_subresource" {
  command = plan

  variables {
    networking = {
      subnet_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-pe"
      private_endpoints = { vault = {} }
    }
  }

  expect_failures = [var.networking]
}

run "rejects_integration_subnet" {
  command = plan

  variables {
    networking = {
      subnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-pe"
      integration_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-hub/subnets/snet-integration"
    }
  }

  expect_failures = [var.networking]
}

run "requires_key_id_when_encryption_enabled" {
  command = plan

  variables {
    encryption = { enabled = true }
  }

  expect_failures = [var.encryption]
}

run "requires_arm_key_resource_id_when_encryption_enabled" {
  command = plan

  variables {
    encryption = {
      enabled = true
      key_id  = "https://kv-myapp-dev.vault.azure.net/keys/cmk"
      # key_resource_id omitted — Event Hubs needs the ARM ID for the CMK itself.
    }
  }

  expect_failures = [var.encryption]
}

run "rejects_invalid_lock_level" {
  command = plan

  variables {
    lock = { enabled = true, level = "ReadWrite" }
  }

  expect_failures = [var.lock]
}
