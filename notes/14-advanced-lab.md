# Advanced Topics Lab Reference Notes

Lab script: `cluster/scripts/lab-advanced.sh` | Run: `make lab-advanced`

---

## Exercise 1: Projections Deep Dive

**What we did:**
- Created a table with ORDER BY (event_type, ts) and 200K rows
- Added 2 reorder projections (by user_id, by region) and 1 aggregation projection
- Measured storage at each step — each reorder projection roughly doubled size
- Showed the optimizer picks the best projection per query via EXPLAIN

**Key takeaways:**
- Each reorder projection stores a full data copy (~2x storage each)
- Aggregation projections are cheap (pre-aggregated, much fewer rows)
- The optimizer transparently picks the best projection per query
- Sweet spot: 1 reorder + 1-2 aggregation projections
- Beyond that, use Materialized Views (separate table, more flexibility)

**Commands:**
```sql
ALTER TABLE t ADD PROJECTION proj_name (SELECT * ORDER BY col1, col2);
ALTER TABLE t MATERIALIZE PROJECTION proj_name;
EXPLAIN SELECT ... -- shows which projection is used
SELECT sum(bytes_on_disk) FROM system.parts WHERE table = 't' AND active
```

---

## Exercise 2: Lightweight Deletes vs Mutations

**What we did:**
- ALTER TABLE DELETE: rewrote entire parts, measured time
- DELETE FROM: row masking only, measured time
- Compared timing and part state before/after

**Key takeaways:**
- ALTER DELETE rewrites the entire part even if only 1 row matches
- DELETE FROM sets `_row_exists = 0` (lightweight bitmap mask)
- Masked rows are filtered at query time, physically removed at next merge
- DELETE FROM is significantly faster for targeted removals
- ALTER DELETE blocks other mutations; DELETE FROM does not
- Prefer append-only patterns in OLAP whenever possible

**Commands:**
```sql
ALTER TABLE t DELETE WHERE condition   -- mutation (heavy, rewrites parts)
DELETE FROM t WHERE condition          -- lightweight (fast, row mask)
SELECT * FROM system.mutations WHERE NOT is_done
```

---

## Exercise 3: Window Functions

**What we did:**
- Running totals: `sum(revenue) OVER (PARTITION BY region ORDER BY day ROWS UNBOUNDED PRECEDING)`
- Day-over-day change: `revenue - lagInFrame(revenue, 1) OVER (...)`
- Rankings: `rank() OVER (ORDER BY total DESC)` and `dense_rank()`
- Moving average: `avg() OVER (... ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)`
- Session detection: `lagInFrame(ts)` to find gaps > 1 hour

**Key takeaways:**
- Window functions compute across related rows WITHOUT collapsing them (unlike GROUP BY)
- `PARTITION BY` = groups within the window
- `ORDER BY` = row ordering within partition
- Frame spec controls which rows to include: `ROWS UNBOUNDED PRECEDING`, `ROWS BETWEEN N PRECEDING AND M FOLLOWING`
- lagInFrame()/leadInFrame() enable row-to-row comparisons (change detection, session boundaries)
- ClickHouse uses `lagInFrame`/`leadInFrame` (not `lag`/`lead`) — requires explicit frame spec
- rank() vs dense_rank(): rank has gaps for ties, dense_rank doesn't

**Common patterns:**
```sql
sum(x) OVER (ORDER BY ts ROWS UNBOUNDED PRECEDING)     -- running total
lagInFrame(x, 1) OVER (ORDER BY ts ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)  -- previous value
rank() OVER (PARTITION BY group ORDER BY val DESC)      -- ranking
avg(x) OVER (ORDER BY ts ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)  -- moving avg
```

---

## Exercise 4: Dictionaries

**What we did:**
- Created a lookup table and COMPLEX_KEY_HASHED dictionary
- Enriched orders with `dictGet()` instead of JOIN
- Used `dictGetOrDefault()` for safe fallback on missing keys
- Created a RANGE_HASHED dictionary for time-versioned prices
- Looked up prices valid on different dates

**Key takeaways:**
- Dictionaries are in-memory, O(1) lookups — much faster than JOINs
- FLAT: small tables, UInt64 keys only
- HASHED: medium tables, single key of any type
- COMPLEX_KEY_HASHED: composite (multi-column) keys
- RANGE_HASHED: time-versioned data (prices, exchange rates, configs)
- LIFETIME(MIN, MAX): randomized refresh interval to avoid thundering herd
- DIRECT: no caching, always queries source (for always-fresh needs)

**Commands:**
```sql
CREATE DICTIONARY dict_name (...) PRIMARY KEY key SOURCE(...) LAYOUT(...) LIFETIME(...)
SELECT dictGet('dict_name', 'attribute', key_value)
SELECT dictGetOrDefault('dict_name', 'attr', key, default_value)
SELECT * FROM system.dictionaries
SYSTEM RELOAD DICTIONARY dict_name
```

---

## Exercise 5: Parameterized Views

**What we did:**
- Created a view with `{target_region:String}`, `{start_date:Date}`, `{end_date:Date}` parameters
- Called it with different parameter values
- Created a second view with `{since:Date}` and `{top_n:UInt32}` parameters

**Key takeaways:**
- Syntax: `{name:Type}` in the view definition
- Call syntax: `SELECT * FROM view_name(param1 = value1, param2 = value2)`
- Parameters are typed — SQL injection safe (not string interpolation)
- No performance overhead vs regular queries
- Great for reusable dashboard queries, report templates, API backends

**Commands:**
```sql
CREATE VIEW v AS SELECT ... WHERE col = {param:String} AND ts >= {since:Date}
SELECT * FROM v(param = 'value', since = today() - 7)
```

---

## Exercise 6: Buffer Tables + Async Inserts

**What we did:**
- Created a Buffer table that batches writes to a MergeTree destination
- 50 single-row INSERTs into buffer → flushed as ~1 part (not 50)
- 50 async INSERTs with `async_insert=1` → server batched into fewer parts
- Compared direct INSERT (many parts) vs buffer vs async (few parts)

**Key takeaways:**
- **Buffer tables**: in-memory batching with configurable flush thresholds
  - Data in buffer is lost on crash
  - Reads transparently merge buffer + destination data
  - Flush when: time > max OR rows > max OR bytes > max
- **Async inserts**: server-side batching, WAL-backed (crash-safe)
  - Just a setting: `SET async_insert = 1`
  - Server collects small INSERTs and flushes together
  - Simpler than buffer tables, safer (durable)
- Both solve too-many-parts from high-frequency small INSERTs
- Async inserts are generally preferred (simpler, safer)

**Buffer table syntax:**
```sql
CREATE TABLE buf AS dest_table
ENGINE = Buffer(db, dest_table, num_layers,
                min_time, max_time,
                min_rows, max_rows,
                min_bytes, max_bytes)
```

**Async insert settings:**
```sql
SET async_insert = 1;
SET wait_for_async_insert = 1;
SET async_insert_max_data_size = 10485760;   -- 10MB
SET async_insert_busy_timeout_ms = 200;      -- 200ms max wait
```
