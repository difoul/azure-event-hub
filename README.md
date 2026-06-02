# Azure Event Hub — Container App Log Pipeline

Azure-native log pipeline that collects telemetry from a Container App and forwards it to **Cribl Stream** via **Azure Event Hub**. Cribl acts as the data router and can forward logs to any destination (Splunk, S3, Elastic, syslog, etc.).

## Architecture

```
Container App (Python/FastAPI)
  └─ stdout JSON logs
       └─► ContainerAppConsoleLogs / ContainerAppSystemLogs
            └─► Diagnostic Settings
                 └─► Azure Event Hub
                      └─► Cribl Stream (Container App, port 9000)
                           └─► [your destination: Splunk, S3, Elastic, ...]

Log Analytics Workspace (optional, enable_law = true)
  └─► ContainerAppHTTPLogs (Envoy ingress logs)
```

## Prerequisites

- Azure CLI (`az login` authenticated)
- Terraform >= 1.5
- Contributor access on the target subscription

## Quick Start

### 1. Copy and fill in variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
resource_group_name = "rg-event-hub-demo"
location            = "swedencentral"
container_app_name  = "my-app"
alert_email         = "you@example.com"
enable_law          = false
container_image     = "<acr_name>.azurecr.io/my-app:latest"
```

### 2. Deploy ACR first

```bash
cd terraform
terraform init
terraform apply -target=azurerm_container_registry.main
```

### 3. Build and push the app image

Run from the repo root (where `Dockerfile` lives).

**Option A — ACR Tasks (no local Docker required):**

```bash
az acr build \
  --registry $(terraform output -raw acr_login_server | cut -d. -f1) \
  --image my-app:latest \
  .
```

Azure builds the image in the cloud and pushes it to ACR automatically. Useful when Docker is not installed locally.

**Option B — Local Docker:**

```bash
ACR=$(terraform output -raw acr_login_server)
docker build -t my-app:latest .
docker tag my-app:latest $ACR/my-app:latest
az acr login --name $(echo $ACR | cut -d. -f1)
docker push $ACR/my-app:latest
```

### 4. Deploy the rest of the stack

```bash
terraform apply
```

## Key Variables

| Variable | Default | Notes |
|---|---|---|
| `container_image` | **required** | Must listen on port 8000, expose `GET /health` |
| `alert_email` | **required** | Receives all alert notifications |
| `enable_law` | `false` | Set `true` to deploy LAW + AMPLS for `ContainerAppHTTPLogs` |
| `event_hub_capacity` | `1` | Starting throughput units (1–20, auto-inflate ceiling: 20) |
| `cribl_image` | `cribl/cribl:latest` | Pin to a specific version for production |

## Key Outputs

| Output | Command |
|---|---|
| App URL | `terraform output container_app_url` |
| Cribl UI URL | `terraform output cribl_ui_url` |
| Cribl admin password | `terraform output -raw cribl_admin_password` |
| Event Hub FQDN | `terraform output eventhub_namespace_fqdn` |
| Cribl connection string | `terraform output -raw eventhub_cribl_connection_string` |
| ACR login server | `terraform output acr_login_server` |

If Terraform state is unavailable, retrieve directly from Azure:

```bash
az eventhubs namespace authorization-rule keys list \
  --resource-group <rg> \
  --namespace-name <namespace> \
  --name CriblListenRule \
  --query primaryConnectionString -o tsv

az containerapp secret show \
  --resource-group <rg> \
  --name cribl-stream \
  --secret-name cribl-admin-password \
  --query value -o tsv
```

## Configuring Cribl to consume from Event Hub

1. Open the Cribl UI (`terraform output cribl_ui_url`) — login: `admin` / `<cribl_admin_password>`
2. **Data → Sources → Add Source** — choose **Azure Event Hubs** (or **Kafka** if prompted for brokers)

**Azure Event Hubs source:**

| Field | Value |
|---|---|
| Event Hub Namespace | `<eventhub_namespace_fqdn>` |
| Event Hub Name | `evh-container-app-logs` |
| Consumer Group | `cribl` |
| Connection String | `terraform output -raw eventhub_cribl_connection_string` |

**Kafka source** (if Cribl shows a "brokers" field):

| Field | Value |
|---|---|
| Brokers | `<namespace>.servicebus.windows.net:9093` |
| Topic | `evh-container-app-logs` |
| Consumer Group | `cribl` |
| TLS | Enabled |
| SASL Mechanism | `PLAIN` |
| Username | `$ConnectionString` |
| Password | *(full connection string from above)* |

3. **Parse the Azure Monitor envelope** — Azure wraps all diagnostic logs in a `records[]` array with the log content in `records[N].properties.Log` as a JSON string. Add a pipeline with:
   - **Unroll Array** on field `records`
   - **JSON Parse** on field `properties.Log`
   - **Eval** to promote fields and drop the envelope

4. Route to your destination and save.

## Repository Structure

```
azure-event-hub/
├── app/
│   ├── logging_config.py          # JSON stdout logging (python-json-logger)
│   ├── main.py                    # FastAPI app + AccessLogMiddleware + OTel ConsoleSpanExporter
│   └── routers/                   # Simulation endpoints: latency, errors, load, scaling, DR
├── Dockerfile
├── requirements.txt
└── terraform/
    ├── main.tf                    # Resource group, common_tags
    ├── providers.tf               # azurerm ~>4.67
    ├── variables.tf
    ├── network.tf                 # VNet, subnets (/23 CAE + /27 private endpoints), NSG
    ├── acr.tf                     # Azure Container Registry
    ├── container_app.tf           # Container Apps Environment + demo app
    ├── container_app_cribl.tf     # Cribl Stream Container App + Azure Files persistence
    ├── eventhub.tf                # Namespace, hub, SAS policies, consumer group, private endpoint
    ├── monitoring.tf              # Diagnostic settings → Event Hub; optional LAW module
    ├── alerts.tf                  # CPU, memory, restart, Event Hub throttle + consumer lag alerts
    ├── dashboard.tf               # Azure Monitor Workbook
    ├── outputs.tf
    ├── terraform.tfvars.example
    └── modules/
        └── law-secure/            # Optional LAW + AMPLS with private link
```

## Known Limitations

- `ContainerAppHTTPLogs` (Envoy per-request logs) cannot be streamed to Event Hub — they are Log Analytics only. Deploy with `enable_law = true` to query them.
- Cribl runs in single-node mode. Distributed mode (leader/worker) is required for HA.
- Public access to Event Hub is disabled. On-premise Cribl instances need ExpressRoute or VPN Gateway to reach the private endpoint.
