# ClickHouse Mastery Roadmap
### From Foundations → Production Expertise (Infra + Dev)

---

## Phase 1: Foundations — What is ClickHouse & Why It Exists

### Core Concept
ClickHouse is a **column-oriented OLAP database** built for real-time analytical queries on massive datasets. Unlike row-oriented databases (PostgreSQL, MySQL), it stores data column-by-column, which means:

- Queries that touch only a few columns out of hundreds read far less data from disk
- Compression is dramatically better (similar values stored together)
- Vectorized query execution processes data in batches, leveraging CPU caches and SIMD

### When to Use ClickHouse (vs What You Already Know)

| Scenario | Best Fit | Why |
|----------|----------|-----|
| KYC journey analytics, funnel metrics | **ClickHouse** | Aggregations over millions of journeys in ms |
| Real-time face match vendor performance dashboards | **ClickHouse** | Fast GROUP BY over time-series vendor data |
| Transactional KYC record CRUD | **PostgreSQL/MongoDB** | Row-level reads/writes, ACID transactions |
| Session/cache store | **Redis** | Sub-ms key-value lookups |
| Event streaming buffer | **Kafka → ClickHouse** | Kafka as ingestion pipe, CH as analytical sink |

### Key Mental Model Shift
- **PostgreSQL**: optimized for "give me row #12345 with all its columns"
- **ClickHouse**: optimized for "give me the average of column X across 100M rows where date > Y"

