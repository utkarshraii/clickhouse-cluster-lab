# ClickHouse Architecture: How Data Lives on Disk

## The Write Path

```
INSERT → In-Memory Buffer → Part (on disk) → Background Merges → Larger Parts
```

### Step by Step

1. **INSERT arrives** — ClickHouse receives a batch of rows
2. **Sort** — Rows are sorted by the `ORDER BY` key (this is NOT optional — it's structural)
3. **Write a Part** — The sorted data is written as a new **part** (a directory on disk)
4. **Background Merge** — Parts are asynchronously merged into larger parts

**Key insight**: Every INSERT creates a new part. If you insert 1 row at a time, you create 1 part per row. This is why batching matters — 10,000 small parts = disaster.

---

## What is a Part?

A part is a directory on disk containing one chunk of a table's data. It's the fundamental unit of storage.

```
/var/lib/clickhouse/data/demo/events/
├── 202401_1_1_0/           ← Part: partition 202401, block range 1-1, merge level 0
│   ├── primary.idx         ← Sparse index (one entry per granule)
│   ├── event_type.bin      ← Column data (compressed)
│   ├── event_type.mrk2     ← Marks: granule → byte offset mapping
│   ├── user_id.bin
│   ├── user_id.mrk2
│   ├── timestamp.bin
│   ├── timestamp.mrk2
│   ├── count.txt           ← Row count in this part
│   ├── columns.txt         ← Column list
│   ├── checksums.txt       ← Data integrity checksums
│   └── minmax_timestamp.idx ← Min/max for partition key column
└── 202401_2_5_1/           ← Merged part: blocks 2-5, merge level 1
    └── ...
```

### Part Naming Convention
```
{partition}_{min_block}_{max_block}_{merge_level}
```
- **partition**: Derived from `PARTITION BY` expression
- **min_block / max_block**: Range of block numbers included
- **merge_level**: How many times this part has been through a merge (0 = fresh insert)

---

## Columnar Storage

Each column is stored in its own file (`.bin`). This is why ClickHouse is fast for analytics:

```sql
-- This query only reads event_type.bin and user_id.bin
-- It NEVER touches timestamp.bin, properties.bin, amount.bin
SELECT event_type, count(DISTINCT user_id)
FROM events
GROUP BY event_type
```

**Implication**: Wide tables (100+ columns) are fine if queries only touch a few columns. The untouched columns have zero I/O cost.

### Compression

Each `.bin` file is compressed in blocks (default 64KB–1MB compressed).

| Codec | Ratio | Speed | Best For |
|-------|-------|-------|----------|
| LZ4 (default) | ~2-4x | Very fast | General purpose, hot data |
| ZSTD | ~3-6x | Slower | Cold data, archival, text-heavy columns |
| Delta + LZ4 | ~5-10x | Fast | Timestamps, monotonic IDs |
| DoubleDelta + LZ4 | ~10-50x | Fast | Counters with near-constant deltas |
| T64 | ~2-5x | Very fast | Small integers (fits in fewer bits) |

You can set compression per-column:
```sql
CREATE TABLE t (
    id UInt64 CODEC(Delta, ZSTD),
    timestamp DateTime CODEC(DoubleDelta, LZ4),
    body String CODEC(ZSTD(3))  -- ZSTD level 3
) ENGINE = MergeTree() ORDER BY id;
```

---

## Granules: The Unit of Reading

A **granule** is a logical group of rows (default: 8192 rows). It's the smallest unit ClickHouse reads from disk.

```
Part with 81,920 rows → 10 granules

Granule 0: rows     0 –  8,191
Granule 1: rows  8,192 – 16,383
Granule 2: rows 16,384 – 24,575
...
Granule 9: rows 73,728 – 81,919
```

**Why 8192?** Balance between:
- Too small (e.g., 100) → Index gets huge, too many mark entries
- Too large (e.g., 1M) → Poor selectivity, reads too much data per seek

---

## The Sparse (Primary) Index

The `primary.idx` file stores one entry per granule — the value of the `ORDER BY` columns for the **first row** of each granule.

```
ORDER BY (event_type, user_id, timestamp)

primary.idx:
Granule 0: ('click', 1, '2024-01-01 00:00:00')
Granule 1: ('click', 500, '2024-01-15 12:00:00')
Granule 2: ('purchase', 10, '2024-01-02 00:00:00')
Granule 3: ('view', 1, '2024-01-01 00:00:00')
...
```

### How a Query Uses It

```sql
WHERE event_type = 'purchase'
```

1. Binary search in `primary.idx` → finds granule 2 is the first with 'purchase'
2. Scan forward until first granule with 'view' → reads granules 2-2
3. Load ONLY those granules from the `.bin` files

**This is why ORDER BY selection is the single most important performance decision.**

### What the Sparse Index Cannot Do

- **Point lookups by non-prefix columns**: `WHERE user_id = 42` must scan all granules because `user_id` is not the first key column
- **Range scans on non-first columns**: `WHERE timestamp > X` without filtering by `event_type` first

---

## Mark Files (.mrk2)

Marks connect the sparse index to the physical data. Each mark says:

> "Granule N starts at byte offset X in the compressed file, and at byte offset Y within the decompressed block"

```
Granule 0 → compressed offset: 0,       decompressed offset: 0
Granule 1 → compressed offset: 65,412,  decompressed offset: 0
Granule 2 → compressed offset: 65,412,  decompressed offset: 32,768
Granule 3 → compressed offset: 131,000, decompressed offset: 0
```

**mark_cache_size** in config.xml caches these marks in RAM. A cache miss means a disk seek just to find WHERE to read, before reading the actual data.

---

## Merges

Background threads continuously merge smaller parts into larger ones:

```
Before:  part_1 (1K rows) + part_2 (1K rows) + part_3 (1K rows)
After:   part_1_3 (3K rows, re-sorted, re-compressed)
```

### Why Merges Matter

1. **Query performance**: Fewer parts → fewer files to open, less merge overhead during reads
2. **Deduplication**: `ReplacingMergeTree` removes duplicates during merges
3. **Aggregation**: `AggregatingMergeTree` merges aggregate states during merges
4. **TTL**: Expired rows are removed during merges

### When Merges Go Wrong

| Symptom | Cause | Fix |
|---------|-------|-----|
| `parts_to_delay_insert` hit | Too many small inserts | Batch inserts (≥10K rows) |
| High CPU from merges | `background_pool_size` too high | Reduce pool size |
| Parts keep growing | `background_pool_size` too low | Increase pool size |
| Disk space doubled | Large merge in progress | Wait, or check `system.merges` |

---

## Partitions

Partitions are logical groups defined by `PARTITION BY`. Common choices:

```sql
PARTITION BY toYYYYMM(timestamp)     -- monthly
PARTITION BY toYYYYMMDD(timestamp)   -- daily (careful: too many partitions)
PARTITION BY (region, toYYYYMM(ts))  -- composite
```

### Partition Rules

- **Each partition has its own set of parts** — parts never cross partition boundaries
- **DROP PARTITION is instant** — deletes entire directories
- **Too many partitions = too many parts** — rule of thumb: <1000 active partitions
- **Merges never cross partitions** — a part in January will never merge with a part in February

---

## Summary: Mental Model

```
Table
├── Partition (e.g., 2024-01)
│   ├── Part (sorted, compressed, immutable once written)
│   │   ├── Granule 0  (8192 rows)
│   │   ├── Granule 1  (8192 rows)
│   │   └── ...
│   ├── Part (from another insert)
│   └── Part (from a merge)
├── Partition (e.g., 2024-02)
│   └── ...
└── primary.idx maps: granule number → ORDER BY values
    .mrk2 maps:      granule number → byte offset in .bin
    .bin contains:    actual column data, compressed
```
