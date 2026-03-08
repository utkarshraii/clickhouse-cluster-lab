# Production Operations in ClickHouse

## 1. Backup & Restore

ClickHouse has built-in SQL-native `BACKUP` and `RESTORE` commands (since 22.7+).

### Configuration Prerequisite

Backups require an `allowed_path` or `allowed_disk` in server config:

```xml
<clickhouse>
    <backups>
        <allowed_path>/var/lib/clickhouse/backups/</allowed_path>
    </backups>
</clickhouse>
```

Without this, all BACKUP/RESTORE commands fail with `INVALID_CONFIG_PARAMETER` (Code 318).

### Full Backup

```sql
BACKUP TABLE mydb.mytable
TO File('/var/lib/clickhouse/backups/full_backup')
```

The `File()` engine writes to the local filesystem. For S3, use `S3('endpoint', 'key', 'secret')`.

### Restore

```sql
RESTORE TABLE mydb.mytable
FROM File('/var/lib/clickhouse/backups/full_backup')
```

The table must not already exist. To restore to a different name:

```sql
RESTORE TABLE mydb.mytable AS mydb.mytable_restored
FROM File('/var/lib/clickhouse/backups/full_backup')
```

### Incremental Backup

```sql
BACKUP TABLE mydb.mytable
TO File('/var/lib/clickhouse/backups/incr_backup')
SETTINGS base_backup = File('/var/lib/clickhouse/backups/full_backup')
```

Only new/changed parts since the base backup are stored. Incremental backups are significantly smaller.

### Monitoring Backups

```sql
SELECT id, name, status, num_files,
       formatReadableSize(uncompressed_size) AS uncompressed,
       formatReadableSize(compressed_size) AS compressed,
       start_time, end_time
FROM system.backups
ORDER BY start_time DESC
```

### Production Considerations

