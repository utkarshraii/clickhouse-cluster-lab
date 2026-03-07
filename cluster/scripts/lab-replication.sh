#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-replication.sh — Hands-On Lab: Replication & Clustering
# ═══════════════════════════════════════════════════════════════════
#
# This lab demonstrates replication, distributed queries, sharding,
# failover recovery, and Keeper internals with real operations
# across multiple nodes in a 2-shard x 2-replica cluster.
#
# Exercises:
#   1. Replication in Action          — async replication within a shard
#   2. Inspect Replication Metadata   — system.replicas + Keeper paths
#   3. Distributed Query Flow         — coordinator, local vs distributed
#   4. Sharding Key Impact            — rand() vs cityHash64()
#   5. Replica Failover & Recovery    — stop/start a node mid-flight
#   6. Keeper Health & Quorum         — ruok, mntr, stat, srvr
#
# Usage:
#   ./cluster/scripts/lab-replication.sh
#   make lab-replication
#
# Prerequisites:
#   - Cluster must be running: make up
#   - Init must have run: make init

set -euo pipefail

# ── Safety: ensure ch-s1r2 is always running at exit ─────────────
trap 'docker start ch-s1r2 2>/dev/null; exit' INT TERM

# ── Config ────────────────────────────────────────────────────────
DB_NAME="demo"
KEEPER_NODES="keeper1 keeper2 keeper3"
CH_NODES="ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2"

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

section "Replication & Clustering Hands-On Lab"
echo "  This lab operates across all 4 ClickHouse nodes to demonstrate"
echo "  replication, distributed queries, sharding, failover, and Keeper."
echo ""
echo "  Cluster: 2 shards x 2 replicas"
echo "    Shard 1: ch-s1r1, ch-s1r2"
echo "    Shard 2: ch-s2r1, ch-s2r2"
echo "    Keeper:  keeper1, keeper2, keeper3"
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: Replication in Action
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: Replication in Action"

echo "  Replication in ClickHouse is async and happens within a shard."
echo "  When you INSERT into ch-s1r1, the data is replicated to ch-s1r2"
echo "  (same shard), but NOT to ch-s2r1 or ch-s2r2 (different shard)."
echo ""

subsection "Creating table: demo.lab_repl_test ON CLUSTER"
run_multiline_on ch-s1r1 <<'SQL'
DROP TABLE IF EXISTS demo.lab_repl_test ON CLUSTER 'ch_cluster' SYNC;

