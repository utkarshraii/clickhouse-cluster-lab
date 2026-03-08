# Advanced ClickHouse Topics

## 1. Projections Deep Dive

Projections were introduced in Phase 6. Here we go deeper: multiple projections per table, storage cost analysis, and when projections hurt.

### Multiple Projections Per Table

A single table can have multiple projections. The optimizer picks the best one per query.

```sql
CREATE TABLE events (
    event_id UInt64,
    event_type LowCardinality(String),
    user_id UInt32,
    region LowCardinality(String),
    ts DateTime,
    amount Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY (event_type, ts);

-- Projection for user-centric queries
ALTER TABLE events ADD PROJECTION proj_by_user
    (SELECT * ORDER BY user_id, ts);

-- Projection for region-centric queries
ALTER TABLE events ADD PROJECTION proj_by_region
    (SELECT * ORDER BY region, ts);

-- Pre-aggregation projection for dashboards
ALTER TABLE events ADD PROJECTION proj_hourly_summary
    (SELECT event_type, toStartOfHour(ts) AS hour,
            count(), sum(amount)
     GROUP BY event_type, hour);
```

### Storage Cost

Each reorder projection stores a **full copy** of the data. Each aggregation projection stores the pre-aggregated result.

```sql
-- Measure storage cost of projections
SELECT
    name,
    formatReadableSize(bytes_on_disk) AS size,
    rows
FROM system.parts
WHERE database = 'demo' AND table = 'events' AND active

-- Compare table vs projection storage
SELECT
    part_type,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed
FROM system.parts_columns
WHERE database = 'demo' AND table = 'events' AND active
GROUP BY part_type
```

### When Projections Hurt

- **2x+ write amplification** per reorder projection — every INSERT writes data twice
- **Merge cost increases** — each projection's parts also need merging
- **Diminishing returns** — 3+ reorder projections means 4x+ storage and write cost
- **Aggregation projections** are cheap — they store much less data

**Rule of thumb:** 1 reorder projection + 1-2 aggregation projections is the sweet spot. Beyond that, consider Materialized Views instead.

---

## 2. Lightweight Deletes vs Mutations

Phase 7 introduced both. Here we compare in depth.

### ALTER DELETE (Mutation)

```sql
ALTER TABLE events DELETE WHERE status = 'test'
```

- Rewrites **entire parts** containing matching rows
- Async: ALTER returns immediately, background rewrite
- Heavy: even 1 matching row causes full part rewrite
- Blocks subsequent mutations on the same table

### DELETE FROM (Lightweight)

```sql
DELETE FROM events WHERE status = 'test'
```

- Sets `_row_exists = 0` in a mask bitmap
- Masked rows filtered out at query time
- Actual removal during the next background merge
- Much faster for targeted deletions

### Key Differences

| Aspect | ALTER DELETE | DELETE FROM |
|--------|-------------|-------------|
| Mechanism | Rewrites parts | Row masking |
| Speed | Slow (I/O bound) | Fast (metadata only) |
| Disk I/O | High (rewrites entire part) | Minimal |
| When rows disappear | After rewrite completes | Immediately hidden, physically removed at merge |
| Blocking | Blocks other mutations | Non-blocking |
| Best for | Bulk cleanup | Targeted deletes |

### The `_row_exists` Virtual Column

Lightweight DELETE sets a hidden `_row_exists` column to 0. You can observe this:

```sql
-- See the mask in action
SELECT *, _row_exists FROM events WHERE _row_exists = 0
-- Returns nothing (masked rows are filtered before reaching SELECT)
```

The mask is stored as a lightweight file alongside the part data, not by rewriting the part.

---

## 3. Window Functions

Window functions compute values across a set of rows related to the current row, without collapsing rows like GROUP BY.

### Syntax

```sql
SELECT
    column,
    window_function() OVER (
        [PARTITION BY partition_columns]
        [ORDER BY sort_columns]
        [frame_spec]
    )
FROM table
```

### Common Window Functions

