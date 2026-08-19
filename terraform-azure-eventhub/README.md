# terraform-azure-eventhub

Deploys one Azure Event Hubs **Premium** namespace per application per environment,
together with its event hubs, their consumer groups, and a private endpoint. The
namespace is Entra ID only — SAS is disabled and the module creates no
authorization rules, so data-plane access is granted by the **central assignment
layer** like every other service.

The module does **not** create the resource group, the subnet, the CMK key, or any
Private DNS record. It exports what the DNS owner needs from `private_endpoint_dns`.

## Tier

Bronze. It implements `networking` and `encryption`, plus the supporting `lock`.

| Interface | Status | Reason |
|---|---|---|
| `networking` | ✓ | one private endpoint on the `namespace` sub-resource |
| `encryption` | ✓ | CMK via `azurerm_eventhub_namespace_customer_managed_key`, with the module's own user-assigned identity and a self-grant on the key |
| `high_availability` | omitted | Silver, and Premium already replicates to three replicas across availability zones — there is no zone knob to expose |
| `backup` | omitted | Gold, and Event Hubs has no backup concept; retention is the durability model |
| `multi_region` | omitted | Platinum |

## What it enforces

| Setting | Value | Why |
|---|---|---|
| `sku` | `Premium` | the tier this module targets; Basic/Standard change every limit below |
| `public_network_access_enabled` | `false` | private networking only |
| `network_rulesets.default_action` | `Deny` | deny by default |
| `trusted_service_access_enabled` | `true` | without it Azure Monitor diagnostic settings stop delivering, silently |
| `minimum_tls_version` | `1.2` | Premium supports nothing lower |
| `local_authentication_enabled` | `false` | Entra ID only — no SAS keys, no connection strings |
| `auto_inflate_enabled` | `false` | a Standard-tier mechanism; Premium scales by Processing Units |
| Private DNS zone group | none | DNS is wired externally |
| Partitions per hub | 1–100 | Premium limit, validated |
| Partitions per namespace | ≤ 200 × PU | Premium limit, precondition |
| Event hubs per namespace | ≤ 100 × PU | Premium limit, precondition |
| Retention | 1–90 days | Premium limit, validated |

Because SAS is off, anything that authenticates with a connection string will not
work against this namespace — including Azure Monitor diagnostic settings that
target an authorization rule. Diagnostic settings must target the namespace by
resource ID with a managed identity, and clients (Cribl, Kafka apps, SDK
consumers) need `Azure Event Hubs Data Receiver` / `Data Sender` from the central
layer.

## Usage

```hcl
module "eventhub" {
  source = "git::https://<host>/terraform-azure-eventhub.git?ref=v0.1.0"

  application_code           = "myapp"
  environment                = "prd"
  location                   = "westeurope"
  target_resource_group_name = "rg-myapp-prd-001"

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
    subnet_id = azurerm_subnet.privatelink.id
    # Optional: pin a static IP. Leave out for a dynamic IP on the "namespace"
    # sub-resource.
    # private_endpoints = { namespace = { private_ip_address = "10.0.1.10" } }
  }

  encryption = {
    enabled         = true
    key_id          = module.cmk_key.key_id          # data-plane URI
    key_resource_id = module.cmk_key.key_resource_id # ARM ID, for the self-grant
  }
}
```

## Inputs

| Name | Type | Default | Required |
|---|---|---|---|
| `application_code` | `string` | — | yes |
| `environment` | `string` | — | yes |
| `location` | `string` | — | yes |
| `target_resource_group_name` | `string` | — | yes |
| `company` | `string` | — | yes |
| `owner` | `string` | — | yes |
| `source_repo` | `string` | — | yes (pipeline sets `TF_VAR_source_repo`) |
| `object_index` | `string` | `"000"` | no |
| `tags` | `map(string)` | `{}` | no |
| `processing_units` | `number` | `1` | no |
| `event_hubs` | `map(object)` | `{}` | no |
| `networking` | `object` | — | yes |
| `encryption` | `object` | `{ enabled = false }` | no |
| `lock` | `object` | `{ enabled = false }` | no |

