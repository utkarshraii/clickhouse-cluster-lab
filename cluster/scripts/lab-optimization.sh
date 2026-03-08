#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-optimization.sh — Hands-On Lab: Data Modeling & Query Optimization
# ═══════════════════════════════════════════════════════════════════
#
# This lab demonstrates how ORDER BY keys, skip indexes, projections,
# and materialized views affect query performance. Students design
# schemas, measure query performance, and see the impact with real data.
#
# Exercises:
#   1. ORDER BY Key         — Good vs bad key selection
#   2. PREWHERE             — Automatic early filtering
#   3. Skip Indexes         — bloom_filter, minmax, set
#   4. Projections          — Alternative sort orders
#   5. Materialized Views   — Write-time aggregation
#   6. Putting It Together  — Full optimization workflow
#
# Usage:
#   ./cluster/scripts/lab-optimization.sh
#   make lab-optimization
#
# Prerequisites:
#   - Cluster must be running: make up
#   - Init must have run: make init

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────
CH_NODE="ch-s1r1"
DB_NAME="demo"

run_query() {
    local query="$1"
    docker exec "$CH_NODE" clickhouse-client --query "$query"
}

run_query_with_id() {
    local query_id="$1"
    local query="$2"
    docker exec "$CH_NODE" clickhouse-client --query_id "$query_id" --query "$query"
}