- Built-in BACKUP/RESTORE is good for single tables and small clusters
- For production S3 backups with scheduling, use [clickhouse-backup](https://github.com/Altinity/clickhouse-backup)
- Backup path must not already exist (no overwrite) — delete first for idempotency
- BACKUP is atomic per table — consistent snapshot of parts at the moment of execution

---

## 2. TTL Management

TTL (Time-To-Live) automatically deletes old data or moves it to different storage tiers.

### TTL DELETE

```sql
CREATE TABLE logs (
    ts DateTime,
    message String
) ENGINE = MergeTree()
ORDER BY ts
TTL ts + INTERVAL 30 DAY DELETE
```

Rows where `ts + 30 days < now()` are eligible for deletion.

### Key Behavior: TTL is Lazy

TTL is **only evaluated during merges**, not at query time or insert time.

- Expired rows remain queryable until a merge processes them
- `OPTIMIZE TABLE ... FINAL` forces a merge and triggers TTL evaluation
- Background merges eventually clean up, but timing is unpredictable

```sql
-- Force TTL evaluation
OPTIMIZE TABLE logs FINAL
```

### Adding TTL to Existing Tables

```sql
ALTER TABLE logs MODIFY TTL ts + INTERVAL 7 DAY DELETE
```

This sets the TTL but doesn't immediately delete. Run `OPTIMIZE TABLE ... FINAL` to apply.

### TTL to Volume (Tiered Storage)

```sql
CREATE TABLE events (...)
ENGINE = MergeTree()
ORDER BY ts
TTL ts + INTERVAL 7 DAY TO VOLUME 'cold',
    ts + INTERVAL 30 DAY DELETE
```

Data moves from hot to cold storage before eventual deletion.

### TTL Gotchas

- TTL uses the **column value**, not the insert time
- If you insert rows with old timestamps, they're immediately eligible for TTL on next merge
- TTL can only use a Date or DateTime column
- Multiple TTL rules are evaluated independently

---

## 3. Disk & Part Management

### Understanding Disks

```sql
SELECT name, path, free_space, total_space,
       formatReadableSize(free_space) AS free,
       formatReadableSize(total_space) AS total,
       round(100 - (free_space / total_space * 100), 1) AS pct_used
FROM system.disks
```

### Part Anatomy

Each part is a directory on disk containing column files, index, checksums, and metadata.

**Part naming convention:** `{partition_id}_{min_block}_{max_block}_{level}`

| Component | Meaning |
|-----------|---------|
| partition_id | Partition key value (e.g., `202401` for monthly) |
| min_block | First data block number in this part |
| max_block | Last data block number in this part |
| level | Merge depth (0 = fresh insert, higher = merged more times) |

Example: `202401_1_5_2` = January 2024 partition, blocks 1-5, merged 2 times.

### Inspecting Parts

```sql
SELECT partition, name, rows, bytes_on_disk,
       formatReadableSize(bytes_on_disk) AS size,
       level, active,
       modification_time
FROM system.parts
WHERE database = 'mydb' AND table = 'mytable'
ORDER BY partition, name
```

### Per-Column Compression

```sql
SELECT column, type,
       formatReadableSize(data_compressed_bytes) AS compressed,
       formatReadableSize(data_uncompressed_bytes) AS uncompressed,
       round(data_uncompressed_bytes / data_compressed_bytes, 2) AS ratio
FROM system.parts_columns
WHERE database = 'mydb' AND table = 'mytable' AND active
ORDER BY data_compressed_bytes DESC
```

### Part Lifecycle

1. **INSERT** creates a new part (level 0)
2. **Background merge** combines parts within the same partition (level increases)
3. **Merged parts** become inactive, then deleted after `old_parts_lifetime` (default 8 minutes)
4. **OPTIMIZE TABLE FINAL** forces all parts in a partition to merge into one

---

## 4. Too-Many-Parts Problem

### The Problem

Every INSERT creates a new part. If you INSERT faster than merges can consolidate, parts accumulate.

### Thresholds

| Setting | Default | Effect |
|---------|---------|--------|
| `parts_to_delay_insert` | 300 | INSERTs are throttled (slowed down) |
| `parts_to_throw_insert` | 600 | INSERTs are rejected with an error |

These are per-partition thresholds.

### Root Cause

```sql
-- CATASTROPHIC: 1 row per INSERT = 1 part per INSERT
for i in range(1000):
    INSERT INTO events VALUES (...)

-- CORRECT: batch rows into a single INSERT
INSERT INTO events SELECT ... FROM numbers(10000)
```

### Monitoring

```sql
SELECT database, table, partition,
       count() AS active_parts
FROM system.parts
WHERE active
GROUP BY database, table, partition
HAVING active_parts > 50
ORDER BY active_parts DESC
```

The best single metric: `MaxPartCountForPartition` from `system.asynchronous_metrics`.

### Solutions

| Approach | When |
|----------|------|
| Batch INSERTs (10K+ rows) | Always — first fix |
| Buffer tables | High-frequency producers you can't control |
| Async inserts (`async_insert=1`) | Many small clients, server-side batching |
| `OPTIMIZE TABLE` | Emergency cleanup |

---

## 5. Mutations

Mutations are ALTER-based data modifications that **rewrite entire parts**.

### ALTER UPDATE

```sql
ALTER TABLE events UPDATE status = 'archived'
WHERE created_at < now() - INTERVAL 90 DAY
```

This rewrites every part that contains matching rows. It's an **async operation** — the ALTER returns immediately, and parts are rewritten in the background.

### ALTER DELETE

```sql
ALTER TABLE events DELETE
WHERE status = 'test'
```

Same mechanism — rewrites parts to remove matching rows.

### Lightweight DELETE

```sql
DELETE FROM events WHERE id = 42
```

Lightweight DELETE uses **row masking** instead of part rewriting:
- Marks rows as deleted in a bitmap
- Masked rows are filtered out at query time
- Actual removal happens during the next merge
- Much faster than ALTER DELETE for small deletions

### Monitoring Mutations

```sql
SELECT database, table, mutation_id, command,
       create_time, is_done,
       parts_to_do, latest_fail_reason
FROM system.mutations
WHERE NOT is_done
ORDER BY create_time DESC
```

### KILL MUTATION

If a mutation is stuck or was a mistake:

```sql
KILL MUTATION WHERE mutation_id = 'mutation_0000000042'
```

This stops the mutation but does **not** roll back parts already rewritten.

### Mutations Best Practices

- Mutations are expensive — they rewrite entire parts, even if only 1 row changes
- Prefer **append-only** patterns in OLAP: insert corrections, don't update in place
- Use ReplacingMergeTree for "last version wins" instead of ALTER UPDATE
- Lightweight DELETE is preferred over ALTER DELETE for targeted removals
- Monitor `system.mutations` — stuck mutations block subsequent ones

---

## 6. Monitoring via System Tables

ClickHouse exposes three categories of metrics through system tables.

### system.metrics — Real-Time Gauges (Speedometer)

Current state of the server right now.

```sql
SELECT metric, value, description
FROM system.metrics
WHERE metric IN (
    'Query', 'Merge', 'MemoryTracking',
    'TCPConnection', 'BackgroundMergesAndMutationsPoolTask'
)
```

| Metric | What it means |
|--------|---------------|
| Query | Currently running queries |
| Merge | Currently running merges |
| MemoryTracking | Total memory used (bytes) |
| TCPConnection | Active TCP client connections |
| BackgroundMergesAndMutationsPoolTask | Active background merge/mutation threads |

### system.events — Cumulative Counters (Odometer)

Total counts since server start.

```sql
SELECT event, value, description
FROM system.events
WHERE event IN (
    'InsertedRows', 'MergedRows', 'FailedQuery',
    'DelayedInserts', 'SelectedRows'
)
```

| Event | What it means |
|-------|---------------|
| InsertedRows | Total rows inserted |
| MergedRows | Total rows processed by merges |
| FailedQuery | Total failed queries |
| DelayedInserts | INSERTs delayed due to too-many-parts |
| SelectedRows | Total rows read by queries |

### system.asynchronous_metrics — Background Stats (Dashboard Gauges)

Periodically updated background metrics.

```sql
SELECT metric, value, description
FROM system.asynchronous_metrics
WHERE metric IN (
    'Uptime', 'MaxPartCountForPartition',
    'TotalRowsOfMergeTreeTables', 'NumberOfTables'
)
```

| Metric | Why it matters |
|--------|----------------|
| MaxPartCountForPartition | **#1 ops metric** — approaching 300 = danger |
| TotalRowsOfMergeTreeTables | Total data volume indicator |
| Uptime | Detect unexpected restarts |

### Key Alerts

| Metric | Warning | Critical |
|--------|---------|----------|
| MaxPartCountForPartition | > 200 | > 300 |
| FailedQuery rate | > 1/min | > 10/min |
| MemoryTracking | > 80% of max | > 90% of max |
| ReplicasMaxAbsoluteDelay | > 60s | > 300s |
| Disk free space | < 20% | < 10% |

### Replication Health

```sql
SELECT database, table, replica_name,
       is_leader, absolute_delay, queue_size,
       active_replicas
FROM system.replicas
```

- `absolute_delay > 0` = replica is behind
- `queue_size > 0` = pending replication tasks
- `active_replicas < expected` = a node is down

### Recent Errors

```sql
SELECT name, value AS count,
       last_error_time, last_error_message
FROM system.errors
WHERE last_error_time > now() - INTERVAL 1 HOUR
ORDER BY last_error_time DESC
```