| Function | Purpose |
|----------|---------|
| `row_number()` | Sequential row number within partition |
| `rank()` | Rank with gaps for ties |
| `dense_rank()` | Rank without gaps |
| `lagInFrame(col, N)` | Value N rows before current (within frame) |
| `leadInFrame(col, N)` | Value N rows after current (within frame) |
| `sum() OVER (...)` | Running/cumulative sum |
| `avg() OVER (...)` | Moving average |
| `first_value(col)` | First value in window |
| `last_value(col)` | Last value in window |

### Running Totals

```sql
SELECT
    ts,
    amount,
    sum(amount) OVER (ORDER BY ts ROWS UNBOUNDED PRECEDING) AS cumulative
FROM orders
```

### Rankings

```sql
SELECT
    region,
    user_id,
    total_spent,
    rank() OVER (PARTITION BY region ORDER BY total_spent DESC) AS region_rank
FROM user_spending
```

### Lag/Lead for Comparisons

ClickHouse uses `lagInFrame()`/`leadInFrame()` (not `lag()`/`lead()`). They require an explicit frame specification.

```sql
SELECT
    ts,
    revenue,
    lagInFrame(revenue, 1) OVER (ORDER BY ts
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS prev_revenue,
    revenue - lagInFrame(revenue, 1) OVER (ORDER BY ts
        ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) AS change
FROM daily_revenue
```

### Session Analysis

```sql
SELECT
    user_id,
    ts,
    event_type,
    dateDiff('second',
        lagInFrame(ts, 1) OVER (PARTITION BY user_id ORDER BY ts
            ROWS BETWEEN 1 PRECEDING AND CURRENT ROW),
        ts) AS gap_seconds
FROM events
-- Rows where gap_seconds > 1800 indicate a new session
```

### Frame Specifications

```sql
ROWS UNBOUNDED PRECEDING              -- all rows from start to current
ROWS BETWEEN 3 PRECEDING AND CURRENT ROW  -- sliding window of 4 rows
ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING  -- current to end
```

---

## 4. Dictionaries

Dictionaries are in-memory key-value lookup structures. They replace JOINs with O(1) `dictGet()` calls.

### Creating a Dictionary

```sql
CREATE DICTIONARY region_dict
(
    region_code String,
    region_name String,
    country String,
    timezone String
)
PRIMARY KEY region_code
SOURCE(CLICKHOUSE(
    TABLE 'region_lookup'
    DB 'demo'
))
LAYOUT(FLAT())
LIFETIME(MIN 300 MAX 600)
```

### Layout Types

| Layout | Best For | Memory | Key Type |
|--------|----------|--------|----------|
| `FLAT()` | Small tables (<500K rows) | Pre-allocated array | UInt64 |
| `HASHED()` | Medium tables, any key type | Hash table | Any |
| `RANGE_HASHED()` | Time-versioned lookups | Hash + ranges | Key + date range |
| `COMPLEX_KEY_HASHED()` | Composite keys | Hash table | Multiple columns |
| `DIRECT()` | Always-fresh, no caching | None (queries source) | Any |
| `CACHE(SIZE)` | Huge source, sparse access | LRU cache | Any |

### Using Dictionaries

```sql
-- Single attribute lookup
SELECT dictGet('region_dict', 'country', region_code) AS country
FROM events

-- Multiple attributes
SELECT
    dictGet('region_dict', 'region_name', region_code) AS name,
    dictGet('region_dict', 'timezone', region_code) AS tz
FROM events

-- With default value
SELECT dictGetOrDefault('region_dict', 'country', region_code, 'Unknown')
FROM events
```

### LIFETIME — Refresh Strategy

```sql
LIFETIME(MIN 300 MAX 600)
```

- ClickHouse refreshes the dictionary at a random interval between MIN and MAX seconds
- Randomized to avoid thundering herd (all dictionaries refreshing at once)
- `LIFETIME(0)` = never auto-refresh (manual only via `SYSTEM RELOAD DICTIONARY`)

### Range Hashed — Time-Versioned Lookups

```sql
CREATE DICTIONARY price_dict
(
    product_id UInt32,
    valid_from Date,
    valid_to Date,
    price Decimal(10, 2)
)
PRIMARY KEY product_id
SOURCE(CLICKHOUSE(TABLE 'price_history' DB 'demo'))
RANGE(MIN valid_from MAX valid_to)
LAYOUT(RANGE_HASHED())
LIFETIME(3600)
```