### Where to Start
1. Install ClickHouse locally: `curl https://clickhouse.com/ | sh` then `./clickhouse server`
2. Open `clickhouse-client` and run: `SELECT 1`, `SELECT version()`
3. Read: [ClickHouse official docs — Overview](https://clickhouse.com/docs/en/intro)
4. Play with the built-in datasets: `system.numbers`, `system.one`

---

## Phase 2: Architecture Deep Dive

### 2.1 Storage Architecture

```
Write Path:
  INSERT → In-Memory Buffer → Write to new "Part" on disk → Background Merges

Storage Layout:
  /var/lib/clickhouse/
  ├── data/
  │   └── <database>/
  │       └── <table>/
  │           ├── <part_name>/          ← Each part is a directory
  │           │   ├── primary.idx       ← Sparse primary index
  │           │   ├── <column>.bin      ← Compressed column data
  │           │   ├── <column>.mrk2     ← Mark files (index into .bin)
  │           │   ├── count.txt         ← Row count
  │           │   ├── checksums.txt     ← Data integrity
  │           │   └── columns.txt       ← Column list
  │           └── <part_name>/
  ├── metadata/                         ← DDL .sql files
  └── store/                            ← Symlink targets (newer versions)
```

**Key concepts:**
- **Parts**: Immutable chunks of data. Each INSERT creates a new part. Background merges combine small parts into larger ones.
- **Granules**: Within a part, data is divided into granules (default 8192 rows). The sparse index stores one entry per granule, not per row.
- **Sparse Primary Index**: Unlike B-tree indexes, ClickHouse stores only one index entry per granule. This means the index fits in memory even for billions of rows.
- **Mark Files (.mrk2)**: Map from granule number → byte offset in the compressed .bin file. This is how ClickHouse knows where to seek.

### 2.2 Query Execution Pipeline

```
SQL Query
  → Parser (AST)
  → Analyzer (resolve names, types)
  → Query Planner
  → Pipeline of Processors (DAG)
      ├── ReadFromMergeTree (parallel, by part + granule range)
      ├── FilterTransform (WHERE pushdown)
      ├── AggregatingTransform (partial aggregation per thread)
      ├── MergingAggregatedTransform (combine partials)
      └── OutputFormat (JSON, TSV, Pretty, etc.)
```

**What makes it fast:**
- **Vectorized execution**: Processes columns in batches (blocks of ~65K values), not row-by-row
- **Parallel reads**: Multiple threads read different parts/granule ranges simultaneously
- **Predicate pushdown**: WHERE clause filtering happens at the storage layer, skipping irrelevant granules
- **Compression**: LZ4 by default (fast decompression), ZSTD for better ratios

### 2.3 How Queries Use the Primary Index

```
Table: events (event_date Date, user_id UInt64, event_type String)
ORDER BY (event_date, user_id)

Query: WHERE event_date = '2025-01-15' AND user_id = 12345

Step 1: Binary search primary.idx → find granule range where event_date = '2025-01-15'
Step 2: Within that range, narrow further by user_id
Step 3: Read only those granules from .bin files
Step 4: Decompress and scan (final filtering within granule)
```

**The ORDER BY clause IS the primary index.** Choosing it well is the single most impactful performance decision.

---

## Phase 3: Table Engines — The Heart of ClickHouse

### 3.1 MergeTree Family (Production Workhorses)

| Engine | Use Case | Key Feature |
|--------|----------|-------------|
| **MergeTree** | Base engine, most common | Sorting, partitioning, TTL, sampling |
| **ReplacingMergeTree** | Deduplication by key | Keeps latest version (by version column) on merge |
| **SummingMergeTree** | Pre-aggregated metrics | Auto-sums numeric columns on merge |
| **AggregatingMergeTree** | Complex pre-aggregation | Stores intermediate aggregate states (for materialized views) |
| **CollapsingMergeTree** | Mutable data via collapse/insert pattern | Uses sign column (+1/-1) to "cancel" old rows |
| **VersionedCollapsingMergeTree** | Same as above, order-independent | Adds version column to handle out-of-order inserts |

**MergeTree Example:**
```sql
CREATE TABLE kyc_journeys (
    journey_id UUID,
    tenant_id String,
    journey_date Date,
    status Enum8('initiated'=1, 'in_progress'=2, 'completed'=3, 'failed'=4),
    face_match_score Float32,
    vendor String,
    processing_time_ms UInt32,
    created_at DateTime
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(journey_date)
ORDER BY (tenant_id, journey_date, journey_id)
TTL journey_date + INTERVAL 2 YEAR
SETTINGS index_granularity = 8192;
```

**Critical decisions:**
- `ORDER BY`: Determines data layout AND primary index. Put high-cardinality filtering columns first.
- `PARTITION BY`: Physical data separation. Usually by month/day. Too many partitions = too many parts = bad.
- `TTL`: Automatic data expiry or movement to cold storage.

### 3.2 ReplacingMergeTree (Important for KYC Use Cases)

```sql
-- Journey status updates: keep only the latest status
CREATE TABLE kyc_journey_latest (
    journey_id UUID,
    tenant_id String,
    status String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (tenant_id, journey_id);

-- IMPORTANT: Dedup only happens during background merges, NOT at query time!
-- To get deduplicated results, use FINAL:
SELECT * FROM kyc_journey_latest FINAL WHERE tenant_id = 'xyz';
```

**Gotcha**: `FINAL` can be slow on large tables. Alternatives: use `argMax()` aggregation or design around append-only patterns.

### 3.3 Log Family (Simple, No Merges)

| Engine | Use Case |
|--------|----------|
| **TinyLog** | Small reference tables, testing |
| **StripeLog** | Slightly larger, single file per column |
| **Log** | Append-only logs, no concurrent reads during writes |

### 3.4 Integration Engines

| Engine | Purpose |
|--------|---------|
| **Kafka** | Read directly from Kafka topics |
| **PostgreSQL** | Query PostgreSQL tables from ClickHouse |
| **MongoDB** | Query MongoDB collections |
| **MySQL** | Query MySQL tables |
| **S3** | Query files in S3 (Parquet, CSV, JSON) |
| **URL** | Query remote HTTP endpoints |

**Kafka Engine Example (highly relevant for your stack):**
```sql
-- 1. Kafka consumer table
CREATE TABLE kafka_events (
    event_id String,
    event_type String,
    payload String,
    timestamp DateTime
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'broker1:9092,broker2:9092',
    kafka_topic_list = 'kyc-events',
    kafka_group_name = 'clickhouse-consumer',
    kafka_format = 'JSONEachRow';

-- 2. Target MergeTree table
CREATE TABLE events (
    event_id String,
    event_type String,
    payload String,
    timestamp DateTime
) ENGINE = MergeTree()
ORDER BY (event_type, timestamp);

-- 3. Materialized View bridges them (auto-consumes)
CREATE MATERIALIZED VIEW events_mv TO events AS
SELECT * FROM kafka_events;
```

### 3.5 Special Engines

| Engine | Purpose |
|--------|---------|
| **Distributed** | Query across shards (see Replication section) |
| **MaterializedView** | Auto-transform on INSERT |
| **Dictionary** | Fast key-value lookups from external sources |
| **Buffer** | In-memory buffer that flushes to another table |
| **Null** | Discards data (useful with MVs that write elsewhere) |
| **Memory** | RAM-only, lost on restart |

---

## Phase 4: Replication & Clustering

### 4.1 Architecture Overview

```
ClickHouse Cluster Topology:

Cluster "production"
├── Shard 1 (data subset: e.g., tenant_id hash % 3 == 0)
│   ├── Replica 1A  ←→  ZooKeeper/ClickHouse Keeper
│   └── Replica 1B  ←→  ZooKeeper/ClickHouse Keeper
├── Shard 2 (data subset: e.g., tenant_id hash % 3 == 1)
│   ├── Replica 2A  ←→  ZooKeeper/ClickHouse Keeper
│   └── Replica 2B  ←→  ZooKeeper/ClickHouse Keeper
└── Shard 3 (data subset: e.g., tenant_id hash % 3 == 2)
    ├── Replica 3A  ←→  ZooKeeper/ClickHouse Keeper
    └── Replica 3B  ←→  ZooKeeper/ClickHouse Keeper
```

**Key terms:**
- **Shard**: A horizontal partition of data. Each shard holds a subset.
- **Replica**: A copy of a shard's data for high availability.
- **ZooKeeper/ClickHouse Keeper**: Coordinates replication — stores metadata about which parts exist, replication queue, leader election.

### 4.2 Replication (ReplicatedMergeTree)

```sql
-- On Replica 1A:
CREATE TABLE events ON CLUSTER 'production' (
    ...
) ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/events',   -- ZK path
    '{replica}'                             -- Replica identifier
)
ORDER BY (event_type, timestamp);
```

**How replication works:**
1. Client INSERTs to any replica
2. That replica writes the part locally and logs the action to ZooKeeper
3. Other replicas see the log entry, fetch the part, and apply it locally
4. Merges are coordinated — one replica becomes the merge "leader", others replicate the merged result

**Replication is at the table level, not server level.** Each table has its own ZK path and replication log.

### 4.3 ClickHouse Keeper vs ZooKeeper

| Aspect | ZooKeeper | ClickHouse Keeper |
|--------|-----------|-------------------|
| Language | Java | C++ (part of ClickHouse) |
| Protocol | ZAB | Raft |
| Deployment | Separate cluster | Embedded or standalone |
| Recommendation | Legacy setups | **Preferred for new deployments** |

### 4.4 Distributed Tables

```sql
-- Sits on top of local ReplicatedMergeTree tables
CREATE TABLE events_distributed ON CLUSTER 'production' AS events
ENGINE = Distributed('production', 'default', 'events', rand());
--                    cluster      database   table     sharding_key

-- Queries hit all shards in parallel
SELECT count() FROM events_distributed WHERE event_type = 'face_match';
-- → Coordinator sends sub-queries to each shard → merges results
```

**Sharding key choices:**
- `rand()`: Even distribution, no locality
- `sipHash64(tenant_id)`: Tenant-level locality (all data for a tenant on one shard)
- `intHash64(user_id) % 3`: Explicit modulo sharding

### 4.5 Replication Metadata in ZooKeeper

```
/clickhouse/tables/{shard}/events/
├── metadata          ← Table schema
├── columns           ← Column definitions
├── replicas/
│   ├── replica1/
│   │   ├── queue/    ← Pending replication tasks
│   │   ├── parts/    ← List of parts this replica has
│   │   └── is_active ← Ephemeral node (replica health)
│   └── replica2/
├── log/              ← Shared replication log
├── leader_election   ← Which replica does merges
└── quorum/           ← For quorum inserts
```

---

## Phase 5: ClickHouse Metadata — system.* Tables

This is where operational mastery begins. ClickHouse exposes everything through `system.*` tables.

### 5.1 Essential System Tables

```sql
-- What tables exist and their engines
SELECT database, name, engine, total_rows, total_bytes
FROM system.tables WHERE database = 'default';

-- Part-level details (crucial for understanding storage)
SELECT table, partition, name, rows, bytes_on_disk, 
       modification_time, active
FROM system.parts WHERE database = 'default' AND active;

-- Currently running queries
SELECT query_id, user, query, elapsed, read_rows, memory_usage
FROM system.processes;

-- Query history and performance
SELECT query, type, query_duration_ms, read_rows, read_bytes,
       result_rows, memory_usage
FROM system.query_log 
WHERE type = 'QueryFinish' 
ORDER BY event_time DESC LIMIT 20;

-- Replication status
SELECT database, table, is_leader, total_replicas, active_replicas,
       queue_size, inserts_in_queue, merges_in_queue,
       last_queue_update, log_pointer, absolute_delay
FROM system.replicas;

-- Merge activity
SELECT database, table, elapsed, progress, num_parts, 
       rows_read, bytes_read_uncompressed
FROM system.merges;

-- Disk usage
SELECT name, path, free_space, total_space, keep_free_space
FROM system.disks;

-- Current settings
SELECT name, value, changed, description
FROM system.settings WHERE changed;
```

### 5.2 Key System Tables Reference

| Table | What It Tells You |
|-------|-------------------|
| `system.tables` | All tables, engines, row/byte counts |
| `system.parts` | Individual data parts per table |
| `system.partitions` | Partition-level aggregates |
| `system.columns` | Column metadata, types, compression |
| `system.replicas` | Replication health, lag, queue |
| `system.query_log` | Historical query performance |
| `system.processes` | Currently executing queries |
| `system.merges` | Active background merges |
| `system.mutations` | ALTER TABLE mutation progress |
| `system.disks` | Storage volumes |
| `system.clusters` | Cluster topology |
| `system.zookeeper` | Browse ZK paths from SQL |
| `system.errors` | Error counts by code |
| `system.metrics` | Current server metrics (connections, queries, merges) |
| `system.events` | Cumulative counters (reads, writes, cache hits) |
| `system.asynchronous_metrics` | Background metrics (memory, CPU, uptime) |

### 5.3 Metadata Storage on Disk

```
/var/lib/clickhouse/metadata/
├── default.sql                        ← Database DDL
├── default/
│   ├── events.sql                     ← Table DDL (CREATE TABLE ...)
│   └── events_mv.sql                  ← Materialized View DDL
```

Every DDL statement is persisted as a `.sql` file. On startup, ClickHouse replays these to reconstruct its catalog. In replicated setups, DDL is also stored in ZooKeeper for coordination.

---

## Phase 6: Data Modeling & Query Optimization

### 6.1 Choosing the Right ORDER BY

This is the **#1 performance lever**. Rules of thumb:

1. Put columns that appear in WHERE clauses most often first
2. Go from low cardinality → high cardinality
3. Commonly: `(tenant_id, date, high_cardinality_id)`

```sql
-- BAD: journey_id first (every query scans everything unless filtering by UUID)
ORDER BY (journey_id, tenant_id, journey_date)

-- GOOD: tenant + date first (most queries filter by these)
ORDER BY (tenant_id, journey_date, journey_id)
```

### 6.2 Secondary / Skip Indexes

```sql
-- Bloom filter index for high-cardinality columns not in ORDER BY
ALTER TABLE events ADD INDEX idx_user_id user_id TYPE bloom_filter GRANULARITY 4;

-- Min/Max index for range queries
ALTER TABLE events ADD INDEX idx_score face_match_score TYPE minmax GRANULARITY 4;

-- Set index for low-cardinality columns
ALTER TABLE events ADD INDEX idx_vendor vendor TYPE set(100) GRANULARITY 4;
```

**These are "skip indexes"** — they help skip granules, not locate individual rows.

### 6.3 Materialized Views for Pre-Aggregation

```sql
-- Real-time vendor performance dashboard
CREATE MATERIALIZED VIEW vendor_hourly_stats
ENGINE = SummingMergeTree()
ORDER BY (vendor, hour)
AS SELECT
    vendor,
    toStartOfHour(created_at) AS hour,
    count() AS total_attempts,
    countIf(status = 'completed') AS successful,
    avg(face_match_score) AS avg_score,
    avg(processing_time_ms) AS avg_time_ms
FROM kyc_journeys
GROUP BY vendor, hour;
```

### 6.4 Dictionaries for Enrichment

```sql
CREATE DICTIONARY tenant_info (
    tenant_id String,
    tenant_name String,
    country String,
    tier String
) PRIMARY KEY tenant_id
SOURCE(POSTGRESQL(
    host 'pg-host' port 5432 user 'readonly' password '...'
    db 'kyc' table 'tenants'
))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 600);

-- Use in queries for fast lookups
SELECT 
    tenant_id,
    dictGet('tenant_info', 'tenant_name', tenant_id) AS name,
    count()
FROM kyc_journeys GROUP BY tenant_id;
```

---

## Phase 7: Infrastructure & Operations

### 7.1 Deployment Options

| Option | Best For |
|--------|----------|
| **Single node** | Dev/staging, <1TB |
| **Replicated (no sharding)** | HA for <5TB, read scaling |
| **Sharded + Replicated** | >5TB, horizontal write scaling |
| **ClickHouse Cloud** | Managed, auto-scaling, zero ops |
| **Kubernetes (Altinity Operator)** | Cloud-native, GitOps |

### 7.2 Configuration Essentials

```xml
<!-- /etc/clickhouse-server/config.xml key sections -->

<!-- Memory limits -->
<max_memory_usage>10000000000</max_memory_usage>  <!-- 10GB per query -->
<max_memory_usage_for_all_queries>30000000000</max_memory_usage_for_all_queries>

<!-- Background merges -->
<background_pool_size>16</background_pool_size>
<background_schedule_pool_size>16</background_schedule_pool_size>

<!-- Storage policies (tiered storage) -->
<storage_configuration>
    <disks>
        <hot><path>/ssd/clickhouse/</path></hot>
        <cold><path>/hdd/clickhouse/</path></cold>
        <s3_archive>
            <type>s3</type>
            <endpoint>https://s3.amazonaws.com/bucket/</endpoint>
        </s3_archive>
    </disks>
    <policies>
        <tiered>
            <volumes>
                <hot><disk>hot</disk></hot>
                <cold><disk>cold</disk></cold>
            </volumes>
            <move_factor>0.1</move_factor>
        </tiered>
    </policies>
</storage_configuration>
```

### 7.3 Monitoring Checklist

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| Replication lag | `system.replicas.absolute_delay` | > 300s |
| Queue size | `system.replicas.queue_size` | > 100 |
| Active parts per partition | `system.parts` | > 300 (too many = merge backlog) |
| Memory usage | `system.asynchronous_metrics` | > 80% of limit |
| Failed queries | `system.query_log` (type=ExceptionWhileProcessing) | > 0 per minute |
| Merge rate | `system.merges` | Backlog growing = increase `background_pool_size` |
| ZK latency | ZK/Keeper metrics | > 100ms |
| Disk free space | `system.disks` | < 20% |

### 7.4 Backup & Recovery

```bash
# Native backup (ClickHouse 22.8+)
BACKUP TABLE events TO Disk('backups', 'events_backup_20250228');
RESTORE TABLE events FROM Disk('backups', 'events_backup_20250228');

# clickhouse-backup tool (popular for production)
clickhouse-backup create daily_backup
clickhouse-backup upload daily_backup  # → S3/GCS
```

---

## Phase 8: Advanced Topics

### 8.1 Projections (Query-Specific Sort Orders)

```sql
ALTER TABLE kyc_journeys ADD PROJECTION by_vendor (
    SELECT * ORDER BY (vendor, journey_date, journey_id)
);
ALTER TABLE kyc_journeys MATERIALIZE PROJECTION by_vendor;

-- Now queries filtering by vendor use this projection automatically
SELECT avg(face_match_score) FROM kyc_journeys WHERE vendor = 'trulioo';
```

### 8.2 Lightweight Deletes & Updates (ClickHouse 23.3+)

```sql
-- These are now "lightweight" but still not as fast as in PostgreSQL
DELETE FROM events WHERE event_date < '2024-01-01';
ALTER TABLE events UPDATE status = 'expired' WHERE created_at < now() - INTERVAL 1 YEAR;
```

### 8.3 Window Functions

```sql
SELECT 
    journey_id,
    tenant_id,
    face_match_score,
    row_number() OVER (PARTITION BY tenant_id ORDER BY face_match_score DESC) AS rank
FROM kyc_journeys
WHERE journey_date = today();
```

### 8.4 Parameterized Views & Query Caching

```sql
-- Query cache (22.8+)
SET use_query_cache = 1;
SET query_cache_ttl = 300;
SELECT count() FROM events WHERE event_date = today();
```

---

## Phase 9: Learning Path & Resources

### Structured Order to Learn

```
Week 1-2:  Install → basic SQL → INSERT/SELECT → system tables exploration
Week 3-4:  MergeTree deep dive → ORDER BY impact → partitioning strategies
Week 5-6:  ReplicatedMergeTree → set up 3-node cluster → test failover
Week 7-8:  Kafka integration → Materialized Views → pre-aggregation patterns
Week 9-10: Query optimization → EXPLAIN → skip indexes → projections
Week 11-12: Operations → monitoring → backups → config tuning
Ongoing:   system.query_log analysis → production incident handling → schema evolution
```

### Hands-On Projects (Relevant to Your Work)

1. **KYC Analytics Dashboard**: Ingest journey events from Kafka → MergeTree → Materialized Views for hourly/daily aggregates → Grafana dashboard
2. **Vendor Performance Monitor**: ReplacingMergeTree for latest vendor scores → compare latency/accuracy across vendors with window functions
3. **Audit Log System**: Append-only MergeTree with TTL → partitioned by month → tiered storage (SSD → S3)
4. **Replication Lab**: 3-node cluster with ClickHouse Keeper → simulate node failure → observe recovery

### Key Resources

| Resource | URL/Location |
|----------|-------------|
| Official Docs | clickhouse.com/docs |
| ClickHouse Academy (free) | clickhouse.com/learn |
| YouTube: ClickHouse Channel | Official talks and deep dives |
| Blog: Altinity | altinity.com/blog (excellent ops content) |
| Book: "ClickHouse in Action" | Manning Publications |
| GitHub: ClickHouse | github.com/ClickHouse/ClickHouse (read the tests for edge cases) |
| Playground | play.clickhouse.com (browser-based, with sample datasets) |
| Community Slack | clickhouse.com/slack |

### CLI Tools to Master

```bash
clickhouse-client          # Interactive SQL client
clickhouse-local           # Run queries on local files without a server
clickhouse-benchmark       # Load testing
clickhouse-obfuscator      # Anonymize data for sharing
clickhouse-format          # SQL formatter
clickhouse-compressor      # Compress/decompress CH native format
```

---

## Quick Reference: Decision Matrix

| Decision | Recommendation |
|----------|---------------|
| Engine for analytics | MergeTree |
| Engine for dedup/upserts | ReplacingMergeTree + FINAL |
| Engine for counters/metrics | SummingMergeTree |
| Engine for Kafka consumption | Kafka → MV → MergeTree |
| Replication coordinator | ClickHouse Keeper (not ZK) |
| Primary key strategy | Low cardinality first → Date → High cardinality |
| Partition key | `toYYYYMM(date)` for most time-series data |
| When to add skip indexes | After profiling, not upfront |
| Pre-aggregation | Materialized Views to AggregatingMergeTree |
| Tiered storage | Hot (SSD) → Cold (HDD) → Archive (S3) via storage policies |