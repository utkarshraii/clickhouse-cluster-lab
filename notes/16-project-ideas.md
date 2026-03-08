# ClickHouse Project Ideas

Five hands-on projects that exercise the concepts from Phases 1-8. Each project specifies the key decisions you'll make, which phases it draws from, and a suggested schema.

---

## Project 1: Real-Time Analytics Dashboard

**What you build:** An event ingestion pipeline with pre-aggregated dashboard queries. Simulates a product analytics system (page views, clicks, purchases).

**Phases exercised:** 3 (engines), 5 (ORDER BY, skip indexes), 6 (MVs, projections), 7 (monitoring)

**Key decisions:**
- Engine: MergeTree for raw events, AggregatingMergeTree for dashboard rollups
- ORDER BY: `(event_type, user_id, ts)` — low cardinality first
- MV: hourly rollup with `countState()`, `sumState()`, `uniqState()`
- Projection: pre-aggregation for daily summary queries

**Suggested schema:**

```sql
CREATE TABLE analytics.events (
    event_id    UInt64,
    event_type  LowCardinality(String),
    user_id     UInt32,
    page_url    String,
    referrer    String,
    country     LowCardinality(String),
    device      LowCardinality(String),
    ts          DateTime,
    duration_ms UInt32,
    revenue     Decimal(18, 2)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (event_type, country, ts)
TTL ts + INTERVAL 90 DAY DELETE;

CREATE TABLE analytics.hourly_dashboard (
    event_type  LowCardinality(String),
    country     LowCardinality(String),
    hour        DateTime,
    events      AggregateFunction(count, UInt64),
    unique_users AggregateFunction(uniq, UInt32),
    total_revenue AggregateFunction(sum, Decimal(18, 2))
)
ENGINE = AggregatingMergeTree()
ORDER BY (event_type, country, hour);

CREATE MATERIALIZED VIEW analytics.hourly_mv TO analytics.hourly_dashboard
AS SELECT
    event_type, country, toStartOfHour(ts) AS hour,
    countState() AS events,
    uniqState(user_id) AS unique_users,
    sumState(revenue) AS total_revenue
FROM analytics.events
GROUP BY event_type, country, hour;
```

**Stretch goals:**
- Add a dictionary for country → region enrichment
- Create parameterized views for common dashboard queries
- Set up TTL to move data to cold storage after 30 days, delete after 90

---

## Project 2: User Behavior Tracking

**What you build:** A user-centric analytics system where most queries filter by `user_id`. Supports session analysis, funnel tracking, and per-user timelines.

**Phases exercised:** 4 (sharding), 5 (ORDER BY), 6 (projections), 8 (window functions, dictionaries)

**Key decisions:**
- Sharding key: `cityHash64(user_id)` — co-locates all data for a user
- ORDER BY: `(user_id, ts)` — user-first for per-user queries
- Projection: `ORDER BY (event_type, ts)` for event-type aggregations
- Window functions: session detection via `lagInFrame()`, funnels via `row_number()`

**Suggested schema:**

```sql
CREATE TABLE tracking.user_events ON CLUSTER ch_cluster (
    user_id     UInt32,
    session_id  UInt64,
    event_type  LowCardinality(String),
    page_url    String,
    ts          DateTime64(3),
    properties  String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/tracking/user_events', '{replica}')
PARTITION BY toYYYYMM(ts)
ORDER BY (user_id, ts);

CREATE TABLE tracking.user_events_dist ON CLUSTER ch_cluster
AS tracking.user_events
ENGINE = Distributed(ch_cluster, tracking, user_events, cityHash64(user_id));
```

**Key queries to implement:**
```sql
-- Session detection
SELECT user_id, ts, event_type,
    dateDiff('second',
        lagInFrame(ts, 1) OVER (PARTITION BY user_id ORDER BY ts
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW), ts) AS gap,
    sum(if(gap > 1800 OR gap IS NULL, 1, 0)) OVER (
        PARTITION BY user_id ORDER BY ts ROWS UNBOUNDED PRECEDING) AS session_num
FROM tracking.user_events
WHERE user_id = 12345

-- Funnel analysis
SELECT event_type, count() AS users,
    round(count() / first_value(count()) OVER (ORDER BY step) * 100, 1) AS pct
FROM (
    SELECT user_id, event_type,
        row_number() OVER (PARTITION BY user_id ORDER BY ts) AS step
    FROM tracking.user_events
    WHERE event_type IN ('landing', 'signup', 'purchase')
) GROUP BY event_type, step ORDER BY step
```

