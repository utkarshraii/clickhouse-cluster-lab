#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-table-engines.sh — Hands-On Lab: MergeTree Engine Variants
# ═══════════════════════════════════════════════════════════════════
#
# This lab creates tables with different MergeTree engines, inserts
# data, and demonstrates how each engine behaves differently during
# inserts, merges, and queries.
#
# Exercises:
#   1. MergeTree          — The baseline engine
#   2. ReplacingMergeTree — Deduplication on merge
#   3. SummingMergeTree   — Auto-aggregation on merge
#   4. AggregatingMergeTree — Complex pre-aggregation
#   5. CollapsingMergeTree  — Mutable data via sign column
#   6. VersionedCollapsingMergeTree — Order-independent collapsing
#
# Usage:
#   ./cluster/scripts/lab-table-engines.sh
#   make lab-engines
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

section "Table Engines Hands-On Lab"
echo "  This lab demonstrates 6 MergeTree engine variants."
echo "  Each exercise creates a table, inserts data, and shows"
echo "  how the engine's merge behavior affects query results."
echo ""
echo "  All tables are created locally on ${CH_NODE} (no ON CLUSTER)."
echo "  These are learning exercises — not production patterns."
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: MergeTree — The Baseline
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: MergeTree — The Baseline"

echo "  MergeTree is the foundation of all ClickHouse table engines."
echo "  Every other *MergeTree variant inherits its behavior and adds"
echo "  special logic that runs during background merges."
echo ""

subsection "Creating table: demo.lab_mergetree"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_mergetree;

CREATE TABLE demo.lab_mergetree
(
    event_date  Date,
    user_id     UInt32,
    event_type  LowCardinality(String),
    amount      Decimal(18, 2),
    created_at  DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, user_id, event_date)
TTL event_date + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
SQL
echo "  ✓ Table created"
echo ""
echo "  Key decisions in this DDL:"
echo "    PARTITION BY toYYYYMM(event_date)"
echo "      → Creates physical directories per month (enables fast DROP PARTITION)"
echo "    ORDER BY (event_type, user_id, event_date)"
echo "      → Primary index — determines which granules are read for a query"
echo "      → Low cardinality first: event_type has few values → great prefix"
echo "    TTL event_date + INTERVAL 90 DAY"
echo "      → Rows older than 90 days are auto-deleted during merges"
echo ""

subsection "Inserting data in two batches (creates separate parts)"
run_query_multiline <<'SQL'
-- Batch 1: this month's data (1000 rows)
INSERT INTO demo.lab_mergetree (event_date, user_id, event_type, amount)
SELECT
    today() - (number % 28) AS event_date,
    (number % 100) + 1 AS user_id,
    arrayElement(['click', 'view', 'purchase'], (number % 3) + 1) AS event_type,
    round((number % 500) / 10, 2) AS amount
FROM numbers(1000);

-- Batch 2: last month's data (500 rows)
INSERT INTO demo.lab_mergetree (event_date, user_id, event_type, amount)
SELECT
    today() - 30 - (number % 28) AS event_date,
    (number % 100) + 1 AS user_id,
    arrayElement(['click', 'view', 'purchase'], (number % 3) + 1) AS event_type,
    round((number % 300) / 10, 2) AS amount
FROM numbers(500);
SQL
echo "  ✓ Inserted 1,000 + 500 rows in two batches"
echo ""

subsection "Parts created (each INSERT creates a new part)"
run_query "SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS size FROM system.parts WHERE database = 'demo' AND table = 'lab_mergetree' AND active ORDER BY partition, name FORMAT PrettyCompact"
echo ""
commentary "Each INSERT creates a separate 'part' (directory on disk). Background merges combine parts within the same partition. You should see parts in two partitions (this month and last month)."

subsection "How ORDER BY affects query performance"
echo ""
echo "  Query 1: Filter on event_type (first ORDER BY column) — FAST"
run_query "SELECT event_type, count(), sum(amount) FROM demo.lab_mergetree WHERE event_type = 'purchase' GROUP BY event_type FORMAT PrettyCompact"
echo ""
echo "  Query 2: Filter on user_id without event_type — must scan more granules"
run_query "SELECT user_id, count(), sum(amount) FROM demo.lab_mergetree WHERE user_id = 42 GROUP BY user_id FORMAT PrettyCompact"
echo ""
commentary "ORDER BY defines the primary index. Queries that filter on the first column(s) of ORDER BY can skip most granules. Filtering on later columns without the prefix requires scanning more data."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: ReplacingMergeTree — Deduplication
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: ReplacingMergeTree — Deduplication"

