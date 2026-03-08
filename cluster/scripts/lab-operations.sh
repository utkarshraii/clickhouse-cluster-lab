#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-operations.sh — Hands-On Lab: Infrastructure & Operations
# ═══════════════════════════════════════════════════════════════════
#
# This lab covers production operations skills: backup/restore, TTL,
# disk/part management, too-many-parts, mutations, and monitoring.
#
# Exercises:
#   1. Backup & Restore     — SQL-native backup, incremental
#   2. TTL Management        — Auto-expiry, merge-time evaluation
#   3. Disk & Part Mgmt      — system.disks, system.parts, compression
#   4. Too-Many-Parts        — Simulate, diagnose, fix
#   5. Mutations             — ALTER UPDATE/DELETE, lightweight DELETE
#   6. Monitoring Dashboard  — system.metrics, events, async_metrics
#
# Usage:
#   ./cluster/scripts/lab-operations.sh
#   make lab-operations
#
# Prerequisites:
#   - Cluster must be running: make up
#   - Init must have run: make init
#   - backups.xml must be mounted (added by Phase 7 setup)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
CH_NODE="ch-s1r1"
DB_NAME="demo"

run_query() {
    local query="$1"
    docker exec "$CH_NODE" clickhouse-client --query "$query"
}

run_query_multiline() {
    docker exec -i "$CH_NODE" clickhouse-client --multiquery
}

run_query_on() {
    local node="$1"
    local query="$2"
    docker exec "$node" clickhouse-client --query "$query"
}

section() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════"
    echo ""
}

subsection() {
    echo "── $1 ──"
}

commentary() {
    echo ""
    echo "  💡 $1"
    echo ""
}

pause() {
    echo "  ───────────────────────────────────────────"
}

section "Infrastructure & Operations Hands-On Lab"
echo "  This lab covers production operations: backup/restore, TTL,"
echo "  disk and part management, too-many-parts, mutations, and"
echo "  monitoring via system tables."
echo ""
echo "  All exercises run on ${CH_NODE} except Exercise 6 (all nodes)."
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: Backup & Restore
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: Backup & Restore"

echo "  ClickHouse has SQL-native BACKUP/RESTORE commands."
echo "  We'll do a full backup, restore it, then try incremental."
echo ""

subsection "Creating demo.lab_ops_orders with 10K rows"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_orders;

CREATE TABLE demo.lab_ops_orders
(
    order_id  UInt64,
    region    LowCardinality(String),
    ts        DateTime,
    amount    Decimal(18, 2),
    status    LowCardinality(String)
)
ENGINE = MergeTree()
ORDER BY (region, ts)
SETTINGS index_granularity = 8192;
SQL

run_query "INSERT INTO demo.lab_ops_orders SELECT number AS order_id, arrayElement(['us-east', 'us-west', 'eu-west', 'ap-south'], (number % 4) + 1) AS region, now() - toIntervalSecond(number * 10) AS ts, round((number % 500) + 1, 2) AS amount, arrayElement(['pending', 'shipped', 'delivered'], (number % 3) + 1) AS status FROM numbers(10000)"
echo "  ✓ Table created with 10K rows"
echo ""

subsection "Cleaning any existing backup files (idempotency)"
docker exec "$CH_NODE" rm -rf /var/lib/clickhouse/backups/lab_ops_full
docker exec "$CH_NODE" rm -rf /var/lib/clickhouse/backups/lab_ops_incr
echo "  ✓ Backup paths cleaned"
echo ""

subsection "Full backup"
echo ""
echo "  BACKUP TABLE demo.lab_ops_orders"
echo "  TO File('/var/lib/clickhouse/backups/lab_ops_full')"
echo ""
run_query "BACKUP TABLE demo.lab_ops_orders TO File('/var/lib/clickhouse/backups/lab_ops_full')" > /dev/null
echo "  ✓ Full backup completed"
echo ""

subsection "Backup status from system.backups"
run_query_multiline <<'SQL'
SELECT
    id,
    status,
    num_files,
    formatReadableSize(uncompressed_size) AS uncompressed,
    formatReadableSize(compressed_size) AS compressed,
    start_time
FROM system.backups
WHERE name LIKE '%lab_ops_full%'
ORDER BY start_time DESC
LIMIT 1
FORMAT PrettyCompact
SQL
echo ""