**Stretch goals:**
- Build a user properties dictionary for enrichment
- Compare sharding by `rand()` vs `cityHash64(user_id)` — measure query performance difference

---

## Project 3: Log Aggregation System

**What you build:** A high-volume log ingestion and search system. Handles high-cardinality fields (service names, trace IDs), full-text search, and automatic data lifecycle with TTL.

**Phases exercised:** 1 (compression), 3 (engines), 5 (skip indexes), 7 (TTL, parts, monitoring), 8 (buffer tables)

**Key decisions:**
- Compression: ZSTD for message body, DoubleDelta for timestamps
- ORDER BY: `(service, severity, ts)` — filter by service first
- Skip indexes: `tokenbf_v1` on message for text search, `bloom_filter` on trace_id
- TTL: 7 days hot, 30 days cold, 90 days delete
- Ingestion: Buffer table or async inserts for high-frequency log producers

**Suggested schema:**

```sql
CREATE TABLE logs.entries (
    ts          DateTime64(3) CODEC(DoubleDelta, LZ4),
    service     LowCardinality(String),
    severity    Enum8('DEBUG'=0, 'INFO'=1, 'WARN'=2, 'ERROR'=3, 'FATAL'=4),
    trace_id    String,
    span_id     String,
    message     String CODEC(ZSTD(3)),
    attributes  String CODEC(ZSTD(3)),
    INDEX idx_trace trace_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_msg message TYPE tokenbf_v1(10240, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(ts)
ORDER BY (service, severity, ts)
TTL ts + INTERVAL 7 DAY TO VOLUME 'cold',
    ts + INTERVAL 90 DAY DELETE
SETTINGS index_granularity = 8192;

CREATE TABLE logs.entries_buffer AS logs.entries
ENGINE = Buffer(logs, entries, 16, 5, 30, 10000, 100000, 1048576, 10485760);
```

**Key queries to implement:**
```sql
-- Search logs by text
SELECT ts, service, severity, message
FROM logs.entries
WHERE service = 'payment-api' AND message LIKE '%timeout%'
ORDER BY ts DESC LIMIT 50

-- Error rate by service (last hour)
SELECT service, count() AS errors,
    round(count() / (SELECT count() FROM logs.entries
        WHERE ts > now() - INTERVAL 1 HOUR) * 100, 2) AS error_pct
FROM logs.entries
WHERE severity >= 'ERROR' AND ts > now() - INTERVAL 1 HOUR
GROUP BY service ORDER BY errors DESC

-- Trace reconstruction
SELECT ts, service, span_id, severity, message
FROM logs.entries WHERE trace_id = 'abc123' ORDER BY ts
```

**Stretch goals:**
- Measure compression ratios: compare LZ4 vs ZSTD on the message column
- Build an error rate MV for a real-time error dashboard
- Monitor part counts and disk usage as data ages through TTL tiers

---

## Project 4: Time-Series Metrics Store

**What you build:** A metrics storage system with multi-resolution rollups. Raw metrics at 1-second resolution roll up to 1-minute, 5-minute, and hourly aggregations via MVs.

**Phases exercised:** 3 (SummingMergeTree), 5 (ORDER BY), 6 (MVs), 7 (TTL, disk management), 8 (parameterized views)

**Key decisions:**
- Engine: MergeTree for raw, SummingMergeTree for rollups
- ORDER BY: `(metric_name, host, ts)` — metric-first for dashboard queries
- MVs: cascade of rollups (raw → 1min → 5min → hourly)
- TTL: raw 7 days, 1min 30 days, 5min 90 days, hourly forever
- Parameterized views: for resolution-aware queries

**Suggested schema:**

```sql
CREATE TABLE metrics.raw (
    metric_name LowCardinality(String),
    host        LowCardinality(String),
    ts          DateTime,
    value       Float64
)
ENGINE = MergeTree()
PARTITION BY toYYYYMMDD(ts)
ORDER BY (metric_name, host, ts)
TTL ts + INTERVAL 7 DAY DELETE;

CREATE TABLE metrics.rollup_1min (
    metric_name LowCardinality(String),
    host        LowCardinality(String),
    ts          DateTime,
    min_val     SimpleAggregateFunction(min, Float64),
    max_val     SimpleAggregateFunction(max, Float64),
    avg_val     SimpleAggregateFunction(avg, Float64),
    count       SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (metric_name, host, ts)
TTL ts + INTERVAL 30 DAY DELETE;

CREATE MATERIALIZED VIEW metrics.mv_1min TO metrics.rollup_1min
AS SELECT
    metric_name, host,
    toStartOfMinute(ts) AS ts,
    min(value) AS min_val,
    max(value) AS max_val,
    avg(value) AS avg_val,
    count() AS count
FROM metrics.raw
GROUP BY metric_name, host, ts;
```

