# Query Optimization in ClickHouse

## The ORDER BY Key: Most Important Performance Decision

The `ORDER BY` in a MergeTree table definition determines:
1. How data is physically sorted on disk
2. What the sparse (primary) index contains
3. Which queries can efficiently skip granules

```sql
-- This ORDER BY determines ALL read performance characteristics
CREATE TABLE events (...)
ENGINE = MergeTree()
ORDER BY (event_type, user_id, timestamp)
```

### ORDER BY Selection Strategy

**Rule**: Put your most common `WHERE` filter columns first, ordered from lowest to highest cardinality.

```
Low cardinality first ──────────────► High cardinality last

event_type (4 values) → user_id (1000 values) → timestamp (millions)
```

**Why low cardinality first?**
- The sparse index stores the first row of each granule
- With low-cardinality first column, many granules have the same prefix → better binary search

### Decision Framework

| Your most common query pattern | Best ORDER BY |
|-------------------------------|---------------|
| `WHERE event_type = X` | `(event_type, ...)` |
| `WHERE event_type = X AND user_id = Y` | `(event_type, user_id, ...)` |
| `WHERE user_id = Y` | `(user_id, ...)` — or add a skip index |
| `WHERE timestamp > X` | `(timestamp, ...)` — but only if time-range is dominant |
| `GROUP BY event_type` | `(event_type, ...)` — enables streaming aggregation |

### Anti-Patterns

```sql
-- BAD: High-cardinality column first
ORDER BY (timestamp, event_type)
-- Every granule starts with a different timestamp → index is useless for event_type queries

-- BAD: Too many columns in ORDER BY
ORDER BY (a, b, c, d, e, f, g)
-- Only the first 2-3 columns are useful in practice. The rest just increase merge cost.

-- BAD: ORDER BY matches no common query pattern
ORDER BY (id)  -- if nobody ever filters by id
```

---

## Skip Indexes (Data Skipping Indexes)

Skip indexes are secondary indexes that allow skipping **granules** (not individual rows). They're checked AFTER the primary index.

### Types of Skip Indexes

#### 1. `minmax` — Track min/max per block of granules

```sql
ALTER TABLE events ADD INDEX idx_ts timestamp TYPE minmax GRANULARITY 4;
```

- Stores: min and max of `timestamp` for every 4 granules
- Useful for: Range queries (`WHERE timestamp > X`)
- Skip condition: If block's max < X, skip the whole block
- **When to use**: Columns not in ORDER BY that you filter by range

#### 2. `set(N)` — Track unique values per block

```sql
ALTER TABLE events ADD INDEX idx_region region TYPE set(100) GRANULARITY 4;
```

- Stores: Set of unique values (up to N) per 4 granules
- Useful for: Equality checks (`WHERE region = 'us-east'`)
- Skip condition: If the value isn't in the set, skip the block
- **When to use**: Low-cardinality columns not in ORDER BY. N should be > cardinality.
- **Caveat**: If N < actual unique values, the index stores nothing (falls back to always-match)

#### 3. `bloom_filter` — Probabilistic membership test

```sql
ALTER TABLE events ADD INDEX idx_uid user_id TYPE bloom_filter(0.01) GRANULARITY 4;
```

- Stores: Bloom filter per block of granules
- Useful for: Equality and IN checks on high-cardinality columns
- Skip condition: If bloom filter says "definitely not here", skip
- **False positive rate**: 0.01 = 1% false positives (reads 1% extra granules)
- **When to use**: High-cardinality columns not in ORDER BY (e.g., UUIDs, user IDs)

#### 4. `tokenbf_v1` / `ngrambf_v1` — Text search indexes

```sql
ALTER TABLE logs ADD INDEX idx_msg message TYPE tokenbf_v1(10240, 3, 0) GRANULARITY 4;
```

- Useful for: `WHERE message LIKE '%error%'` or `hasToken(message, 'error')`
- **When to use**: Text columns you search with LIKE/hasToken

### Skip Index Effectiveness

