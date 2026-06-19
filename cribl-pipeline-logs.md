# Cribl Pipeline — ContainerAppConsoleLogs

Parses application access logs from Azure Container Apps delivered via Azure Event Hub.

## Event Hub payload structure

Azure Monitor wraps all diagnostic logs in a `records[]` array stored under `_raw`. Each record's app log is a string in `properties.Log`.

```
_raw (object)
  └─ records[] (array)
       └─ each record:
            ├─ time, category, resourceId, operationName, location
            ├─ Tenant, Level, ProviderGuid, ProviderName, EventId, Pid, Tid, ActivityId
            └─ properties
                 ├─ Log              ← actual log line (string)
                 ├─ ContainerName, ContainerAppName, RevisionName
                 ├─ ContainerId, ContainerGroupName, ContainerGroupId
                 ├─ EnvironmentName, Stream, ContainerImage
```

## Log types in `properties.Log`

| Type | Pattern | Action |
|---|---|---|
| App access log | `{"asctime": ..., "name": "access", ...}` | Keep + parse |
| OTel span fragment | Partial line e.g. `"    \"status\": {"` | Drop (~120/batch) |
| Uvicorn access log | `INFO:     127.0.0.1 - "GET /health..."` | Drop (redundant) |

> **Note:** `ConsoleSpanExporter` in `app/main.py` pretty-prints each OTel span as multi-line JSON — every line becomes a separate Event Hub record (~120 per request). Replace with an OTLP exporter to cut Event Hub volume by ~98%.

---

## Pipeline Steps

### Step 1 — Unroll

| Field | Value |
|---|---|
| **Source field expression** | `_raw.records` |
| **Destination field** | `record` |

> Destination field is mandatory in this Cribl version.

---

### Step 2 — Eval: promote fields + set timestamp

| Name | Value expression |
|---|---|
| `Log` | `record.properties.Log` |
| `container` | `record.properties.ContainerName` |
| `app` | `record.properties.ContainerAppName` |
| `revision` | `record.properties.RevisionName` |
| `_time` | `new Date(record.time).getTime() / 1000` |
| `record` | `undefined` |
| `records` | `undefined` |

---

### Step 3 — Drop: discard OTel fragments + uvicorn lines

| Field | Value |
|---|---|
| **Field** | `Log` |
| **Regex** | `^(?!\{"asctime")` |

Drops every event where `Log` does **not** start with `{"asctime"`. The Drop function drops events that **match** the regex — the negative lookahead inverts this so only non-app-log records are dropped.

---

### Step 4 — Parser (JSON)

| Field | Value |
|---|---|
| **Source field** | `Log` |

---

### Step 5 — Eval: enrich + clean up

| Name | Value expression |
|---|---|
| `severity` | `levelname` |
| `logger` | `name` |
| `log_type` | `name === 'access' ? 'http_access' : 'app'` |
| `is_error` | `status_code >= 400` |
| `is_slow` | `duration_ms > 1000` |
| `query` | `query === '' ? undefined : query` |
| `levelname` | `undefined` |
| `name` | `undefined` |
| `asctime` | `undefined` |
| `Log` | `undefined` |
| `Tenant` | `undefined` |
| `Level` | `undefined` |
| `ProviderGuid` | `undefined` |
| `ProviderName` | `undefined` |
| `EventId` | `undefined` |
| `Pid` | `undefined` |
| `Tid` | `undefined` |
| `ActivityId` | `undefined` |
| `time` | `undefined` |
| `resourceId` | `undefined` |
| `operationName` | `undefined` |
| `category` | `undefined` |
| `location` | `undefined` |
| `properties` | `undefined` |

---

### Step 6 — Drop: suppress health check noise

| Field | Value |
|---|---|
| **Field** | `path` |
| **Regex** | `^/health$` |

> Add a condition so this only applies to `status_code === 200` health checks if you want to keep failed health checks.

---

## Output event shape

```json
{
  "_time": 1748970149,
  "message": "http_request",
  "severity": "INFO",
  "logger": "access",
  "log_type": "http_access",
  "taskName": "Task-28073",
  "method": "GET",
  "path": "/load/cpu",
  "query": "duration=30&intensity=80",
  "status_code": 200,
  "duration_ms": 145.3,
  "trace_id": "abc123def456abc123def456abc123de",
  "span_id": "abc123def456abc1",
  "user_agent": "curl/8.11.1",
  "x_forwarded_for": null,
  "request_id": null,
  "is_error": false,
  "is_slow": false,
  "container": "event-hub-demo",
  "app": "event-hub-demo",
  "revision": "event-hub-demo--eaotb4o"
}
```

---

## Gotchas

- Use `_raw.records` not `records` — the source stores the JSON batch under `_raw` as an object
- Unroll destination field is mandatory — use `record`
- Drop regex applies to the specified Field value, not `_raw` by default
- Drop logic is inverted — use negative lookahead `^(?!\{"asctime")` to drop non-matching events
- EPIPE error in preview — caused by processing the full 100+ record batch; test with a 3-4 record sample
- "Parse records array" option does not exist in this Cribl source version