run_query_multiline() {
    docker exec -i "$CH_NODE" clickhouse-client --multiquery
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

section "Data Modeling & Query Optimization Hands-On Lab"
echo "  This lab demonstrates how ORDER BY keys, skip indexes,"
echo "  projections, and materialized views affect query performance."
echo ""
echo "  All exercises run on ${CH_NODE} (single-node focus)."
echo "  Optimization concepts don't need multi-node to demonstrate."
echo ""

# ── Setup: Create base table with 500K rows ───────────────────────

section "Setup: Creating base table with 500K rows"

run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_events;

CREATE TABLE demo.lab_opt_events
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime,
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (event_type, user_id, ts)
SETTINGS index_granularity = 8192;
SQL
echo "  ✓ Table created"

echo "  Inserting 500K rows..."
run_query "INSERT INTO demo.lab_opt_events (event_id, event_type, user_id, region, ts, amount, payload) SELECT number AS event_id, arrayElement(['click', 'view', 'purchase', 'signup', 'logout'], (number % 5) + 1) AS event_type, (number % 10000) + 1 AS user_id, arrayElement(['us-east', 'us-west', 'eu-west', 'eu-east', 'ap-south', 'ap-east', 'sa-east', 'af-south', 'me-west', 'oc-east'], (number % 10) + 1) AS region, now() - toIntervalSecond(number) AS ts, round((number % 1000) / 10, 2) AS amount, repeat('x', 100) AS payload FROM numbers(500000)"
echo "  ✓ 500K rows inserted"

run_query "OPTIMIZE TABLE demo.lab_opt_events FINAL"
echo "  ✓ Table optimized"
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: ORDER BY Key — Good vs Bad
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: ORDER BY Key — Good vs Bad"

echo "  The ORDER BY key is your most important performance decision."
echo "  It determines the primary index — which granules ClickHouse"
echo "  can skip when processing a query."
echo ""

subsection "Creating two tables with different ORDER BY keys"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_good;
DROP TABLE IF EXISTS demo.lab_opt_bad;

CREATE TABLE demo.lab_opt_good
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime,
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = MergeTree()
ORDER BY (event_type, user_id, ts)
SETTINGS index_granularity = 8192;

CREATE TABLE demo.lab_opt_bad
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime,
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = MergeTree()
ORDER BY (ts, event_type)
SETTINGS index_granularity = 8192;
SQL
echo "  ✓ lab_opt_good: ORDER BY (event_type, user_id, ts) — low cardinality first"
echo "  ✓ lab_opt_bad:  ORDER BY (ts, event_type) — high cardinality first"
echo ""

subsection "Inserting 500K identical rows into each"
run_query "INSERT INTO demo.lab_opt_good SELECT * FROM demo.lab_opt_events"
run_query "INSERT INTO demo.lab_opt_bad SELECT * FROM demo.lab_opt_events"
run_query "OPTIMIZE TABLE demo.lab_opt_good FINAL"
run_query "OPTIMIZE TABLE demo.lab_opt_bad FINAL"
echo "  ✓ Both tables populated and optimized"
echo ""

subsection "Running the same query on both tables"
echo ""
echo "  Query: SELECT count() WHERE event_type = 'purchase' AND user_id = 42"
echo ""

run_query_with_id "lab_opt_ex1_good" "SELECT count() FROM demo.lab_opt_good WHERE event_type = 'purchase' AND user_id = 42 FORMAT Null"
run_query_with_id "lab_opt_ex1_bad" "SELECT count() FROM demo.lab_opt_bad WHERE event_type = 'purchase' AND user_id = 42 FORMAT Null"
run_query "SYSTEM FLUSH LOGS"

subsection "Performance comparison from system.query_log"
run_query_multiline <<'SQL'
SELECT
    query_id,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms
FROM system.query_log
WHERE query_id IN ('lab_opt_ex1_good', 'lab_opt_ex1_bad')
    AND type = 'QueryFinish'
ORDER BY query_id
FORMAT PrettyCompact
SQL
echo ""

subsection "EXPLAIN indexes=1 on GOOD table"
echo ""
explain_good=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_good WHERE event_type = 'purchase' AND user_id = 42")
echo "$explain_good"
echo ""

subsection "EXPLAIN indexes=1 on BAD table"
echo ""
explain_bad=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_bad WHERE event_type = 'purchase' AND user_id = 42")
echo "$explain_bad"
echo ""

commentary "The GOOD table (event_type, user_id, ts) reads far fewer rows because the filter matches the ORDER BY prefix. The BAD table (ts, event_type) can't use the primary index effectively — ts is too high-cardinality as the first key. Rule: low cardinality columns first in ORDER BY."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: PREWHERE — Automatic Early Filtering
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: PREWHERE — Automatic Early Filtering"

echo "  ClickHouse automatically converts WHERE to PREWHERE for"
echo "  MergeTree tables. PREWHERE reads filter columns first, then"
echo "  loads other columns only for matching rows."
echo ""

subsection "EXPLAIN showing automatic PREWHERE conversion"
echo ""
echo "  EXPLAIN SELECT * FROM demo.lab_opt_good WHERE event_type = 'purchase'"
echo ""
explain_prewhere=$(run_query "EXPLAIN SELECT * FROM demo.lab_opt_good WHERE event_type = 'purchase'")
echo "$explain_prewhere"
echo ""
commentary "Look for 'Prewhere' in the output. ClickHouse automatically moved the WHERE filter to PREWHERE — it reads event_type first, and only loads other columns (payload, amount, etc.) for matching rows."

subsection "Column selectivity: fewer columns = less I/O"
echo ""
run_query_with_id "lab_opt_ex2_star" "SELECT * FROM demo.lab_opt_good WHERE event_type = 'purchase' FORMAT Null"
run_query_with_id "lab_opt_ex2_agg" "SELECT event_type, count() FROM demo.lab_opt_good WHERE event_type = 'purchase' GROUP BY event_type FORMAT Null"
run_query "SYSTEM FLUSH LOGS"

run_query_multiline <<'SQL'
SELECT
    query_id,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms
FROM system.query_log
WHERE query_id IN ('lab_opt_ex2_star', 'lab_opt_ex2_agg')
    AND type = 'QueryFinish'
ORDER BY query_id
FORMAT PrettyCompact
SQL
echo ""
commentary "Both queries read the same rows, but read_bytes differs significantly. SELECT * loads all columns (including the 100-char payload). SELECT event_type, count() loads only the event_type column. Columnar storage means fewer columns in SELECT = less I/O."

subsection "Manual PREWHERE example"
echo ""
echo "  EXPLAIN SELECT * FROM demo.lab_opt_good"
echo "  PREWHERE event_type = 'purchase' WHERE amount > 50"
echo ""
explain_manual=$(run_query "EXPLAIN SELECT * FROM demo.lab_opt_good PREWHERE event_type = 'purchase' WHERE amount > 50")
echo "$explain_manual"
echo ""
commentary "You can manually split filters: PREWHERE for the cheap filter (reads one column first), WHERE for the rest. ClickHouse usually does this automatically, but manual control helps when you know your data better."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: Skip Indexes — bloom_filter, minmax, set
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: Skip Indexes — bloom_filter, minmax, set"

echo "  Skip indexes work AFTER the primary index. They let ClickHouse"
echo "  skip granule blocks for columns not in the ORDER BY key."
echo ""

subsection "Baseline: query on region (not in ORDER BY) — full scan"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_opt_good WHERE region = 'us-east'"
echo ""
explain_no_skip=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_good WHERE region = 'us-east'")
echo "$explain_no_skip"
echo ""
commentary "region is not in the ORDER BY key, so the primary index cannot help. All granules are read."

subsection "Adding bloom_filter index on region"
run_query "ALTER TABLE demo.lab_opt_good ADD INDEX IF NOT EXISTS idx_region region TYPE bloom_filter(0.01) GRANULARITY 4"
run_query "ALTER TABLE demo.lab_opt_good MATERIALIZE INDEX idx_region"
echo "  ✓ bloom_filter(0.01) index added and materialized on region"
sleep 2
echo ""

subsection "After bloom_filter — EXPLAIN shows skip behavior"
echo ""
explain_bloom=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_good WHERE region = 'us-east'")
echo "$explain_bloom"
echo ""
commentary "The Skip section shows how many granule blocks the bloom_filter eliminated. bloom_filter is best for equality checks (WHERE column = value)."

subsection "Adding minmax index on amount"
run_query "ALTER TABLE demo.lab_opt_good ADD INDEX IF NOT EXISTS idx_amount amount TYPE minmax GRANULARITY 4"
run_query "ALTER TABLE demo.lab_opt_good MATERIALIZE INDEX idx_amount"
echo "  ✓ minmax index added and materialized on amount"
sleep 2
echo ""

subsection "minmax index for range queries"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_opt_good WHERE amount > 90"
echo ""
explain_minmax=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_good WHERE amount > 90")
echo "$explain_minmax"
echo ""
commentary "minmax stores the min and max value per granule block. If the range [min, max] doesn't overlap with amount > 90, the entire block is skipped. Best for range filters."

subsection "Adding set index on event_type (low cardinality)"
run_query "ALTER TABLE demo.lab_opt_good ADD INDEX IF NOT EXISTS idx_event_type event_type TYPE set(10) GRANULARITY 4"
run_query "ALTER TABLE demo.lab_opt_good MATERIALIZE INDEX idx_event_type"
echo "  ✓ set(10) index added and materialized on event_type"
sleep 2
echo ""

subsection "set index for IN/= queries"
echo ""
echo "  EXPLAIN indexes = 1"
echo "  SELECT count() FROM demo.lab_opt_good WHERE event_type IN ('purchase', 'signup')"
echo ""
explain_set=$(run_query "EXPLAIN indexes = 1 SELECT count() FROM demo.lab_opt_good WHERE event_type IN ('purchase', 'signup')")
echo "$explain_set"
echo ""

echo "  Skip index comparison:"
echo "  ┌─────────────┬──────────────────────┬──────────────────────────┐"
echo "  │ Index Type   │ Best For             │ Example Filter           │"
echo "  ├─────────────┼──────────────────────┼──────────────────────────┤"
echo "  │ bloom_filter │ Equality, IN         │ WHERE region = 'us-east' │"
echo "  │ minmax       │ Range comparisons    │ WHERE amount > 90        │"
echo "  │ set(N)       │ Low-cardinality IN/= │ WHERE type IN (...)      │"
echo "  └─────────────┴──────────────────────┴──────────────────────────┘"
echo ""
commentary "Skip indexes are secondary — they work AFTER the primary index, skipping granule blocks the primary index couldn't eliminate. They add storage overhead, so only add them for columns you actually filter on."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: Projections — Alternative Sort Orders
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: Projections — Alternative Sort Orders"

echo "  Projections store a second copy of the data with a different"
echo "  ORDER BY key. The query optimizer automatically picks the best"
echo "  projection for each query."
echo ""

subsection "Baseline: user-centric query on the good table (user_id is 2nd in ORDER BY)"
echo ""
run_query_with_id "lab_opt_ex4_no_proj" "SELECT user_id, count(), sum(amount) FROM demo.lab_opt_good WHERE user_id = 42 GROUP BY user_id FORMAT Null"
run_query "SYSTEM FLUSH LOGS"
echo "  Baseline read_rows:"
run_query "SELECT read_rows FROM system.query_log WHERE query_id = 'lab_opt_ex4_no_proj' AND type = 'QueryFinish'"
echo ""

subsection "Adding a projection sorted by (user_id, ts)"
run_query_multiline <<'SQL'
ALTER TABLE demo.lab_opt_good
    ADD PROJECTION IF NOT EXISTS proj_by_user
    (SELECT * ORDER BY user_id, ts);
SQL
echo "  ✓ Projection added"
run_query "ALTER TABLE demo.lab_opt_good MATERIALIZE PROJECTION proj_by_user"
echo "  ✓ Projection materialized for existing data"
sleep 2
echo ""

subsection "Same query after projection — optimizer selects it"
echo ""
echo "  EXPLAIN"
echo "  SELECT user_id, count(), sum(amount)"
echo "  FROM demo.lab_opt_good WHERE user_id = 42 GROUP BY user_id"
echo ""
explain_proj=$(run_query "EXPLAIN SELECT user_id, count(), sum(amount) FROM demo.lab_opt_good WHERE user_id = 42 GROUP BY user_id")
echo "$explain_proj"
echo ""

run_query_with_id "lab_opt_ex4_with_proj" "SELECT user_id, count(), sum(amount) FROM demo.lab_opt_good WHERE user_id = 42 GROUP BY user_id FORMAT Null"
run_query "SYSTEM FLUSH LOGS"
echo "  With projection read_rows:"
run_query "SELECT read_rows FROM system.query_log WHERE query_id = 'lab_opt_ex4_with_proj' AND type = 'QueryFinish'"
echo ""
commentary "The projection reorders data by (user_id, ts), so WHERE user_id = 42 can now use the primary index on the projection. The optimizer automatically chooses the projection with fewer granules to read."

subsection "Pre-aggregation projection"
run_query_multiline <<'SQL'
ALTER TABLE demo.lab_opt_good
    ADD PROJECTION IF NOT EXISTS proj_hourly_agg
    (
        SELECT
            event_type,
            toStartOfHour(ts) AS hour,
            count() AS cnt,
            sum(amount) AS total_amount
        GROUP BY event_type, hour
    );
SQL
echo "  ✓ Aggregation projection added"
run_query "ALTER TABLE demo.lab_opt_good MATERIALIZE PROJECTION proj_hourly_agg"
echo "  ✓ Projection materialized"
sleep 2
echo ""

subsection "Aggregation query — reads from pre-aggregated projection"
echo ""
run_query_with_id "lab_opt_ex4_agg_proj" "SELECT event_type, toStartOfHour(ts) AS hour, count() AS cnt, sum(amount) AS total_amount FROM demo.lab_opt_good GROUP BY event_type, hour ORDER BY event_type, hour LIMIT 10 FORMAT PrettyCompact"
run_query "SYSTEM FLUSH LOGS"
echo ""
echo "  Aggregation projection read_rows:"
run_query "SELECT read_rows FROM system.query_log WHERE query_id = 'lab_opt_ex4_agg_proj' AND type = 'QueryFinish'"
echo ""
commentary "The aggregation projection pre-computes count() and sum(amount) per (event_type, hour). Instead of scanning 500K rows, the optimizer reads the pre-aggregated data. Projections = 2x storage but exact secondary index. Use for your second-most-common query pattern."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: Materialized Views — Write-Time Aggregation
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: Materialized Views — Write-Time Aggregation"

echo "  Materialized Views (MVs) are INSERT triggers. When new data is"
echo "  inserted into the source table, the MV transforms it and writes"
echo "  to a separate target table. This is the most powerful optimization"
echo "  tool in ClickHouse."
echo ""

subsection "Creating target table (AggregatingMergeTree) and MV"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_mv_hourly;
DROP TABLE IF EXISTS demo.lab_opt_hourly;

CREATE TABLE demo.lab_opt_hourly
(
    event_type  LowCardinality(String),
    hour        DateTime,
    cnt         AggregateFunction(count, UInt64),
    total_amount AggregateFunction(sum, Decimal(18, 2)),
    unique_users AggregateFunction(uniq, UInt32)
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_type, hour);

CREATE MATERIALIZED VIEW demo.lab_opt_mv_hourly
TO demo.lab_opt_hourly
AS SELECT
    event_type,
    toStartOfHour(ts) AS hour,
    countState() AS cnt,
    sumState(amount) AS total_amount,
    uniqState(user_id) AS unique_users
FROM demo.lab_opt_good
GROUP BY event_type, hour;
SQL
echo "  ✓ Target table and MV created"
echo ""

subsection "Inserting 100K rows into source — MV fires automatically"
run_query "INSERT INTO demo.lab_opt_good (event_id, event_type, user_id, region, ts, amount, payload) SELECT 500000 + number AS event_id, arrayElement(['click', 'view', 'purchase', 'signup', 'logout'], (number % 5) + 1) AS event_type, (number % 10000) + 1 AS user_id, arrayElement(['us-east', 'us-west', 'eu-west'], (number % 3) + 1) AS region, now() - toIntervalSecond(number) AS ts, round((number % 1000) / 10, 2) AS amount, repeat('z', 100) AS payload FROM numbers(100000)"
echo "  ✓ Inserted 100K rows (MV populated automatically)"
echo ""

subsection "Row count comparison: source vs MV target"
source_rows=$(run_query "SELECT count() FROM demo.lab_opt_good")
target_rows=$(run_query "SELECT count() FROM demo.lab_opt_hourly")
echo "  Source table (lab_opt_good):  $source_rows rows"
echo "  Target table (lab_opt_hourly): $target_rows rows"
echo ""

subsection "Querying the MV target with -Merge combinators"
run_query_multiline <<'SQL'
SELECT
    event_type,
    hour,
    countMerge(cnt) AS total_events,
    sumMerge(total_amount) AS total_amount,
    uniqMerge(unique_users) AS unique_users
FROM demo.lab_opt_hourly
GROUP BY event_type, hour
ORDER BY event_type, hour
LIMIT 10
FORMAT PrettyCompact
SQL
echo ""

subsection "Performance comparison: raw aggregation vs MV"
run_query_with_id "lab_opt_ex5_raw" "SELECT event_type, toStartOfHour(ts) AS hour, count() AS cnt, sum(amount) AS total_amount, uniq(user_id) AS unique_users FROM demo.lab_opt_good GROUP BY event_type, hour ORDER BY event_type, hour FORMAT Null"
run_query_with_id "lab_opt_ex5_mv" "SELECT event_type, hour, countMerge(cnt) AS cnt, sumMerge(total_amount) AS total_amount, uniqMerge(unique_users) AS unique_users FROM demo.lab_opt_hourly GROUP BY event_type, hour ORDER BY event_type, hour FORMAT Null"
run_query "SYSTEM FLUSH LOGS"

run_query_multiline <<'SQL'
SELECT
    query_id,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms
FROM system.query_log
WHERE query_id IN ('lab_opt_ex5_raw', 'lab_opt_ex5_mv')
    AND type = 'QueryFinish'
ORDER BY query_id
FORMAT PrettyCompact
SQL
echo ""
commentary "The MV target has far fewer rows (pre-aggregated by event_type + hour). Querying it reads orders of magnitude less data. MVs are INSERT triggers that write to a separate table — the most powerful optimization tool in ClickHouse. Use MV when: different schema/engine, massive row reduction. Use projections when: same table, transparent to queries."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: Putting It All Together — Optimization Workflow
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: Putting It All Together — Optimization Workflow"

echo "  Let's walk through a complete optimization workflow:"
echo "  1. Start with a bad table"
echo "  2. Measure baseline performance"
echo "  3. Fix ORDER BY, add skip indexes, add projection, create MV"
echo "  4. Compare before vs after"
echo ""

subsection "Step 1: Create a 'bad' table (high-cardinality ORDER BY, no indexes)"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_baseline;

CREATE TABLE demo.lab_opt_baseline
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime,
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = MergeTree()
ORDER BY (event_id)
SETTINGS index_granularity = 8192;
SQL
run_query "INSERT INTO demo.lab_opt_baseline SELECT * FROM demo.lab_opt_events"
run_query "OPTIMIZE TABLE demo.lab_opt_baseline FINAL"
echo "  ✓ Bad table created: ORDER BY (event_id) — worst case for all our queries"
echo ""

subsection "Step 2: Baseline — 4 representative queries"
echo ""
echo "  Q1: Filter by event_type + user_id"
echo "  Q2: Filter by user_id only"
echo "  Q3: Filter by region"
echo "  Q4: Hourly aggregation by event_type"
echo ""

run_query_with_id "lab_opt_ex6_q1_before" "SELECT count(), sum(amount) FROM demo.lab_opt_baseline WHERE event_type = 'purchase' AND user_id = 42 FORMAT Null"
run_query_with_id "lab_opt_ex6_q2_before" "SELECT count(), sum(amount) FROM demo.lab_opt_baseline WHERE user_id = 42 FORMAT Null"
run_query_with_id "lab_opt_ex6_q3_before" "SELECT count() FROM demo.lab_opt_baseline WHERE region = 'us-east' FORMAT Null"
run_query_with_id "lab_opt_ex6_q4_before" "SELECT event_type, toStartOfHour(ts) AS hour, count(), sum(amount) FROM demo.lab_opt_baseline GROUP BY event_type, hour FORMAT Null"
run_query "SYSTEM FLUSH LOGS"

echo "  Baseline performance:"
run_query_multiline <<'SQL'
SELECT
    query_id,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms AS ms
FROM system.query_log
WHERE query_id LIKE 'lab_opt_ex6_%_before'
    AND type = 'QueryFinish'
ORDER BY query_id
FORMAT PrettyCompact
SQL
echo ""

subsection "Step 3a: Fix ORDER BY (recreate with good key)"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_optimized;

CREATE TABLE demo.lab_opt_optimized
(
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    region      LowCardinality(String),
    ts          DateTime,
    amount      Decimal(18, 2),
    payload     String
)
ENGINE = MergeTree()
ORDER BY (event_type, user_id, ts)
SETTINGS index_granularity = 8192;
SQL
run_query "INSERT INTO demo.lab_opt_optimized SELECT * FROM demo.lab_opt_events"
run_query "OPTIMIZE TABLE demo.lab_opt_optimized FINAL"
echo "  ✓ Optimized table: ORDER BY (event_type, user_id, ts)"
echo ""

subsection "Step 3b: Add skip index for region"
run_query "ALTER TABLE demo.lab_opt_optimized ADD INDEX idx_region region TYPE bloom_filter(0.01) GRANULARITY 4"
run_query "ALTER TABLE demo.lab_opt_optimized MATERIALIZE INDEX idx_region"
echo "  ✓ bloom_filter skip index on region"
sleep 1

subsection "Step 3c: Add projection for user-centric queries"
run_query_multiline <<'SQL'
ALTER TABLE demo.lab_opt_optimized
    ADD PROJECTION proj_by_user
    (SELECT * ORDER BY user_id, ts);
SQL
run_query "ALTER TABLE demo.lab_opt_optimized MATERIALIZE PROJECTION proj_by_user"
echo "  ✓ Projection by (user_id, ts) for Q2"
sleep 1

subsection "Step 3d: Create MV for hourly aggregation"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_opt_ex6_mv;
DROP TABLE IF EXISTS demo.lab_opt_ex6_hourly;

CREATE TABLE demo.lab_opt_ex6_hourly
(
    event_type LowCardinality(String),
    hour       DateTime,
    cnt        SimpleAggregateFunction(sum, UInt64),
    total      SimpleAggregateFunction(sum, Decimal(38, 2))
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_type, hour);

CREATE MATERIALIZED VIEW demo.lab_opt_ex6_mv
TO demo.lab_opt_ex6_hourly
AS SELECT
    event_type,
    toStartOfHour(ts) AS hour,
    count() AS cnt,
    sum(amount) AS total
FROM demo.lab_opt_optimized
GROUP BY event_type, hour;
SQL
echo "  ✓ MV for hourly aggregation"

echo "  Populating MV by re-inserting data..."
run_query "INSERT INTO demo.lab_opt_optimized SELECT * FROM demo.lab_opt_events"
run_query "SYSTEM FLUSH LOGS"
echo ""

subsection "Step 4: Re-run all 4 queries on optimized table"
echo ""
run_query_with_id "lab_opt_ex6_q1_after" "SELECT count(), sum(amount) FROM demo.lab_opt_optimized WHERE event_type = 'purchase' AND user_id = 42 FORMAT Null"
run_query_with_id "lab_opt_ex6_q2_after" "SELECT count(), sum(amount) FROM demo.lab_opt_optimized WHERE user_id = 42 FORMAT Null"
run_query_with_id "lab_opt_ex6_q3_after" "SELECT count() FROM demo.lab_opt_optimized WHERE region = 'us-east' FORMAT Null"
run_query_with_id "lab_opt_ex6_q4_after" "SELECT event_type, hour, sum(cnt) AS cnt, sum(total) AS total FROM demo.lab_opt_ex6_hourly GROUP BY event_type, hour FORMAT Null"
run_query "SYSTEM FLUSH LOGS"

echo "  Optimized performance:"
run_query_multiline <<'SQL'
SELECT
    query_id,
    read_rows,
    formatReadableSize(read_bytes) AS read_bytes,
    query_duration_ms AS ms
FROM system.query_log
WHERE query_id LIKE 'lab_opt_ex6_%_after'
    AND type = 'QueryFinish'
ORDER BY query_id
FORMAT PrettyCompact
SQL
echo ""

subsection "Before vs After comparison"
echo ""
run_query_multiline <<'SQL'
SELECT
    replaceOne(b.query_id, '_before', '') AS query,
    b.read_rows AS before_rows,
    a.read_rows AS after_rows,
    if(a.read_rows > 0,
        round(b.read_rows / a.read_rows, 1),
        0) AS speedup_factor
FROM
    (SELECT query_id, read_rows FROM system.query_log
     WHERE query_id LIKE 'lab_opt_ex6_%_before' AND type = 'QueryFinish') AS b
INNER JOIN
    (SELECT query_id, read_rows FROM system.query_log
     WHERE query_id LIKE 'lab_opt_ex6_%_after' AND type = 'QueryFinish') AS a
ON replaceOne(b.query_id, '_before', '') = replaceOne(a.query_id, '_after', '')
ORDER BY query
FORMAT PrettyCompact
SQL
echo ""
commentary "Optimization workflow: (1) Fix ORDER BY first — biggest impact. (2) Add skip indexes for secondary filter columns. (3) Add projections for the second query pattern. (4) Create MVs for dashboard aggregations. Each step targets a specific query pattern."

# ═══════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════

section "Cleanup"

echo "  Dropping all lab tables..."
echo ""
run_query "DROP TABLE IF EXISTS demo.lab_opt_mv_hourly"
run_query "DROP TABLE IF EXISTS demo.lab_opt_ex6_mv"
run_query "DROP TABLE IF EXISTS demo.lab_opt_hourly"
run_query "DROP TABLE IF EXISTS demo.lab_opt_ex6_hourly"
run_query "DROP TABLE IF EXISTS demo.lab_opt_good"
run_query "DROP TABLE IF EXISTS demo.lab_opt_bad"
run_query "DROP TABLE IF EXISTS demo.lab_opt_events"
run_query "DROP TABLE IF EXISTS demo.lab_opt_baseline"
run_query "DROP TABLE IF EXISTS demo.lab_opt_optimized"
echo "  ✓ All lab tables dropped"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — Optimization Techniques Summary"

echo "  ┌────────────────────┬─────────────────────────────┬──────────────┬─────────────────────┐"
echo "  │ Technique          │ When to Use                 │ Storage Cost │ Query Benefit        │"
echo "  ├────────────────────┼─────────────────────────────┼──────────────┼─────────────────────┤"
echo "  │ ORDER BY key       │ Most common filter pattern  │ None         │ 10-1000x fewer rows  │"
echo "  │ PREWHERE           │ Automatic (MergeTree)       │ None         │ Less I/O per query   │"
echo "  │ Skip index         │ Secondary filter columns    │ Small        │ Skip granule blocks  │"
echo "  │ Projection         │ 2nd query pattern / alt key │ ~2x table    │ Alternative ORDER BY │"
echo "  │ Materialized View  │ Dashboard aggregations      │ Varies       │ Pre-computed results │"
echo "  └────────────────────┴─────────────────────────────┴──────────────┴─────────────────────┘"
echo ""
echo "  Optimization priority:"
echo "    1. Fix ORDER BY key (biggest impact, zero cost)"
echo "    2. Add skip indexes (small cost, targeted benefit)"
echo "    3. Add projections (storage cost, transparent to queries)"
echo "    4. Create MVs (most powerful, requires schema design)"
echo ""
echo "  See notes/10-optimization-lab.md for detailed reference."
echo ""