subsection "DROP the table, then restore"
run_query "DROP TABLE demo.lab_ops_orders"
echo "  ✓ Table dropped"

run_query "RESTORE TABLE demo.lab_ops_orders FROM File('/var/lib/clickhouse/backups/lab_ops_full')" > /dev/null
restored_count=$(run_query "SELECT count() FROM demo.lab_ops_orders")
echo "  ✓ Table restored — row count: $restored_count"
echo ""

subsection "Incremental backup"
echo "  Inserting 5K more rows..."
run_query "INSERT INTO demo.lab_ops_orders SELECT 10000 + number AS order_id, arrayElement(['us-east', 'us-west', 'eu-west', 'ap-south'], (number % 4) + 1) AS region, now() - toIntervalSecond(number * 5) AS ts, round((number % 300) + 1, 2) AS amount, 'pending' AS status FROM numbers(5000)"
echo "  ✓ 5K more rows inserted (total: $(run_query "SELECT count() FROM demo.lab_ops_orders"))"
echo ""

echo "  BACKUP ... SETTINGS base_backup = File('.../lab_ops_full')"
run_query "BACKUP TABLE demo.lab_ops_orders TO File('/var/lib/clickhouse/backups/lab_ops_incr') SETTINGS base_backup = File('/var/lib/clickhouse/backups/lab_ops_full')" > /dev/null
echo "  ✓ Incremental backup completed"
echo ""

subsection "Comparing backup sizes"
run_query_multiline <<'SQL'
SELECT
    name,
    status,
    num_files,
    formatReadableSize(compressed_size) AS compressed
FROM system.backups
WHERE name LIKE '%lab_ops%'
ORDER BY start_time
FORMAT PrettyCompact
SQL
echo ""
commentary "The incremental backup is smaller — it only stores parts that changed since the full backup. In production, use clickhouse-backup (Altinity) for scheduled S3 backups with retention policies."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: TTL Management
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: TTL Management"

echo "  TTL (Time-To-Live) automatically removes expired data."
echo "  Key insight: TTL is lazy — only evaluated during merges."
echo ""

subsection "Creating table with TTL ts + INTERVAL 1 HOUR DELETE"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_ttl;

CREATE TABLE demo.lab_ops_ttl
(
    id     UInt64,
    ts     DateTime,
    value  Float64
)
ENGINE = MergeTree()
ORDER BY id
TTL ts + INTERVAL 1 HOUR DELETE;
SQL
echo "  ✓ Table created with 1-hour TTL"
echo ""

subsection "Inserting 10K rows: 5K old (2+ hours ago) + 5K recent"
run_query "INSERT INTO demo.lab_ops_ttl SELECT number AS id, now() - toIntervalHour(number + 2) AS ts, rand() / 1000000.0 AS value FROM numbers(5000)"
run_query "INSERT INTO demo.lab_ops_ttl SELECT 5000 + number AS id, now() - toIntervalSecond(number) AS ts, rand() / 1000000.0 AS value FROM numbers(5000)"

count_before=$(run_query "SELECT count() FROM demo.lab_ops_ttl")
echo "  Row count BEFORE optimize: $count_before"
echo "  (TTL is lazy — expired rows are still here)"
echo ""

subsection "OPTIMIZE TABLE FINAL — forcing TTL evaluation"
run_query "OPTIMIZE TABLE demo.lab_ops_ttl FINAL"
sleep 1

count_after=$(run_query "SELECT count() FROM demo.lab_ops_ttl")
echo "  Row count AFTER optimize: $count_after"
echo ""

subsection "Verifying remaining rows have recent timestamps"
run_query_multiline <<'SQL'
SELECT
    min(ts) AS oldest_remaining,
    max(ts) AS newest_remaining,
    count() AS rows
FROM demo.lab_ops_ttl
FORMAT PrettyCompact
SQL
echo ""

subsection "Adding TTL to an existing table"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_ttl2;

CREATE TABLE demo.lab_ops_ttl2
(
    id     UInt64,
    ts     DateTime,
    value  Float64
)
ENGINE = MergeTree()
ORDER BY id;
SQL
echo "  ✓ Created table WITHOUT TTL"

run_query "INSERT INTO demo.lab_ops_ttl2 SELECT number AS id, now() - toIntervalHour(number + 2) AS ts, rand() / 1000000.0 AS value FROM numbers(5000)"
run_query "INSERT INTO demo.lab_ops_ttl2 SELECT 5000 + number AS id, now() - toIntervalSecond(number) AS ts, rand() / 1000000.0 AS value FROM numbers(5000)"
echo "  Rows before ALTER: $(run_query "SELECT count() FROM demo.lab_ops_ttl2")"

