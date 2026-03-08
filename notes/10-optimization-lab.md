# Data Modeling & Query Optimization Lab — Reference Notes

Lab script: `cluster/scripts/lab-optimization.sh` (`make lab-optimization`)

This lab demonstrates how ORDER BY keys, skip indexes, projections, and materialized views affect query performance. All exercises run on a single node (ch-s1r1) with 500K rows.

---

## Exercise 1: ORDER BY Key — Good vs Bad

The ORDER BY key is the most important performance decision in ClickHouse.

**What we do:**
- Create two tables with identical data, different ORDER BY keys
- `lab_opt_good`: ORDER BY (event_type, user_id, ts) — low cardinality first
- `lab_opt_bad`: ORDER BY (ts, event_type) — high cardinality first
- Run the same filter query on both, compare `read_rows` from query_log
- EXPLAIN indexes=1 shows granule skip ratios

**Key rules:**
1. **Low cardinality first** — columns with few distinct values (event_type: 5 values) should come before high-cardinality columns (user_id: 10K values)
2. **Match your most common WHERE clause** — the ORDER BY prefix should match your most frequent filter pattern
3. **ts alone as first key is almost always wrong** — timestamps are unique, so the primary index can't skip anything

**Expected result:** The good table reads 10-100x fewer rows for the same query.

---

## Exercise 2: PREWHERE — Automatic Early Filtering

ClickHouse automatically converts WHERE to PREWHERE on MergeTree tables.

**What we do:**
- Show EXPLAIN output with automatic PREWHERE conversion
- Compare `read_bytes` for SELECT * vs SELECT event_type, count()
- Demonstrate manual PREWHERE syntax

**How PREWHERE works:**
1. Read only the filter column(s) from disk
2. Evaluate the filter condition
3. For matching rows only, read the remaining columns

**Key takeaway:** Columnar storage means fewer columns in SELECT = less I/O. PREWHERE makes this automatic for filter columns.

---

## Exercise 3: Skip Indexes — bloom_filter, minmax, set

Skip indexes work after the primary index to eliminate granule blocks for non-ORDER BY columns.

**What we do:**
- Show a full scan on `region` (not in ORDER BY)
- Add `bloom_filter(0.01)` on region → granules skipped for equality
- Add `minmax` on amount → granules skipped for range queries
- Add `set(10)` on event_type → granules skipped for IN queries

**Index type selection:**
| Index Type | Best For | Example |
|-----------|---------|---------|
| `bloom_filter(fpr)` | Equality, IN | `WHERE region = 'us-east'` |
| `minmax` | Range comparisons | `WHERE amount > 90` |
| `set(N)` | Low-cardinality IN/= | `WHERE type IN ('a', 'b')` |

**Important details:**
- `GRANULARITY 4` means the index covers 4 granules (4 x 8192 = 32768 rows) per block
- Lower granularity = more precise skipping but more index data
- After `ADD INDEX`, run `MATERIALIZE INDEX` for existing data
- New inserts auto-populate skip indexes

**Key takeaway:** Skip indexes are secondary — add them only for columns you actually filter on frequently.

---

## Exercise 4: Projections — Alternative Sort Orders

Projections store a second copy of data with a different ORDER BY or pre-aggregation.

**What we do:**
- Add a `(user_id, ts)` projection for user-centric queries
- Show EXPLAIN proving the optimizer selects the projection
- Add a pre-aggregation projection for hourly stats
- Compare read_rows with and without projections

**Two types of projections:**
1. **Reorder projection** — `SELECT * ORDER BY (user_id, ts)` — alternative primary index
2. **Aggregation projection** — `SELECT event_type, toStartOfHour(ts), count(), sum(amount) GROUP BY ...` — pre-computed aggregates

**Trade-offs:**
- Storage: ~2x the table size (full data copy)
- Query: transparent — optimizer picks the best projection automatically
- INSERT: slightly slower (writes to all projections)

**Projection vs MV:**
| Aspect | Projection | Materialized View |
|--------|-----------|-------------------|
| Storage location | Inside the same table | Separate table |
| Query transparency | Automatic optimizer selection | Must query target table |
| Schema | Same columns or aggregates | Any schema |
| Engine | Inherits parent engine | Any engine |

---

## Exercise 5: Materialized Views — Write-Time Aggregation

MVs are INSERT triggers that transform data and write to a separate target table.

**What we do:**
- Create AggregatingMergeTree target + MV for hourly aggregation
- Insert 100K rows → MV fires automatically
- Query target with `-Merge` combinators
- Compare performance: raw aggregation vs pre-aggregated MV

**MV pattern:**
```
Source table  →  MV (SELECT ... GROUP BY ...)  →  Target table (AggregatingMergeTree)
INSERT here      fires on each INSERT             query here with -Merge combinators
```

**Key details:**
- MVs only process NEW inserts — they don't backfill existing data
- Use `-State` combinators in the MV SELECT, `-Merge` combinators when querying
- AggregatingMergeTree merges partial aggregate states correctly
- `SimpleAggregateFunction` works for sum/min/max/any (simpler syntax)
- `AggregateFunction` needed for avg/uniq/quantile (stores intermediate state)

**Key takeaway:** MVs are the most powerful optimization tool — massive row reduction for dashboard queries.

---

## Exercise 6: Putting It All Together — Optimization Workflow

**Step-by-step optimization:**
1. Start with a bad table (ORDER BY event_id)
2. Measure baseline: 4 queries capture read_rows from query_log
3. Fix ORDER BY → biggest impact, zero storage cost
4. Add skip index on secondary filter column → small storage cost
5. Add projection for second query pattern → ~2x storage
6. Create MV for aggregation query → pre-computed results
7. Re-measure: before/after comparison

**Priority order:**
| Priority | Technique | Impact | Cost |
|----------|-----------|--------|------|
| 1 | Fix ORDER BY key | 10-1000x | None |
| 2 | PREWHERE (automatic) | 2-10x I/O reduction | None |
| 3 | Skip indexes | 2-10x for secondary columns | Small |
| 4 | Projections | 10-100x for alt query patterns | ~2x storage |
| 5 | Materialized Views | 100-10000x for aggregations | Varies |

---

## Optimization Decision Tree

```
Is the query slow?
├── Check ORDER BY matches your WHERE clause → Fix ORDER BY key
├── Filtering on non-ORDER BY column?
│   ├── Low cardinality → set(N) skip index
│   ├── Equality/IN → bloom_filter skip index
│   └── Range → minmax skip index
├── Second common query pattern with different filter?
│   └── Add a projection with matching ORDER BY
└── Dashboard/aggregation query scanning millions of rows?
    └── Create a Materialized View with AggregatingMergeTree
```
