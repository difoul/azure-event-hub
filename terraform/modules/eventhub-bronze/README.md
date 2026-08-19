# eventhub-bronze

Bronze-tier Event Hubs module. Creates a **Premium** Event Hubs namespace, a
map-driven set of event hubs with their consumer groups, least-privilege SAS
policies, and an optional private endpoint with private DNS.

The module is deliberately opinionated about the Premium tier: `sku` is fixed to
`Premium`, auto-inflate is off (Premium scales by Processing Units, not TUs), and
retention is expressed in days up to 90.

## Usage

```hcl
module "eventhub_bronze" {
  source = "./modules/eventhub-bronze"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  namespace_name      = "evhns-bronze-prod"
  processing_units    = 2

  event_hubs = {
    "evh-container-app-logs" = {
      partition_count   = 8
      message_retention = 30
      consumer_groups   = ["cribl"]
    }

    "evh-platform-metrics" = {
      partition_count   = 4
      message_retention = 7
    }

    "evh-cdc-state" = {
      partition_count           = 4
      message_retention         = 90
      cleanup_policy            = "Compact"
      tombstone_retention_hours = 24
    }
  }

  namespace_authorization_rules = {
    DiagnosticsRule = { listen = false, send = true, manage = false }
    CriblListenRule = { listen = true, send = false, manage = false }
  }

  private_endpoint_subnet_id = azurerm_subnet.private_endpoints.id
  virtual_network_id         = azurerm_virtual_network.main.id

  tags = local.common_tags
}
```

## Premium tier limits enforced by the module

| Limit | Premium value | Where it is enforced |
| --- | --- | --- |
| Partitions per event hub | 1–100 | `validation` on `event_hubs` |
| Partitions per namespace | 200 × PU | `precondition` on the namespace |
| Event hubs per namespace | 100 × PU | `precondition` on the namespace |
| Retention | 1–90 days | `validation` on `event_hubs` |
| Consumer groups per hub | 100 | `validation` on `event_hubs` |
| Processing Units | 1, 2, 4, 6, 8, 10, 12, 16 | `validation` on `processing_units` |
| Minimum TLS | 1.2 | `validation` on `minimum_tls_version` |

Per-hub `validation` blocks cannot reference `processing_units`, which is why the
two namespace-wide budgets are `precondition` blocks on
`azurerm_eventhub_namespace` instead. Both fail at plan time.

## Things to know before you apply

**Retention goes through `retention_description`, not `message_retention`.**
`message_retention` caps at 7 days on a shared parent namespace, so the module
converts `message_retention` (days) into
`retention_description.retention_time_in_hours` and leaves `message_retention`
unset. Setting both is the usual cause of a perpetual diff on this resource.

**Partition counts are effectively one-way.** Premium lets you *increase*
`partition_count` in place, but a decrease is a destroy/create: every buffered
event and every consumer offset is lost. Increasing also re-maps partition keys
to partitions, so per-key ordering is disturbed at the moment of the change. Size
for peak concurrent readers up front.

**`cleanup_policy` is immutable.** Switching a hub between `Delete` and `Compact`
forces a new Event Hub.

**Renaming a hub replaces it.** The map key is the hub name and part of the AMQP
entity path.

**`local_authentication_enabled = false` breaks SAS consumers.** That includes
Azure Monitor diagnostic settings pointed at an authorization rule, and any
client using a connection string. Leave it `true` unless every consumer
authenticates with Entra ID.

**`trusted_service_access_enabled` defaults to `true`** because diagnostic
settings stop delivering — silently, with no error surfaced — once network rules
are enabled without it.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `resource_group_name` | `string` | — | Target resource group. |
| `location` | `string` | — | Azure region. Premium is not available everywhere. |
| `namespace_name` | `string` | — | Globally unique namespace name, 6–50 chars. |
| `processing_units` | `number` | `1` | PUs: 1, 2, 4, 6, 8, 10, 12 or 16. |
| `event_hubs` | `map(object)` | `{}` | Event hubs to create. See below. |
| `namespace_authorization_rules` | `map(object)` | `{}` | Namespace SAS policies. |
| `minimum_tls_version` | `string` | `"1.2"` | Premium supports 1.2 only. |
| `local_authentication_enabled` | `bool` | `true` | Allow SAS authentication. |
| `public_network_access_enabled` | `bool` | `false` | Public internet reachability. |
| `trusted_service_access_enabled` | `bool` | `true` | Let trusted Azure services bypass the firewall. |
| `ip_rules` | `list(string)` | `[]` | Allowed public IPs / CIDRs. |
| `virtual_network_subnet_ids` | `list(string)` | `[]` | Service-endpoint subnet allowlist. |
| `private_endpoint_subnet_id` | `string` | `null` | Subnet for the private endpoint. Null skips it. |
| `private_endpoint_name` | `string` | `null` | Override the private endpoint name. |
| `private_dns_zone_ids` | `list(string)` | `null` | Existing DNS zones. Null makes the module create one. |
| `virtual_network_id` | `string` | `null` | VNet to link the module-created DNS zone to. |
| `identity_type` | `string` | `null` | `SystemAssigned` or `UserAssigned`. |
| `identity_ids` | `list(string)` | `[]` | Required when `identity_type = "UserAssigned"`. |

### `event_hubs` object

| Attribute | Type | Default | Description |
| --- | --- | --- | --- |
| `partition_count` | `number` | required | 1–100. Increase-only after creation. |
| `message_retention` | `number` | required | Retention in days, 1–90. |
| `cleanup_policy` | `string` | `"Delete"` | `Delete` or `Compact`. Immutable. |
| `tombstone_retention_hours` | `number` | `null` | Only with `cleanup_policy = "Compact"`. |
| `consumer_groups` | `list(string)` | `[]` | Extra groups beyond `$Default`, max 100. |
| `status` | `string` | `"Active"` | `Active`, `Disabled` or `SendDisabled`. |

## Outputs

| Name | Description |
| --- | --- |
| `namespace_id` | Namespace resource ID. |
| `namespace_name` | Namespace name. |
| `namespace_fqdn` | `<name>.servicebus.windows.net`. |
| `processing_units` | PUs assigned. |
| `partition_budget` | `{ used, available }` against the 200-per-PU cap. |
| `event_hub_ids` | Hub name → resource ID. |
| `event_hub_partition_ids` | Hub name → partition identifiers. |
| `consumer_group_ids` | `<hub>/<group>` → resource ID. |
| `authorization_rule_ids` | Rule name → resource ID. |
| `authorization_rule_primary_connection_strings` | Rule name → connection string (sensitive). |
| `private_endpoint_id` | Private endpoint ID, or null. |
| `private_endpoint_ip` | Private endpoint IP, or null. |
| `private_dns_zone_id` | Module-created DNS zone ID, or null. |
| `identity_principal_id` | System-assigned identity principal ID, or null. |