run_query "ALTER TABLE demo.lab_ops_ttl2 MODIFY TTL ts + INTERVAL 1 HOUR DELETE"
echo "  ✓ TTL added via ALTER TABLE MODIFY TTL"

run_query "OPTIMIZE TABLE demo.lab_ops_ttl2 FINAL"
sleep 1
echo "  Rows after OPTIMIZE: $(run_query "SELECT count() FROM demo.lab_ops_ttl2")"
echo ""

commentary "TTL is evaluated during merges only, not in real-time. Expired rows persist until a merge happens. OPTIMIZE TABLE FINAL forces it. TTL uses the column value, not insert time — inserting old timestamps means immediate eligibility."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: Disk & Part Management
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: Disk & Part Management"

echo "  Every INSERT creates a new part. Parts are merged in the"
echo "  background. Understanding part lifecycle is key to operations."
echo ""

subsection "Creating table with 50K rows spanning 3 months"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_parts;

CREATE TABLE demo.lab_ops_parts
(
    id     UInt64,
    region LowCardinality(String),
    ts     DateTime,
    value  Float64
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (region, ts)
SETTINGS index_granularity = 8192;
SQL

run_query "INSERT INTO demo.lab_ops_parts SELECT number AS id, arrayElement(['us-east', 'us-west', 'eu-west'], (number % 3) + 1) AS region, today() - toIntervalDay(number % 90) AS ts, rand() / 1000000.0 AS value FROM numbers(50000)"
run_query "OPTIMIZE TABLE demo.lab_ops_parts FINAL"
echo "  ✓ Table created and optimized"
echo ""

subsection "Disk information (system.disks)"
run_query_multiline <<'SQL'
SELECT
    name,
    path,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    round(100 - (free_space / total_space * 100), 1) AS pct_used
FROM system.disks
FORMAT PrettyCompact
SQL
echo ""

subsection "Part structure (system.parts)"
echo ""
echo "  Part name format: {partition}_{min_block}_{max_block}_{level}"
echo ""
run_query_multiline <<'SQL'
SELECT
    partition,
    name,
    rows,
    formatReadableSize(bytes_on_disk) AS size,
    level,
    active
FROM system.parts
WHERE database = 'demo' AND table = 'lab_ops_parts' AND active
ORDER BY partition, name
FORMAT PrettyCompact
SQL
echo ""

subsection "Per-column compression (system.parts_columns)"
run_query_multiline <<'SQL'
SELECT
    column,
    type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 2) AS ratio
FROM system.parts_columns
WHERE database = 'demo' AND table = 'lab_ops_parts' AND active
GROUP BY column, type
ORDER BY sum(data_compressed_bytes) DESC
FORMAT PrettyCompact
SQL
echo ""

subsection "Inserting a small batch — new part appears"
parts_before=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts' AND active")
run_query "INSERT INTO demo.lab_ops_parts SELECT 50000 + number AS id, 'us-east' AS region, today() AS ts, rand() / 1000000.0 AS value FROM numbers(100)"
parts_after=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts' AND active")
echo "  Active parts before insert: $parts_before"
echo "  Active parts after insert:  $parts_after"
echo ""

subsection "OPTIMIZE FINAL — merging parts"
run_query "OPTIMIZE TABLE demo.lab_ops_parts FINAL"
sleep 1
parts_merged=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts' AND active")
echo "  Active parts after OPTIMIZE FINAL: $parts_merged"
echo ""

subsection "Inactive parts (superseded by merge)"
inactive=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts' AND NOT active")
echo "  Inactive parts: $inactive (cleaned up after ~8 minutes)"
echo ""

commentary "Part naming shows lineage: {partition}_{min}_{max}_{level}. Level shows merge depth — 0 is a fresh insert. Monitor active part counts per partition. OPTIMIZE FINAL forces everything to merge but is expensive."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: Too-Many-Parts
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: Too-Many-Parts"

echo "  Every INSERT creates 1 part. Rapid single-row INSERTs are"
echo "  the #1 ClickHouse anti-pattern. Let's see why."
echo ""

subsection "Creating table with LOW thresholds (100/200 instead of 300/600)"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_parts_bomb;

