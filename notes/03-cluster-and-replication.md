# Cluster and Replication Internals

## Core Concepts

### Sharding vs Replication

```
Sharding  = splitting data ACROSS nodes (horizontal partitioning)
Replication = copying data WITHIN a shard (redundancy, read scaling)
```

| | Sharding | Replication |
|--|----------|-------------|
| **Purpose** | Scale writes, distribute data | HA, read scaling |
| **Data overlap** | Different data per shard | Same data per replica |
| **Failure impact** | Lose a shard → lose that data (unless replicated) | Lose a replica → other replicas serve reads |

In our cluster:
- **Shard 1** (ch-s1r1, ch-s1r2): Both have rows where `hash(sharding_key) % 2 == 0`
- **Shard 2** (ch-s2r1, ch-s2r2): Both have rows where `hash(sharding_key) % 2 == 1`

---

## Replication Flow

### How an INSERT gets replicated

```
1. Client INSERTs into ch-s1r1
2. ch-s1r1 writes the data as a new part locally
3. ch-s1r1 registers the part in Keeper:
   /clickhouse/tables/01/events/replicas/ch-s1r1/parts/202401_1_1_0
4. ch-s1r1 adds an entry to the replication log:
   /clickhouse/tables/01/events/log/log-0000000001
   "I have part 202401_1_1_0, fetch it from ch-s1r1:9009"
5. ch-s1r2 watches the log, sees the new entry
6. ch-s1r2 fetches the part from ch-s1r1 via interserver_http_port (9009)
7. ch-s1r2 writes the part locally and registers it in Keeper
```

### Key Points

- Replication is **asynchronous** — the INSERT returns success after step 2 (local write)
- The replica fetches the actual data via HTTP (port 9009), not via Keeper
- Keeper only stores metadata (part names, log entries), never the actual data
- `insert_quorum` setting can make INSERTs wait for N replicas (synchronous replication)

---

## Keeper vs ZooKeeper

ClickHouse Keeper is a drop-in replacement for ZooKeeper, built specifically for ClickHouse.

| | ZooKeeper | ClickHouse Keeper |
|--|-----------|-------------------|
| **Protocol** | ZAB (ZooKeeper Atomic Broadcast) | Raft |
| **Language** | Java | C++ |
| **Memory** | JVM heap (GC pauses) | Native (no GC) |
| **Deployment** | Separate service | Built into ClickHouse (or standalone) |
| **Compatibility** | Original | Wire-compatible with ZK protocol |
| **Snapshots** | Binary | Binary, can be inspected with tools |
| **Why preferred** | Battle-tested, wide ecosystem | Simpler ops, no JVM, better performance for CH workloads |

### Raft Consensus (How Keeper Works)

```
1. One node is elected LEADER (handles all writes)
2. Followers forward write requests to the leader
3. Leader proposes a log entry
4. Followers acknowledge the entry
5. Once MAJORITY (2 of 3) acknowledge → entry is COMMITTED
6. Leader notifies followers to apply the entry
```

**Quorum math**: With 3 nodes, need 2 for a majority. Tolerates 1 failure.
- 3 nodes → tolerates 1 failure
- 5 nodes → tolerates 2 failures (rarely needed)

---

## Distributed Table Query Flow

When you query a `Distributed` table:

```sql
SELECT event_type, count() FROM events_distributed GROUP BY event_type
```

```
1. Client connects to ch-s1r1 (this node becomes the COORDINATOR)
2. Coordinator rewrites the query for each shard:
   → Send "SELECT event_type, count() FROM events GROUP BY event_type" to shard 1
   → Send "SELECT event_type, count() FROM events GROUP BY event_type" to shard 2
3. Each shard executes locally and returns partial results
4. Coordinator MERGES partial results:
   → Sums up count() for each event_type across shards
5. Final result returned to client
```

### What the Coordinator Does

- **Aggregation merging**: Combines partial aggregates (SUM, COUNT are easy; quantiles are approximate)
- **ORDER BY / LIMIT**: Final sort and limit on merged results
- **Replica selection**: For each shard, picks ONE replica based on `load_balancing` setting

### Pitfalls

