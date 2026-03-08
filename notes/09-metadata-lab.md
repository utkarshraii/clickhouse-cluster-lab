# System Metadata & Debugging Lab — Reference Notes

Lab script: `cluster/scripts/lab-metadata.sh` (`make lab-metadata`)

This lab queries real system tables on the running 2-shard x 2-replica cluster. Students learn to debug performance issues, inspect storage internals, monitor replication health, and read query plans.

---

## Exercise 1: system.query_log — Finding Slow & Failed Queries

`system.query_log` records every query the server executes.

**What we do:**
- Run a slow query (full scan) and a fast query (filtered by ORDER BY prefix)
- Compare `query_duration_ms`, `read_rows`, `read_bytes`, `memory_usage` in query_log
- Run a failing query (divide by zero) and find it via `type = 'ExceptionWhileProcessing'`
- Inspect `ProfileEvents` map for the slow query

**Key columns:**
| Column | What it tells you |
|--------|-------------------|
| `type` | QueryStart, QueryFinish, ExceptionBeforeStart, ExceptionWhileProcessing |
| `query_duration_ms` | Wall-clock time |
| `read_rows` / `result_rows` | Selectivity — lower ratio = better index usage |
| `memory_usage` | Peak memory for the query |
| `exception_code` / `exception` | Error details for failed queries |
| `ProfileEvents` | Map of 200+ counters (disk reads, cache hits, etc.) |

**Key takeaway:** `SYSTEM FLUSH LOGS` makes entries appear immediately. query_log is your first debugging stop — every query leaves a trace.

---

## Exercise 2: system.parts — Understanding Part Lifecycle

Every INSERT creates a new "part" on disk. Background merges combine parts within the same partition.

**What we do:**
- Show current parts for the lab table
- Insert 5 tiny batches → 5 new parts appear
- OPTIMIZE TABLE FINAL → parts merge into one
- Inspect partition-level metadata

**Key columns:**
| Column | What it tells you |
|--------|-------------------|
| `partition` | Which partition this part belongs to |
| `name` | Part directory name (encodes partition, block range, level) |
| `rows` | Row count in this part |
| `bytes_on_disk` | Compressed size on disk |
| `active` | Whether this part is current (inactive = superseded by merge) |
| `modification_time` | When this part was created or last merged |

**Key takeaway:** Too many parts = too many small INSERTs. Batch writes for performance. Each INSERT = 1 new part.

---

## Exercise 3: system.columns — Storage Introspection

`system.columns` shows per-column storage details.

**What we do:**
- Show column types and compression codecs
- Compare compressed vs uncompressed sizes per column
- Calculate compression ratios
- Show `marks_bytes` (sparse index memory cost per column)

**Key columns:**
| Column | What it tells you |
|--------|-------------------|
| `data_compressed_bytes` | On-disk size for this column |
| `data_uncompressed_bytes` | Original size before compression |
| `compression_codec` | Which codec is applied |
| `marks_bytes` | Memory cost of the sparse primary index marks |

**Key takeaway:** Columnar storage means each column compresses independently. LowCardinality(String) with few distinct values compresses extremely well.

---

## Exercise 4: system.merges + system.metrics — Live Server State

**What we do:**
- Insert a large batch to trigger merges, then query `system.merges`
- Query `system.metrics` for current gauges (running queries, active merges)
- Query `system.events` for cumulative counters (InsertedRows, MergedRows)
- Query `system.asynchronous_metrics` for background stats (MaxPartCountForPartition)

**Three metric tables:**
| Table | Type | Example |
|-------|------|---------|
| `system.metrics` | Current gauges | Query=3, Merge=1 |
| `system.events` | Cumulative counters | InsertedRows=5000000 |
| `system.asynchronous_metrics` | Background stats | MaxPartCountForPartition=12 |

**Key takeaway:** Together these give you Prometheus-style monitoring without external tools. Empty `system.merges` = healthy state.

---

## Exercise 5: system.replicas + system.replication_queue — Replication Monitoring

**What we do:**
- Query `system.replicas` across all 4 nodes: is_leader, is_readonly, absolute_delay, queue_size
- Show healthy state criteria: all zeros, active_replicas = total_replicas
- Query `system.replication_queue` for pending tasks

**Healthy replica checklist:**
- `is_readonly = 0` — replica can accept writes
- `absolute_delay = 0` — no replication lag
- `queue_size = 0` — no pending tasks
- `active_replicas = total_replicas` — all replicas online

**Replication queue task types:**
- `GET_PART` — fetch a part from another replica
- `MERGE_PARTS` — execute a merge (leader-coordinated)
- `MUTATE_PART` — apply an ALTER UPDATE/DELETE

**Key takeaway:** These two tables are your primary replication health dashboard.

---

## Exercise 6: EXPLAIN — Reading Query Plans

**What we do:**
- `EXPLAIN indexes = 1` on a well-filtered query → small granule ratio
- `EXPLAIN indexes = 1` on a poorly-filtered query → full scan
- `EXPLAIN PIPELINE` to show parallelism
- Add a bloom_filter skip index, re-run EXPLAIN to see the Skip section

**EXPLAIN variants:**
| Syntax | Shows |
|--------|-------|
| `EXPLAIN` | Logical plan |
| `EXPLAIN indexes = 1` | Granule-level primary + skip index detail |
| `EXPLAIN PIPELINE` | Execution stages and thread counts |
| `EXPLAIN AST` | Abstract syntax tree |

**Interpreting granule ratios:**
- `Granules: 2/100` = excellent (skipped 98% of data)
- `Granules: 95/100` = poor (nearly full scan)

**Key takeaway:** EXPLAIN is how you prove your ORDER BY key and skip indexes are working.

---

## Quick Reference: Which System Table for Which Question?

| Question | System Table |
|----------|-------------|
| Why is this query slow? | `system.query_log` |
| Why did this query fail? | `system.query_log` (exception columns) |
| How many parts does my table have? | `system.parts` |
| How well is my data compressed? | `system.columns` |
| Are merges running? | `system.merges` |
| What is the server doing now? | `system.metrics` |
| How many rows were ever inserted? | `system.events` |
| Is replication healthy? | `system.replicas` |
| Any pending replication tasks? | `system.replication_queue` |
| Is my ORDER BY key effective? | `EXPLAIN indexes = 1` |
