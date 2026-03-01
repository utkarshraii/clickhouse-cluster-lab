# Debugging and Monitoring ClickHouse

## System Tables: Your Observability Layer

ClickHouse exposes everything through `system.*` tables. No external monitoring needed to start debugging.

---

## system.query_log — Finding Slow & Failed Queries

The most important debugging tool. Every query is logged here.

```sql
-- Recent slow queries (>1 second)
SELECT
    query_id,
    user,
    query,
    type,                    -- 'QueryStart', 'QueryFinish', 'ExceptionBeforeStart', 'ExceptionWhileProcessing'
    event_time,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    exception,
    exception_code
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY event_time DESC
LIMIT 20;
```

```sql
-- Failed queries in the last hour
SELECT
    event_time,
    query,
    exception,
    exception_code,
    stack_trace
FROM system.query_log
WHERE type IN ('ExceptionBeforeStart', 'ExceptionWhileProcessing')
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY event_time DESC;
```

```sql
-- Memory-heavy queries (potential OOM candidates)
SELECT
    query,
    memory_usage,
    formatReadableSize(memory_usage) AS mem_readable,
    read_rows,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
ORDER BY memory_usage DESC
LIMIT 10;
```

### Key Columns in query_log

| Column | What It Tells You |
|--------|-------------------|
| `query_duration_ms` | Total execution time |
| `read_rows` | Rows scanned (high = bad index usage) |
| `read_bytes` | Data read from disk |
| `memory_usage` | Peak memory for this query |
| `result_rows` | Rows returned (compare with read_rows for selectivity) |
| `exception` | Error message if query failed |
| `thread_ids` | Threads used (parallelism indicator) |
| `ProfileEvents` | Detailed counters (cache hits, seeks, etc.) |

---

## system.parts — Detecting Merge Problems

```sql
-- Parts per table (look for high counts)
SELECT
    database,
    table,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY part_count DESC;
```

```sql
-- Detect "too many parts" problem
-- If part_count > 300 for a table, inserts will be throttled
-- If part_count > 600, inserts will be rejected
SELECT
    database, table,
    partition,
    count() AS parts_in_partition,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE active
GROUP BY database, table, partition
HAVING parts_in_partition > 100
ORDER BY parts_in_partition DESC;
```

### What "Too Many Parts" Means

```
Normal:       10-50 parts per partition
Warning:      100-300 parts (inserts may be delayed)
Critical:     300-600 parts (inserts ARE delayed)
Emergency:    600+ parts (inserts REJECTED)
```

**Root cause**: Almost always — too many small INSERTs. Each INSERT creates 1 part. If you insert 1 row at a time, 100 times per second, you get 360,000 parts per hour.

**Fix**: Batch inserts. Aim for ≥10,000 rows per INSERT. Use `Buffer` table if you can't batch at the application level.

---

## system.replicas — Replication Health

```sql
-- Overview of all replicated tables
SELECT
    database,
    table,
    replica_name,
    is_leader,                  -- Is this replica the leader for merges?
    can_become_leader,
    is_readonly,                -- true = replica can't write (Keeper issue)
    absolute_delay,             -- Seconds behind the leader
    queue_size,                 -- Pending replication tasks
    inserts_in_queue,           -- Parts to fetch from other replicas
    merges_in_queue,            -- Merges to perform
    total_replicas,             -- Expected replica count
    active_replicas             -- Actually online replicas
FROM system.replicas
FORMAT Vertical;
```

### Interpreting system.replicas

| Column | Healthy | Unhealthy |
|--------|---------|-----------|
| `is_readonly` | 0 | 1 → Keeper connection lost |
| `absolute_delay` | 0 | >10 → replica is falling behind |
| `queue_size` | 0-5 | >100 → replication backlog |
| `active_replicas` | = `total_replicas` | < `total_replicas` → replica(s) down |

```sql
-- Detailed replication queue (what's stuck?)
SELECT
    database, table, replica_name,
    type,           -- 'GET_PART', 'MERGE_PARTS', 'MUTATE_PART'
    source_replica,
    new_part_name,
    create_time,
    num_tries,
    last_exception,
    num_postponed,
    postpone_reason
FROM system.replication_queue
ORDER BY create_time;
```

---

## system.merges — Active Merges

```sql
-- What's merging right now?
SELECT
    database, table,
    elapsed,
    round(progress * 100, 1) AS pct,
    num_parts,                    -- Parts being merged
    result_part_name,
    total_size_bytes_compressed,
    formatReadableSize(total_size_bytes_compressed) AS size,
    rows_read, rows_written,
    memory_usage
FROM system.merges;
```

**If merges are slow**: Check `background_pool_size` and disk I/O. Merges compete with queries for disk bandwidth.

---

## system.errors — Error Counts

```sql
-- Error summary
SELECT
    name,
    value AS count,
    last_error_time,
    last_error_message,
    last_error_trace
FROM system.errors
ORDER BY last_error_time DESC;
```

Common errors to watch:
- `KEEPER_EXCEPTION` — Keeper connection problems
- `TOO_MANY_PARTS` — Insert batching issue
- `MEMORY_LIMIT_EXCEEDED` — Query needs more memory or optimization
- `TIMEOUT_EXCEEDED` — Query took too long

---

## system.metrics / system.events / system.asynchronous_metrics