- **Non-aggregated queries**: `SELECT * FROM dist_table LIMIT 10` fetches from ALL shards, then limits. Wasteful.
  - Fix: Use `distributed_group_by_mode = 'in_order'` or push LIMIT to shard level
- **JOINs across shards**: Left table is on one shard, right table on another → data transfer
  - Fix: Co-locate related tables on the same shard (same sharding key)

---

## Sharding Key Strategies

The sharding key determines which shard receives each row.

```sql
-- Random: even distribution, no co-location
ENGINE = Distributed('cluster', 'db', 'table', rand())

-- Hash-based: deterministic, co-locates by user
ENGINE = Distributed('cluster', 'db', 'table', cityHash64(user_id))

-- Expression-based: shard by region
ENGINE = Distributed('cluster', 'db', 'table', cityHash64(region))
```

| Strategy | Pros | Cons |
|----------|------|------|
| `rand()` | Perfect balance | Can't co-locate related data |
| `cityHash64(user_id)` | All user data on one shard → fast user-level queries | Hotspots if some users have 1000x more data |
| `cityHash64(tenant_id)` | Tenant isolation | Same hotspot risk |
| No sharding (1 shard) | Simple, no cross-shard issues | Limited by single node capacity |

### Choosing a Sharding Key

Ask: **"What's my most common WHERE clause?"**

- If most queries filter by `user_id` → shard by `user_id`
- If queries are global aggregations → `rand()` is fine
- If you need tenant isolation → shard by `tenant_id`

---

## internal_replication Setting

This setting in `clusters.xml` is critical and confusing:

### `internal_replication = true` (Correct for ReplicatedMergeTree)

```
INSERT into Distributed table
  → Routes to ONE replica per shard
  → ReplicatedMergeTree handles replication to other replicas
  → Each row is written ONCE
```

### `internal_replication = false` (For plain MergeTree only)

```
INSERT into Distributed table
  → Writes to ALL replicas in each shard
  → No ReplicatedMergeTree replication needed
  → But with ReplicatedMergeTree → DUPLICATE ROWS
```

**Rule**: If your local table is `ReplicatedMergeTree`, always use `internal_replication = true`.

---

## ZooKeeper Path Structure

ClickHouse creates this tree in Keeper for each replicated table:

```
/clickhouse/tables/{shard}/{db}/{table}/
├── metadata          ← Table schema (CREATE TABLE statement)
├── columns           ← Column list
├── log/              ← Replication log (new parts, merges, mutations)
│   ├── log-0000000001
│   ├── log-0000000002
│   └── ...
├── replicas/
│   ├── ch-s1r1/
│   │   ├── is_active   ← Ephemeral node (disappears if replica dies)
│   │   ├── host        ← Hostname + ports for data transfer
│   │   ├── parts/      ← List of parts this replica has
│   │   └── queue/      ← Pending replication tasks for this replica
│   └── ch-s1r2/
│       └── ...
├── block_numbers/    ← Block number allocation (prevents duplicates)
├── quorum/           ← For insert_quorum synchronous writes
└── mutations/        ← ALTER TABLE ... UPDATE/DELETE tracking
```

### Debugging ZooKeeper Paths

```sql
-- View the ZK tree from ClickHouse
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/events';

-- Check replica parts
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/events/replicas/ch-s1r1/parts';

-- Check replication log
SELECT * FROM system.zookeeper WHERE path = '/clickhouse/tables/01/demo/events/log';
```

---

## Common Replication Issues

### "Replica is read-only"
- **Cause**: Keeper is unreachable or quorum is lost
- **Fix**: Restore Keeper quorum, check network between CH and Keeper nodes

### "Too many parts in replication queue"
- **Cause**: Replica can't keep up with inserts (slow disk, network)
- **Fix**: Check `system.replication_queue`, check disk I/O, check network to source replica

### "Replica has different schema"
- **Cause**: ALTER TABLE ON CLUSTER partially applied
- **Fix**: Check `system.replicas` → `is_readonly`, manually apply the ALTER on the lagging node

### "Data inconsistency between replicas"
- **Cause**: Usually a bug or manual data manipulation
- **Fix**: `SYSTEM RESTART REPLICA db.table` or `SYSTEM RESTORE REPLICA db.table`
