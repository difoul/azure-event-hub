# Bronze example: a Premium namespace with two event hubs behind a private
# endpoint, Microsoft-managed keys.
#
# To enable CMK, pass the keys module's outputs:
#
#   encryption = {
#     enabled         = true
#     key_id          = var.key_id          # https://<vault>.vault.azure.net/keys/<name>
#     key_resource_id = var.key_resource_id # /subscriptions/.../vaults/<vault>/keys/<name>
#   }

variable "subnet_id" {
  description = "Subnet the private endpoint is placed in."
  type        = string
}

module "eventhub" {
  source = "../../"

  application_code           = "myapp"
  environment                = "dev"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-dev-001"

  company = "contoso"
  owner   = "platform-team"

  processing_units = 2

  event_hubs = {
    "evh-app-logs" = {
      partition_count   = 8
      message_retention = 30
      consumer_groups   = ["analytics"]
    }

    "evh-cdc-state" = {
      partition_count           = 4
      message_retention         = 90
      cleanup_policy            = "Compact"
      tombstone_retention_hours = 24
    }
  }

  networking = {
    subnet_id = var.subnet_id
    # Optional: pin a static IP. Leave out for a dynamic IP on the "namespace"
    # sub-resource.
    # private_endpoints = { namespace = { private_ip_address = "10.0.1.10" } }
  }

  # source_repo is set by the pipeline via TF_VAR_source_repo.
  source_repo = "example"
}

output "namespace_fqdn" {
  description = "Hostname clients connect to."
  value       = module.eventhub.fqdn
}

output "private_endpoint_dns" {
  description = "Feed these to the DNS owner — the module registers no zone itself."
  value       = module.eventhub.private_endpoint_dns
}
