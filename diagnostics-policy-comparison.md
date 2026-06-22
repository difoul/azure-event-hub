# Diagnostic-settings-at-scale: two-setting vs single-setting

Decision doc for how we stream **logs + metrics** from Azure resources to the
central Event Hub (for Cribl) via Azure Policy.

Two implementations exist in `terraform/`. They are **mutually exclusive** for
any given resource — running both against the same scope produces duplicate
diagnostic settings.

| | **Option A — Two settings (current default)** | **Option B — Single setting (opt-in)** |
|---|---|---|
| Terraform | `policy_diagnostics.tf` + `policy_metrics.tf` | `policy_combined.tf` |
| Toggle | on by default when `diagnostics_policy_management_group_id` is set | `diagnostics_combined_policy_enabled = true` |
| Diagnostic settings per resource | **2** (`setByPolicy-LogAnalytics-*` + `setByPolicy-Metrics-EventHub`) | **1** (`setByPolicy-LogsMetrics-EventHub`) |
| Logs source | **Built-in** allLogs initiative (Microsoft-maintained, ~140 per-type policies) | Custom DINE — **we own it** |
| Metrics source | Custom DINE (`AllMetrics`) | Same custom DINE, merged in |
| Resource-type coverage | **Logs: all supported types** (built-in is broad). Metrics: curated metric-emitting list. | **Metric-emitting list only** (both halves). Log-only types get nothing. |
| Policy assignments / identities to manage | 2 | 1 |
| 5-setting cap consumed | 2 of 5 | 1 of 5 |

## The core trade-off

Azure caps each resource at **5 diagnostic settings**. Option A spends 2 of
them; Option B spends 1. That's the headline win for B.

But the win isn't free, because **logs and metrics have different valid
targeting**:

- **Logs** — the built-in initiative applies `categoryGroup: allLogs`
  generically to nearly *every* resource type, maintained by Microsoft.
- **Metrics** — `AllMetrics` *fails remediation* on resource types that emit no
  metrics, so any policy carrying it must be restricted to a curated
  metric-emitting type list.

A single shared setting must satisfy both at once, so it can only target the
**metric-emitting** set. Consequences:

- Resource types that emit logs but **no metrics** (and aren't in our list) get
  **nothing** from Option B. They would still need the built-in logs
  initiative — which reintroduces a second policy and, on overlapping types, a
  second setting.
- We **give up the Microsoft-maintained** allLogs initiative and own the logs
  half ourselves (curation + upkeep as Azure adds log categories/types).
- `allLogs` is a generic category *group*, so a targeted type with no log
  categories simply exports no logs — the setting still applies cleanly. Low
  risk, but it's our code now.

## Shared constraints (both options)

- **Single region** — the Event Hub destination supports one region; only
  resources in `diagnostics_policy_resource_location` get settings. Cover other
  regions by assigning again per region against a hub in that region.
- **New/updated resources only** — DeployIfNotExists fires on create/update. No
  remediation task is wired; backfill existing resources manually (see the
  notes at the bottom of `policy_diagnostics.tf`).
- **Identity roles** — the policy identity needs **Log Analytics Contributor**
  (control plane: `diagnosticSettings/write`) **+ Azure Event Hubs Data Owner**
  (data plane: write to the hub). Monitoring Contributor alone is not enough.
- **Metric dimensions are dropped** on the diagnostic-settings export route. If
  a specific type needs dimensions, use DCR metrics export for that type
  (~10 supported types only) — orthogonal to this choice.

## Recommendation

Stay on **Option A** unless we have resources genuinely approaching the
5-setting cap. The slot Option B saves costs us the Microsoft-maintained allLogs
initiative and narrows coverage to metric-emitting types. 2 of 5 is comfortable
headroom for most estates.

Choose **Option B** when:
- resources in scope already carry other settings (LAW export, partner SIEM,
  Sentinel) and the cap is real, **and**
- the estate is dominated by metric-emitting types, so the log-only gap is
  small, **and**
- we accept owning the logs policy.

## How to test Option B

```bash
# Terraform: plan only the combined policy on
terraform plan -var 'diagnostics_combined_policy_enabled=true'
```

Or import `terraform/policy_combined.portal.json` in the portal
(**Policy → Definitions → + Policy definition**), assign at a test MG/RG with a
system-assigned identity + the two roles above, then create/update an in-region
Key Vault or Storage account and confirm a **single**
`setByPolicy-LogsMetrics-EventHub` setting appears carrying **both** logs and
metrics.