```sql
-- Check if your skip index is actually helping
EXPLAIN indexes = 1
SELECT * FROM events WHERE region = 'us-east';

-- Look for:
--   Skip
--     Name: idx_region
--     Parts: 5/10           ← Skipped 5 out of 10 parts
--     Granules: 100/1000    ← Read only 100 out of 1000 granules
```

### When Skip Indexes DON'T Help

- Column is already the first column in ORDER BY (primary index already handles it)
- Column values are randomly distributed across granules (can't skip anything)
- GRANULARITY is too large (block size too big to skip effectively)

---

## Projections: Pre-Sorted Alternative Orderings

A projection is like a materialized secondary ORDER BY. The data is stored twice (once per ordering), but queries automatically use the best ordering.

```sql
CREATE TABLE events (
    event_id UInt64,
    event_type LowCardinality(String),
    user_id UInt32,
    timestamp DateTime,
    amount Decimal(18, 2)
)
ENGINE = MergeTree()
ORDER BY (event_type, timestamp)  -- Primary ordering

-- Add a projection for queries that filter by user_id
-- Data is re-sorted by user_id in the projection's storage
PROJECTION proj_by_user (
    SELECT event_id, event_type, user_id, timestamp, amount
    ORDER BY user_id
);
```

### How Projections Work

1. When data is inserted, it's stored in BOTH the primary ordering AND the projection ordering
2. When a query arrives, the optimizer checks if any projection is better
3. If the projection's ORDER BY matches the WHERE clause better, it's used transparently

### Projections vs Skip Indexes

| | Projection | Skip Index |
|--|-----------|------------|
| **Storage** | Full data copy (2× disk) | Tiny metadata |
| **Accuracy** | Exact (true secondary index) | Approximate (can over-read) |
| **Insert cost** | 2× write amplification | Minimal overhead |
| **When to use** | Second most common query pattern | Occasional filters, low overhead tolerance |

### Projections for Pre-Aggregation

```sql
-- Projection that pre-aggregates hourly counts
PROJECTION proj_hourly_counts (
    SELECT
        event_type,
        toStartOfHour(timestamp) AS hour,
        count()
    GROUP BY event_type, hour
);
```

When you run `SELECT event_type, toStartOfHour(timestamp) AS hour, count() FROM events GROUP BY event_type, hour`, ClickHouse automatically uses this projection instead of scanning raw data.

---

## Materialized Views for Pre-Aggregation

Unlike projections, Materialized Views (MVs) write to a SEPARATE table. They're triggered on INSERT.

```sql
-- Source table
CREATE TABLE events (...) ENGINE = MergeTree() ORDER BY ...;

-- Destination table (stores aggregated data)
CREATE TABLE events_hourly (
    event_type LowCardinality(String),
    hour DateTime,
    event_count SimpleAggregateFunction(sum, UInt64),
    unique_users AggregateFunction(uniq, UInt32)
) ENGINE = AggregatingMergeTree()
ORDER BY (event_type, hour);

-- The "view" is really an INSERT trigger
CREATE MATERIALIZED VIEW events_hourly_mv
TO events_hourly
AS SELECT
    event_type,
    toStartOfHour(timestamp) AS hour,
    count() AS event_count,
    uniqState(user_id) AS unique_users
FROM events
GROUP BY event_type, hour;
```

### MVs vs Projections

| | Materialized View | Projection |
|--|-------------------|------------|
| **Storage** | Separate table (can have different ENGINE) | Inside the same table |
| **Flexibility** | Any transformation (JOINs, functions) | Only ORDER BY / GROUP BY |
| **Schema** | Can have fewer columns | Must include all columns (for non-aggregate) |
| **Querying** | Query the target table directly | Transparent (optimizer picks) |
| **Maintenance** | Separate lifecycle (drop/recreate) | Tied to the table |

### When to Use MVs

- You need to transform data (not just reorder)
- You want to reduce storage (aggregate down from billions to millions of rows)
- You query a dashboard frequently with the same GROUP BY

---

## EXPLAIN Output Interpretation

### Full EXPLAIN Reference

```sql
EXPLAIN indexes = 1, actions = 1, header = 1
SELECT event_type, count()
FROM events
WHERE timestamp > '2024-01-01'
GROUP BY event_type
ORDER BY count() DESC
LIMIT 10;
```

### What Each Section Means

```
Limit 10                                  ← Final LIMIT
  Sorting (ORDER BY count() DESC)         ← Sort merged results
    Expression                            ← Evaluate column expressions
      Aggregating                         ← GROUP BY aggregation
        Expression (Before GROUP BY)      ← Evaluate expressions for GROUP BY
          Filter (WHERE)                  ← Apply WHERE filter
            ReadFromMergeTree             ← Read from disk
            Indexes:
              PrimaryKey
                Keys: timestamp           ← Primary index columns used
                Condition: (timestamp > '2024-01-01')
                Parts: 3/12              ← 3 of 12 parts matched
                Granules: 450/5000       ← 450 of 5000 granules to read
              Skip (if skip indexes exist)
                Name: idx_region
                Parts: 2/3
                Granules: 100/450
```

### Reading the Granule Ratio

```
Granules: 450/5000  → Reading 9% of data → GOOD index usage
Granules: 4800/5000 → Reading 96% of data → Index is NOT helping, full scan
Granules: 1/5000    → Reading 0.02% → GREAT, very selective
```

---

## Performance Patterns & Tips

### 1. Avoid `SELECT *`

```sql
-- BAD: reads ALL columns from disk
SELECT * FROM events WHERE ...;

-- GOOD: only reads 2 column files
SELECT event_type, count() FROM events WHERE ...;
```

ClickHouse is columnar — each column is a separate file. Reading unnecessary columns wastes I/O.

### 2. Use `PREWHERE` for Early Filtering

```sql
-- ClickHouse automatically converts WHERE to PREWHERE when beneficial
-- PREWHERE reads filter columns FIRST, then reads other columns only for matching rows
SELECT event_type, user_id, amount
FROM events
WHERE event_type = 'purchase';

-- Execution: read event_type.bin → filter → read user_id.bin and amount.bin only for matches
```

The optimizer does this automatically, but you can force it:
```sql
SELECT ... FROM events PREWHERE event_type = 'purchase' WHERE amount > 100;
```

### 3. LowCardinality for String Columns

```sql
-- BAD: each row stores the full string
event_type String

-- GOOD: dictionary encoding, much smaller
event_type LowCardinality(String)
```

Use `LowCardinality` when a column has <10,000 unique values. It dictionary-encodes the values, dramatically reducing storage and improving filter performance.

### 4. Partition Pruning

```sql
-- If table is PARTITION BY toYYYYMM(timestamp):
-- GOOD: only reads January 2024 partition
WHERE timestamp >= '2024-01-01' AND timestamp < '2024-02-01'

-- BAD: function wrapping prevents partition pruning
WHERE toYYYYMM(timestamp) = 202401
-- (ClickHouse may optimize this, but explicit ranges are safer)
```

### 5. Avoid Large JOINs — Use Dictionaries

```sql
-- BAD: JOIN with a large table
SELECT e.*, u.name
FROM events e
JOIN users u ON e.user_id = u.id;

-- GOOD: Use a dictionary for lookups
CREATE DICTIONARY user_dict (id UInt32, name String)
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'users' DB 'demo'))
LAYOUT(FLAT())
LIFETIME(300);

SELECT *, dictGet('user_dict', 'name', user_id) AS user_name
FROM events;
```

Dictionaries are loaded into memory and provide O(1) lookups.

### 6. Approximate Functions for Speed

```sql
-- Exact count distinct (slow on billions of rows)
SELECT count(DISTINCT user_id) FROM events;

-- Approximate (HyperLogLog, ~2% error, 10-100× faster)
SELECT uniq(user_id) FROM events;

-- Exact median (requires sorting ALL values)
SELECT median(amount) FROM events;

-- Approximate quantile (t-digest, much faster)
SELECT quantile(0.5)(amount) FROM events;
```

### 7. FINAL Keyword Caution

```sql
-- ReplacingMergeTree deduplication happens at merge time
-- FINAL forces deduplication at query time (SLOW for large tables)
SELECT * FROM events FINAL;

-- Better: design queries to handle duplicates
SELECT argMax(amount, timestamp) FROM events GROUP BY event_id;
```