echo "  ReplacingMergeTree removes duplicate rows (same ORDER BY key)"
echo "  during background merges. It keeps the row with the highest"
echo "  'version' column value."
echo ""
echo "  Use case: tracking the 'latest state' of an entity (e.g., order status)."
echo ""

subsection "Creating table: demo.lab_replacing"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_replacing;

CREATE TABLE demo.lab_replacing
(
    order_id    UInt64,
    status      String,
    amount      Decimal(18, 2),
    updated_at  DateTime
)
ENGINE = ReplacingMergeTree(updated_at)  -- updated_at is the "version" column
ORDER BY order_id;                        -- order_id is the dedup key
SQL
echo "  ✓ Table created"
echo ""
echo "  ReplacingMergeTree(updated_at):"
echo "    → When rows with the same ORDER BY key (order_id) are merged,"
echo "      only the row with the LATEST updated_at is kept."
echo ""

subsection "Inserting initial order states"
run_query_multiline <<'SQL'
INSERT INTO demo.lab_replacing VALUES
    (1001, 'pending',   99.99,  '2024-01-01 10:00:00'),
    (1002, 'pending',   49.99,  '2024-01-01 10:01:00'),
    (1003, 'pending',   149.99, '2024-01-01 10:02:00');
SQL
echo "  ✓ Inserted 3 orders (all pending)"
echo ""

subsection "Inserting status updates (same order_id, newer timestamp)"
run_query_multiline <<'SQL'
INSERT INTO demo.lab_replacing VALUES
    (1001, 'shipped',   99.99,  '2024-01-02 14:00:00'),
    (1002, 'cancelled', 49.99,  '2024-01-01 15:00:00'),
    (1001, 'delivered', 99.99,  '2024-01-05 09:00:00');
SQL
echo "  ✓ Inserted 3 updates (order 1001 updated twice)"
echo ""

subsection "Query WITHOUT FINAL — sees all rows (duplicates included)"
run_query "SELECT order_id, status, amount, updated_at FROM demo.lab_replacing ORDER BY order_id, updated_at FORMAT PrettyCompact"
echo ""
commentary "Without FINAL, you see ALL inserted rows — 6 total. Deduplication has NOT happened yet because the rows are in different parts."

subsection "Query WITH FINAL — applies dedup logic at query time"
run_query "SELECT order_id, status, amount, updated_at FROM demo.lab_replacing FINAL ORDER BY order_id FORMAT PrettyCompact"
echo ""
commentary "With FINAL, ClickHouse applies the ReplacingMergeTree logic at read time: for each order_id, only the row with the latest updated_at is returned. This is correct but slower — it must merge on the fly."

subsection "Force merge with OPTIMIZE TABLE FINAL"
run_query "OPTIMIZE TABLE demo.lab_replacing FINAL"
echo "  ✓ Forced merge — old versions are physically removed"
echo ""

subsection "Query WITHOUT FINAL after merge — now clean"
run_query "SELECT order_id, status, amount, updated_at FROM demo.lab_replacing ORDER BY order_id FORMAT PrettyCompact"
echo ""
commentary "After OPTIMIZE FINAL, duplicates are physically removed. Now even without FINAL, you see only 3 rows. In production, don't rely on OPTIMIZE — use FINAL or argMax() for consistent reads."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: SummingMergeTree — Auto-Aggregation
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: SummingMergeTree — Auto-Aggregation"

echo "  SummingMergeTree automatically SUMS numeric columns for rows"
echo "  with the same ORDER BY key during background merges."
echo ""
echo "  Use case: counters, daily metrics, pre-aggregated rollups."
echo ""

subsection "Creating table: demo.lab_summing"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_summing;

CREATE TABLE demo.lab_summing
(
    date        Date,
    user_id     UInt32,
    page_views  UInt64,
    clicks      UInt64,
    revenue     Decimal(18, 2)
)
ENGINE = SummingMergeTree()   -- sums ALL numeric columns not in ORDER BY
ORDER BY (date, user_id);     -- these columns define the "group"
SQL
echo "  ✓ Table created"
echo ""
echo "  SummingMergeTree():"
echo "    → On merge, rows with same (date, user_id) are collapsed"
echo "    → page_views, clicks, revenue are automatically summed"
echo ""

