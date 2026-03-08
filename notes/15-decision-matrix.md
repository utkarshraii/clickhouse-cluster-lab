# ClickHouse Decision Matrix

A consolidated reference of every "when to use what" decision from Phases 1-8.

---

## 1. Table Engine Selection

The most important structural decision. Choose based on your write/read pattern.

| I need to... | Engine | Consistency pattern |
|---|---|---|
| Store raw events/logs | **MergeTree** | Direct query |
| Keep latest version of a row | **ReplacingMergeTree** | `FINAL` or `argMax(col, version)` |
| Auto-sum counters/metrics | **SummingMergeTree** | `SUM(col) ... GROUP BY keys` |
| Pre-aggregate avg/uniq/quantile | **AggregatingMergeTree** | `-Merge` combinators |
| Update/delete rows (ordered inserts) | **CollapsingMergeTree** | `SUM(col * sign) ... HAVING SUM(sign) > 0` |
| Update/delete rows (any order) | **VersionedCollapsingMergeTree** | Same as Collapsing |

**Decision flow:**

```
Is it append-only data (logs, events)?
  └── YES → MergeTree

Do you need "latest row" dedup?
  └── YES → ReplacingMergeTree

Do you need pre-aggregation?
  ├── Only SUM → SummingMergeTree
  └── avg/uniq/quantile → AggregatingMergeTree (+ MV)

Do you need UPDATE/DELETE semantics?
  ├── Single writer, ordered → CollapsingMergeTree
  └── Multiple writers / async → VersionedCollapsingMergeTree
```

---

## 2. ORDER BY Key Strategy

The ORDER BY key is your most important performance decision — it determines the primary index.

**Rule:** Put your most common WHERE filter columns first, ordered from lowest to highest cardinality.

| Your most common query pattern | Best ORDER BY |
|-------------------------------|---------------|
| `WHERE event_type = X` | `(event_type, ...)` |
| `WHERE event_type = X AND user_id = Y` | `(event_type, user_id, ...)` |
| `WHERE user_id = Y` | `(user_id, ...)` or add a skip index |
| `WHERE timestamp > X` | `(timestamp, ...)` only if time-range dominant |
| `GROUP BY event_type` | `(event_type, ...)` enables streaming aggregation |

**Anti-patterns:**
- High-cardinality column first (timestamp, UUID) — breaks index selectivity
- Too many columns (only first 2-3 are useful, rest increase merge cost)
- ORDER BY matches no common query pattern (e.g., `ORDER BY id` when nobody filters by id)

---

## 3. Partitioning Strategy

Partitions determine how data is physically grouped on disk. ClickHouse prunes entire partitions when the WHERE clause matches.

| Strategy | Use When | Example |
|----------|----------|---------|
| Monthly | Default for time-series | `PARTITION BY toYYYYMM(ts)` |
| Daily | High-volume, short retention | `PARTITION BY toYYYYMMDD(ts)` |
| Composite | Multi-tenant + time | `PARTITION BY (tenant_id, toYYYYMM(ts))` |
| None | Small tables, no time dimension | (omit PARTITION BY) |

**Rules:**
- Keep < 1,000 active partitions — more = too many parts
- Don't partition by high-cardinality columns (user_id, session_id)
- TTL operates per-partition — align TTL granularity with partition key

---

## 4. Skip Index Selection

Skip indexes are secondary — they work AFTER the primary index, skipping granule blocks.

| Index Type | Best For | Example Filter | Notes |
|------------|----------|----------------|-------|
| `bloom_filter(0.01)` | Equality, IN on high-cardinality | `WHERE user_id = 42` | 1% false positive rate |
| `minmax` | Range queries | `WHERE amount > 90` | Stores min/max per block |
| `set(N)` | Equality on low-cardinality | `WHERE region IN (...)` | N must exceed cardinality |
| `tokenbf_v1` | Text search (LIKE, hasToken) | `WHERE msg LIKE '%error%'` | Token-based bloom filter |

**When skip indexes DON'T help:**
- Column is already first in ORDER BY (primary index handles it)
- Values randomly distributed across granules (nothing to skip)
- GRANULARITY too large (blocks too big to skip effectively)

---

## 5. Query Acceleration: Projections vs Skip Indexes vs MVs

| Aspect | Projection | Skip Index | Materialized View |
|--------|-----------|------------|-------------------|
| **Storage cost** | 2x per reorder | Tiny metadata | Varies (separate table) |
| **Accuracy** | Exact | Approximate | Exact |
| **Write cost** | 2x amplification | Minimal | Insert trigger overhead |
| **Transparency** | Automatic (optimizer picks) | Automatic | Must query target table |
| **Flexibility** | ORDER BY / GROUP BY only | Filter acceleration | Any transformation |
| **Best for** | 2nd query pattern | Occasional filters | Dashboard aggregations |

**Decision flow:**

```
Need a second sort order for queries?
  └── Projection (automatic, transparent)

Need to filter a column not in ORDER BY?
  └── Skip index (cheap, approximate)

Need pre-aggregated dashboard data?
  └── Materialized View (most powerful, separate table)

Need transformed schema (fewer columns, different engine)?
  └── Materialized View
```

**Projection sweet spot:** 1 reorder + 1-2 aggregation projections. Beyond that, MVs are better.

---

## 6. Sharding Key Strategy

