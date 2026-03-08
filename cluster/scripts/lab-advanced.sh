#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# lab-advanced.sh — Hands-On Lab: Advanced Topics
# ═══════════════════════════════════════════════════════════════════
#
# This lab covers advanced ClickHouse features: projections deep dive,
# lightweight deletes, window functions, dictionaries, parameterized
# views, and buffer tables + async inserts.
#
# Exercises:
#   1. Projections Deep Dive  — Multiple projections, storage cost
#   2. Lightweight Deletes    — ALTER DELETE vs DELETE FROM comparison
#   3. Window Functions       — Running totals, ranks, lag/lead, sessions
#   4. Dictionaries           — Layout types, enrichment, refresh
#   5. Parameterized Views    — Reusable query templates
#   6. Buffer Tables + Async  — High-frequency ingestion patterns
#
# Usage:
#   ./cluster/scripts/lab-advanced.sh
#   make lab-advanced
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

run_query_with_settings() {
    local settings="$1"
    local query="$2"
    docker exec "$CH_NODE" clickhouse-client $settings --query "$query"
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

section "Advanced Topics Hands-On Lab"
echo "  This lab covers advanced features: projections deep dive,"
echo "  lightweight deletes, window functions, dictionaries,"
echo "  parameterized views, and high-frequency ingestion."
echo ""
echo "  All exercises run on ${CH_NODE} (single-node focus)."
echo ""

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 1: Projections Deep Dive
# ═══════════════════════════════════════════════════════════════════

section "Exercise 1: Projections Deep Dive"

echo "  Projections store a second copy of data with a different sort"
echo "  order. Here we add MULTIPLE projections and measure storage cost."
echo ""

subsection "Creating base table with 200K rows"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_proj;

CREATE TABLE demo.lab_adv_proj
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
ORDER BY (event_type, ts)
SETTINGS index_granularity = 8192;
SQL

run_query "INSERT INTO demo.lab_adv_proj SELECT number AS event_id, arrayElement(['click', 'view', 'purchase', 'signup', 'logout'], (number % 5) + 1) AS event_type, (number % 10000) + 1 AS user_id, arrayElement(['us-east', 'us-west', 'eu-west', 'ap-south'], (number % 4) + 1) AS region, now() - toIntervalSecond(number * 2) AS ts, round((number % 500) / 10.0, 2) AS amount, repeat('x', 50) AS payload FROM numbers(200000)"
run_query "OPTIMIZE TABLE demo.lab_adv_proj FINAL"
echo "  ✓ Table created: ORDER BY (event_type, ts), 200K rows"
echo ""

subsection "Baseline storage — no projections"
base_size=$(run_query "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_proj' AND active")
echo "  Table size (no projections): $base_size"
echo ""

subsection "Adding projection 1: ORDER BY (user_id, ts)"
run_query "ALTER TABLE demo.lab_adv_proj ADD PROJECTION IF NOT EXISTS proj_by_user (SELECT * ORDER BY user_id, ts)"
run_query "ALTER TABLE demo.lab_adv_proj MATERIALIZE PROJECTION proj_by_user"
sleep 2
run_query "OPTIMIZE TABLE demo.lab_adv_proj FINAL"
sleep 1

size_1proj=$(run_query "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_proj' AND active")
echo "  ✓ Projection proj_by_user added"
echo "  Table size (1 projection): $size_1proj"
echo ""

subsection "Adding projection 2: ORDER BY (region, ts)"
run_query "ALTER TABLE demo.lab_adv_proj ADD PROJECTION IF NOT EXISTS proj_by_region (SELECT * ORDER BY region, ts)"
run_query "ALTER TABLE demo.lab_adv_proj MATERIALIZE PROJECTION proj_by_region"
sleep 2
run_query "OPTIMIZE TABLE demo.lab_adv_proj FINAL"
sleep 1

size_2proj=$(run_query "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_proj' AND active")
echo "  ✓ Projection proj_by_region added"
echo "  Table size (2 projections): $size_2proj"
echo ""

subsection "Adding projection 3: pre-aggregation (cheap)"
run_query_multiline <<'SQL'
ALTER TABLE demo.lab_adv_proj ADD PROJECTION IF NOT EXISTS proj_hourly_agg
(
    SELECT
        event_type,
        toStartOfHour(ts) AS hour,
        count() AS cnt,
        sum(amount) AS total
    GROUP BY event_type, hour
);
SQL
run_query "ALTER TABLE demo.lab_adv_proj MATERIALIZE PROJECTION proj_hourly_agg"
sleep 2
run_query "OPTIMIZE TABLE demo.lab_adv_proj FINAL"
sleep 1

size_3proj=$(run_query "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_proj' AND active")
echo "  ✓ Aggregation projection proj_hourly_agg added"
echo "  Table size (2 reorder + 1 aggregation): $size_3proj"
echo ""

subsection "Storage cost summary"
echo ""
echo "  No projections:           $base_size"
echo "  + 1 reorder projection:   $size_1proj"
echo "  + 2 reorder projections:  $size_2proj"
echo "  + 1 aggregation proj:     $size_3proj"
echo ""

subsection "Optimizer picks the best projection per query"
echo ""
echo "  Query 1: WHERE event_type = 'purchase' (uses primary ORDER BY)"
explain1=$(run_query "EXPLAIN SELECT count() FROM demo.lab_adv_proj WHERE event_type = 'purchase'" 2>&1 | head -5)
echo "$explain1"
echo ""

echo "  Query 2: WHERE user_id = 42 (uses proj_by_user)"
explain2=$(run_query "EXPLAIN SELECT count() FROM demo.lab_adv_proj WHERE user_id = 42" 2>&1 | head -5)
echo "$explain2"
echo ""

echo "  Query 3: WHERE region = 'us-east' (uses proj_by_region)"
explain3=$(run_query "EXPLAIN SELECT count() FROM demo.lab_adv_proj WHERE region = 'us-east'" 2>&1 | head -5)
echo "$explain3"
echo ""

commentary "Each reorder projection roughly doubles storage. Aggregation projections are cheap (pre-aggregated, much fewer rows). Rule: 1 reorder + 1-2 aggregation projections is the sweet spot. Beyond that, use Materialized Views."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 2: Lightweight Deletes — ALTER DELETE vs DELETE FROM
# ═══════════════════════════════════════════════════════════════════

section "Exercise 2: Lightweight Deletes vs Mutations"

echo "  ALTER TABLE DELETE rewrites entire parts."
echo "  DELETE FROM uses row masking — much faster."
echo "  Let's compare them side by side."
echo ""

subsection "Creating table with 100K rows"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_deletes;

CREATE TABLE demo.lab_adv_deletes
(
    id      UInt64,
    status  LowCardinality(String),
    amount  Decimal(18, 2),
    payload String
)
ENGINE = MergeTree()
ORDER BY id;
SQL

run_query "INSERT INTO demo.lab_adv_deletes SELECT number AS id, arrayElement(['active', 'pending', 'test'], (number % 3) + 1) AS status, round((number % 1000) / 10.0, 2) AS amount, repeat('d', 100) AS payload FROM numbers(100000)"
run_query "OPTIMIZE TABLE demo.lab_adv_deletes FINAL"
echo "  ✓ 100K rows inserted and optimized"
echo ""

subsection "Part state before any deletes"
run_query_multiline <<'SQL'
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size, level
FROM system.parts
WHERE database = 'demo' AND table = 'lab_adv_deletes' AND active
FORMAT PrettyCompact
SQL
echo ""

subsection "ALTER TABLE DELETE — mutation (rewrites parts)"
echo ""
echo "  Deleting rows WHERE status = 'test' (~33K rows)"
rows_before=$(run_query "SELECT count() FROM demo.lab_adv_deletes")

start_s=$(python3 -c 'import time; print(time.time())')
run_query "ALTER TABLE demo.lab_adv_deletes DELETE WHERE status = 'test'"

for attempt in $(seq 1 15); do
    pending=$(run_query "SELECT count() FROM system.mutations WHERE database = 'demo' AND table = 'lab_adv_deletes' AND is_done = 0")
    if [ "$pending" = "0" ]; then
        break
    fi
    sleep 1
done
end_s=$(python3 -c 'import time; print(time.time())')
alter_time=$(python3 -c "print(int(($end_s - $start_s) * 1000))")

rows_after=$(run_query "SELECT count() FROM demo.lab_adv_deletes")
echo "  Rows before: $rows_before → after: $rows_after"
echo "  ALTER DELETE time: ${alter_time}ms"
echo ""

subsection "Part state after ALTER DELETE"
run_query_multiline <<'SQL'
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size, level
FROM system.parts
WHERE database = 'demo' AND table = 'lab_adv_deletes' AND active
FORMAT PrettyCompact
SQL
echo ""
echo "  (Notice: part was rewritten — new name, higher level)"
echo ""

subsection "DELETE FROM — lightweight (row masking)"
echo ""
echo "  Deleting rows WHERE status = 'pending' (~33K rows)"
rows_before2=$(run_query "SELECT count() FROM demo.lab_adv_deletes")

start_s2=$(python3 -c 'import time; print(time.time())')
run_query "DELETE FROM demo.lab_adv_deletes WHERE status = 'pending'"
sleep 1
end_s2=$(python3 -c 'import time; print(time.time())')
lwd_time=$(python3 -c "print(int(($end_s2 - $start_s2) * 1000))")

rows_after2=$(run_query "SELECT count() FROM demo.lab_adv_deletes")
echo "  Rows before: $rows_before2 → after: $rows_after2"
echo "  DELETE FROM time: ${lwd_time}ms"
echo ""

subsection "Part state after lightweight DELETE"
run_query_multiline <<'SQL'
SELECT name, rows, formatReadableSize(bytes_on_disk) AS size, level
FROM system.parts
WHERE database = 'demo' AND table = 'lab_adv_deletes' AND active
FORMAT PrettyCompact
SQL
echo ""
echo "  (Notice: rows shows the physical count — masked rows still exist"
echo "   until the next merge. The part was NOT rewritten.)"
echo ""

subsection "Mutation history comparison"
run_query_multiline <<'SQL'
SELECT
    mutation_id,
    command,
    is_done,
    parts_to_do
FROM system.mutations
WHERE database = 'demo' AND table = 'lab_adv_deletes'
ORDER BY create_time
FORMAT PrettyCompact
SQL
echo ""

echo "  Timing comparison:"
echo "  ┌──────────────────┬───────────┐"
echo "  │ Method           │ Time (ms) │"
echo "  ├──────────────────┼───────────┤"
printf "  │ ALTER DELETE      │ %9s │\n" "$alter_time"
printf "  │ DELETE FROM       │ %9s │\n" "$lwd_time"
echo "  └──────────────────┴───────────┘"
echo ""

commentary "ALTER DELETE rewrites entire parts (expensive I/O). DELETE FROM masks rows instantly with a lightweight bitmap — actual removal happens at next merge. Prefer DELETE FROM for targeted removals. Prefer append-only patterns for OLAP."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 3: Window Functions
# ═══════════════════════════════════════════════════════════════════

section "Exercise 3: Window Functions"

echo "  Window functions compute values across related rows without"
echo "  collapsing them (unlike GROUP BY). Essential for analytics."
echo ""

subsection "Creating sample data: daily revenue by region"
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_revenue;

CREATE TABLE demo.lab_adv_revenue
(
    region  LowCardinality(String),
    day     Date,
    revenue Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY (region, day);
SQL

run_query_multiline <<'SQL'
INSERT INTO demo.lab_adv_revenue
SELECT
    region,
    day,
    round(500 + (rand() % 1000) + if(region = 'us-east', 200, 0), 2) AS revenue
FROM (
    SELECT
        arrayElement(['us-east', 'us-west', 'eu-west', 'ap-south'], (number % 4) + 1) AS region,
        today() - toIntervalDay(number / 4) AS day,
        number
    FROM numbers(120)
)
SQL
echo "  ✓ 120 rows: 4 regions x 30 days of daily revenue"
echo ""

subsection "Running total (cumulative sum)"
echo ""
echo "  sum(revenue) OVER (PARTITION BY region ORDER BY day)"
echo ""
run_query_multiline <<'SQL'
SELECT
    region,
    day,
    revenue,
    sum(revenue) OVER (PARTITION BY region ORDER BY day
                       ROWS UNBOUNDED PRECEDING) AS cumulative_revenue
FROM demo.lab_adv_revenue
WHERE region = 'us-east'
ORDER BY day
LIMIT 10
FORMAT PrettyCompact
SQL
echo ""

subsection "Day-over-day change with lag()"
echo ""
echo "  revenue - lagInFrame(revenue, 1) OVER (...) AS daily_change"
echo ""
run_query_multiline <<'SQL'
SELECT
    region,
    day,
    revenue,
    lagInFrame(revenue, 1) OVER (PARTITION BY region ORDER BY day ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS prev_day,
    revenue - lagInFrame(revenue, 1) OVER (PARTITION BY region ORDER BY day ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS daily_change
FROM demo.lab_adv_revenue
WHERE region = 'us-east'
ORDER BY day
LIMIT 10
FORMAT PrettyCompact
SQL
echo ""

subsection "Ranking regions by total revenue"
echo ""
echo "  rank() OVER (ORDER BY total_revenue DESC)"
echo ""
run_query_multiline <<'SQL'
SELECT
    region,
    sum(revenue) AS total_revenue,
    rank() OVER (ORDER BY sum(revenue) DESC) AS revenue_rank,
    dense_rank() OVER (ORDER BY sum(revenue) DESC) AS dense_revenue_rank
FROM demo.lab_adv_revenue
GROUP BY region
ORDER BY revenue_rank
FORMAT PrettyCompact
SQL
echo ""

subsection "Moving average (3-day window)"
echo ""
echo "  avg(revenue) OVER (... ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)"
echo ""
run_query_multiline <<'SQL'
SELECT
    region,
    day,
    revenue,
    round(avg(revenue) OVER (
        PARTITION BY region ORDER BY day
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ), 2) AS moving_avg_3d
FROM demo.lab_adv_revenue
WHERE region = 'us-east'
ORDER BY day
LIMIT 10
FORMAT PrettyCompact
SQL
echo ""

subsection "Session analysis: detecting gaps"
echo ""
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_sessions;

CREATE TABLE demo.lab_adv_sessions
(
    user_id  UInt32,
    ts       DateTime,
    action   LowCardinality(String)
)
ENGINE = MergeTree()
ORDER BY (user_id, ts);

INSERT INTO demo.lab_adv_sessions
SELECT
    (number % 3) + 1 AS user_id,
    now() - toIntervalSecond(
        (2 - (number % 3)) * 86400
        + arrayElement([10, 20, 35, 3700, 3710, 3720, 7500, 7510], (toUInt64(number / 3) % 8) + 1)
    ) AS ts,
    arrayElement(['page_view', 'click', 'scroll', 'purchase'], (number % 4) + 1) AS action
FROM numbers(24)
SQL
echo "  ✓ Session data created (3 users, gaps > 1 hour = new session)"
echo ""

echo "  Detecting session boundaries with lagInFrame():"
echo ""
run_query_multiline <<'SQL'
SELECT
    user_id,
    ts,
    action,
    dateDiff('second',
        lagInFrame(ts, 1) OVER (PARTITION BY user_id ORDER BY ts ROWS BETWEEN 1 PRECEDING AND CURRENT ROW),
        ts) AS gap_seconds,
    if(
        dateDiff('second',
            lagInFrame(ts, 1) OVER (PARTITION BY user_id ORDER BY ts ROWS BETWEEN 1 PRECEDING AND CURRENT ROW),
            ts) > 3600
        OR lagInFrame(ts, 1) OVER (PARTITION BY user_id ORDER BY ts ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) = toDateTime(0),
        '** NEW SESSION **',
        ''
    ) AS session_boundary
FROM demo.lab_adv_sessions
WHERE user_id = 1
ORDER BY ts
FORMAT PrettyCompact
SQL
echo ""

commentary "Window functions keep all rows (unlike GROUP BY). Key patterns: running totals with sum() OVER, comparisons with lagInFrame()/leadInFrame(), rankings with rank()/dense_rank(), moving averages with frame specs. Session detection uses lagInFrame() to find time gaps."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 4: Dictionaries
# ═══════════════════════════════════════════════════════════════════

section "Exercise 4: Dictionaries"

echo "  Dictionaries are in-memory key-value stores for O(1) lookups."
echo "  They replace expensive JOINs with fast dictGet() calls."
echo ""

subsection "Creating lookup table and dictionary"
run_query_multiline <<'SQL'
DROP DICTIONARY IF EXISTS demo.lab_adv_region_dict;
DROP TABLE IF EXISTS demo.lab_adv_region_lookup;
DROP TABLE IF EXISTS demo.lab_adv_orders;

CREATE TABLE demo.lab_adv_region_lookup
(
    region_code String,
    region_name String,
    country String,
    timezone String
)
ENGINE = MergeTree()
ORDER BY region_code;

INSERT INTO demo.lab_adv_region_lookup VALUES
    ('us-east', 'US East (Virginia)', 'United States', 'America/New_York'),
    ('us-west', 'US West (Oregon)', 'United States', 'America/Los_Angeles'),
    ('eu-west', 'EU West (Ireland)', 'Ireland', 'Europe/Dublin'),
    ('ap-south', 'AP South (Mumbai)', 'India', 'Asia/Kolkata'),
    ('eu-east', 'EU East (Frankfurt)', 'Germany', 'Europe/Berlin'),
    ('ap-east', 'AP East (Tokyo)', 'Japan', 'Asia/Tokyo');
SQL
echo "  ✓ Lookup table created with 6 regions"
echo ""

subsection "Creating FLAT dictionary"
run_query_multiline <<'SQL'
CREATE DICTIONARY demo.lab_adv_region_dict
(
    region_code String,
    region_name String,
    country String,
    timezone String
)
PRIMARY KEY region_code
SOURCE(CLICKHOUSE(
    TABLE 'lab_adv_region_lookup'
    DB 'demo'
))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600)
SQL
echo "  ✓ Dictionary created (COMPLEX_KEY_HASHED layout)"
echo ""

subsection "Dictionary status"
run_query_multiline <<'SQL'
SELECT
    name,
    status,
    element_count,
    formatReadableSize(bytes_allocated) AS memory,
    loading_duration
FROM system.dictionaries
WHERE database = 'demo' AND name = 'lab_adv_region_dict'
FORMAT PrettyCompact
SQL
echo ""

subsection "Creating orders table for enrichment"
run_query_multiline <<'SQL'
CREATE TABLE demo.lab_adv_orders
(
    order_id  UInt64,
    region    LowCardinality(String),
    amount    Decimal(18, 2),
    ts        DateTime
)
ENGINE = MergeTree()
ORDER BY (region, ts);

INSERT INTO demo.lab_adv_orders
SELECT
    number AS order_id,
    arrayElement(['us-east', 'us-west', 'eu-west', 'ap-south'], (number % 4) + 1) AS region,
    round((number % 500) + 1, 2) AS amount,
    now() - toIntervalSecond(number * 10) AS ts
FROM numbers(50000)
SQL
echo "  ✓ 50K orders inserted"
echo ""

subsection "JOIN approach (traditional)"
echo ""
run_query_multiline <<'SQL'
SELECT
    o.region,
    r.region_name,
    r.country,
    count() AS orders,
    sum(o.amount) AS total
FROM demo.lab_adv_orders o
JOIN demo.lab_adv_region_lookup r ON o.region = r.region_code
GROUP BY o.region, r.region_name, r.country
ORDER BY total DESC
FORMAT PrettyCompact
SQL
echo ""

subsection "dictGet() approach (O(1) lookup, no JOIN)"
echo ""
run_query_multiline <<'SQL'
SELECT
    region,
    dictGet('demo.lab_adv_region_dict', 'region_name', region) AS region_name,
    dictGet('demo.lab_adv_region_dict', 'country', region) AS country,
    count() AS orders,
    sum(amount) AS total
FROM demo.lab_adv_orders
GROUP BY region
ORDER BY total DESC
FORMAT PrettyCompact
SQL
echo ""

subsection "dictGetOrDefault for missing keys"
echo ""
run_query "SELECT dictGetOrDefault('demo.lab_adv_region_dict', 'country', 'unknown-region', 'N/A') AS result"
echo ""

subsection "Range hashed dictionary: time-versioned prices"
run_query_multiline <<'SQL'
DROP DICTIONARY IF EXISTS demo.lab_adv_price_dict;
DROP TABLE IF EXISTS demo.lab_adv_prices;

CREATE TABLE demo.lab_adv_prices
(
    product_id UInt32,
    valid_from Date,
    valid_to Date,
    price Decimal(10, 2)
)
ENGINE = MergeTree()
ORDER BY (product_id, valid_from);

INSERT INTO demo.lab_adv_prices VALUES
    (1, '2024-01-01', '2024-06-30', 9.99),
    (1, '2024-07-01', '2024-12-31', 12.99),
    (2, '2024-01-01', '2024-03-31', 29.99),
    (2, '2024-04-01', '2024-12-31', 24.99),
    (3, '2024-01-01', '2024-12-31', 49.99);

CREATE DICTIONARY demo.lab_adv_price_dict
(
    product_id UInt32,
    valid_from Date,
    valid_to Date,
    price Decimal(10, 2)
)
PRIMARY KEY product_id
SOURCE(CLICKHOUSE(TABLE 'lab_adv_prices' DB 'demo'))
RANGE(MIN valid_from MAX valid_to)
LAYOUT(RANGE_HASHED())
LIFETIME(3600)
SQL
echo "  ✓ Range hashed dictionary created (time-versioned prices)"
echo ""

echo "  Product 1 price on 2024-03-15 vs 2024-09-15:"
price_march=$(run_query "SELECT dictGet('demo.lab_adv_price_dict', 'price', toUInt32(1), toDate('2024-03-15'))")
price_sept=$(run_query "SELECT dictGet('demo.lab_adv_price_dict', 'price', toUInt32(1), toDate('2024-09-15'))")
echo "  March: $price_march | September: $price_sept"
echo ""

echo "  Product 2 price on 2024-02-01 vs 2024-08-01:"
price_feb=$(run_query "SELECT dictGet('demo.lab_adv_price_dict', 'price', toUInt32(2), toDate('2024-02-01'))")
price_aug=$(run_query "SELECT dictGet('demo.lab_adv_price_dict', 'price', toUInt32(2), toDate('2024-08-01'))")
echo "  February: $price_feb | August: $price_aug"
echo ""

subsection "Dictionary layout comparison"
echo ""
echo "  ┌──────────────────────┬──────────────────────────┬─────────────┐"
echo "  │ Layout               │ Best For                 │ Key Type    │"
echo "  ├──────────────────────┼──────────────────────────┼─────────────┤"
echo "  │ FLAT()               │ Small tables (<500K)     │ UInt64      │"
echo "  │ HASHED()             │ Medium tables, any key   │ Any single  │"
echo "  │ COMPLEX_KEY_HASHED() │ Composite keys           │ Multiple    │"
echo "  │ RANGE_HASHED()       │ Time-versioned lookups   │ Key + range │"
echo "  │ DIRECT()             │ Always-fresh, no cache   │ Any         │"
echo "  │ CACHE(SIZE)          │ Huge source, sparse use  │ Any         │"
echo "  └──────────────────────┴──────────────────────────┴─────────────┘"
echo ""

commentary "Dictionaries replace JOINs with O(1) in-memory lookups. FLAT/HASHED for simple lookups, RANGE_HASHED for time-versioned data (prices, exchange rates). LIFETIME randomizes refresh to avoid thundering herd. Use dictGetOrDefault for safe fallback on missing keys."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 5: Parameterized Views
# ═══════════════════════════════════════════════════════════════════

section "Exercise 5: Parameterized Views"

echo "  Parameterized views are reusable query templates with"
echo "  typed runtime parameters. Like stored functions in SQL."
echo ""

subsection "Creating a parameterized view for revenue analysis"
run_query_multiline <<'SQL'
DROP VIEW IF EXISTS demo.lab_adv_revenue_report;

CREATE VIEW demo.lab_adv_revenue_report AS
SELECT
    region,
    day,
    revenue,
    sum(revenue) OVER (PARTITION BY region ORDER BY day
                       ROWS UNBOUNDED PRECEDING) AS cumulative
FROM demo.lab_adv_revenue
WHERE region = {target_region:String}
    AND day >= {start_date:Date}
    AND day <= {end_date:Date}
ORDER BY day
SQL
echo "  ✓ Parameterized view created with {target_region}, {start_date}, {end_date}"
echo ""

subsection "Calling the view with different parameters"
echo ""
echo "  Query 1: us-east, last 7 days"
run_query_multiline <<SQL
SELECT * FROM demo.lab_adv_revenue_report(
    target_region = 'us-east',
    start_date = today() - 7,
    end_date = today()
)
FORMAT PrettyCompact
SQL
echo ""

echo "  Query 2: eu-west, last 5 days"
run_query_multiline <<SQL
SELECT * FROM demo.lab_adv_revenue_report(
    target_region = 'eu-west',
    start_date = today() - 5,
    end_date = today()
)
FORMAT PrettyCompact
SQL
echo ""

subsection "Parameterized view with aggregation"
run_query_multiline <<'SQL'
DROP VIEW IF EXISTS demo.lab_adv_top_regions;

CREATE VIEW demo.lab_adv_top_regions AS
SELECT
    region,
    sum(revenue) AS total_revenue,
    count() AS days_active,
    round(avg(revenue), 2) AS avg_daily
FROM demo.lab_adv_revenue
WHERE day >= {since:Date}
GROUP BY region
ORDER BY total_revenue DESC
LIMIT {top_n:UInt32}
SQL
echo "  ✓ Created parameterized view with {since} and {top_n}"
echo ""

echo "  Top 3 regions (last 14 days):"
run_query_multiline <<SQL
SELECT * FROM demo.lab_adv_top_regions(
    since = today() - 14,
    top_n = 3
)
FORMAT PrettyCompact
SQL
echo ""

echo "  Top 2 regions (last 7 days):"
run_query_multiline <<SQL
SELECT * FROM demo.lab_adv_top_regions(
    since = today() - 7,
    top_n = 2
)
FORMAT PrettyCompact
SQL
echo ""

commentary "Parameterized views use {name:Type} syntax. Parameters are typed (not string-interpolated), so they are SQL injection safe. They act like reusable query templates — define once, call with different arguments. No performance overhead vs regular queries."

pause

# ═══════════════════════════════════════════════════════════════════
# EXERCISE 6: Buffer Tables + Async Inserts
# ═══════════════════════════════════════════════════════════════════

section "Exercise 6: Buffer Tables + Async Inserts"

echo "  Both solve the too-many-parts problem for high-frequency"
echo "  ingestion by batching small INSERTs before they hit MergeTree."
echo ""

subsection "Part A: Buffer Tables"
echo ""

run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_buf;
DROP TABLE IF EXISTS demo.lab_adv_buf_dest;

CREATE TABLE demo.lab_adv_buf_dest
(
    id     UInt64,
    value  Float64,
    ts     DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY id;

CREATE TABLE demo.lab_adv_buf AS demo.lab_adv_buf_dest
ENGINE = Buffer(
    demo,
    lab_adv_buf_dest,
    4,
    5, 30,
    1000, 10000,
    65536, 1048576
);
SQL
echo "  ✓ Buffer table created"
echo "    Flushes when: time > 30s OR rows > 10K OR bytes > 1MB"
echo "    Or when: time > 5s AND rows > 1K AND bytes > 64KB"
echo ""

subsection "Rapid single-row INSERTs into buffer"
for i in $(seq 1 50); do
    run_query "INSERT INTO demo.lab_adv_buf VALUES ($i, rand(), now())" 2>/dev/null || true
done
echo "  ✓ 50 single-row INSERTs into buffer"
echo ""

buf_rows=$(run_query "SELECT count() FROM demo.lab_adv_buf")
dest_rows=$(run_query "SELECT count() FROM demo.lab_adv_buf_dest")
dest_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_buf_dest' AND active")
echo "  Buffer table rows (includes unflushed): $buf_rows"
echo "  Destination table rows (flushed only):  $dest_rows"
echo "  Destination parts: $dest_parts"
echo ""
echo "  (Data sits in the buffer until flush thresholds are met."
echo "   Buffer transparently merges reads from buffer + destination.)"
echo ""

subsection "Waiting for buffer flush..."
sleep 6
dest_rows_after=$(run_query "SELECT count() FROM demo.lab_adv_buf_dest")
dest_parts_after=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_buf_dest' AND active")
echo "  After waiting ~6s:"
echo "  Destination rows: $dest_rows_after"
echo "  Destination parts: $dest_parts_after"
echo "  (Buffer flushed — 50 rows became ~1 part instead of 50)"
echo ""

subsection "Part B: Async Inserts"
echo ""

run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_async;

CREATE TABLE demo.lab_adv_async
(
    id     UInt64,
    value  Float64,
    ts     DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY id;
SQL
echo "  ✓ Target table created for async inserts"
echo ""

echo "  Inserting 50 rows with async_insert=1..."
for i in $(seq 1 50); do
    run_query_with_settings "--async_insert=1 --wait_for_async_insert=0" "INSERT INTO demo.lab_adv_async VALUES ($i, rand(), now())" 2>/dev/null || true
done
echo "  ✓ 50 async INSERTs submitted"
echo ""

sleep 3
async_rows=$(run_query "SELECT count() FROM demo.lab_adv_async")
async_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_async' AND active")
echo "  After flush:"
echo "  Rows: $async_rows"
echo "  Parts: $async_parts (server batched the 50 INSERTs into fewer parts)"
echo ""

subsection "Comparison: direct INSERT vs buffer vs async"
echo ""
run_query_multiline <<'SQL'
DROP TABLE IF EXISTS demo.lab_adv_direct;

CREATE TABLE demo.lab_adv_direct
(
    id     UInt64,
    value  Float64,
    ts     DateTime DEFAULT now()
)
ENGINE = MergeTree()
ORDER BY id;
SQL

for i in $(seq 1 50); do
    run_query "INSERT INTO demo.lab_adv_direct VALUES ($i, rand(), now())" 2>/dev/null || true
done

sleep 1
direct_parts=$(run_query "SELECT count() FROM system.parts WHERE database = 'demo' AND table = 'lab_adv_direct' AND active")

echo "  50 single-row INSERTs:"
echo "  ┌─────────────────┬───────┬──────────────────────────────────────┐"
echo "  │ Method          │ Parts │ Notes                                │"
echo "  ├─────────────────┼───────┼──────────────────────────────────────┤"
printf "  │ Direct INSERT   │ %5s │ 1 part per INSERT (worst case)       │\n" "$direct_parts"
printf "  │ Buffer table    │ %5s │ Batched in memory, flushed as one    │\n" "$dest_parts_after"
printf "  │ Async INSERT    │ %5s │ Server-side batching, WAL-backed     │\n" "$async_parts"
echo "  └─────────────────┴───────┴──────────────────────────────────────┘"
echo ""

commentary "Buffer tables batch writes in memory (lost on crash). Async inserts are server-side batching with WAL durability. Both solve too-many-parts. Async inserts are simpler (just a setting) and safer (crash-safe). Buffer tables give more control over flush timing."

# ═══════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════

section "Cleanup"

echo "  Dropping all lab tables..."
run_query "DROP VIEW IF EXISTS demo.lab_adv_revenue_report"
run_query "DROP VIEW IF EXISTS demo.lab_adv_top_regions"
run_query "DROP DICTIONARY IF EXISTS demo.lab_adv_price_dict"
run_query "DROP DICTIONARY IF EXISTS demo.lab_adv_region_dict"
run_query "DROP TABLE IF EXISTS demo.lab_adv_proj"
run_query "DROP TABLE IF EXISTS demo.lab_adv_deletes"
run_query "DROP TABLE IF EXISTS demo.lab_adv_revenue"
run_query "DROP TABLE IF EXISTS demo.lab_adv_sessions"
run_query "DROP TABLE IF EXISTS demo.lab_adv_region_lookup"
run_query "DROP TABLE IF EXISTS demo.lab_adv_orders"
run_query "DROP TABLE IF EXISTS demo.lab_adv_prices"
run_query "DROP TABLE IF EXISTS demo.lab_adv_buf"
run_query "DROP TABLE IF EXISTS demo.lab_adv_buf_dest"
run_query "DROP TABLE IF EXISTS demo.lab_adv_async"
run_query "DROP TABLE IF EXISTS demo.lab_adv_direct"
echo "  ✓ All lab tables, views, and dictionaries dropped"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

section "Lab Complete — Advanced Topics Summary"

echo "  ┌──────────────────────┬─────────────────────────────────────────────────┐"
echo "  │ Topic                │ What We Learned                                 │"
echo "  ├──────────────────────┼─────────────────────────────────────────────────┤"
echo "  │ Projections          │ 2x storage per reorder; agg projections cheap   │"
echo "  │ Lightweight Deletes  │ Row masking vs part rewrite; DELETE FROM faster  │"
echo "  │ Window Functions     │ Running totals, lag/lead, ranks, sessions       │"
echo "  │ Dictionaries         │ O(1) lookups replace JOINs; range for versions  │"
echo "  │ Parameterized Views  │ Reusable typed templates; SQL injection safe    │"
echo "  │ Buffer + Async       │ Both batch small INSERTs; async is simpler      │"
echo "  └──────────────────────┴─────────────────────────────────────────────────┘"
echo ""
echo "  Key rules:"
echo "    1. Projections: 1 reorder + 1-2 aggregation = sweet spot"
echo "    2. DELETE FROM over ALTER DELETE for targeted removals"
echo "    3. Window functions: analytics without GROUP BY collapse"
echo "    4. Dictionaries: O(1) lookups, not JOINs, for enrichment"
echo "    5. Parameterized views: typed, safe, reusable query templates"
echo "    6. Async inserts: simplest fix for high-frequency producers"
echo ""
echo "  See notes/13-advanced-topics.md for theory and notes/14-advanced-lab.md for reference."
echo ""
