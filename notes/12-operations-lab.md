# Operations Lab Reference Notes

Lab script: `cluster/scripts/lab-operations.sh` | Run: `make lab-operations`

---

## Exercise 1: Backup & Restore

**What we did:**
- Full backup with `BACKUP TABLE ... TO File(...)` — SQL-native, no external tools
- Verified backup status in `system.backups` (num_files, compressed_size)
- Dropped the table, restored with `RESTORE TABLE ... FROM File(...)`
- Incremental backup with `SETTINGS base_backup = File(...)` — only stores changed parts

**Key takeaways:**
- Backup path must not already exist — no overwrite, delete first for idempotency
- Config requires `<allowed_path>` in `backups.xml` or BACKUP fails (Code 318)
- Incremental backups are significantly smaller (only new/changed parts)
- For production S3 backups, use clickhouse-backup (Altinity)

**Commands:**
```sql
BACKUP TABLE db.table TO File('/path/to/backup')
RESTORE TABLE db.table FROM File('/path/to/backup')
BACKUP TABLE db.table TO File('/path/incr') SETTINGS base_backup = File('/path/full')
SELECT * FROM system.backups ORDER BY start_time DESC
```

---

## Exercise 2: TTL Management

**What we did:**
- Created table with `TTL ts + INTERVAL 1 HOUR DELETE`
- Inserted 10K rows: 5K old (2+ hours ago), 5K recent
- Count showed 10K — TTL is lazy, only applies during merges
- `OPTIMIZE TABLE ... FINAL` forced merge and TTL evaluation — count dropped to ~5K
- Added TTL to existing table with `ALTER TABLE MODIFY TTL`

**Key takeaways:**
- TTL is NOT real-time — it's evaluated during background merges only
- `OPTIMIZE TABLE ... FINAL` forces TTL evaluation immediately
- TTL uses the column value, not insert time — old timestamps = immediate eligibility
- Multiple TTL rules can exist (e.g., move to cold, then delete)

**Commands:**
```sql
CREATE TABLE t (...) ENGINE = MergeTree() ORDER BY id TTL ts + INTERVAL 1 HOUR DELETE
ALTER TABLE t MODIFY TTL ts + INTERVAL 7 DAY DELETE
OPTIMIZE TABLE t FINAL
```

---

## Exercise 3: Disk & Part Management

**What we did:**
- Queried `system.disks` for free/total space and utilization percentage
- Queried `system.parts` to see partition structure, part names, rows, bytes, merge level
- Queried `system.parts_columns` for per-column compression ratios
- Inserted a batch → observed new part at level 0
- `OPTIMIZE FINAL` → parts merged, level increased, old parts became inactive

**Key takeaways:**
- Part name format: `{partition}_{min_block}_{max_block}_{level}`
- Level 0 = fresh insert, higher = merged more times
- Inactive parts (after merge) are cleaned up after ~8 minutes
- `system.parts_columns` reveals per-column compression — find bloated columns

**Commands:**
```sql
SELECT name, path, formatReadableSize(free_space) FROM system.disks
SELECT partition, name, rows, level, active FROM system.parts WHERE database='demo' AND table='t'
SELECT column, round(data_uncompressed_bytes/data_compressed_bytes, 2) AS ratio FROM system.parts_columns
```

---

## Exercise 4: Too-Many-Parts

**What we did:**
- Created table with low thresholds: `parts_to_delay_insert=100, parts_to_throw_insert=200`
- Rapid single-row INSERTs created ~80 individual parts
- Showed each INSERT = 1 new part (catastrophic pattern)
- Single batch INSERT of 10K rows = 1 part (correct pattern)
- `OPTIMIZE FINAL` merged everything

**Key takeaways:**
- Default thresholds: 300 (delay) / 600 (throw) per partition
- 1 row per INSERT is the #1 ClickHouse anti-pattern
- Batch 10K+ rows per INSERT for healthy part counts
- `MaxPartCountForPartition` (async_metrics) is the #1 ops metric to monitor
- Buffer tables or `async_insert=1` help when you can't control the client

**Commands:**
```sql
SELECT count() FROM system.parts WHERE database='demo' AND table='t' AND active
SELECT value FROM system.asynchronous_metrics WHERE metric='MaxPartCountForPartition'
```

---

## Exercise 5: Mutations

**What we did:**
- `ALTER TABLE UPDATE` — changed status for matching rows (rewrites entire parts)
- `ALTER TABLE DELETE` — removed matching rows (rewrites parts)
- `DELETE FROM` (lightweight) — row masking, much faster
- Monitored progress in `system.mutations WHERE is_done = 0`

**Key takeaways:**
- ALTER UPDATE/DELETE are async — they rewrite entire parts in the background
- Even changing 1 row rewrites the full part it belongs to
- Lightweight DELETE masks rows immediately, actual removal during next merge
- Prefer append-only patterns: insert corrections rather than update in place
- Use ReplacingMergeTree for "last version wins" instead of ALTER UPDATE
- `KILL MUTATION` stops a mutation but doesn't roll back already-rewritten parts

**Commands:**
```sql
ALTER TABLE t UPDATE col = 'val' WHERE condition
ALTER TABLE t DELETE WHERE condition
DELETE FROM t WHERE condition
SELECT * FROM system.mutations WHERE NOT is_done
KILL MUTATION WHERE mutation_id = 'xxx'
```

---

## Exercise 6: Monitoring Dashboard

**What we did:**
- `system.metrics` — real-time gauges (Query, Merge, MemoryTracking)
- `system.events` — cumulative counters (InsertedRows, FailedQuery, DelayedInserts)
- `system.asynchronous_metrics` — background stats (Uptime, MaxPartCountForPartition)
- Replication health across all 4 nodes (absolute_delay, queue_size)
- Disk space utilization with percent-used calculation
- Recent errors from `system.errors`

**Key takeaways:**
- Three metric types: metrics (speedometer), events (odometer), async_metrics (dashboard gauges)
- `MaxPartCountForPartition` is the single most important operational metric
- Check replication health on ALL nodes, not just one
- Alert thresholds: MaxPartCount > 200 warn / > 300 critical

**Monitoring cheat sheet:**
```sql
SELECT metric, value FROM system.metrics WHERE metric IN ('Query','Merge','MemoryTracking')
SELECT event, value FROM system.events WHERE event IN ('InsertedRows','FailedQuery','DelayedInserts')
SELECT metric, value FROM system.asynchronous_metrics WHERE metric = 'MaxPartCountForPartition'
SELECT database, table, absolute_delay, queue_size FROM system.replicas
SELECT name, value, last_error_time FROM system.errors WHERE last_error_time > now() - INTERVAL 1 HOUR
```