| Strategy | Pros | Cons | Use When |
|----------|------|------|----------|
| `rand()` | Perfect balance | Can't co-locate related data | Global aggregations, no entity-level queries |
| `cityHash64(user_id)` | Co-locates user data | Hotspots if variance in user activity | User-centric queries |
| `cityHash64(tenant_id)` | Tenant isolation | Same hotspot risk | Multi-tenant systems |
| No sharding (1 shard) | Simple, no cross-shard issues | Limited by single node | Small datasets (< 1 TB) |

**Decision rule:** "What's my most common WHERE clause?" Shard by that column.

---

## 7. Compression Codec Selection

| Codec | Compression Ratio | Speed | Best For |
|-------|-------------------|-------|----------|
| LZ4 (default) | 2-4x | Very fast | General purpose, hot data |
| ZSTD | 3-6x | Slower | Cold data, archival, text-heavy columns |
| Delta + LZ4 | 5-10x | Fast | Timestamps, monotonic IDs |
| DoubleDelta + LZ4 | 10-50x | Fast | Counters, near-constant deltas |
| T64 | 2-5x | Very fast | Small integers |

**Rule:** Start with defaults (LZ4). Only change per-column if you need to optimize storage for specific columns.

---

## 8. Dictionary Layout Selection

| Layout | Best For | Memory Model | Key Type |
|--------|----------|-------------|----------|
| `FLAT()` | Small tables (< 500K rows) | Pre-allocated array | UInt64 only |
| `HASHED()` | Medium tables, any key | Hash table | Any single key |
| `COMPLEX_KEY_HASHED()` | Composite keys | Hash table | Multiple columns |
| `RANGE_HASHED()` | Time-versioned lookups | Hash + date ranges | Key + date range |
| `DIRECT()` | Always-fresh, no caching | None (queries source) | Any |
| `CACHE(SIZE)` | Huge source, sparse access | LRU cache | Any |

**Dictionary vs JOIN:**

| Scenario | Use |
|----------|-----|
| Lookup table < 1M rows | Dictionary (FLAT or HASHED) |
| Lookup table > 10M rows | JOIN or DIRECT dictionary |
| Need real-time freshness | DIRECT layout or low LIFETIME |
| Time-versioned prices/rates | RANGE_HASHED |

---

## 9. Delete/Update Strategy

| Approach | Mechanism | Speed | Best For |
|----------|-----------|-------|----------|
| Append-only (insert corrections) | No mutation | Fastest | OLAP default — preferred |
| ReplacingMergeTree | Merge-time dedup | Fast writes | "Last version wins" |
| `DELETE FROM` (lightweight) | Row mask bitmap | Fast | Targeted single-row deletes |
| `ALTER TABLE DELETE` | Rewrite entire parts | Slow | Bulk cleanup |
| `ALTER TABLE UPDATE` | Rewrite entire parts | Slow | Bulk field changes |

**Decision rule:** Prefer append-only patterns. If you must delete, use `DELETE FROM`. Avoid ALTER mutations unless doing bulk cleanup.

---

## 10. High-Frequency Ingestion Strategy

| Scenario | Solution | Crash Safe? | Complexity |
|----------|----------|-------------|------------|
| Can batch in client code | Batch INSERT (10K+ rows) | Yes | None |
| Many small clients, can't change code | `async_insert = 1` | Yes (WAL) | Setting only |
| Single high-frequency producer | Buffer table | No (in-memory) | Extra table |
| Emergency part cleanup | `OPTIMIZE TABLE` | N/A | Manual |

**Rule:** Always try batching first. If impossible, async inserts are the simplest safe option.

---

## 11. Monitoring & Alerting

| Metric | Source | Warning | Critical |
|--------|--------|---------|----------|
| MaxPartCountForPartition | `system.asynchronous_metrics` | > 200 | > 300 |
| FailedQuery rate | `system.events` | > 1/min | > 10/min |
| MemoryTracking | `system.metrics` | > 80% of max | > 90% |
| ReplicasMaxAbsoluteDelay | `system.replicas` | > 60s | > 300s |
| Disk free space | `system.disks` | < 20% | < 10% |

**Three metric types:**
- `system.metrics` = speedometer (current state)
- `system.events` = odometer (cumulative since boot)
- `system.asynchronous_metrics` = dashboard gauges (periodically updated)

**#1 operational metric:** `MaxPartCountForPartition` — if it approaches 300, you have a too-many-parts problem.

---

## 12. Backup Strategy

| Approach | Use Case | Incremental? | Scheduling? |
|----------|----------|-------------|-------------|
| `BACKUP TABLE ... TO File(...)` | Single table, local | Yes (base_backup) | Manual |
| `BACKUP TABLE ... TO S3(...)` | Single table, cloud | Yes | Manual |
| clickhouse-backup (Altinity) | Production clusters | Yes | Built-in cron |

**Rule:** Built-in BACKUP is good for dev/test. Use clickhouse-backup for production with scheduled S3 backups and retention policies.

---

## Quick Reference: The 5 Most Common Mistakes

1. **1 row per INSERT** → Too many parts → Use batch inserts (10K+ rows)
2. **High-cardinality first in ORDER BY** → Full scans → Low cardinality first
3. **Using ALTER DELETE for targeted removals** → Expensive → Use `DELETE FROM`
4. **JOINing large lookup tables** → Slow → Use dictionaries
5. **SELECT * on wide tables** → Excessive I/O → Select only needed columns