CREATE TABLE demo.lab_ops_parts_bomb
(
    id     UInt64,
    value  Float64
)
ENGINE = MergeTree()
ORDER BY id
SETTINGS parts_to_delay_insert = 100, parts_to_throw_insert = 200;
SQL
echo "  ✓ Table created (delay at 100 parts, reject at 200)"
echo ""

initial_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts_bomb' AND active")
echo "  Current active parts: $initial_parts"
echo ""

subsection "Rapid single-row INSERTs (80 iterations)"
echo "  Inserting 1 row at a time — the WRONG way..."
for i in $(seq 1 80); do
    run_query "INSERT INTO demo.lab_ops_parts_bomb VALUES ($i, rand())" 2>/dev/null || true
done
echo "  ✓ 80 individual INSERTs completed"
echo ""

bomb_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts_bomb' AND active")
echo "  Active parts after 80 single-row INSERTs: $bomb_parts"
echo ""

subsection "Part distribution"
run_query_multiline <<'SQL'
SELECT
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size,
    round(avg(rows), 1) AS avg_rows_per_part
FROM system.parts
WHERE database = 'demo' AND table = 'lab_ops_parts_bomb' AND active
FORMAT PrettyCompact
SQL
echo ""

subsection "The RIGHT way: single batch INSERT"
run_query "INSERT INTO demo.lab_ops_parts_bomb SELECT 1000 + number AS id, rand() / 1000000.0 AS value FROM numbers(10000)"
echo "  ✓ 10K rows inserted in a single INSERT"
echo ""

new_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts_bomb' AND active")
echo "  Active parts now: $new_parts (10K rows added only ~1 new part)"
echo ""

subsection "Cleanup: OPTIMIZE FINAL"
run_query "OPTIMIZE TABLE demo.lab_ops_parts_bomb FINAL"
sleep 1
final_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_ops_parts_bomb' AND active")
echo "  Active parts after OPTIMIZE: $final_parts"
echo ""

commentary "Defaults are 300 (delay) / 600 (reject) per partition. 1 row per INSERT is catastrophic — each creates a separate part. Batch 10K+ rows per INSERT. Use Buffer tables or async_insert=1 for high-frequency producers. MaxPartCountForPartition is the #1 ops metric."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: Mutations (ALTER UPDATE/DELETE)
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: Mutations (ALTER UPDATE/DELETE)"

echo "  Mutations rewrite entire parts. They are async operations —"
echo "  ALTER returns immediately, parts are rewritten in background."
echo ""

subsection "Creating table with 100K rows"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_ops_mutations;

