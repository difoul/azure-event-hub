# Azure Event Hub — Monitoring Pipeline (Context)

## Purpose

This project provisions an Azure-native log pipeline that collects telemetry from a Container App and forwards it to **Cribl Stream** (deployed as a Container App) via **Azure Event Hub**. Cribl acts as a data pipeline and can route logs to any destination (e.g. Splunk, S3, Elastic).

This replaces the Application Insights SDK used in the source project (`/opt/ws/azure/container-app-monitoring-demo`).

---

## Architecture

```
Container App (Python/FastAPI)
  └─ stdout JSON logs (access logs + OTel traces)
       └─► ContainerAppConsoleLogs
       └─► ContainerAppSystemLogs
            └─► Diagnostic Settings (azure-monitor mode)
                 └─► Azure Event Hub (evh-container-app-logs)
                      └─► Cribl Stream (Container App, port 9000)
                           └─► [configured destination: Splunk, S3, Elastic, etc.]

Container App (metrics only)
  └─► Diagnostic Settings → Event Hub

Log Analytics Workspace (optional, enable_law = true)
  └─► ContainerAppHTTPLogs (Envoy ingress logs — NOT available via diagnostic settings)
```

---

## Key Design Decisions

- **No Application Insights**: removed `azure-monitor-opentelemetry` SDK. App logs to stdout via `python-json-logger`. OTel traces use `ConsoleSpanExporter`.
- **ContainerAppHTTPLogs gap**: Azure Monitor does not expose HTTP ingress logs (status codes, latency, upstream) via diagnostic settings — they are lake-only in Log Analytics. The app must log HTTP access data to stdout itself via `AccessLogMiddleware`.
- **Log Analytics optional**: controlled by `enable_law` variable (default `false`). Set to `true` to deploy LAW + AMPLS + private DNS zones for querying `ContainerAppHTTPLogs`. The main Event Hub pipeline works without it.
- **Cribl instead of Splunk**: replaced Splunk Add-on consumer with Cribl Stream deployed as a Container App in the same VNet. Cribl is consumer-agnostic and can route to any destination.
- **Single Event Hub**: all log categories from the environment flow into one hub (`evh-container-app-logs`). Cribl parses the `category` field to differentiate.
- **Azure Files persistence**: Cribl config is persisted to an Azure Files share so configuration survives container restarts.
- **ACR for the demo app**: `azurerm_container_registry` (Basic SKU, admin enabled) with `random_id` suffix. Image built via `az acr build` (no local Docker needed) or `docker build` + `docker push`. ACR credentials injected as a secret into the demo app Container App.
- **Event Hub network hardened**: `default_action = "Deny"` + `public_network_access_enabled = false` must be set at BOTH the top-level namespace attribute AND inside the `network_rulesets` block — Azure rejects plans where they differ. Cribl reaches the hub via the private endpoint in the same VNet. Azure Monitor diagnostic settings bypass the firewall via `trusted_service_access_enabled = true`.
- **DiagnosticsRule is Send-only** (`manage = false`): Azure Monitor only needs Send. Terraform reads connection strings via ARM management plane RBAC — not via the SAS Manage right. Setting `manage = true` without `listen = true` causes `InvalidCombinationOfRights`.
- **Cribl storage network hardened**: `network_rules { default_action = "Deny", bypass = ["AzureServices"], virtual_network_subnet_ids = [snet-container-apps] }`. `bypass = ["AzureServices"]` alone does NOT cover CAE CIFS mounts — `service_endpoints = ["Microsoft.Storage"]` must also be set on the CAE subnet or mounts fail with error 13 (permission denied).

---

## Repository Structure

```
azure-event-hub/
├── app/
│   ├── __init__.py
│   ├── logging_config.py          # JSON stdout logging setup (python-json-logger)
│   ├── main.py                    # FastAPI app: OTel ConsoleSpanExporter + AccessLogMiddleware
│   └── routers/
│       ├── dr.py                  # Disaster recovery simulation endpoints
│       ├── errors.py              # HTTP error code simulation
│       ├── latency.py             # Latency simulation
│       ├── load.py                # CPU/memory load generation
│       └── scaling.py             # Burst request generation
├── Dockerfile
├── requirements.txt               # python-json-logger, opentelemetry-sdk, opentelemetry-instrumentation-fastapi
└── terraform/
    ├── main.tf                    # Resource group, common_tags
    ├── providers.tf               # azurerm ~>4.67, random ~>3.0
    ├── variables.tf               # All vars: container_image (required), enable_law, cribl_image, event_hub_capacity, alert_email, etc.
    ├── network.tf                 # VNet, subnets, NSG (incl. EventHub outbound rule)
    ├── acr.tf                     # ACR (Basic SKU, admin enabled, random_id suffix)
    ├── container_app.tf           # Container App Environment + demo app Container App
    ├── container_app_cribl.tf     # Cribl Stream Container App + Azure Files persistence + admin password
    ├── eventhub.tf                # Event Hub namespace, hub, SAS policies, consumer group, private endpoint
    ├── monitoring.tf              # Diagnostic settings → Event Hub; optional law-secure module
    ├── alerts.tf                  # CPU, memory, restart, activity log, EH throttle, EH consumer lag alerts
    ├── dashboard.tf               # Azure Monitor Workbook: Container App + Event Hub metrics
    ├── outputs.tf                 # URLs, Event Hub FQDN, Cribl connection string, admin password
    ├── terraform.tfvars.example
    └── modules/
        └── law-secure/            # Log Analytics Workspace with optional AMPLS private link
```