**Key queries to implement:**
```sql
-- Parameterized view: auto-select resolution based on time range
CREATE VIEW metrics.smart_query AS
SELECT metric_name, host, ts, avg_val AS value
FROM metrics.rollup_1min
WHERE metric_name = {metric:String}
    AND host = {target_host:String}
    AND ts >= {from_ts:DateTime}
    AND ts <= {to_ts:DateTime}
ORDER BY ts
```

**Stretch goals:**
- Add 5-minute and hourly rollup tiers (cascade of MVs)
- Compare query performance across resolutions
- Build a host dictionary for enrichment (datacenter, rack, OS)

---

## Project 5: A/B Testing Platform

**What you build:** An experiment analysis system that tracks user assignments to variants and measures outcomes. Uses statistical functions, window functions, and approximate aggregations.

**Phases exercised:** 3 (ReplacingMergeTree), 5 (ORDER BY), 6 (MVs), 8 (window functions, dictionaries)

**Key decisions:**
- Engine: MergeTree for events, ReplacingMergeTree for experiment assignments (user can be reassigned)
- ORDER BY: `(experiment_id, variant, user_id)` — experiment-first
- Window functions: cumulative conversion rates, sequential testing
- Approximate functions: `uniq()` for unique users, `quantile()` for revenue distributions

**Suggested schema:**

```sql
CREATE TABLE experiments.assignments (
    experiment_id LowCardinality(String),
    user_id       UInt32,
    variant       LowCardinality(String),
    assigned_at   DateTime,
    version       UInt32
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (experiment_id, user_id);

CREATE TABLE experiments.events (
    experiment_id LowCardinality(String),
    user_id       UInt32,
    event_type    LowCardinality(String),
    revenue       Decimal(18, 2),
    ts            DateTime
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (experiment_id, user_id, ts);
```

**Key queries to implement:**
```sql
-- Experiment summary with statistical comparison
SELECT
    a.variant,
    uniq(a.user_id) AS users,
    countIf(e.event_type = 'purchase') AS conversions,
    round(countIf(e.event_type = 'purchase') / uniq(a.user_id) * 100, 2) AS conv_rate_pct,
    round(avgIf(e.revenue, e.event_type = 'purchase'), 2) AS avg_revenue,
    round(quantileIf(0.5)(e.revenue, e.event_type = 'purchase'), 2) AS median_revenue
FROM experiments.assignments FINAL AS a
LEFT JOIN experiments.events AS e
    ON a.experiment_id = e.experiment_id AND a.user_id = e.user_id
WHERE a.experiment_id = 'homepage_redesign'
GROUP BY a.variant

-- Cumulative conversion rate over time (sequential testing)
SELECT
    variant, day,
    cumulative_conversions,
    cumulative_users,
    round(cumulative_conversions / cumulative_users * 100, 2) AS cum_conv_rate
FROM (
    SELECT variant, toDate(ts) AS day,
        sum(conversions) OVER (PARTITION BY variant ORDER BY day
            ROWS UNBOUNDED PRECEDING) AS cumulative_conversions,
        sum(users) OVER (PARTITION BY variant ORDER BY day
            ROWS UNBOUNDED PRECEDING) AS cumulative_users
    FROM daily_experiment_stats
)
```

**Stretch goals:**
- Build a variant assignment dictionary for fast enrichment
- Create MVs for daily experiment summaries
- Implement a parameterized view for experiment reports

---

## Choosing a Project

| Project | Complexity | Key Skills Practiced |
|---------|-----------|---------------------|
| Analytics Dashboard | Medium | MVs, AggregatingMergeTree, TTL |
| User Behavior | Medium-High | Sharding, window functions, sessions |
| Log Aggregation | Medium | Compression, skip indexes, Buffer tables |
| Time-Series Metrics | Medium | Multi-resolution MVs, parameterized views |
| A/B Testing | High | ReplacingMergeTree, statistics, window functions |

**Recommended starting point:** Project 1 (Analytics Dashboard) — it exercises the most foundational concepts with moderate complexity.