CREATE TABLE demo.lab_repl_test ON CLUSTER 'ch_cluster'
(
    id       UInt64,
    value    String,
    ts       DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/lab_repl_test', '{replica}')
ORDER BY id;
SQL
echo "  ✓ Table created on all 4 nodes"
echo ""

subsection "Inserting 100 rows on ch-s1r1 (Shard 1, Replica 1)"
run_query_on ch-s1r1 "INSERT INTO demo.lab_repl_test (id, value) SELECT number, concat('row-', toString(number)) FROM numbers(100)"
echo "  ✓ Inserted 100 rows on ch-s1r1"
echo ""

# Brief wait for replication
sleep 2

subsection "Checking row counts across all nodes"
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    count=$(run_query_on "$node" "SELECT count() FROM demo.lab_repl_test")
    printf "  %-10s → %s rows\n" "$node" "$count"
done
echo ""
commentary "ch-s1r1 and ch-s1r2 both have 100 rows — async replication works within the shard. ch-s2r1 and ch-s2r2 have 0 rows — replication does NOT cross shard boundaries."

subsection "Comparing checksums between Shard 1 replicas"
echo ""
echo "  ch-s1r1 checksum:"
run_query_on ch-s1r1 "SELECT sum(cityHash64(*)) AS checksum FROM demo.lab_repl_test"
echo "  ch-s1r2 checksum:"
run_query_on ch-s1r2 "SELECT sum(cityHash64(*)) AS checksum FROM demo.lab_repl_test"
echo ""
commentary "Identical checksums prove byte-for-byte replication. The replica fetches the actual data parts via the interserver HTTP port (9009), not via Keeper."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: Inspect Replication Metadata
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: Inspect Replication Metadata"

echo "  ClickHouse exposes replication internals via system tables."
echo "  Keeper stores the metadata (part names, log entries), never data."
echo ""

subsection "system.replicas on ch-s1r1 (lab_repl_test)"
run_query_on ch-s1r1 "SELECT replica_name, is_leader, absolute_delay, queue_size, active_replicas FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test' FORMAT PrettyCompact"
echo ""

subsection "Leader status: ch-s1r1 vs ch-s1r2"
echo ""
s1r1_leader=$(run_query_on ch-s1r1 "SELECT is_leader FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test'")
s1r2_leader=$(run_query_on ch-s1r2 "SELECT is_leader FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test'")
printf "  ch-s1r1 is_leader: %s\n" "$s1r1_leader"
printf "  ch-s1r2 is_leader: %s\n" "$s1r2_leader"
echo ""
commentary "Exactly one replica per shard is the leader. The leader coordinates merge assignments so both replicas end up with the same merged parts."

subsection "Browsing Keeper path tree via system.zookeeper"
echo ""
echo "  Top-level entries for lab_repl_test:"
run_query_on ch-s1r1 "SELECT name, ctime FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/lab_repl_test' ORDER BY name FORMAT PrettyCompact"
echo ""

echo "  Registered replicas:"
run_query_on ch-s1r1 "SELECT name FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/lab_repl_test/replicas' FORMAT PrettyCompact"
echo ""

echo "  Parts registered by ch-s1r1 in Keeper:"
run_query_on ch-s1r1 "SELECT name FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/lab_repl_test/replicas/ch-s1r1/parts' FORMAT PrettyCompact"
echo ""
commentary "Keeper stores metadata only: which replicas exist, which parts each has, and the replication log. The actual data travels replica-to-replica via port 9009."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: Distributed Query Flow
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: Distributed Query Flow"

echo "  A Distributed table is a query router — it fans out to shards,"
echo "  collects partial results, and merges them. Any node can be the"
echo "  coordinator."
echo ""

subsection "Creating a Distributed table for lab_repl_test"
run_multiline_on ch-s1r1 <<'SQL'
DROP TABLE IF EXISTS demo.lab_repl_test_dist ON CLUSTER 'ch_cluster' SYNC;

CREATE TABLE demo.lab_repl_test_dist ON CLUSTER 'ch_cluster'
AS demo.lab_repl_test
ENGINE = Distributed('ch_cluster', 'demo', 'lab_repl_test', rand());
SQL
echo "  ✓ Distributed table created"
echo ""

# Insert some data on shard 2 so both shards have rows
subsection "Inserting 50 rows directly on ch-s2r1 (Shard 2)"
run_query_on ch-s2r1 "INSERT INTO demo.lab_repl_test (id, value) SELECT number + 1000, concat('shard2-row-', toString(number)) FROM numbers(50)"
echo "  ✓ Inserted 50 rows on Shard 2"
echo ""

sleep 2

subsection "Row counts: local table per node vs distributed total"
echo ""
echo "  Local table counts:"
for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do
    count=$(run_query_on "$node" "SELECT count() FROM demo.lab_repl_test")
    printf "    %-10s → %s rows\n" "$node" "$count"
done
echo ""
dist_count=$(run_query_on ch-s1r1 "SELECT count() FROM demo.lab_repl_test_dist")
echo "  Distributed count (from ch-s1r1): $dist_count"
echo ""
commentary "Distributed count = Shard 1 rows + Shard 2 rows. The coordinator (ch-s1r1) queries one replica per shard and sums the counts."

subsection "Cluster topology from system.clusters"
run_query_on ch-s1r1 "SELECT shard_num, replica_num, host_name, is_local FROM system.clusters WHERE cluster = 'ch_cluster' FORMAT PrettyCompact"
echo ""

subsection "Local aggregation (one shard) vs distributed aggregation"
echo ""
echo "  Local query on ch-s1r1 (Shard 1 only):"
run_query_on ch-s1r1 "SELECT 'shard1-local' AS scope, count() AS rows, min(id) AS min_id, max(id) AS max_id FROM demo.lab_repl_test FORMAT PrettyCompact"
echo ""
echo "  Distributed query (all shards):"
run_query_on ch-s1r1 "SELECT 'distributed' AS scope, count() AS rows, min(id) AS min_id, max(id) AS max_id FROM demo.lab_repl_test_dist FORMAT PrettyCompact"
echo ""

subsection "Same distributed query from ch-s2r1 (any node can coordinate)"
run_query_on ch-s2r1 "SELECT 'from-ch-s2r1' AS scope, count() AS rows, min(id) AS min_id, max(id) AS max_id FROM demo.lab_repl_test_dist FORMAT PrettyCompact"
echo ""
commentary "Same result from ch-s2r1 — any node in the cluster can be the coordinator for a distributed query. The Distributed table fans out to all shards regardless of where you connect."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: Sharding Key Impact
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: Sharding Key Impact"

echo "  The sharding key determines which shard receives each row."
echo "  rand() gives even distribution but scatters related data."
echo "  cityHash64(user_id) co-locates all data for a user on one shard."
echo ""

subsection "Creating two table pairs ON CLUSTER"

# rand()-sharded tables
run_multiline_on ch-s1r1 <<'SQL'
DROP TABLE IF EXISTS demo.lab_shard_rand_dist ON CLUSTER 'ch_cluster' SYNC;
DROP TABLE IF EXISTS demo.lab_shard_rand ON CLUSTER 'ch_cluster' SYNC;

CREATE TABLE demo.lab_shard_rand ON CLUSTER 'ch_cluster'
(
    user_id   UInt32,
    event     String,
    ts        DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/lab_shard_rand', '{replica}')
ORDER BY (user_id, ts);

CREATE TABLE demo.lab_shard_rand_dist ON CLUSTER 'ch_cluster'
AS demo.lab_shard_rand
ENGINE = Distributed('ch_cluster', 'demo', 'lab_shard_rand', rand());
SQL
echo "  ✓ lab_shard_rand + lab_shard_rand_dist (sharding key: rand())"

# cityHash64()-sharded tables
run_multiline_on ch-s1r1 <<'SQL'
DROP TABLE IF EXISTS demo.lab_shard_hash_dist ON CLUSTER 'ch_cluster' SYNC;
DROP TABLE IF EXISTS demo.lab_shard_hash ON CLUSTER 'ch_cluster' SYNC;

CREATE TABLE demo.lab_shard_hash ON CLUSTER 'ch_cluster'
(
    user_id   UInt32,
    event     String,
    ts        DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/demo/lab_shard_hash', '{replica}')
ORDER BY (user_id, ts);

CREATE TABLE demo.lab_shard_hash_dist ON CLUSTER 'ch_cluster'
AS demo.lab_shard_hash
ENGINE = Distributed('ch_cluster', 'demo', 'lab_shard_hash', cityHash64(user_id));
SQL
echo "  ✓ lab_shard_hash + lab_shard_hash_dist (sharding key: cityHash64(user_id))"
echo ""

subsection "Inserting 1000 rows with 10 distinct user_ids into each"
# Insert via the distributed table so the sharding key routes rows
run_multiline_on ch-s1r1 <<'SQL'
INSERT INTO demo.lab_shard_rand_dist (user_id, event)
SELECT
    (number % 10) + 1 AS user_id,
    concat('event-', toString(number)) AS event
FROM numbers(1000);

INSERT INTO demo.lab_shard_hash_dist (user_id, event)
SELECT
    (number % 10) + 1 AS user_id,
    concat('event-', toString(number)) AS event
FROM numbers(1000);
SQL
echo "  ✓ Inserted 1000 rows into each distributed table"
echo ""

sleep 2

subsection "rand() sharding — row distribution per shard"
echo ""
echo "  Shard 1 (ch-s1r1):"
run_query_on ch-s1r1 "SELECT user_id, count() AS rows FROM demo.lab_shard_rand GROUP BY user_id ORDER BY user_id FORMAT PrettyCompact"
echo ""
echo "  Shard 2 (ch-s2r1):"
run_query_on ch-s2r1 "SELECT user_id, count() AS rows FROM demo.lab_shard_rand GROUP BY user_id ORDER BY user_id FORMAT PrettyCompact"
echo ""
commentary "With rand(), rows are split ~500/500 between shards, and ALL 10 users appear on BOTH shards. Data for a single user is scattered across the cluster."

subsection "cityHash64(user_id) sharding — row distribution per shard"
echo ""
echo "  Shard 1 (ch-s1r1):"
run_query_on ch-s1r1 "SELECT user_id, count() AS rows FROM demo.lab_shard_hash GROUP BY user_id ORDER BY user_id FORMAT PrettyCompact"
echo ""
echo "  Shard 2 (ch-s2r1):"
run_query_on ch-s2r1 "SELECT user_id, count() AS rows FROM demo.lab_shard_hash GROUP BY user_id ORDER BY user_id FORMAT PrettyCompact"
echo ""
commentary "With cityHash64(user_id), each user lives on exactly ONE shard. All 100 rows for user_id=1 are co-located. This means a per-user query only needs to read from one shard — no cross-shard fan-out needed."

subsection "Per-user query comparison"
echo ""
echo "  Hash sharding: query for user_id=1 (reads one shard):"
run_query_on ch-s1r1 "SELECT count() AS rows FROM demo.lab_shard_hash_dist WHERE user_id = 1 FORMAT PrettyCompact"
echo ""
commentary "With hash sharding, queries filtered by the sharding key can be routed to a single shard instead of fanning out to all shards. This is a major performance benefit for user-scoped queries."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: Replica Failover & Recovery
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: Replica Failover & Recovery"

echo "  When a replica goes down, the cluster continues to serve reads"
echo "  and accepts writes on the surviving replica. When the failed"
echo "  replica comes back, it catches up from the replication log."
echo ""

subsection "Baseline row counts on Shard 1"
s1r1_before=$(run_query_on ch-s1r1 "SELECT count() FROM demo.lab_repl_test")
s1r2_before=$(run_query_on ch-s1r2 "SELECT count() FROM demo.lab_repl_test")
printf "  ch-s1r1: %s rows\n" "$s1r1_before"
printf "  ch-s1r2: %s rows\n" "$s1r2_before"
echo ""

subsection "Stopping ch-s1r2 (simulate replica failure)"
docker stop ch-s1r2
echo "  ✓ ch-s1r2 stopped"
echo ""

sleep 3

subsection "Inserting 200 rows on ch-s1r1 while ch-s1r2 is down"
run_query_on ch-s1r1 "INSERT INTO demo.lab_repl_test (id, value) SELECT number + 5000, concat('failover-row-', toString(number)) FROM numbers(200)"
echo "  ✓ Inserted 200 rows on ch-s1r1"
echo ""

subsection "Distributed query still works (routes to live replica)"
dist_count=$(run_query_on ch-s1r1 "SELECT count() FROM demo.lab_repl_test_dist")
echo "  Distributed count: $dist_count (Shard 1 via ch-s1r1 + Shard 2)"
echo ""
commentary "The distributed table routes Shard 1 queries to ch-s1r1 (the surviving replica). No data loss, no downtime for reads."

subsection "Replication metadata while ch-s1r2 is down"
active=$(run_query_on ch-s1r1 "SELECT active_replicas FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test'")
echo "  active_replicas: $active (expected: 1 — ch-s1r2 is down)"
echo ""

subsection "Restarting ch-s1r2"
docker start ch-s1r2
echo "  ✓ ch-s1r2 start issued"
echo ""

echo "  Waiting for ch-s1r2 to become healthy..."
max_wait=150
elapsed=0
while [ "$elapsed" -lt "$max_wait" ]; do
    status=$(docker inspect --format='{{.State.Health.Status}}' ch-s1r2 2>/dev/null || echo "unknown")
    if [ "$status" = "healthy" ]; then
        echo "  ✓ ch-s1r2 is healthy (took ~${elapsed}s)"
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done
if [ "$elapsed" -ge "$max_wait" ]; then
    echo "  ⚠ ch-s1r2 did not become healthy within ${max_wait}s — continuing anyway"
fi
echo ""

# Give replication a moment to catch up
sleep 3

subsection "Verifying ch-s1r2 caught up"
s1r1_after=$(run_query_on ch-s1r1 "SELECT count() FROM demo.lab_repl_test")
s1r2_after=$(run_query_on ch-s1r2 "SELECT count() FROM demo.lab_repl_test")
printf "  ch-s1r1: %s rows\n" "$s1r1_after"
printf "  ch-s1r2: %s rows\n" "$s1r2_after"
echo ""

queue_size=$(run_query_on ch-s1r2 "SELECT queue_size FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test'")
active_after=$(run_query_on ch-s1r1 "SELECT active_replicas FROM system.replicas WHERE database = 'demo' AND table = 'lab_repl_test'")
echo "  ch-s1r2 queue_size: $queue_size (0 = fully caught up)"
echo "  active_replicas: $active_after (should be 2 again)"
echo ""
commentary "ch-s1r2 fetched the 200 rows it missed from the replication log. queue_size=0 means nothing pending. active_replicas is back to 2. This is the self-healing nature of ReplicatedMergeTree."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: Keeper Health & Quorum
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: Keeper Health & Quorum"

echo "  ClickHouse Keeper (Raft consensus) stores all replication metadata."
echo "  3 nodes = tolerates 1 failure. If 2 die, cluster goes read-only."
echo ""

subsection "ruok on all 3 keepers (expect 'imok')"
for keeper in keeper1 keeper2 keeper3; do
    response=$(docker exec "$keeper" clickhouse-keeper-client -h localhost -p 9181 --query 'ruok' 2>/dev/null || echo "no_response")
    printf "  %-10s → %s\n" "$keeper" "$response"
done
echo ""

subsection "mntr on keeper1 (monitoring stats)"
echo ""
docker exec keeper1 clickhouse-keeper-client -h localhost -p 9181 --query 'mntr' 2>/dev/null | grep -E 'zk_server_state|zk_followers|zk_znode_count|zk_approximate_data_size' || echo "  (mntr not available)"
echo ""
commentary "mntr shows key Keeper metrics: server_state (leader/follower), follower count, total znode count, and approximate data size."

subsection "stat on all 3 keepers (identify leader vs followers)"
echo ""
for keeper in keeper1 keeper2 keeper3; do
    state=$(docker exec "$keeper" clickhouse-keeper-client -h localhost -p 9181 --query 'srvr' 2>/dev/null | grep -i 'mode' || echo "  mode: unknown")
    printf "  %-10s → %s\n" "$keeper" "$(echo "$state" | xargs)"
done
echo ""

subsection "Finding the Keeper leader"
echo ""
for keeper in keeper1 keeper2 keeper3; do
    srvr_output=$(docker exec "$keeper" clickhouse-keeper-client -h localhost -p 9181 --query 'srvr' 2>/dev/null || echo "")
    if echo "$srvr_output" | grep -qi "leader"; then
        echo "  Leader: $keeper"
        echo ""
        echo "  Full srvr output for the leader:"
        echo "$srvr_output" | head -20
        break
    fi
done
echo ""
commentary "Exactly one Keeper is the leader (handles all writes). Followers replicate via Raft. The leader was elected by majority vote (2 of 3). If the leader dies, a new election happens automatically."

# ═══════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════

section "Cleanup"

echo "  Dropping all lab tables (distributed tables first, then local)..."
echo ""

# Drop distributed tables first (they reference the local tables)
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_repl_test_dist ON CLUSTER 'ch_cluster' SYNC"
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_shard_rand_dist ON CLUSTER 'ch_cluster' SYNC"
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_shard_hash_dist ON CLUSTER 'ch_cluster' SYNC"
echo "  ✓ Distributed tables dropped"

# Drop local replicated tables
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_repl_test ON CLUSTER 'ch_cluster' SYNC"
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_shard_rand ON CLUSTER 'ch_cluster' SYNC"
run_query_on ch-s1r1 "DROP TABLE IF EXISTS demo.lab_shard_hash ON CLUSTER 'ch_cluster' SYNC"
echo "  ✓ Local replicated tables dropped"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — Replication & Clustering Summary"

echo "  ┌──────────────────────────────────┬─────────────────────────────────────────┐"
echo "  │ Concept                          │ What we observed                        │"
echo "  ├──────────────────────────────────┼─────────────────────────────────────────┤"
echo "  │ Async replication                │ INSERT on r1 → appears on r2 in <2s    │"
echo "  │ Shard isolation                  │ Shard 2 has 0 rows after shard 1 write │"
echo "  │ Checksum match                   │ Byte-identical data on both replicas   │"
echo "  │ Leader election                  │ Exactly 1 leader per shard             │"
echo "  │ Keeper metadata                  │ Part names, replicas visible in ZK tree│"
echo "  │ Distributed queries              │ Any node can coordinate, same result   │"
echo "  │ rand() sharding                  │ Even split, users on both shards       │"
echo "  │ cityHash64() sharding            │ User co-location on one shard          │"
echo "  │ Failover (stop replica)          │ Writes + reads continue on survivor    │"
echo "  │ Recovery (start replica)         │ Catches up from replication log        │"
echo "  │ Keeper quorum                    │ 3 nodes, 1 leader, all respond 'imok'  │"
echo "  └──────────────────────────────────┴─────────────────────────────────────────┘"
echo ""
echo "  See notes/08-replication-lab.md for detailed reference."
echo ""
