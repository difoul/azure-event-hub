# Cribl Pipeline — Container App Metrics

Parses Azure Monitor metrics from Azure Container Apps delivered via Azure Event Hub.

## Event Hub payload structure

Metrics arrive in the same `records[]` array as logs but with a flat structure — no `properties.Log`, no `Tenant` or `category` fields.

```
_raw (object)
  └─ records[] (array)
       └─ each record:
            ├─ time
            ├─ resourceId
            ├─ metricName
            ├─ timeGrain
            ├─ average, minimum, maximum, total, count
```

---

## Available metrics

| `metricName` | Unit | Description |
|---|---|---|
| `CpuPercentage` | % | Container CPU usage |
| `UsageNanoCores` | nanocores | Raw CPU — divide by 1e9 for cores |
| `MemoryPercentage` | % | Container memory usage |
| `WorkingSetBytes` | bytes | Raw memory — divide by 1048576 for MB |
| `Replicas` | count | Running replicas |
| `RestartCount` | count | Container restarts |
| `RxBytes` | bytes | Network bytes received |
| `TxBytes` | bytes | Network bytes transmitted |
| `CoresQuotaUsed` | cores | Per-revision quota consumption |
| `TotalCoresQuotaUsed` | cores | Total environment quota consumption |
| `ResiliencyRequestsPendingConnectionPool` | count | Connection pool queue depth |

---

## Pipeline Steps

### Step 1 — Unroll

| Field | Value |
|---|---|
| **Source field expression** | `_raw.records` |
| **Destination field** | `record` |

---

### Step 2 — Eval: promote fields + set timestamp

| Name | Value expression |
|---|---|
| `metric_name` | `record.metricName` |
| `average` | `record.average` |
| `minimum` | `record.minimum` |
| `maximum` | `record.maximum` |
| `total` | `record.total` |
| `count` | `record.count` |
| `time_grain` | `record.timeGrain` |
| `app` | `record.resourceId.split('/').pop().toLowerCase()` |
| `_time` | `new Date(record.time).getTime() / 1000` |
| `record` | `undefined` |
| `records` | `undefined` |

---

### Step 3 — Drop: discard log records (keep only metrics)

| Field | Value |
|---|---|
| **Field** | `metric_name` |
| **Regex** | `^(?!\w)` |

Drops events where `metric_name` is empty or undefined (log records). Keeps all metric records where `metric_name` starts with a word character.

---

### Step 4 — Eval: add derived fields

| Name | Value expression |
|---|---|
| `cpu_cores` | `metric_name === 'UsageNanoCores' ? Math.round(average / 1e9 * 1000) / 1000 : undefined` |
| `memory_mb` | `metric_name === 'WorkingSetBytes' ? Math.round(average / 1048576 * 100) / 100 : undefined` |
| `event_type` | `'metric'` |

---

## Output event shapes

**CPU percentage:**
```json
{
  "_time": 1748977380,
  "event_type": "metric",
  "metric_name": "CpuPercentage",
  "average": 12.5,
  "minimum": 10.1,
  "maximum": 15.3,
  "total": 50.0,
  "count": 4,
  "time_grain": "PT1M",
  "app": "event-hub-demo"
}
```

**CPU nanocores (with derived field):**
```json
{
  "_time": 1748977380,
  "event_type": "metric",
  "metric_name": "UsageNanoCores",
  "average": 1740492.5,
  "minimum": 1693860,
  "maximum": 1855562,
  "total": 6961970,
  "count": 4,
  "time_grain": "PT1M",
  "app": "event-hub-demo",
  "cpu_cores": 0.002
}
```

**Memory (with derived field):**
```json
{
  "_time": 1748977380,
  "event_type": "metric",
  "metric_name": "WorkingSetBytes",
  "average": 40722432,
  "minimum": 40714240,
  "maximum": 40730624,
  "total": 162889728,
  "count": 4,
  "time_grain": "PT1M",
  "app": "event-hub-demo",
  "memory_mb": 38.83
}
```

**Restart count:**
```json
{
  "_time": 1748977380,
  "event_type": "metric",
  "metric_name": "RestartCount",
  "average": 0,
  "minimum": 0,
  "maximum": 0,
  "total": 0,
  "count": 2,
  "time_grain": "PT1M",
  "app": "event-hub-demo"
}
```