---

## Python App Changes (vs source project)

| Concern | Before (App Insights) | After (stdout) |
|---|---|---|
| SDK | `azure-monitor-opentelemetry` | `python-json-logger` + `opentelemetry-sdk` |
| HTTP logs | Auto-collected by SDK | `AccessLogMiddleware` writes JSON to stdout |
| Traces | Azure Monitor exporter | `ConsoleSpanExporter` → stdout |
| Correlation | App Insights e2e transaction | `trace_id` / `span_id` injected in every access log line |
| Env var | `APPLICATIONINSIGHTS_CONNECTION_STRING` | None |

---

## Terraform Resources Summary

### Event Hub (`eventhub.tf`)
- Namespace: `evhns-event-hub-demo`, Standard tier, auto-inflate up to 20 TU
- Hub: `evh-container-app-logs`, 4 partitions, 7-day retention
- SAS policies: `DiagnosticsRule` (Send only, manage=false — Azure Monitor doesn't need Manage), `CriblListenRule` (Listen only)
- Consumer group: `cribl`
- Private endpoint in `snet-private-endpoints` with `privatelink.servicebus.windows.net` DNS zone
- Network hardened: `default_action = "Deny"`, `public_network_access_enabled = false`, `trusted_service_access_enabled = true`

### Cribl Stream (`container_app_cribl.tf`)
- Image: `cribl/cribl:latest` (variable: `cribl_image`)
- CPU: 1.0 / Memory: 2Gi, min/max replicas: 1 (single-node mode)
- Port 9000 (web UI) exposed externally
- Azure Files share mounted at `/opt/cribl/config-volume` via `CRIBL_VOLUME_DIR`
- Admin password: generated by `random_password.cribl_admin`, injected as `CRIBL_ADMIN_PASSWORD`
- Event Hub connection string injected as `AZURE_EVENTHUB_CONNECTION_STRING` (secret-backed)
- Storage account network-restricted: `default_action = "Deny"`, `bypass = ["AzureServices"]`

### Monitoring (`monitoring.tf`)
- Diagnostic settings point to Event Hub (not Log Analytics)
- Log Analytics workspace optional (`enable_law`, default `false`); when enabled, uses AMPLS hybrid mode

### Alerts (`alerts.tf`)
- Container App: CPU spike (>80%), CPU sustained (>70% for 15m), memory (>80%), restarts
- Activity log: container app deleted, environment deleted
- Event Hub: throttled requests, consumer lag (two static criteria: IncomingMessages > 10 AND OutgoingMessages ≤ 0 over 15m)

---

## Key Variables

| Variable | Default | Notes |
|---|---|---|
| `container_image` | **required** | Must listen on port 8000 and expose `GET /health` |
| `enable_law` | `false` | Set `true` to deploy LAW + AMPLS for ContainerAppHTTPLogs |
| `event_hub_capacity` | `1` | Starting throughput units (1–20); auto-inflate ceiling is 20 |
| `cribl_image` | `cribl/cribl:latest` | Pin to a specific version for production |
| `alert_email` | **required** | Receives all alert notifications |

---

## Key Outputs

| Output | How to retrieve |
|---|---|
| Cribl UI URL | `terraform output cribl_ui_url` |
| Cribl admin password | `terraform output -raw cribl_admin_password` |
| Event Hub FQDN | `terraform output eventhub_namespace_fqdn` |
| Cribl connection string | `terraform output -raw eventhub_cribl_connection_string` |
| Consumer group | `terraform output eventhub_consumer_group` (value: `cribl`) |
| LAW workspace ID | `terraform output log_analytics_workspace_id` (null if `enable_law = false`) |

---

## Configuring Cribl After Deploy

1. Open `cribl_ui_url` in browser — login: `admin` / `<cribl_admin_password output>`
2. Data → Sources → Azure Event Hubs → Add Source:
   - Namespace FQDN: `<eventhub_namespace_fqdn>`
   - Event Hub name: `evh-container-app-logs`
   - Consumer group: `cribl`
   - Connection string: `<eventhub_cribl_connection_string>` (already in container as `AZURE_EVENTHUB_CONNECTION_STRING`)
3. Add a Pipeline to unroll the `records[]` array Azure Monitor wraps all diagnostic logs in
4. Route to your destination

---

## Known Limitations

- `ContainerAppHTTPLogs` (Envoy ingress per-request logs) cannot be streamed to Event Hub — lake-only in Log Analytics (deploy with `enable_law = true` to query them)
- Cribl single-node mode: no HA; distributed mode requires a leader/worker topology
- Docker Hub rate limits apply to anonymous pulls — consider pinning `cribl_image` to a specific version for production
- On-premise Cribl instances need ExpressRoute or VPN Gateway to reach the Event Hub private endpoint (public access is disabled)