### `event_hubs` object

| Attribute | Type | Default | Description |
|---|---|---|---|
| `partition_count` | `number` | required | 1–100. Increase-only after creation. |
| `message_retention` | `number` | required | Retention in days, 1–90. |
| `cleanup_policy` | `string` | `"Delete"` | `Delete` or `Compact`. Immutable. |
| `tombstone_retention_hours` | `number` | `null` | Only with `cleanup_policy = "Compact"`. |
| `consumer_groups` | `list(string)` | `[]` | Extra groups beyond `$Default`, max 100. |
| `status` | `string` | `"Active"` | `Active`, `Disabled` or `SendDisabled`. |

## Outputs

| Name | Description |
|---|---|
| `id` | Resource ID of the namespace |
| `name` | Composed namespace name |
| `fqdn` | `<name>.servicebus.windows.net` |
| `processing_units` | PUs assigned |
| `partition_budget` | `{ used, available }` against the 200-per-PU cap |
| `event_hub_ids` | Hub name → resource ID |
| `event_hub_partition_ids` | Hub name → partition identifiers |
| `consumer_group_ids` | `<hub>/<group>` → resource ID |
| `identity_principal_id` | Principal ID of the module's UAMI; null without CMK |
| `private_endpoint_dns` | FQDN + private IP pairs for external DNS registration |

## Notes

**Name.** Composed as `evhns-<application_code>-<environment>-<index>-<suffix>`.
The namespace name is globally unique (it becomes the `servicebus.windows.net`
hostname), so a 4-character random suffix carries the entropy on top of the
3-digit index. The name is therefore not predictable from the inputs alone — read
it from the `name` output. `application_code` is capped at 31 characters so the
composed name stays within Azure's 50-character limit, and a precondition
restates the budget at plan time.

**CMK requires an empty namespace.** Azure rejects encryption on a namespace that
already contains event hubs. The module orders the graph accordingly — identity,
self-grant, namespace, CMK, *then* event hubs — so a single apply works. The
consequence is that adding CMK to a namespace that already has hubs is not an
in-place change, and CMK cannot be removed at all without recreating the
namespace (the provider makes the delete a no-op).

| CMK field | Value |
|---|---|
| CMK API | `azurerm_eventhub_namespace_customer_managed_key`, `key_vault_key_ids` |
| Which ID the service consumes | the **data-plane URI** (`encryption.key_id`) |
| Which ID the self-grant uses | the **ARM resource ID** (`encryption.key_resource_id`) |
| Versionless `key_id` supported? | Yes |
| If versionless | auto-rotates |
| If versioned | pinned — rotation needs an apply with a new `key_id` |
| Identity used | the module's own user-assigned MI, granted `[ENV] Key Vault Crypto User` on the key |

**Retention is written through `retention_description`.** The resource's own
`message_retention` argument caps at 7 days on a shared parent namespace, so the
module converts `message_retention` (days) to `retention_time_in_hours` and
leaves `message_retention` unset. Azure reports it back as a computed value.
Setting both is what produces a perpetual diff on this resource.

**Partition counts are effectively one-way.** Premium allows `partition_count` to
be *increased* in place; a decrease is a destroy/create that loses every buffered
event and every consumer offset. Increasing also re-maps partition keys to
partitions, so per-key ordering is disturbed at the moment of the change. Size for
peak concurrent readers up front.

**Write-once fields.** `cleanup_policy` is immutable — switching a hub between
`Delete` and `Compact` replaces it. A hub's map key is its name and part of the
AMQP entity path, so renaming replaces it and drops consumer offsets. `status`
may only be set to `SendDisabled` on an existing hub; create it `Active` or
`Disabled` first.

**Scaling.** Change `processing_units` (1, 2, 4, 6, 8, 10, 12, 16). Both
namespace-wide budgets scale with it, and the `partition_budget` output reports
headroom.