CREATE TABLE demo.lab_ops_mutations
(
    id      UInt64,
    status  LowCardinality(String),
    amount  Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY id;
SQL

run_query "INSERT INTO demo.lab_ops_mutations SELECT number AS id, arrayElement(['active', 'pending', 'inactive'], (number % 3) + 1) AS status, round((number % 1000) / 10.0, 2) AS amount FROM numbers(100000)"
echo "  ✓ 100K rows inserted"
echo ""

subsection "Initial state: count by status"
run_query_multiline <<'SQL'
SELECT status, count() AS cnt
FROM demo.lab_ops_mutations
GROUP BY status
ORDER BY status
FORMAT PrettyCompact
SQL
echo ""

subsection "ALTER TABLE UPDATE — changing status"
echo ""
echo "  ALTER TABLE demo.lab_ops_mutations"
echo "  UPDATE status = 'archived' WHERE amount < 10"
echo ""
run_query "ALTER TABLE demo.lab_ops_mutations UPDATE status = 'archived' WHERE amount < 10"

echo "  Waiting for mutation to complete..."
for attempt in $(seq 1 10); do
    pending=$(run_query "SELECT count() FROM system.mutations WHERE database = 'demo' AND table = 'lab_ops_mutations' AND is_done = 0")
    if [ "$pending" = "0" ]; then
        echo "  ✓ Mutation completed (attempt $attempt)"
        break
    fi
    sleep 1
done
echo ""

subsection "After UPDATE: count by status"
run_query_multiline <<'SQL'
SELECT status, count() AS cnt
FROM demo.lab_ops_mutations
GROUP BY status
ORDER BY status
FORMAT PrettyCompact
SQL
echo ""

subsection "ALTER TABLE DELETE — removing archived rows"
echo ""
echo "  ALTER TABLE demo.lab_ops_mutations DELETE WHERE status = 'archived'"
echo ""
run_query "ALTER TABLE demo.lab_ops_mutations DELETE WHERE status = 'archived'"

echo "  Waiting for mutation to complete..."
for attempt in $(seq 1 10); do
    pending=$(run_query "SELECT count() FROM system.mutations WHERE database = 'demo' AND table = 'lab_ops_mutations' AND is_done = 0")
    if [ "$pending" = "0" ]; then
        echo "  ✓ Mutation completed (attempt $attempt)"
        break
    fi
    sleep 1
done

rows_after_delete=$(run_query "SELECT count() FROM demo.lab_ops_mutations")
echo "  Rows after DELETE: $rows_after_delete"
echo ""

subsection "Lightweight DELETE (row masking, not part rewrite)"
echo ""
echo "  Inserting 10K more rows, then using DELETE FROM..."
run_query "INSERT INTO demo.lab_ops_mutations SELECT 200000 + number AS id, 'pending' AS status, round((number % 100) + 90, 2) AS amount FROM numbers(10000)"

count_before_lwd=$(run_query "SELECT count() FROM demo.lab_ops_mutations WHERE amount > 150")
echo "  Rows with amount > 150: $count_before_lwd"

run_query "DELETE FROM demo.lab_ops_mutations WHERE amount > 150"
sleep 1

count_after_lwd=$(run_query "SELECT count() FROM demo.lab_ops_mutations WHERE amount > 150")
echo "  Rows with amount > 150 after DELETE FROM: $count_after_lwd"
echo ""

subsection "Mutation history"
run_query_multiline <<'SQL'
SELECT
    mutation_id,
    command,
    create_time,
    is_done,
    parts_to_do
FROM system.mutations
WHERE database = 'demo' AND table = 'lab_ops_mutations'
ORDER BY create_time
FORMAT PrettyCompact
SQL
echo ""

echo "  KILL MUTATION syntax (for stuck mutations):"
echo "  KILL MUTATION WHERE mutation_id = 'mutation_0000000042'"
echo "  (Stops mutation but does NOT roll back already-rewritten parts)"
echo ""

commentary "Mutations rewrite entire parts — even changing 1 row rewrites the full part. Lightweight DELETE (DELETE FROM) masks rows instead. Prefer append-only patterns in OLAP: insert corrections, don't update in place. Use ReplacingMergeTree for 'last version wins'."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: Monitoring Dashboard
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: Monitoring Dashboard"

echo "  ClickHouse exposes three categories of metrics via system tables."
echo "  No new tables needed — we query system tables directly."
echo ""

subsection "Server gauges (system.metrics) — current state"
echo ""
echo "  metrics = speedometer (what's happening RIGHT NOW)"
echo ""
run_query_multiline <<'SQL'
SELECT metric, value, description
FROM system.metrics
WHERE metric IN (
    'Query', 'Merge', 'MemoryTracking',
    'TCPConnection', 'BackgroundMergesAndMutationsPoolTask'
)
FORMAT PrettyCompact
SQL
echo ""

subsection "Cumulative counters (system.events) — since server start"
echo ""
echo "  events = odometer (total counts since boot)"
echo ""
run_query_multiline <<'SQL'
SELECT event, value, description
FROM system.events
WHERE event IN (
    'InsertedRows', 'MergedRows', 'FailedQuery',
    'DelayedInserts', 'SelectedRows'
)
FORMAT PrettyCompact
SQL
echo ""

subsection "Background stats (system.asynchronous_metrics)"
echo ""
echo "  async_metrics = dashboard gauges (periodically updated)"
echo ""
run_query_multiline <<'SQL'
SELECT metric, round(value, 2) AS value
FROM system.asynchronous_metrics
WHERE metric IN (
    'Uptime', 'MaxPartCountForPartition',
    'TotalRowsOfMergeTreeTables', 'NumberOfTables'
)
ORDER BY metric
FORMAT PrettyCompact
SQL
echo ""

subsection "Replication health across all 4 nodes"
echo ""
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    echo "  ── $node ──"
    run_query_on "$node" "SELECT database, table, replica_name, absolute_delay, queue_size FROM system.replicas FORMAT PrettyCompact" 2>/dev/null || echo "    (no replicated tables)"
    echo ""
done

subsection "Disk space utilization"
run_query_multiline <<'SQL'
SELECT
    name AS disk,
    formatReadableSize(free_space) AS free,
    formatReadableSize(total_space) AS total,
    round(100 - (free_space / total_space * 100), 1) AS pct_used
FROM system.disks
FORMAT PrettyCompact
SQL
echo ""

subsection "Recent errors (last hour)"
run_query_multiline <<'SQL'
SELECT
    name,
    value AS count,
    last_error_time,
    substring(last_error_message, 1, 80) AS message
FROM system.errors
WHERE last_error_time > now() - INTERVAL 1 HOUR
ORDER BY last_error_time DESC
LIMIT 10
FORMAT PrettyCompact
SQL
echo ""

subsection "Consolidated dashboard — key metrics in one query"
run_query_multiline <<'SQL'
SELECT
    'Queries running' AS metric,
    toString((SELECT value FROM system.metrics WHERE metric = 'Query')) AS value
UNION ALL
SELECT
    'Memory used',
    formatReadableSize((SELECT value FROM system.metrics WHERE metric = 'MemoryTracking'))
UNION ALL
SELECT
    'Max parts/partition',
    toString((SELECT toUInt64(value) FROM system.asynchronous_metrics WHERE metric = 'MaxPartCountForPartition'))
UNION ALL
SELECT
    'Total MergeTree rows',
    formatReadableQuantity((SELECT value FROM system.asynchronous_metrics WHERE metric = 'TotalRowsOfMergeTreeTables'))
UNION ALL
SELECT
    'Failed queries (total)',
    toString((SELECT value FROM system.events WHERE event = 'FailedQuery'))
UNION ALL
SELECT
    'Uptime',
    toString(toUInt64((SELECT value FROM system.asynchronous_metrics WHERE metric = 'Uptime'))) || ' seconds'
FORMAT PrettyCompact
SQL
echo ""

commentary "Three metric types: metrics (speedometer), events (odometer), async_metrics (dashboard gauges). MaxPartCountForPartition is the #1 ops metric — if it approaches 300, you have a too-many-parts problem. Monitor replication health on ALL nodes."

# ═══════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════

section "Cleanup"

echo "  Dropping all lab tables..."
run_query "DROP TABLE IF EXISTS demo.lab_ops_orders"
run_query "DROP TABLE IF EXISTS demo.lab_ops_ttl"
run_query "DROP TABLE IF EXISTS demo.lab_ops_ttl2"
run_query "DROP TABLE IF EXISTS demo.lab_ops_parts"
run_query "DROP TABLE IF EXISTS demo.lab_ops_parts_bomb"
run_query "DROP TABLE IF EXISTS demo.lab_ops_mutations"
echo "  ✓ All lab tables dropped"
echo ""

echo "  Removing backup files..."
docker exec "$CH_NODE" rm -rf /var/lib/clickhouse/backups/lab_ops_full
docker exec "$CH_NODE" rm -rf /var/lib/clickhouse/backups/lab_ops_incr
echo "  ✓ Backup files removed"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — Operations Summary"

echo "  ┌─────────────────────┬────────────────────────────────────────────────────┐"
echo "  │ Topic               │ What We Observed                                   │"
echo "  ├─────────────────────┼────────────────────────────────────────────────────┤"
echo "  │ Backup & Restore    │ SQL-native backup, incremental smaller than full   │"
echo "  │ TTL Management      │ Lazy evaluation — only during merges, not realtime │"
echo "  │ Disk & Parts        │ Part naming shows lineage, level shows merge depth │"
echo "  │ Too-Many-Parts      │ 1 row/INSERT = catastrophic, batch 10K+ rows      │"
echo "  │ Mutations           │ Rewrite entire parts, lightweight DELETE is faster │"
echo "  │ Monitoring          │ metrics/events/async_metrics = 3 types of insight  │"
echo "  └─────────────────────┴────────────────────────────────────────────────────┘"
echo ""
echo "  Key operational rules:"
echo "    1. Batch INSERTs — never 1 row at a time"
echo "    2. Monitor MaxPartCountForPartition (warn > 200, critical > 300)"
echo "    3. Prefer append-only patterns over mutations"
echo "    4. TTL needs OPTIMIZE or background merges to take effect"
echo "    5. Back up regularly — incremental saves space"
echo ""
echo "  See notes/11-operations.md for theory and notes/12-operations-lab.md for reference."
echo ""