```sql
-- Current server state
SELECT metric, value, description
FROM system.metrics
WHERE value > 0
ORDER BY metric;

-- Cumulative event counters (since server start)
SELECT event, value, description
FROM system.events
ORDER BY value DESC
LIMIT 20;

-- Background metrics (updated periodically)
SELECT metric, value
FROM system.asynchronous_metrics
WHERE metric LIKE '%Memory%'
ORDER BY metric;
```

### Key Metrics to Monitor

| Metric | Where | What It Means |
|--------|-------|---------------|
| `Query` | system.metrics | Currently running queries |
| `Merge` | system.metrics | Currently running merges |
| `ReplicatedSend` | system.metrics | Parts being sent to other replicas |
| `ReplicatedFetch` | system.metrics | Parts being fetched from other replicas |
| `MemoryTracking` | system.metrics | Current memory usage (bytes) |
| `MaxPartCountForPartition` | system.asynchronous_metrics | Highest part count across all partitions |

---

## Common Debugging Scenarios

### Scenario: "Queries are suddenly slow"

```sql
-- 1. Check if queries are queuing
SELECT metric, value FROM system.metrics WHERE metric = 'Query';
-- If near max_concurrent_queries → queries are waiting

-- 2. Check for ongoing heavy merges
SELECT * FROM system.merges;
-- Large merges consume disk I/O, slowing queries

-- 3. Check memory pressure
SELECT metric, value FROM system.metrics WHERE metric = 'MemoryTracking';

-- 4. Compare query plans
EXPLAIN indexes = 1
SELECT ... FROM table WHERE ...;
-- Look for "Granules: X/Y" — if X ≈ Y, the index isn't helping
```

### Scenario: "Inserts are failing with TOO_MANY_PARTS"

```sql
-- 1. How bad is it?
SELECT database, table, count() as parts
FROM system.parts WHERE active
GROUP BY database, table ORDER BY parts DESC;

-- 2. Are merges running?
SELECT count() FROM system.merges;

-- 3. Temporarily increase the limit (emergency only)
-- ALTER TABLE db.table MODIFY SETTING parts_to_throw_insert = 1000;

-- 4. Wait for merges, then fix your insert batching
SELECT * FROM system.merges;
```

### Scenario: "Replica is lagging behind"

```sql
-- 1. Check the delay
SELECT database, table, absolute_delay, queue_size
FROM system.replicas WHERE absolute_delay > 0;

-- 2. What's in the replication queue?
SELECT type, count(), min(create_time)
FROM system.replication_queue
GROUP BY type;

-- 3. Check if it's a network issue (can the replica reach the source?)
-- docker exec ch-s1r2 curl -s http://ch-s1r1:9009/

-- 4. Check Keeper health
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/events/replicas';
```

### Scenario: "OOM killed — query used too much memory"

```sql
-- 1. Find the query that caused it
SELECT query, memory_usage, formatReadableSize(memory_usage),
       read_rows, query_duration_ms
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND exception_code = 241  -- MEMORY_LIMIT_EXCEEDED
ORDER BY event_time DESC LIMIT 5;

-- 2. Options to fix:
-- a) Add WHERE clauses to reduce data scanned
-- b) Use external sorting:
--    SET max_bytes_before_external_sort = 5000000000;
-- c) Use external GROUP BY:
--    SET max_bytes_before_external_group_by = 5000000000;
-- d) Reduce max_threads to lower parallelism (less memory)
```

---

## EXPLAIN and EXPLAIN PIPELINE

### EXPLAIN — Query Plan

```sql
EXPLAIN indexes = 1
SELECT event_type, count()
FROM events
WHERE user_id = 42
GROUP BY event_type;
```

Output:
```
Expression ((Projection + Before ORDER BY))
  Aggregating
    Expression (Before GROUP BY)
      Filter (WHERE)
        ReadFromMergeTree (demo.events)
        Indexes:
          PrimaryKey
            Keys: user_id
            Condition: (user_id in [42, 42])
            Parts: 3/5          ← 3 out of 5 parts selected
            Granules: 12/1000   ← 12 out of 1000 granules read (good!)
```

**What to look for**:
- `Granules: X/Y` — If X ≈ Y, the primary index isn't helping. Reconsider ORDER BY.
- `Parts: X/Y` — If X ≈ Y, partition pruning isn't helping.

### EXPLAIN PIPELINE — Execution Pipeline

```sql
EXPLAIN PIPELINE
SELECT event_type, count()
FROM events
GROUP BY event_type;
```

Shows the actual execution operators and parallelism:
```
(Expression)
ExpressionTransform × 4
  (Aggregating)
  Resize 4 → 4
    AggregatingTransform × 4
      (Expression)
      ExpressionTransform × 4
        (ReadFromMergeTree)
        MergeTreeThread × 4    ← 4 parallel readers
```

---

## Quick Reference: Which System Table for What?

| Question | System Table |
|----------|-------------|
| Why is this query slow? | `system.query_log` |
| Are there too many parts? | `system.parts` |
| Is replication healthy? | `system.replicas` |
| What's stuck in replication? | `system.replication_queue` |
| Are merges running? | `system.merges` |
| What errors are happening? | `system.errors` |
| What's the server doing right now? | `system.metrics` |
| How much memory is used? | `system.asynchronous_metrics` |
| What's in Keeper/ZooKeeper? | `system.zookeeper` |
| What columns does a table have? | `system.columns` |
| What tables exist? | `system.tables` |
| What databases exist? | `system.databases` |