subsection "Inserting overlapping metrics (same keys, different counts)"
run_query_multiline <<'SQL'
-- Morning batch
INSERT INTO demo.lab_summing VALUES
    ('2024-01-15', 1, 10, 3, 5.00),
    ('2024-01-15', 2, 20, 5, 12.00),
    ('2024-01-15', 3, 15, 2, 0.00);

-- Afternoon batch (same date+user_id → will be summed on merge)
INSERT INTO demo.lab_summing VALUES
    ('2024-01-15', 1, 8,  2, 3.50),
    ('2024-01-15', 2, 12, 4, 8.00);

-- Next day
INSERT INTO demo.lab_summing VALUES
    ('2024-01-16', 1, 5, 1, 2.00);
SQL
echo "  ✓ Inserted 6 rows across 3 batches"
echo ""

subsection "Before merge — all rows visible"
run_query "SELECT date, user_id, page_views, clicks, revenue FROM demo.lab_summing ORDER BY date, user_id FORMAT PrettyCompact"
echo ""
commentary "Before merge, you see all 6 rows. User 1 on Jan 15 appears twice (10+8 page_views). User 2 on Jan 15 also appears twice."

subsection "Force merge with OPTIMIZE TABLE FINAL"
run_query "OPTIMIZE TABLE demo.lab_summing FINAL"
echo "  ✓ Forced merge — numeric columns auto-summed"
echo ""

subsection "After merge — rows with same key are summed"
run_query "SELECT date, user_id, page_views, clicks, revenue FROM demo.lab_summing ORDER BY date, user_id FORMAT PrettyCompact"
echo ""
commentary "After merge: User 1 on Jan 15 now shows page_views=18 (10+8), clicks=5 (3+2), revenue=8.50 (5.00+3.50). The SummingMergeTree auto-aggregated numeric columns. In production, always wrap reads with SUM() GROUP BY to handle unmerged parts."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: AggregatingMergeTree — Complex Pre-Aggregation
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: AggregatingMergeTree — Complex Pre-Aggregation"

echo "  AggregatingMergeTree stores intermediate aggregate states"
echo "  (not final values). It can handle complex aggregations like"
echo "  averages, uniq counts, and quantiles — things SummingMergeTree can't."
echo ""
echo "  Use case: Materialized Views with complex aggregates (avg, uniq, quantile)."
echo ""

subsection "Creating table: demo.lab_aggregating"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_aggregating;

CREATE TABLE demo.lab_aggregating
(
    event_type   LowCardinality(String),
    hour         DateTime,
    avg_amount   AggregateFunction(avg, Decimal(18, 2)),
    uniq_users   AggregateFunction(uniq, UInt32),
    event_count  SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_type, hour);
SQL
echo "  ✓ Table created"
echo ""
echo "  Column types:"
echo "    AggregateFunction(avg, Decimal)  — stores intermediate avg state (sum + count)"
echo "    AggregateFunction(uniq, UInt32)  — stores HyperLogLog sketch for approximate distinct"
echo "    SimpleAggregateFunction(sum, UInt64) — stores a running sum (simpler than full AggregateFunction)"
echo ""

subsection "Inserting with -State combinators"
run_query_multiline <<'SQL'
-- Batch 1: first hour of data
INSERT INTO demo.lab_aggregating
SELECT
    'click' AS event_type,
    toDateTime('2024-01-15 10:00:00') AS hour,
    avgState(toDecimal64(amount, 2)) AS avg_amount,
    uniqState(toUInt32(user_id)) AS uniq_users,
    count() AS event_count
FROM (
    SELECT number % 50 + 1 AS user_id, (number % 100) + 1.00 AS amount
    FROM numbers(200)
);

-- Batch 2: more data for the same hour (will merge with batch 1)
INSERT INTO demo.lab_aggregating
SELECT
    'click' AS event_type,
    toDateTime('2024-01-15 10:00:00') AS hour,
    avgState(toDecimal64(amount, 2)) AS avg_amount,
    uniqState(toUInt32(user_id)) AS uniq_users,
    count() AS event_count
FROM (
    SELECT number % 80 + 1 AS user_id, (number % 200) + 50.00 AS amount
    FROM numbers(300)
);
SQL
echo "  ✓ Inserted 2 batches with aggregate states"
echo ""

subsection "Querying with -Merge combinators (before merge)"
run_query "SELECT event_type, hour, avgMerge(avg_amount) AS avg_amount, uniqMerge(uniq_users) AS unique_users, sum(event_count) AS total_events FROM demo.lab_aggregating GROUP BY event_type, hour FORMAT PrettyCompact"
echo ""
commentary "-State combinators serialize aggregate state on INSERT. -Merge combinators combine states on SELECT. This is how ClickHouse handles avg() across partial aggregates — it stores (sum, count) internally, not a pre-computed average."

