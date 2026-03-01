# ClickHouse Config Reference

Every config field explained with "what breaks if wrong".

---

## config.xml — Server-Level Settings

### Logging

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `logger.level` | `information` | Log verbosity | Too low (`warning`) → miss replication issues. Too high (`trace`) → disk fills with logs |
| `logger.size` | `1000M` | Max log file size before rotation | Too small → logs rotate mid-debug, lose context |
| `logger.count` | `3` | Number of rotated log files kept | Too few → historical logs lost during investigation |

### Network

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `http_port` | `8123` | HTTP API and web UI | Blocked → monitoring, REST clients, health checks fail |
| `tcp_port` | `9000` | Native binary protocol | Blocked → clickhouse-client, JDBC/ODBC drivers can't connect |
| `interserver_http_port` | `9009` | Replica-to-replica data transfer | Blocked → replication stalls, new replicas can't sync |
| `listen_host` | `::1` / `127.0.0.1` | Which interfaces to bind | `0.0.0.0` in prod without firewall → open to the internet |
| `max_connections` | `1024` | Simultaneous client connections | Too low → clients rejected during spikes. Too high → OOM from connection buffers |
| `max_concurrent_queries` | `100` | Parallel query execution | Too low → query queuing, latency spikes. Too high → CPU/memory contention |

### Memory

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `max_memory_usage` | `10GB` | Per-query memory limit | 0 (unlimited) → single bad query OOMs the server |
| `max_server_memory_usage_ratio` | `0.9` | Fraction of RAM the server can use | 1.0 → OOM killer. <0.5 → wasted capacity |
| `mark_cache_size` | `5GB` | Cache for .mrk2 files | Too small → disk seeks on every query. Marks are tiny but frequently read |
| `uncompressed_cache_size` | `0` | Cache decompressed blocks | >0 helps repeated queries but steals from query memory. Usually keep at 0 |

### Background Processing

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `background_pool_size` | `16` | Threads for merges and mutations | Too low → parts accumulate → inserts delayed/rejected. Too high → CPU starvation for queries |
| `background_schedule_pool_size` | `128` | Threads for scheduled tasks (MVs, etc.) | Too low → materialized views lag behind inserts |

### MergeTree Settings

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `max_parts_in_total` | `100000` | Hard limit on total parts | Hit this → all INSERTs rejected. Emergency: increase temporarily, fix batching |
| `parts_to_delay_insert` | `300` | Throttle inserts when parts exceed this | Too low → unnecessary throttling. Too high → no warning before hitting throw limit |
| `parts_to_throw_insert` | `600` | Reject inserts above this part count | Too low → premature rejections. Too high → system becomes unresponsive from too many parts |

---

## users.xml — User & Profile Settings

### Profiles

| Field | Default | What It Does | What Breaks If Wrong |
|-------|---------|-------------|---------------------|
| `max_memory_usage` | `10GB` | Per-query memory limit (per user profile) | Overrides server-level. Too low → legitimate queries fail. Too high → single user can OOM |
| `max_execution_time` | `0` (unlimited) | Query timeout in seconds | 0 → bad joins run forever. Set to 300-600 for interactive users |
| `readonly` | `0` | Access mode: 0=full, 1=read-only, 2=read+settings | Wrong mode → BI tools can't SET format (need mode 2) or users accidentally DROP tables |
| `load_balancing` | `random` | How Distributed queries pick replicas | `in_order` with bad first replica → all queries hit a slow node |
| `allow_ddl` | `1` | Can user run DDL (CREATE, DROP, ALTER) | 1 for analytics users → accidental table drops |
| `max_rows_to_read` | `0` (unlimited) | Max rows a query can scan | 0 → `SELECT *` on billion-row table kills the server |

### Quotas

| Field | What It Does | What Breaks If Wrong |
|-------|-------------|---------------------|
| `duration` | Quota window in seconds | Too short → users hit limits doing normal work |
| `queries` | Max queries per interval | Too low → dashboards with many panels break |
| `read_rows` | Max rows scanned per interval | Too low → complex reports fail. Too high → no protection |
| `execution_time` | Max cumulative query time per interval | Too low → heavy analytics blocked. 0 → no limit |

---

## clusters.xml — Cluster Topology

| Field | What It Does | What Breaks If Wrong |
|-------|-------------|---------------------|
| `remote_servers.<cluster_name>` | Defines a named cluster | Wrong name → `ON CLUSTER 'x'` silently fails |
| `shard.internal_replication` | `true` = let ReplicatedMergeTree handle replication | `false` with ReplicatedMergeTree → DUPLICATE data on every insert |
| `shard.replica.host` | Hostname of a replica | Wrong hostname → node unreachable, queries to that shard fail |
| `shard.replica.port` | Native TCP port | Wrong port → same as wrong hostname |

---

## macros/*.xml — Per-Node Identity

| Field | What It Does | What Breaks If Wrong |
|-------|-------------|---------------------|
| `macros.shard` | Shard identifier (e.g., `01`) | Same value on different shards → data goes to wrong ZK path |
| `macros.replica` | Replica identifier (e.g., `ch-s1r1`) | Duplicate within same shard → replicas fight over ZK node, replication breaks |
| `macros.cluster` | Cluster name | Doesn't match `remote_servers` → macros reference wrong cluster |

---

## Scenario Cards

### "Inserts are slow"
1. Check `system.parts` — too many active parts?
2. Check `parts_to_delay_insert` — are inserts being throttled?
3. Check `background_pool_size` — enough merge threads?
4. Check insert batch size — should be ≥10K rows per INSERT

### "Queries are slow"
1. Check `ORDER BY` — does it match your WHERE clauses?
2. Check `system.query_log` — memory usage, read rows, read bytes
3. Check `mark_cache_size` — are marks being evicted?
4. Check `max_concurrent_queries` — are queries queuing?

### "Replica is lagging"
1. Check `system.replicas` — `absolute_delay` column
2. Check `interserver_http_port` — is 9009 reachable between nodes?
3. Check Keeper health — is the quorum alive?
4. Check `system.replication_queue` — what's stuck?

### "OOM killed"
1. Check `max_memory_usage` — was it set? Was it too high?
2. Check `max_server_memory_usage_ratio` — is it < 0.9?
3. Check the query in `system.query_log` — JOINs on large tables?
4. Consider `max_bytes_before_external_sort` / `max_bytes_before_external_group_by`

### "Too many parts error"
1. Stop inserting 1 row at a time
2. Use `Buffer` table engine to batch small inserts
3. Temporarily increase `parts_to_throw_insert`
4. Wait for merges: check `system.merges`
5. Increase `background_pool_size` if merges are the bottleneck
