#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# health-check.sh — Verify ClickHouse cluster health
# ═══════════════════════════════════════════════════════════════════
#
# Checks:
#   1. Container status
#   2. Keeper quorum health
#   3. Cluster topology (system.clusters)
#   4. Replication status (system.replicas)
#   5. Part counts (system.parts)
#   6. Active merges (system.merges)
#   7. Recent errors (system.errors)
#
# Usage:
#   ./scripts/health-check.sh

set -euo pipefail

CH_NODE="ch-s1r1"
KEEPER_NODES="keeper1 keeper2 keeper3"
CH_NODES="ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

run_query() {
    docker exec "$1" clickhouse-client --query "$2" 2>/dev/null
}

echo "════════════════════════════════════════════════════════════"
echo "  ClickHouse Cluster Health Check"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── 1. Container Status ──────────────────────────────────────────
echo "── 1. Container Status ──"
all_healthy=true
for container in $KEEPER_NODES $CH_NODES; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")
    case "$status" in
        healthy)   pass "$container: healthy" ;;
        unhealthy) fail "$container: unhealthy"; all_healthy=false ;;
        starting)  warn "$container: starting..."; all_healthy=false ;;
        *)         fail "$container: $status"; all_healthy=false ;;
    esac
done
echo ""

# ── 2. Keeper Quorum ─────────────────────────────────────────────
echo "── 2. Keeper Quorum ──"
leader_count=0
for keeper in $KEEPER_NODES; do
    # Use clickhouse-keeper-client instead of nc (BusyBox nc doesn't handle four-letter commands reliably)
    response=$(docker exec "$keeper" clickhouse-keeper-client -h localhost -p 9181 --query 'ruok' 2>/dev/null || echo "no_response")
    if [ "$response" = "imok" ]; then
        # Check if this node is the leader
        stat_response=$(docker exec "$keeper" clickhouse-keeper-client -h localhost -p 9181 --query 'stat' 2>/dev/null || echo "")
        if echo "$stat_response" | grep -q "leader"; then
            pass "$keeper: healthy (LEADER)"
            leader_count=$((leader_count + 1))
        else
            pass "$keeper: healthy (follower)"
        fi
    else
        fail "$keeper: not responding"
    fi
done
if [ "$leader_count" -eq 0 ]; then
    fail "No keeper leader elected! Cluster cannot accept DDL or replication."
elif [ "$leader_count" -gt 1 ]; then
    fail "Multiple leaders detected! Possible split-brain."
fi
echo ""

# ── 3. Cluster Topology ─────────────────────────────────────────
echo "── 3. Cluster Topology (system.clusters) ──"
cluster_info=$(run_query "$CH_NODE" "SELECT cluster, shard_num, replica_num, host_name, is_local FROM system.clusters WHERE cluster = 'ch_cluster' FORMAT PrettyCompact" 2>/dev/null || echo "FAILED")
if [ "$cluster_info" = "FAILED" ]; then
    fail "Cannot query system.clusters"
else
    echo "$cluster_info"
    node_count=$(run_query "$CH_NODE" "SELECT count() FROM system.clusters WHERE cluster = 'ch_cluster'" 2>/dev/null || echo "0")
    if [ "$node_count" -eq 4 ]; then
        pass "All 4 nodes visible in cluster topology"
    else
        fail "Expected 4 nodes, found $node_count"
    fi
fi
echo ""

# ── 4. Replication Status ────────────────────────────────────────
echo "── 4. Replication Status (system.replicas) ──"
for node in $CH_NODES; do
    replica_info=$(run_query "$node" "
        SELECT
            database, table, replica_name,
            is_leader,
            absolute_delay,
            queue_size,
            inserts_in_queue,
            merges_in_queue,
            total_replicas,
            active_replicas
        FROM system.replicas
        FORMAT PrettyCompact
    " 2>/dev/null || echo "")

    if [ -z "$replica_info" ]; then
        warn "$node: No replicated tables found (run init-cluster.sh first)"
    else
        echo "  [$node]"
        echo "$replica_info"

        # Check for replication lag
        max_delay=$(run_query "$node" "SELECT max(absolute_delay) FROM system.replicas" 2>/dev/null || echo "0")
        if [ "$max_delay" -gt 10 ]; then
            warn "$node: Replication delay = ${max_delay}s (>10s)"
        fi

        # Check queue depth
        queue=$(run_query "$node" "SELECT sum(queue_size) FROM system.replicas" 2>/dev/null || echo "0")
        if [ "$queue" -gt 0 ]; then
            warn "$node: Replication queue has $queue pending items"
        fi
    fi
done
echo ""

# ── 5. Part Counts ───────────────────────────────────────────────
echo "── 5. Part Counts (system.parts) ──"
for node in $CH_NODES; do
    parts_info=$(run_query "$node" "
        SELECT
            database, table,
            count() AS parts,
            sum(rows) AS total_rows,
            formatReadableSize(sum(bytes_on_disk)) AS disk_size
        FROM system.parts
        WHERE active AND database != 'system'
        GROUP BY database, table
        ORDER BY database, table
        FORMAT PrettyCompact
    " 2>/dev/null || echo "")

    if [ -z "$parts_info" ]; then
        warn "$node: No user data parts"
    else
        echo "  [$node]"
        echo "$parts_info"

        # Check for too many parts (sign of insert problems)
        max_parts=$(run_query "$node" "
            SELECT max(c) FROM (
                SELECT count() AS c FROM system.parts
                WHERE active AND database != 'system'
                GROUP BY database, table
            )
        " 2>/dev/null || echo "0")
        if [ "$max_parts" -gt 300 ]; then
            fail "$node: Table has $max_parts parts — too many! Check insert batching."
        fi
    fi
done
echo ""

# ── 6. Active Merges ─────────────────────────────────────────────
echo "── 6. Active Merges ──"
for node in $CH_NODES; do
    merge_count=$(run_query "$node" "SELECT count() FROM system.merges" 2>/dev/null || echo "0")
    if [ "$merge_count" -gt 0 ]; then
        warn "$node: $merge_count active merge(s)"
        run_query "$node" "
            SELECT database, table, round(progress * 100, 1) AS pct,
                   formatReadableSize(total_size_bytes_compressed) AS size
            FROM system.merges
            FORMAT PrettyCompact
        " 2>/dev/null
    else
        pass "$node: No active merges"
    fi
done
echo ""

# ── 7. Recent Errors ─────────────────────────────────────────────
echo "── 7. Recent Errors (system.errors) ──"
for node in $CH_NODES; do
    error_count=$(run_query "$node" "SELECT count() FROM system.errors WHERE last_error_time > now() - INTERVAL 1 HOUR" 2>/dev/null || echo "0")
    if [ "$error_count" -gt 0 ]; then
        warn "$node: $error_count error type(s) in the last hour:"
        run_query "$node" "
            SELECT name, value AS count, last_error_message
            FROM system.errors
            WHERE last_error_time > now() - INTERVAL 1 HOUR
            ORDER BY value DESC
            LIMIT 5
            FORMAT PrettyCompact
        " 2>/dev/null
    else
        pass "$node: No recent errors"
    fi
done
echo ""

echo "════════════════════════════════════════════════════════════"
if $all_healthy; then
    echo -e "  ${GREEN}All checks passed!${NC}"
else
    echo -e "  ${YELLOW}Some issues detected — review above.${NC}"
fi
echo "════════════════════════════════════════════════════════════"