subsection "Force merge"
run_query "OPTIMIZE TABLE demo.lab_aggregating FINAL"
echo "  ✓ Merged — aggregate states combined"
echo ""

subsection "Querying after merge (same result, fewer parts)"
run_query "SELECT event_type, hour, avgMerge(avg_amount) AS avg_amount, uniqMerge(uniq_users) AS unique_users, sum(event_count) AS total_events FROM demo.lab_aggregating GROUP BY event_type, hour FORMAT PrettyCompact"
echo ""
commentary "Same result before and after merge — that's the point. AggregatingMergeTree merges states correctly. Unlike SummingMergeTree, it can handle avg(), uniq(), quantile(), and other complex aggregates."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: CollapsingMergeTree — Mutable Data via Sign
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: CollapsingMergeTree — Mutable Data via Sign"

echo "  CollapsingMergeTree enables 'updates' and 'deletes' in an"
echo "  append-only system using a sign column (+1 = insert, -1 = cancel)."
echo ""
echo "  To update a row: insert a cancellation (-1) of the old row,"
echo "  then insert the new version (+1)."
echo ""
echo "  Use case: mutable state in real-time analytics (sessions, balances)."
echo ""

subsection "Creating table: demo.lab_collapsing"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_collapsing;

CREATE TABLE demo.lab_collapsing
(
    session_id  UInt64,
    user_id     UInt32,
    duration    UInt32,
    page_count  UInt16,
    sign        Int8        -- +1 = active row, -1 = cancelled row
)
ENGINE = CollapsingMergeTree(sign)
ORDER BY (session_id);
SQL
echo "  ✓ Table created"
echo ""

subsection "Inserting initial sessions"
run_query_multiline <<'SQL'
-- session 5001: 300s, 5 pages
-- session 5002: 120s, 3 pages
-- session 5003: 600s, 12 pages
INSERT INTO demo.lab_collapsing VALUES
    (5001, 10, 300, 5,  1),
    (5002, 20, 120, 3,  1),
    (5003, 30, 600, 12, 1);
SQL
echo "  ✓ Inserted 3 sessions (all sign=+1)"
echo ""

subsection "Updating session 5001: cancel old, insert new"
run_query_multiline <<'SQL'
-- IMPORTANT: the cancellation row must match the original EXACTLY (except sign)
-- First row: cancel the old session 5001
-- Second row: insert updated version (450s, 8 pages)
INSERT INTO demo.lab_collapsing VALUES
    (5001, 10, 300, 5,  -1),
    (5001, 10, 450, 8,   1);
SQL
echo "  ✓ Cancelled old session 5001 and inserted updated version"
echo ""

subsection "Deleting session 5002: just cancel it"
run_query_multiline <<'SQL'
-- Cancel session 5002 (no replacement = delete)
INSERT INTO demo.lab_collapsing VALUES
    (5002, 20, 120, 3, -1);
SQL
echo "  ✓ Cancelled session 5002 (delete)"
echo ""

subsection "Before merge — all 6 rows visible"
run_query "SELECT session_id, user_id, duration, page_count, sign FROM demo.lab_collapsing ORDER BY session_id, sign FORMAT PrettyCompact"
echo ""
commentary "All 6 rows are present. Session 5001 has three rows (+1, -1, +1). Session 5002 has two rows (+1, -1). Collapsing hasn't happened yet."

subsection "Correct way to query before merge: use SUM with sign"
run_query "SELECT session_id, any(user_id) AS user_id, sum(duration * sign) AS duration, sum(page_count * sign) AS page_count FROM demo.lab_collapsing GROUP BY session_id HAVING sum(sign) > 0 ORDER BY session_id FORMAT PrettyCompact"
echo ""
commentary "Multiply each metric by sign and SUM → cancelled rows subtract out. HAVING sum(sign) > 0 filters fully deleted sessions. This gives correct results even before merge."

subsection "Force merge"
run_query "OPTIMIZE TABLE demo.lab_collapsing FINAL"
echo "  ✓ Merged — cancelled rows removed"
echo ""

subsection "After merge — only live sessions remain"
run_query "SELECT session_id, user_id, duration, page_count, sign FROM demo.lab_collapsing ORDER BY session_id FORMAT PrettyCompact"
echo ""
commentary "After merge: session 5001 shows the updated version (450s, 8 pages). Session 5002 is gone (fully cancelled). Session 5003 is untouched. IMPORTANT: cancellation rows must match originals exactly and be inserted in the correct order (+1 before -1 within the same INSERT)."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: VersionedCollapsingMergeTree — Order-Independent
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: VersionedCollapsingMergeTree — Order-Independent Collapsing"

