# ClickHouse Cluster Lab

A production-like ClickHouse cluster running locally via Docker Compose, designed for learning ClickHouse internals from both developer and infrastructure perspectives.

## Cluster Architecture

```
                    ┌─────────────────────────────────────┐
                    │        ClickHouse Keeper Quorum      │
                    │  keeper1 ── keeper2 ── keeper3       │
                    │  (Raft consensus, 3 nodes for HA)    │
                    └──────────────┬──────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
     ┌──────┴───────┐      ┌──────┴───────┐
     │   Shard 1     │      │   Shard 2     │
     │  ch-s1r1      │      │  ch-s2r1      │
     │  ch-s1r2      │      │  ch-s2r2      │
     └───────────────┘      └───────────────┘
```

**7 containers**: 3 Keeper nodes + 4 ClickHouse nodes (2 shards x 2 replicas)

## Quick Start

```bash
# One command — starts cluster, waits for health, creates tables, inserts sample data
make bootstrap
```

Or step by step:

```bash
make up          # Start all 7 containers
make wait        # Block until all containers are healthy
make init        # Create tables and insert 10K sample rows
make health      # Run full health check
```

## Connect and Query

```bash
# Interactive client (defaults to ch-s1r1)
make client

# Connect to a specific node
make client NODE=ch-s2r1

# Run a one-off query
make query Q="SELECT count() FROM demo.events_distributed"
```

## Make Targets

Run `make help` to see all targets:

```
Lifecycle:
  up                Start the cluster (all 7 containers)
  down              Stop the cluster (preserves data volumes)
  destroy           Stop the cluster and DELETE all data volumes
  restart           Restart all containers
  ps                Show container status and health
  pull              Pull latest images (version from .env)
  bootstrap         Start cluster, wait for health, init data, run health check

Setup:
  init              Create sample tables, insert data, verify replication
  health            Run full cluster health check
  wait              Wait until all containers are healthy (up to 90s)

Client:
  client            Open clickhouse-client (override: make client NODE=ch-s2r1)
  query             Run a one-off query: make query Q="SELECT 1"

Logs:
  logs              Tail logs from all containers
  logs-keeper       Tail logs from all keeper nodes
  logs-ch           Tail logs from all ClickHouse nodes
  logs-node         Tail logs from a specific node: make logs-node NODE=ch-s1r1

Debugging:
  cluster-info      Show cluster topology from system.clusters
  replicas          Show replication status across all nodes
  parts             Show part counts per table on each node
  merges            Show active merges
  slow-queries      Show recent slow queries (>1s)
  errors            Show recent errors
```

Most targets accept `NODE=<container>` to target a specific node (default: `ch-s1r1`).

## Useful Queries

```sql
-- See cluster topology
SELECT * FROM system.clusters WHERE cluster = 'ch_cluster';

-- Query across all shards
SELECT event_type, count() FROM demo.events_distributed GROUP BY event_type;

-- Check replication health
SELECT database, table, replica_name, is_leader, absolute_delay
FROM system.replicas;

-- See part counts
SELECT database, table, count() AS parts, sum(rows) AS rows
FROM system.parts WHERE active
GROUP BY database, table;

-- Check Keeper connection
SELECT * FROM system.zookeeper WHERE path = '/clickhouse';
```

## Testing Replication

```bash
# Insert on shard 1, replica 1
make query Q="INSERT INTO demo.events VALUES (99999, 'test', 1, now(), '{}', 42.00)"

# Verify it appears on shard 1, replica 2 (replication)
make query NODE=ch-s1r2 Q="SELECT * FROM demo.events WHERE event_id = 99999"

# Verify it does NOT appear on shard 2 (different shard)
make query NODE=ch-s2r1 Q="SELECT * FROM demo.events WHERE event_id = 99999"

# But it's visible via the Distributed table (queries all shards)
make query Q="SELECT * FROM demo.events_distributed WHERE event_id = 99999"
```

## Port Reference

| Container | HTTP Port | TCP Port | Description |
|-----------|-----------|----------|-------------|
| ch-s1r1 | 8123 | 9000 | Shard 1, Replica 1 |
| ch-s1r2 | 8124 | 9001 | Shard 1, Replica 2 |
| ch-s2r1 | 8125 | 9002 | Shard 2, Replica 1 |
| ch-s2r2 | 8126 | 9003 | Shard 2, Replica 2 |
| keeper1 | — | 9181 | Keeper node 1 |
| keeper2 | — | 9182 | Keeper node 2 |
| keeper3 | — | 9183 | Keeper node 3 |

All ports are configurable in `cluster/.env`.

## Project Structure

```
clickhouse/
├── Makefile                               ← All commands (make help)
├── README.md                              ← You are here
├── docs/
│   └── roadmap.md                         ← Learning roadmap
├── notes/
│   ├── 01-architecture.md                 ← Storage layout, parts, granules, sparse index
│   ├── 02-config-reference.md             ← Every config field with "what breaks if wrong"
│   ├── 03-cluster-and-replication.md      ← Shards, replicas, Keeper, replication flow
│   ├── 04-debugging-and-monitoring.md     ← System tables, query_log, troubleshooting
│   └── 05-query-optimization.md           ← ORDER BY, skip indexes, projections, EXPLAIN
└── cluster/
    ├── docker-compose.yml                 ← Full cluster definition (7 containers)
    ├── .env                               ← Versions, ports, resource limits
    ├── config/
    │   ├── clickhouse/                    ← Server configs (heavily commented)
    │   │   ├── config.xml                 ← Main server config
    │   │   ├── users.xml                  ← Users, profiles, quotas
    │   │   ├── clusters.xml               ← Cluster topology
    │   │   └── macros/                    ← Per-node identity ({shard}, {replica})
    │   └── keeper/                        ← Keeper configs
    │       ├── keeper_config.xml          ← Shared keeper config
    │       └── nodes/                     ← Per-node server_id
    └── scripts/
        ├── init-cluster.sh                ← Create tables and insert sample data
        └── health-check.sh                ← Verify cluster health
```

## Notes

The `notes/` directory contains deep-dive learning material. Read sequentially — each builds on the previous:

1. **Architecture** — How data lives on disk: parts, granules, sparse index, merges
2. **Config Reference** — Every config field with defaults and "what breaks if wrong"
3. **Cluster & Replication** — Replication flow, Keeper internals, sharding strategies
4. **Debugging & Monitoring** — System tables, common failure scenarios, EXPLAIN
5. **Query Optimization** — ORDER BY selection, skip indexes, projections, materialized views

## Requirements

- Docker and Docker Compose v2
- GNU Make
- ~6GB RAM available (2GB x 2 CH nodes + 512MB x 3 keepers + overhead)
- ~2GB disk space for images