```sql
-- Lookup price valid on a specific date
SELECT dictGet('price_dict', 'price', product_id, toDate('2024-06-15'))
FROM orders
```

### When to Use Dictionaries vs JOINs

| Scenario | Use |
|----------|-----|
| Lookup table < 1M rows | Dictionary (FLAT or HASHED) |
| Lookup table > 10M rows | JOIN or DIRECT dictionary |
| Need real-time freshness | DIRECT layout or low LIFETIME |
| Time-versioned prices/rates | RANGE_HASHED |
| Composite key lookups | COMPLEX_KEY_HASHED |

---

## 5. Parameterized Views

Parameterized views are reusable query templates with runtime parameters. They act like stored functions.

### Syntax

```sql
CREATE VIEW events_by_region AS
SELECT
    region,
    count() AS events,
    sum(amount) AS total_amount
FROM events
WHERE ts >= {start_date:Date} AND ts < {end_date:Date}
    AND region = {target_region:String}
GROUP BY region
```

### Usage

```sql
SELECT * FROM events_by_region(
    start_date = '2024-01-01',
    end_date = '2024-02-01',
    target_region = 'us-east'
)
```

### Parameter Types

Parameters use the `{name:Type}` syntax. Supported types: all ClickHouse types (`String`, `UInt32`, `Date`, `DateTime`, etc.).

### Benefits

- **Reusable templates** — define once, call with different parameters
- **SQL injection safe** — parameters are typed, not string-interpolated
- **Performance** — same as a regular query (no overhead)
- **Composable** — can be used in subqueries and JOINs

---

## 6. Buffer Tables & Async Inserts

Both solve the same problem: too many small INSERTs creating too many parts.

### Buffer Tables

A Buffer table batches small writes in memory and flushes to a destination MergeTree table.

```sql
CREATE TABLE events_buffer AS events
ENGINE = Buffer(
    demo,           -- database
    events,         -- destination table
    16,             -- num_layers (parallelism)
    10, 100,        -- min/max seconds before flush
    10000, 100000,  -- min/max rows before flush
    1048576, 10485760  -- min/max bytes before flush
)
```

**How it works:**
1. INSERTs go to the Buffer table (in-memory)
2. Buffer flushes when ANY max threshold is reached, or ALL min thresholds are reached
3. Flush creates one INSERT into the destination table
4. SELECT from buffer automatically includes both buffered and destination data

**Flush conditions:**
- Flush if time > max_time OR rows > max_rows OR bytes > max_bytes
- Flush if time > min_time AND rows > min_rows AND bytes > min_bytes

**Trade-offs:**
- Data in buffer is lost on crash (in-memory only)
- No deduplication between buffer and destination
- Reads from buffer are not indexed

### Async Inserts

Server-side batching introduced in ClickHouse 22.x. The server collects small INSERTs and combines them.

```sql
-- Enable per-session
SET async_insert = 1;
SET wait_for_async_insert = 1;  -- wait for confirmation

INSERT INTO events VALUES (...);  -- batched server-side
```

**Settings:**
| Setting | Default | Meaning |
|---------|---------|---------|
| `async_insert` | 0 | Enable async inserts |
| `async_insert_max_data_size` | 10 MiB | Flush when buffer reaches this size |
| `async_insert_busy_timeout_ms` | 200ms | Max wait before flushing |
| `wait_for_async_insert` | 1 | Client waits for flush confirmation |

**Advantages over Buffer tables:**
- Data is durable (WAL-based, survives crash)
- Works transparently with existing INSERT statements
- Per-user/session configurability
- No separate table needed

### When to Use What

| Scenario | Solution |
|----------|----------|
| Many small clients, can't change client code | Async inserts (server-side, transparent) |
| Single high-frequency producer | Buffer table (predictable batching) |
| Need crash safety | Async inserts (WAL-backed) |
| Simple setup | Async inserts (just a setting) |
| Complex flush logic | Buffer table (configurable thresholds) |