echo "  VersionedCollapsingMergeTree adds a version column so that"
echo "  insert order doesn't matter. The engine uses the version to"
echo "  determine which rows cancel each other."
echo ""
echo "  Use case: same as CollapsingMergeTree, but when you can't"
echo "  guarantee insert order (e.g., multiple writers, async pipelines)."
echo ""

subsection "Creating table: demo.lab_versioned_collapsing"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_versioned_collapsing;

CREATE TABLE demo.lab_versioned_collapsing
(
    product_id  UInt64,
    price       Decimal(18, 2),
    quantity    UInt32,
    sign        Int8,
    version     UInt32
)
ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY product_id;
SQL
echo "  ✓ Table created"
echo ""

subsection "Inserting rows OUT OF ORDER (version resolves correctness)"
run_query_multiline <<'SQL'
-- Insert the cancellation BEFORE the original — normally wrong for CollapsingMergeTree!
-- But VersionedCollapsingMergeTree handles this correctly using the version column.

-- Cancel version 1 of product 7001 (inserted before the original!)
INSERT INTO demo.lab_versioned_collapsing VALUES
    (7001, 29.99, 100, -1, 1);

-- Original version 1 of product 7001
INSERT INTO demo.lab_versioned_collapsing VALUES
    (7001, 29.99, 100, 1, 1);

-- New version 2 of product 7001
INSERT INTO demo.lab_versioned_collapsing VALUES
    (7001, 34.99, 80, 1, 2);

-- Product 7002: just the initial version
INSERT INTO demo.lab_versioned_collapsing VALUES
    (7002, 9.99, 500, 1, 1);
SQL
echo "  ✓ Inserted 4 rows out of order"
echo ""

subsection "Before merge — all rows visible"
run_query "SELECT product_id, price, quantity, sign, version FROM demo.lab_versioned_collapsing ORDER BY product_id, version, sign FORMAT PrettyCompact"
echo ""
commentary "All 4 rows present. Product 7001 has version 1 with both +1 and -1 (will cancel), plus version 2 with +1 (will remain). The -1 was inserted BEFORE the +1 — CollapsingMergeTree would break, but VersionedCollapsing handles it."

subsection "Force merge"
run_query "OPTIMIZE TABLE demo.lab_versioned_collapsing FINAL"
echo "  ✓ Merged — version-based collapsing applied"
echo ""

subsection "After merge — version 1 cancelled, version 2 remains"
run_query "SELECT product_id, price, quantity, sign, version FROM demo.lab_versioned_collapsing ORDER BY product_id FORMAT PrettyCompact"
echo ""
commentary "Product 7001 version 1 is gone (the +1 and -1 at version 1 cancelled each other). Version 2 (price=34.99, qty=80) remains. Product 7002 is untouched. The version column made insert order irrelevant."

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — Engine Decision Matrix"

echo "  ┌─────────────────────────────────┬───────────────────────────────────┐"
echo "  │ I need to...                    │ Use this engine                   │"
echo "  ├─────────────────────────────────┼───────────────────────────────────┤"
echo "  │ Store raw event data            │ MergeTree                         │"
echo "  │ Keep latest version of a row    │ ReplacingMergeTree                │"
echo "  │ Auto-sum counters/metrics       │ SummingMergeTree                  │"
echo "  │ Pre-aggregate avg/uniq/quantile │ AggregatingMergeTree              │"
echo "  │ Update/delete rows (ordered)    │ CollapsingMergeTree               │"
echo "  │ Update/delete rows (any order)  │ VersionedCollapsingMergeTree      │"
echo "  └─────────────────────────────────┴───────────────────────────────────┘"
echo ""
echo "  Key principle: ALL of these are append-only. The 'special' behavior"
echo "  only happens during background merges. Until data is merged, you"
echo "  may see duplicates, uncollapsed rows, or unsummed values."
echo ""
echo "  For consistent reads BEFORE merge:"
echo "    ReplacingMergeTree → use FINAL or argMax()"
echo "    SummingMergeTree   → wrap with SUM() ... GROUP BY"
echo "    Collapsing*        → multiply by sign, HAVING sum(sign) > 0"
echo ""
echo "  See notes/07-table-engines-lab.md for detailed reference."
echo ""
