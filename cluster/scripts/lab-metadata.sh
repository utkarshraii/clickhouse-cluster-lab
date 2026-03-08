#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-metadata.sh — Hands-On Lab: System Metadata & Debugging
# ═══════════════════════════════════════════════════════════════════
#
# This lab demonstrates how to query ClickHouse system tables for
# debugging, monitoring, and operational insight. Students query
# real system tables on the running cluster and interpret the output.
#
# Exercises:
#   1. system.query_log      — Finding slow & failed queries
#   2. system.parts          — Understanding part lifecycle
#   3. system.columns        — Storage introspection
#   4. system.merges + metrics — Live server state
#   5. system.replicas       — Replication monitoring
#   6. EXPLAIN               — Reading query plans
#
# Usage:
#   ./cluster/scripts/lab-metadata.sh
#   make lab-metadata
#
# Prerequisites:
#   - Cluster must be running: make up
#   - Init must have run: make init

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
CH_NODE="ch-s1r1"
DB_NAME="demo"
CH_NODES="ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2"

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

run_multiline_on() {
    local node="$1"
    docker exec -i "$node" clickhouse-client --multiquery
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

section "System Metadata & Debugging Hands-On Lab"
echo "  This lab demonstrates how to query ClickHouse system tables"
echo "  for debugging, monitoring, and operational insight."
echo ""
echo "  All exercises run on the live 2-shard x 2-replica cluster."
echo "  Primary node: ${CH_NODE}"
echo ""

# ── Setup: Create lab table and generate activity ─────────────────

section "Setup: Creating lab table and generating activity"

echo "  Creating demo.lab_meta_events across the cluster..."
run_multiline_on ch-s1r1 <<'SQL'
DROP TABLE IF EXISTS demo.lab_meta_events_dist ON CLUSTER 'ch_cluster' SYNC;
DROP TABLE IF EXISTS demo.lab_meta_events ON CLUSTER 'ch_cluster' SYNC;

CREATE TABLE demo.lab_meta_events ON CLUSTER 'ch_cluster'
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime DEFAULT now(),
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/lab_meta_events', '{replica}')
PARTITION BY toYYYYMM(ts)
ORDER BY (event_type, user_id, ts)
SETTINGS index_granularity = 8192;

CREATE TABLE demo.lab_meta_events_dist ON CLUSTER 'ch_cluster'
AS demo.lab_meta_events
ENGINE = Distributed('ch_cluster', 'demo', 'lab_meta_events', cityHash64(user_id));
SQL
echo "  ✓ Tables created on all nodes"
echo ""

echo "  Inserting 50K rows via distributed table..."
run_query "INSERT INTO demo.lab_meta_events_dist (event_id, event_type, user_id, region, ts, amount, payload) SELECT number AS event_id, arrayElement(['click', 'view', 'purchase', 'signup', 'logout'], (number % 5) + 1) AS event_type, (number % 10000) + 1 AS user_id, arrayElement(['us-east', 'us-west', 'eu-west', 'eu-east', 'ap-south', 'ap-east', 'sa-east', 'af-south', 'me-west', 'oc-east'], (number % 10) + 1) AS region, now() - toIntervalSecond(number % 86400) AS ts, round((number % 1000) / 10, 2) AS amount, repeat('x', 100) AS payload FROM numbers(50000)"
echo "  ✓ Inserted 50K rows"

sleep 3
echo ""
echo "  Setup complete. Let's explore the system tables."
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: system.query_log — Finding Slow & Failed Queries
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: system.query_log — Finding Slow & Failed Queries"

echo "  system.query_log records every query the server executes."
echo "  It stores timing, row counts, memory usage, and error details."
echo "  This is your first stop for debugging performance issues."
echo ""

subsection "Running a deliberately slow query (full table scan, no filter)"
run_query "SELECT count(), sum(amount), avg(amount) FROM demo.lab_meta_events FORMAT Null"
echo "  ✓ Slow query executed (full scan, no filter)"
echo ""

subsection "Running a fast query (filtered by ORDER BY key prefix)"
run_query "SELECT count(), sum(amount) FROM demo.lab_meta_events WHERE event_type = 'purchase' AND user_id = 42 FORMAT Null"
echo "  ✓ Fast query executed (uses primary index)"
echo ""

subsection "Flushing query log so entries are visible immediately"
run_query "SYSTEM FLUSH LOGS"
echo "  ✓ Logs flushed"
echo ""

subsection "Comparing the two queries in system.query_log"
run_query_multiline <<'SQL'
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    result_rows,
    formatReadableSize(memory_usage) AS memory,
    substring(query, 1, 80) AS query_prefix
FROM system.query_log
WHERE type = 'QueryFinish'
    AND query LIKE '%lab_meta_events%'
    AND query NOT LIKE '%system.query_log%'
    AND query NOT LIKE '%SYSTEM FLUSH%'
    AND event_date = today()
ORDER BY event_time DESC
LIMIT 2
FORMAT PrettyCompact
SQL
echo ""
commentary "The full-scan query reads all rows. The filtered query reads far fewer rows thanks to the primary index. The ratio read_rows/result_rows shows selectivity — lower is better."

subsection "Running a deliberately failing query (divide by zero)"
run_query "SELECT 1/0 FROM demo.lab_meta_events LIMIT 1" 2>/dev/null || true
run_query "SYSTEM FLUSH LOGS"
echo ""

subsection "Finding the failed query in query_log"
run_query_multiline <<'SQL'
SELECT
    type,
    query_duration_ms,
    exception_code,
    substring(exception, 1, 100) AS exception_msg,
    substring(query, 1, 80) AS query_prefix
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
    AND event_date = today()
ORDER BY event_time DESC
LIMIT 1
FORMAT PrettyCompact
SQL
echo ""
commentary "Failed queries have type='ExceptionWhileProcessing'. The exception_code and exception columns tell you exactly what went wrong. query_log is your first stop for debugging — every query leaves a trace."

subsection "ProfileEvents for the slow query (cache hits, disk reads)"
run_query_multiline <<'SQL'
SELECT
    ProfileEvents['FileOpen'] AS file_opens,
    ProfileEvents['ReadBufferFromFileDescriptorRead'] AS disk_reads,
    ProfileEvents['SelectedParts'] AS parts_selected,
    ProfileEvents['SelectedRanges'] AS ranges_selected,
    ProfileEvents['SelectedMarks'] AS marks_selected
FROM system.query_log
WHERE type = 'QueryFinish'
    AND query LIKE 'SELECT count(), sum(amount), avg(amount)%'
    AND event_date = today()
ORDER BY event_time DESC
LIMIT 1
FORMAT PrettyCompact
SQL
echo ""
commentary "ProfileEvents is a map inside each query_log row with 200+ counters: file I/O, network, cache behavior, and more. It shows exactly what the server did to execute your query."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: system.parts — Understanding Part Lifecycle
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: system.parts — Understanding Part Lifecycle"

echo "  Every INSERT creates a new 'part' on disk. Background merges"
echo "  combine small parts into larger ones. system.parts shows the"
echo "  current state of all parts for every table."
echo ""

subsection "Current parts for lab_meta_events"
run_query_multiline <<'SQL'
SELECT
    partition,
    count() AS part_count,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS total_size
FROM system.parts
WHERE database = 'demo'
    AND table = 'lab_meta_events'
    AND active
GROUP BY partition
ORDER BY partition
FORMAT PrettyCompact
SQL
echo ""

subsection "Inserting 5 tiny batches (10 rows each) to create 5 new parts"
for i in $(seq 1 5); do
    run_query "INSERT INTO demo.lab_meta_events (event_id, event_type, user_id, region, amount, payload) SELECT 100000 + ($i * 10) + number AS event_id, 'click' AS event_type, number + 1 AS user_id, 'us-east' AS region, 1.00 AS amount, 'tiny-batch' AS payload FROM numbers(10)"
done
echo "  ✓ Inserted 5 batches of 10 rows each"
echo ""

subsection "Parts after 5 small inserts (each INSERT = 1 new part)"
run_query_multiline <<'SQL'
SELECT
    partition,
    name,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'demo'
    AND table = 'lab_meta_events'
    AND active
ORDER BY partition, name
FORMAT PrettyCompact
SQL
echo ""
commentary "Each INSERT creates a separate part. Too many small parts = too many small INSERTs. Batch your writes for best performance."

subsection "Forcing a merge with OPTIMIZE TABLE FINAL"
run_query "OPTIMIZE TABLE demo.lab_meta_events FINAL"
sleep 2
echo "  ✓ Merge complete"
echo ""

subsection "Parts after merge — small parts collapsed"
run_query_multiline <<'SQL'
SELECT
    partition,
    name,
    rows,
    formatReadableSize(bytes_on_disk) AS size
FROM system.parts
WHERE database = 'demo'
    AND table = 'lab_meta_events'
    AND active
ORDER BY partition, name
FORMAT PrettyCompact
SQL
echo ""
commentary "After OPTIMIZE FINAL, parts within the same partition are merged into one. Fewer parts = faster queries (fewer files to open, fewer index lookups)."

subsection "Partition-level inspection"
run_query_multiline <<'SQL'
SELECT
    partition,
    count() AS parts,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE database = 'demo'
    AND table = 'lab_meta_events'
    AND active
GROUP BY partition
ORDER BY partition
FORMAT PrettyCompact
SQL
echo ""
commentary "PARTITION BY toYYYYMM(ts) creates separate part groups per month. Each partition merges independently. You can DROP PARTITION to instantly remove a month of data."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: system.columns — Storage Introspection
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: system.columns — Storage Introspection"

echo "  system.columns shows per-column storage details: compressed and"
echo "  uncompressed sizes, types, and compression codecs. This is how"
echo "  you understand the storage cost of each column."
echo ""

subsection "Column types and compression for lab_meta_events"
run_query_multiline <<'SQL'
SELECT
    name,
    type,
    compression_codec
FROM system.columns
WHERE database = 'demo'
    AND table = 'lab_meta_events'
ORDER BY position
FORMAT PrettyCompact
SQL
echo ""

subsection "Per-column compressed vs uncompressed sizes"
run_query_multiline <<'SQL'
SELECT
    name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed,
    if(data_uncompressed_bytes > 0,
        round(data_compressed_bytes / data_uncompressed_bytes, 3),
        0) AS compression_ratio,
    formatReadableSize(marks_bytes) AS marks_size
FROM system.columns
WHERE database = 'demo'
    AND table = 'lab_meta_events'
ORDER BY data_compressed_bytes DESC
FORMAT PrettyCompact
SQL
echo ""
commentary "Each column has its own compression story. Low-cardinality columns (event_type, region) compress very well. The payload column (random strings) compresses less. LowCardinality(String) stores a dictionary — check if its compressed size is smaller than a plain String would be."

subsection "Compression ratio comparison: LowCardinality vs regular columns"
run_query_multiline <<'SQL'
SELECT
    name,
    type,
    formatReadableSize(data_compressed_bytes) AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed,
    round(data_uncompressed_bytes / greatest(data_compressed_bytes, 1), 1) AS compression_factor
FROM system.columns
WHERE database = 'demo'
    AND table = 'lab_meta_events'
    AND name IN ('event_type', 'region', 'payload', 'user_id')
ORDER BY compression_factor DESC
FORMAT PrettyCompact
SQL
echo ""
commentary "marks_bytes shows the memory cost of the sparse primary index for each column. Columnar storage means each column compresses independently — choose types carefully."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: system.merges + system.metrics — Live Server State
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: system.merges + system.metrics — Live Server State"

echo "  system.merges shows currently running background merges."
echo "  system.metrics, system.events, and system.asynchronous_metrics"
echo "  expose real-time server state and cumulative counters."
echo ""

subsection "Inserting a large batch to trigger background merges"
run_query "INSERT INTO demo.lab_meta_events (event_id, event_type, user_id, region, amount, payload) SELECT 200000 + number AS event_id, arrayElement(['click', 'view', 'purchase', 'signup', 'logout'], (number % 5) + 1) AS event_type, (number % 5000) + 1 AS user_id, arrayElement(['us-east', 'us-west', 'eu-west'], (number % 3) + 1) AS region, round((number % 500) / 10, 2) AS amount, repeat('y', 100) AS payload FROM numbers(200000)"
echo "  ✓ Inserted 200K rows"
echo ""

subsection "Checking system.merges for active merges"
echo ""
merge_found=0
for attempt in $(seq 1 5); do
    merge_count=$(run_query "SELECT count() FROM system.merges WHERE database = 'demo'")
    if [ "$merge_count" -gt 0 ]; then
        echo "  Active merges found (attempt $attempt):"
        run_query_multiline <<'SQL'
SELECT
    table,
    round(progress * 100, 1) AS progress_pct,
    num_parts AS parts_merging,
    formatReadableSize(total_size_bytes_compressed) AS total_size,
    elapsed AS elapsed_sec,
    formatReadableSize(bytes_read_uncompressed) AS bytes_read
FROM system.merges
WHERE database = 'demo'
FORMAT PrettyCompact
SQL
        merge_found=1
        break
    fi
    sleep 1
done
if [ "$merge_found" -eq 0 ]; then
    echo "  No active merges caught (they finished quickly — that's healthy!)"
fi
echo ""
commentary "Merges are fast for small parts. If system.merges is constantly busy, you may have too many INSERTs creating too many parts. Empty merges = healthy state."

subsection "system.metrics — current server state"
run_query_multiline <<'SQL'
SELECT metric, value, description
FROM system.metrics
WHERE metric IN (
    'Query', 'Merge', 'MemoryTracking',
    'ReplicatedFetch', 'BackgroundMergesAndMutationsPoolTask'
)
FORMAT PrettyCompact
SQL
echo ""

subsection "system.events — cumulative counters since server start"
run_query_multiline <<'SQL'
SELECT event, value, description
FROM system.events
WHERE event IN (
    'InsertedRows', 'InsertedBytes',
    'MergedRows', 'MergedUncompressedBytes',
    'SelectedRows', 'SelectedBytes',
    'FailedQuery', 'Query'
)
ORDER BY value DESC
FORMAT PrettyCompact
SQL
echo ""

subsection "system.asynchronous_metrics — background-calculated stats"
run_query_multiline <<'SQL'
SELECT metric, value
FROM system.asynchronous_metrics
WHERE metric IN (
    'MaxPartCountForPartition',
    'TotalRowsOfMergeTreeTables',
    'TotalBytesOfMergeTreeTables',
    'NumberOfDatabases',
    'NumberOfTables'
)
ORDER BY metric
FORMAT PrettyCompact
SQL
echo ""
commentary "metrics = current gauges (running queries, active merges). events = cumulative counters (total rows inserted since start). asynchronous_metrics = background stats (max part count, total table sizes). Together they give you Prometheus-style monitoring without external tools."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: system.replicas + system.replication_queue
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: system.replicas + system.replication_queue — Replication Monitoring"

echo "  system.replicas shows the health of every replicated table."
echo "  system.replication_queue shows pending replication tasks."
echo "  Together, they are your primary replication health dashboard."
echo ""

subsection "system.replicas across all 4 nodes"
echo ""
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    echo "  $node:"
    run_query_on "$node" "SELECT replica_name, is_leader, is_readonly, absolute_delay, queue_size, active_replicas, total_replicas FROM system.replicas WHERE database = 'demo' AND table = 'lab_meta_events' FORMAT PrettyCompact" 2>/dev/null || echo "    (table not found)"
    echo ""
done

subsection "Health check: all zeros = healthy"
echo ""
run_query_multiline <<'SQL'
SELECT
    replica_name,
    is_readonly,
    absolute_delay,
    queue_size,
    active_replicas,
    total_replicas,
    if(is_readonly = 0 AND absolute_delay = 0 AND queue_size = 0
        AND active_replicas = total_replicas, 'HEALTHY', 'CHECK') AS status
FROM system.replicas
WHERE database = 'demo'
    AND table = 'lab_meta_events'
FORMAT PrettyCompact
SQL
echo ""
commentary "is_readonly=0, absolute_delay=0, queue_size=0, and active=total means the replica is fully healthy. Any non-zero value warrants investigation."

subsection "system.replication_queue (pending tasks)"
echo ""
queue_count=$(run_query "SELECT count() FROM system.replication_queue WHERE database = 'demo' AND table = 'lab_meta_events'")
if [ "$queue_count" -gt 0 ]; then
    run_query_multiline <<'SQL'
SELECT
    type,
    source_replica,
    new_part_name,
    create_time,
    is_currently_executing
FROM system.replication_queue
WHERE database = 'demo'
    AND table = 'lab_meta_events'
LIMIT 10
FORMAT PrettyCompact
SQL
else
    echo "  Replication queue is empty — all tasks completed."
    echo ""
    echo "  Common task types you might see:"
    echo "    GET_PART     — fetch a part from another replica"
    echo "    MERGE_PARTS  — execute a merge (coordinated by the leader)"
    echo "    MUTATE_PART  — apply an ALTER UPDATE/DELETE mutation"
fi
echo ""

subsection "Cross-node comparison: active_replicas = total_replicas everywhere"
echo ""
all_healthy=true
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    result=$(run_query_on "$node" "SELECT active_replicas = total_replicas FROM system.replicas WHERE database = 'demo' AND table = 'lab_meta_events'" 2>/dev/null || echo "0")
    status="HEALTHY"
    if [ "$result" != "1" ]; then
        status="DEGRADED"
        all_healthy=false
    fi
    printf "  %-10s → active=total: %s\n" "$node" "$status"
done
echo ""
commentary "These two tables are your primary replication health dashboard. Check system.replicas for overall status and system.replication_queue for pending work."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: EXPLAIN — Reading Query Plans
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: EXPLAIN — Reading Query Plans"

echo "  EXPLAIN shows how ClickHouse will execute a query without"
echo "  actually running it. EXPLAIN indexes=1 reveals granule skip"
echo "  behavior — proof that your ORDER BY key is working."
echo ""

subsection "Well-filtered query (filter on ORDER BY prefix)"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_meta_events"
echo "  WHERE event_type = 'purchase' AND user_id = 42"
echo ""
explain_good=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_meta_events WHERE event_type = 'purchase' AND user_id = 42")
echo "$explain_good"
echo ""
commentary "Look for 'Granules: X/Y' — X is the number of granules actually read, Y is total. A small X/Y ratio means the primary index is effectively skipping irrelevant data."

subsection "Poorly-filtered query (filter on non-indexed column)"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_meta_events"
echo "  WHERE region = 'us-east'"
echo ""
explain_bad=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_meta_events WHERE region = 'us-east'")
echo "$explain_bad"
echo ""
commentary "region is NOT in the ORDER BY key, so ClickHouse cannot skip granules — it reads all of them. The Granules ratio should be close to X/X (full scan)."

subsection "EXPLAIN PIPELINE — parallelism and execution stages"
echo ""
echo "  EXPLAIN PIPELINE"
echo "  SELECT event_type, count() FROM demo.lab_meta_events GROUP BY event_type"
echo ""
explain_pipeline=$(run_query "EXPLAIN PIPELINE SELECT event_type, count() FROM demo.lab_meta_events GROUP BY event_type")
echo "$explain_pipeline"
echo ""
commentary "PIPELINE shows execution stages and thread counts. MergeTreeThread reads data in parallel across parts. More threads = more parallelism."

subsection "Adding a skip index (bloom_filter) on region"
echo ""
run_query "ALTER TABLE demo.lab_meta_events ADD INDEX IF NOT EXISTS idx_region region TYPE bloom_filter(0.01) GRANULARITY 4"
echo "  ✓ bloom_filter index added on region"
run_query "ALTER TABLE demo.lab_meta_events MATERIALIZE INDEX idx_region"
echo "  ✓ Index materialized for existing data"
sleep 2
echo ""

subsection "Re-running EXPLAIN after adding skip index"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_meta_events"
echo "  WHERE region = 'us-east'"
echo ""
explain_with_skip=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_meta_events WHERE region = 'us-east'")
echo "$explain_with_skip"
echo ""
commentary "After adding the bloom_filter skip index, you should see a 'Skip' section in the EXPLAIN output. The skip index eliminates granules where the bloom filter proves 'us-east' is absent. EXPLAIN is how you prove your ORDER BY key and skip indexes are working."

pause

# ═══════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════

section "Cleanup"

echo "  Dropping lab tables..."
echo ""
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_meta_events_dist ON CLUSTER 'ch_cluster' SYNC"
echo "  ✓ Distributed table dropped"
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_meta_events ON CLUSTER 'ch_cluster' SYNC"
echo "  ✓ Local replicated table dropped"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — System Metadata Summary"

echo "  ┌──────────────────────────────────┬──────────────────────────────────────────┐"
echo "  │ Question                         │ System table to query                    │"
echo "  ├──────────────────────────────────┼──────────────────────────────────────────┤"
echo "  │ Why is this query slow?          │ system.query_log (read_rows, duration)   │"
echo "  │ Why did this query fail?         │ system.query_log (exception, type)       │"
echo "  │ How many parts does my table have│ system.parts (active, partition)         │"
echo "  │ How well is my data compressed?  │ system.columns (compressed/uncompressed) │"
echo "  │ Are merges running?              │ system.merges (progress, num_parts)      │"
echo "  │ What is the server doing now?    │ system.metrics (current gauges)          │"
echo "  │ How many rows were ever inserted?│ system.events (cumulative counters)      │"
echo "  │ Is replication healthy?          │ system.replicas (delay, queue_size)      │"
echo "  │ Any pending replication tasks?   │ system.replication_queue (type, state)   │"
echo "  │ Is my ORDER BY key effective?    │ EXPLAIN indexes=1 (granule skip ratio)  │"
echo "  │ Is my skip index working?        │ EXPLAIN indexes=1 (Skip section)        │"
echo "  └──────────────────────────────────┴──────────────────────────────────────────┘"
echo ""
echo "  See notes/09-metadata-lab.md for detailed reference."
echo ""
