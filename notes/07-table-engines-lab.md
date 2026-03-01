# Table Engines Lab — Reference Notes

Lab script: `cluster/scripts/lab-table-engines.sh` (`make lab-engines`)

All MergeTree variants are append-only. Each INSERT creates a new **part** (directory on disk). Background merges combine parts, and each engine applies its special logic during those merges. Until merge happens, queries may see "stale" data (duplicates, unsummed rows, uncollapsed pairs).

---

## Exercise 1: MergeTree — The Baseline

The foundation. All other `*MergeTree` engines inherit from it.

**Key columns in the DDL:**

| Clause | What it controls |
|--------|-----------------|
| `ORDER BY (a, b, c)` | Physical sort order + sparse primary index. Most important decision. |
| `PARTITION BY expr` | Physical separation into directories. Enables fast `DROP PARTITION`. |
| `TTL expr + INTERVAL` | Auto-delete expired rows during merge. |
| `index_granularity` | Rows per granule (default 8192). Tradeoff: precision vs. memory for marks. |

**What to notice:**
- Two INSERTs → two parts (visible in `system.parts`)
- Parts are within the same or different partition depending on data
- Queries filtering on the first ORDER BY column skip the most granules

---

## Exercise 2: ReplacingMergeTree — Deduplication

Keeps only the **latest version** of each row (by ORDER BY key) during merge.

```sql
ENGINE = ReplacingMergeTree(version_column)
ORDER BY (dedup_key)
```

**Behavior:**
- Rows with the same ORDER BY key are considered duplicates
- On merge, keeps only the row with the highest `version_column` value
- Without a version column, keeps the last inserted row

**Before merge (or across parts):** duplicates exist — you see all inserted rows.

**Consistent reads before merge:**
```sql
-- Option 1: FINAL keyword (correct but slower — merges on the fly)
SELECT * FROM table FINAL

-- Option 2: argMax (more flexible, often faster)
SELECT order_id, argMax(status, updated_at) AS status
FROM table GROUP BY order_id
```

**Gotchas:**
- `FINAL` has performance cost — applies merge logic at query time
- Dedup only works within the same partition
- `OPTIMIZE TABLE FINAL` forces merge but is heavy — don't use in production loops

---

## Exercise 3: SummingMergeTree — Auto-Aggregation

Automatically **sums numeric columns** for rows with the same ORDER BY key during merge.

```sql
ENGINE = SummingMergeTree()         -- sums ALL numeric columns not in ORDER BY
ENGINE = SummingMergeTree((col1))   -- sums only specified columns
ORDER BY (group_key_columns)
```

**Behavior:**
- Rows with the same ORDER BY key are collapsed into one
- Numeric columns not in ORDER BY are summed
- Non-numeric, non-key columns: **arbitrary value** is kept (no guarantee which)

**Consistent reads before merge:**
```sql
-- Always wrap with SUM + GROUP BY in queries
SELECT date, user_id, SUM(page_views), SUM(clicks)
FROM table
GROUP BY date, user_id
```

**When to use:** counters, daily metrics, rollup tables. Simple and fast.

**When NOT to use:** when you need avg(), uniq(), quantile() — use AggregatingMergeTree.

---

## Exercise 4: AggregatingMergeTree — Complex Pre-Aggregation

Stores **intermediate aggregate states** (not final values). Can handle any aggregate function.

```sql
CREATE TABLE t (
    key        String,
    avg_val    AggregateFunction(avg, Float64),      -- stores (sum, count) internally
    uniq_users AggregateFunction(uniq, UInt32),       -- stores HyperLogLog sketch
    total      SimpleAggregateFunction(sum, UInt64)   -- stores a plain number (simpler)
) ENGINE = AggregatingMergeTree()
ORDER BY key;
```

**Insert with `-State` combinators:**
```sql
INSERT INTO t SELECT
    key,
    avgState(value)    AS avg_val,
    uniqState(user_id) AS uniq_users,
    count()            AS total
FROM source GROUP BY key;
```

**Query with `-Merge` combinators:**
```sql
SELECT key, avgMerge(avg_val), uniqMerge(uniq_users), sum(total)
FROM t GROUP BY key;
```

**Why not just use SummingMergeTree?**
- SummingMergeTree can only sum. It can't compute averages (you'd lose the count), uniq counts (HyperLogLog states aren't summable as integers), or quantiles.
- AggregatingMergeTree stores the full intermediate state so merges are mathematically correct.

**Typical pattern:** used as the target table for a Materialized View.

---

## Exercise 5: CollapsingMergeTree — Mutable Data via Sign

Enables "updates" and "deletes" using a sign column: `+1` = insert, `-1` = cancel.

```sql
ENGINE = CollapsingMergeTree(sign)
ORDER BY (key)
```

**To update a row:** insert a cancellation (-1) that matches the old row exactly, then insert the new version (+1).

**To delete a row:** insert just the cancellation (-1).

**Consistent reads before merge:**
```sql
SELECT
    session_id,
    SUM(duration * sign) AS duration,
    SUM(page_count * sign) AS page_count
FROM table
GROUP BY session_id
HAVING SUM(sign) > 0   -- filter out deleted sessions
```

**Gotchas:**
- The cancellation row must match the original row **exactly** (all non-sign columns)
- Within a single INSERT, the +1 row must come before the -1 row (insert order matters)
- If the original and cancellation end up in different parts and aren't merged, both remain

---

## Exercise 6: VersionedCollapsingMergeTree — Order-Independent

Same concept as CollapsingMergeTree, but adds a **version column** so insert order doesn't matter.

```sql
ENGINE = VersionedCollapsingMergeTree(sign, version)
ORDER BY (key)
```

**How it differs from CollapsingMergeTree:**
- Pairs rows by `(ORDER BY key, version)` — a +1 and -1 with the same key and version cancel each other
- Insert order is irrelevant — the version column resolves which rows to collapse
- Safer for distributed systems, async pipelines, and multiple writers

**When to use CollapsingMergeTree vs. Versioned:**
- Collapsing: single writer, strict insert ordering, slightly less overhead
- VersionedCollapsing: multiple writers, async inserts, out-of-order data

---

## Engine Decision Matrix

| I need to... | Engine | Query pattern for consistency |
|---|---|---|
| Store raw event data | MergeTree | Direct query |
| Keep latest version of a row | ReplacingMergeTree | `FINAL` or `argMax()` |
| Auto-sum counters/metrics | SummingMergeTree | `SUM() ... GROUP BY` |
| Pre-aggregate avg/uniq/quantile | AggregatingMergeTree | `-Merge` combinators |
| Update/delete rows (ordered inserts) | CollapsingMergeTree | `SUM(col * sign) ... HAVING SUM(sign) > 0` |
| Update/delete rows (any insert order) | VersionedCollapsingMergeTree | Same as Collapsing |

## Common Principle

All `*MergeTree` engines are append-only. The "special" behavior (dedup, sum, collapse) **only runs during background merges**. Your queries must account for unmerged state unless you're OK with eventual consistency.
