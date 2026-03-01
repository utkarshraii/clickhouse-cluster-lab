#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# init-cluster.sh — Initialize the ClickHouse cluster with sample tables
# ═══════════════════════════════════════════════════════════════════
#
# What this script does:
#   1. Creates a ReplicatedMergeTree table ON CLUSTER (runs on all nodes)
#   2. Creates a Distributed table on top (query router)
#   3. Creates a Materialized View for pre-aggregation
#   4. Inserts sample data
#   5. Verifies replication works
#
# Usage:
#   ./scripts/init-cluster.sh
#
# Prerequisites:
#   - Cluster must be running: docker compose up -d
#   - All 7 containers must be healthy: docker compose ps

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
CH_NODE="ch-s1r1"  # We run DDL from one node; ON CLUSTER propagates to all
DB_NAME="demo"

run_query() {
    local query="$1"
    docker exec "$CH_NODE" clickhouse-client --query "$query"
}

run_query_multiline() {
    docker exec -i "$CH_NODE" clickhouse-client --multiquery
}

echo "════════════════════════════════════════════════════════════"
echo "  ClickHouse Cluster Initialization"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Create database ──────────────────────────────────────
echo "[1/5] Creating database '${DB_NAME}' on all nodes..."
run_query "CREATE DATABASE IF NOT EXISTS ${DB_NAME} ON CLUSTER 'ch_cluster'"
echo "  ✓ Database created"
echo ""

# ── Step 2: Create ReplicatedMergeTree table ─────────────────────
# This is the LOCAL table on each node. Each shard has its own data.
# Replicas within a shard share the same data via replication.
#
# ZK path: /clickhouse/tables/{shard}/events
#   - {shard} is substituted from macros → 01 or 02
#   - All replicas in shard 01 share this path → they replicate
#
# {replica} is substituted from macros → ch-s1r1, ch-s1r2, etc.
#   - Must be unique within a shard
echo "[2/5] Creating ReplicatedMergeTree table '${DB_NAME}.events'..."
run_query_multiline <<'SQL'
CREATE TABLE IF NOT EXISTS demo.events ON CLUSTER 'ch_cluster'
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    timestamp   DateTime,
    properties  String,
    amount      Decimal(18, 2)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/events', '{replica}')
PARTITION BY toYYYYMM(timestamp)
ORDER BY (event_type, user_id, timestamp)
SETTINGS
    -- index_granularity: rows per granule. Default 8192.
    -- Smaller → more precise index → more memory for marks.
    -- Larger → fewer marks → less precise seeks.
    index_granularity = 8192;
SQL
echo "  ✓ ReplicatedMergeTree table created on all nodes"
echo ""

# ── Step 3: Create Distributed table ─────────────────────────────
# The Distributed table is a QUERY ROUTER — it doesn't store data itself.
# When you SELECT from it, it queries all shards and merges results.
# When you INSERT into it, it routes rows to shards based on the sharding key.
#
# Arguments: Distributed(cluster, database, local_table, sharding_key)
# Sharding key: rand() distributes evenly. For co-located queries, use
# a deterministic key like cityHash64(user_id) so all data for a user
# lands on the same shard.
echo "[3/5] Creating Distributed table '${DB_NAME}.events_distributed'..."
run_query_multiline <<'SQL'
CREATE TABLE IF NOT EXISTS demo.events_distributed ON CLUSTER 'ch_cluster'
AS demo.events
ENGINE = Distributed('ch_cluster', 'demo', 'events', rand());
SQL
echo "  ✓ Distributed table created on all nodes"
echo ""

# ── Step 4: Create Materialized View for pre-aggregation ─────────
# Materialized Views in ClickHouse are INSERT triggers.
# Every time data is inserted into 'events', this view transforms it
# and inserts the result into a target table.
#
# This is NOT like a traditional SQL view that runs on-read.
# The aggregation happens at write time → queries on the target are instant.
echo "[4/5] Creating Materialized View for hourly aggregation..."
run_query_multiline <<'SQL'
CREATE TABLE IF NOT EXISTS demo.events_hourly ON CLUSTER 'ch_cluster'
(
    event_type  LowCardinality(String),
    hour        DateTime,
    user_count  AggregateFunction(uniq, UInt32),
    event_count SimpleAggregateFunction(sum, UInt64),
    total_amount SimpleAggregateFunction(sum, Decimal(38, 2))
)
ENGINE = ReplicatedAggregatingMergeTree('/clickhouse/tables/{shard}/demo/events_hourly', '{replica}')
PARTITION BY toYYYYMM(hour)
ORDER BY (event_type, hour);
SQL

run_query_multiline <<'SQL'
CREATE MATERIALIZED VIEW IF NOT EXISTS demo.events_hourly_mv ON CLUSTER 'ch_cluster'
TO demo.events_hourly
AS SELECT
    event_type,
    toStartOfHour(timestamp) AS hour,
    uniqState(user_id)       AS user_count,
    count()                  AS event_count,
    sum(amount)              AS total_amount
FROM demo.events
GROUP BY event_type, hour;
SQL
echo "  ✓ Materialized View created on all nodes"
echo ""

# ── Step 5: Insert sample data and verify replication ────────────
echo "[5/5] Inserting sample data..."

# Insert via Distributed table — rows are sharded across both shards
run_query_multiline <<'SQL'
INSERT INTO demo.events_distributed
SELECT
    number AS event_id,
    arrayElement(['click', 'view', 'purchase', 'signup'], (number % 4) + 1) AS event_type,
    (number % 1000) + 1 AS user_id,
    now() - (number * 60) AS timestamp,
    '{}' AS properties,
    round((rand() % 10000) / 100, 2) AS amount
FROM numbers(10000);
SQL
echo "  ✓ Inserted 10,000 sample events"
echo ""

# Verify data distribution
echo "════════════════════════════════════════════════════════════"
echo "  Verification"
echo "════════════════════════════════════════════════════════════"
echo ""

echo "── Row counts per node (local table) ──"
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    count=$(docker exec "$node" clickhouse-client --query "SELECT count() FROM demo.events" 2>/dev/null || echo "ERROR")
    printf "  %-10s → %s rows\n" "$node" "$count"
done
echo ""

echo "── Replication check ──"
echo "  Shard 1: s1r1 and s1r2 should have the SAME row count"
echo "  Shard 2: s2r1 and s2r2 should have the SAME row count"
echo "  Shard 1 + Shard 2 should total 10,000"
echo ""

echo "── Distributed query (all shards) ──"
run_query "SELECT count() AS total_rows FROM demo.events_distributed"
echo ""

echo "── Materialized View check ──"
run_query "SELECT event_type, sum(event_count) AS events FROM demo.events_hourly GROUP BY event_type ORDER BY event_type"
echo ""

echo "════════════════════════════════════════════════════════════"
echo "  Initialization complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Connect to any node:"
echo "    docker exec -it ch-s1r1 clickhouse-client"
echo ""
echo "  Try queries:"
echo "    SELECT * FROM demo.events_distributed LIMIT 10;"
echo "    SELECT * FROM system.clusters;"
echo "    SELECT * FROM system.replicas FORMAT Vertical;"
