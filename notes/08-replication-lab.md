# Replication & Clustering Lab — Reference Notes

Lab script: `cluster/scripts/lab-replication.sh` (`make lab-replication`)

This lab operates across all 4 ClickHouse nodes (2 shards x 2 replicas) and 3 Keeper nodes. It demonstrates replication, distributed queries, sharding strategies, failover recovery, and Keeper internals.

---

## Exercise 1: Replication in Action

Replication in ClickHouse is **async** and happens **within a shard** only.

**What we do:**
- CREATE TABLE ON CLUSTER → table exists on all 4 nodes
- INSERT 100 rows on ch-s1r1 → replicated to ch-s1r2 (same shard)
- ch-s2r1 and ch-s2r2 have 0 rows (different shard)

**Key takeaways:**
- `ReplicatedMergeTree` replication is within-shard. Shards are independent.
- The INSERT returns after the local write (step 2 of the flow). Replication to the other replica is async.
- Checksums match between replicas — byte-for-byte identical data parts.
- Data travels replica-to-replica via `interserver_http_port` (9009), not via Keeper.

**ZK path pattern:**
```
/clickhouse/tables/{shard}/demo/lab_repl_test
```
The `{shard}` macro ensures Shard 1 replicas share one ZK path and Shard 2 replicas share another.

---

## Exercise 2: Inspect Replication Metadata

**system.replicas columns:**

| Column | Meaning |
|--------|---------|
| `replica_name` | This node's replica identifier (from `{replica}` macro) |
| `is_leader` | Whether this replica coordinates merge assignments for the shard |
| `absolute_delay` | Seconds behind the freshest data (0 = up to date) |
| `queue_size` | Pending replication tasks (fetches, merges) |
| `active_replicas` | How many replicas in this shard are alive |

**Leader election:**
- Exactly one replica per shard is the leader at any time
- The leader decides which parts to merge and assigns merge tasks
- Leader status is tracked via an ephemeral Keeper node

**Keeper path tree for a replicated table:**
```
/clickhouse/tables/01/demo/lab_repl_test/
├── metadata        ← CREATE TABLE schema
├── columns         ← Column definitions
├── log/            ← Replication log entries
├── replicas/
│   ├── ch-s1r1/
│   │   ├── parts/  ← Parts this replica has
│   │   └── queue/  ← Pending tasks for this replica
│   └── ch-s1r2/
│       └── ...
├── block_numbers/  ← Dedup tracking
└── mutations/      ← ALTER UPDATE/DELETE tracking
```

Query these paths via `system.zookeeper`:
```sql
SELECT name FROM system.zookeeper
WHERE path = '/clickhouse/tables/01/demo/lab_repl_test/replicas';
```

---

## Exercise 3: Distributed Query Flow

A `Distributed` table is a **query router**, not a storage engine.

**How it works:**
1. Client connects to any node (the **coordinator**)
2. Coordinator fans out the query to one replica per shard
3. Each shard executes locally and returns partial results
4. Coordinator merges partial results and returns to client

**Key observations:**
- Local table count = rows on that shard only
- Distributed table count = sum of all shards
- Any node can be the coordinator — same result regardless of entry point
- Replica selection per shard uses `load_balancing` setting (default: `random`)

**Local vs distributed aggregation:**
```sql
-- Local: only sees this shard's data
SELECT count() FROM demo.lab_repl_test;

-- Distributed: sees all shards
SELECT count() FROM demo.lab_repl_test_dist;
```

---

## Exercise 4: Sharding Key Impact

The sharding key in `Distributed(cluster, db, table, <key>)` determines row routing.

### rand() sharding
- Rows distributed ~50/50 between shards
- All 10 users appear on BOTH shards
- Good for: balanced load, global aggregations
- Bad for: per-user queries (must fan out to all shards)

### cityHash64(user_id) sharding
- Each user lands on exactly ONE shard
- All rows for user_id=1 are co-located
- Good for: per-user queries (single shard read), JOINs by user_id
- Bad for: hotspots if some users have vastly more data

**Decision rule:** What's your most common WHERE clause?
- `WHERE user_id = X` → shard by `cityHash64(user_id)`
- Global aggregations → `rand()` is fine
- Tenant isolation → shard by `cityHash64(tenant_id)`

---

## Exercise 5: Replica Failover & Recovery

**Failover sequence:**
1. Baseline: both replicas have N rows, `active_replicas = 2`
2. `docker stop ch-s1r2` → simulates failure
3. INSERT 200 rows on ch-s1r1 → succeeds (local write)
4. Distributed queries work — route to ch-s1r1 for Shard 1
5. `active_replicas` drops to 1 in `system.replicas`
6. `docker start ch-s1r2` → node comes back
7. ch-s1r2 reads the replication log, fetches missed parts
8. Row counts match, `queue_size = 0`, `active_replicas = 2`

**Self-healing mechanism:**
- The replication log in Keeper records every part created
- When a replica comes back, it compares its parts with the log
- Missing parts are fetched from the live replica via port 9009
- No manual intervention needed

**Monitoring columns during failover:**

| Column | Healthy | During failure | After recovery |
|--------|---------|----------------|----------------|
| `active_replicas` | 2 | 1 | 2 |
| `queue_size` (failed node) | 0 | N/A | 0 (after catch-up) |
| `absolute_delay` (failed node) | 0 | N/A | 0 (after catch-up) |

---

## Exercise 6: Keeper Health & Quorum

**Four-letter commands** (via `clickhouse-keeper-client`):

| Command | Purpose |
|---------|---------|
| `ruok` | Are you OK? Returns `imok` if healthy |
| `mntr` | Monitoring stats: server state, followers, znode count |
| `stat` | Connection and session stats |
| `srvr` | Server details including mode (leader/follower) |

**Quorum math:**
- 3 Keeper nodes → need majority of 2 for consensus
- Tolerates 1 failure
- If 2 die → no quorum → cluster goes **read-only** (can't create/replicate)

**What to look for in `mntr`:**

| Metric | Meaning |
|--------|---------|
| `zk_server_state` | `leader` or `follower` |
| `zk_followers` | Number of followers (only on leader) |
| `zk_znode_count` | Total metadata nodes stored |
| `zk_approximate_data_size` | Bytes of metadata |

**Exactly one leader at any time.** If the leader dies, a Raft election happens and a new leader is chosen within seconds.

---

## Concept Summary

| Concept | Key insight |
|---------|------------|
| Async replication | INSERT returns after local write; replica catches up via log |
| Shard isolation | Replication is within-shard only; shards are independent |
| Distributed table | Query router that fans out to shards; any node can coordinate |
| rand() sharding | Even distribution, no co-location |
| Hash sharding | User co-location on one shard; faster per-user queries |
| Failover | Surviving replica serves reads + writes; no downtime |
| Recovery | Failed replica catches up from replication log automatically |
| Keeper quorum | 3 nodes, 1 leader, tolerates 1 failure |
