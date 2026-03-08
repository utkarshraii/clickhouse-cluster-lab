# ClickHouse Learning Plan

9 phases from foundations to advanced. Each phase has theory notes + hands-on work.

Update the **Status** column as you complete each phase.

---

## Progress

| Phase | Topic | Theory | Hands-On | Status |
|-------|-------|--------|----------|--------|
| 1 | Foundations — What is ClickHouse & Why | `notes/01-architecture.md` | Cluster setup (`docker-compose.yml`) | ✅ Done |
| 2 | Architecture Deep Dive — Storage, query pipeline, primary index | `notes/01-architecture.md`, `notes/02-config-reference.md` | `make init` + `make health` | ✅ Done |
| 3 | Table Engines — MergeTree family | `notes/07-table-engines-lab.md` | `make lab-engines` | ✅ Done |
| 4 | Replication & Clustering — shards, replicas, Keeper, Distributed | `notes/03-cluster-and-replication.md`, `notes/08-replication-lab.md` | `make lab-replication` | ✅ Done |
| 5 | Metadata — system.* tables for operational visibility | `notes/04-debugging-and-monitoring.md`, `notes/09-metadata-lab.md` | `make lab-metadata` | ✅ Done |
| 6 | Data Modeling & Query Optimization — ORDER BY, skip indexes, MVs | `notes/05-query-optimization.md`, `notes/10-optimization-lab.md` | `make lab-optimization` | ✅ Done |
| 7 | Infrastructure & Operations — backup, TTL, parts, mutations, monitoring | `notes/11-operations.md`, `notes/12-operations-lab.md` | `make lab-operations` | ✅ Done |
| 8 | Advanced Topics — projections, deletes, window funcs, dictionaries, buffers | `notes/13-advanced-topics.md`, `notes/14-advanced-lab.md` | `make lab-advanced` | ✅ Done |
| 9 | Learning Path & Resources — decision matrix, projects, resources | `notes/15-decision-matrix.md`, `notes/16-project-ideas.md`, `notes/17-resources.md` | — | ✅ Done |

---

## Phase Details

### Phase 1 — Foundations ✅

**Goal:** Understand what ClickHouse is, OLAP vs OLTP, columnar storage basics.

**Deliverables:**
- [x] `notes/01-architecture.md` — Write path, parts, columnar storage, granules, sparse index, merges, partitions
- [x] `cluster/docker-compose.yml` — 7-container cluster (3 Keeper + 4 CH, 2 shards x 2 replicas)
- [x] `cluster/config/` — All Keeper + ClickHouse configuration files
- [x] `Makefile` — Cluster lifecycle targets (`up`, `down`, `destroy`, `ps`, `client`, `query`)

---

### Phase 2 — Architecture Deep Dive ✅

**Goal:** Understand config, initialization, and health monitoring.

**Deliverables:**
- [x] `notes/02-config-reference.md` — Every config field explained
- [x] `cluster/scripts/init-cluster.sh` — Creates tables, inserts 10K rows, verifies replication
- [x] `cluster/scripts/health-check.sh` — 7-check health script
- [x] `Makefile` targets: `init`, `health`, `wait`, `bootstrap`

---

### Phase 3 — Table Engines ✅

**Goal:** Hands-on with all MergeTree variants, understand merge-time behavior.

**Deliverables:**
- [x] `cluster/scripts/lab-table-engines.sh` — 6 exercises (MergeTree, Replacing, Summing, Aggregating, Collapsing, VersionedCollapsing)
- [x] `notes/07-table-engines-lab.md` — Reference notes with engine decision matrix
- [x] `Makefile` target: `lab-engines`

---

### Phase 4 — Replication & Clustering ✅

**Goal:** Hands-on with replication, distributed queries, sharding, failover, Keeper.

**Deliverables:**
- [x] `notes/03-cluster-and-replication.md` — Theory (replication flow, Keeper, distributed queries, sharding keys, ZK paths)
- [x] `cluster/scripts/lab-replication.sh` — 6 exercises (replication, metadata, distributed flow, sharding keys, failover, Keeper health)
- [x] `notes/08-replication-lab.md` — Lab reference notes
- [x] `Makefile` target: `lab-replication`

---

### Phase 5 — Metadata (system.* tables) ✅

**Goal:** Use system tables for operational visibility — find slow queries, detect merge problems, monitor replication, debug issues.

**Deliverables:**
- [x] `notes/04-debugging-and-monitoring.md` — Theory (system.query_log, system.parts, system.replicas, system.merges, system.errors, EXPLAIN)
- [x] `cluster/scripts/lab-metadata.sh` — 6 exercises (query_log, parts, columns, merges/metrics, replicas, EXPLAIN)
- [x] `notes/09-metadata-lab.md` — Lab reference notes
- [x] `Makefile` target: `lab-metadata`

---

### Phase 6 — Data Modeling & Query Optimization ✅

**Goal:** Design ORDER BY keys for real workloads, use skip indexes, build materialized views, optimize query performance.

**Deliverables:**
- [x] `notes/05-query-optimization.md` — Theory (ORDER BY strategy, skip indexes, projections, MVs, EXPLAIN, performance patterns)
- [x] `cluster/scripts/lab-optimization.sh` — 6 exercises (ORDER BY good/bad, PREWHERE, skip indexes, projections, MVs, full optimization workflow)
- [x] `notes/10-optimization-lab.md` — Lab reference notes
- [x] `Makefile` target: `lab-optimization`

---

### Phase 7 — Infrastructure & Operations ✅

**Goal:** Production readiness — backup/restore, TTL, part management, mutations, monitoring.

**Deliverables:**
- [x] `notes/11-operations.md` — Production operations guide (backup, TTL, parts, mutations, monitoring)
- [x] `cluster/scripts/lab-operations.sh` — 6 exercises (backup/restore, TTL, disk/parts, too-many-parts, mutations, monitoring dashboard)
- [x] `notes/12-operations-lab.md` — Lab reference notes
- [x] `cluster/config/clickhouse/backups.xml` — Backup engine config (required for BACKUP/RESTORE SQL)
- [x] `Makefile` target: `lab-operations`

---

### Phase 8 — Advanced Topics ✅

**Goal:** Power-user features for complex workloads.

**Deliverables:**
- [x] `notes/13-advanced-topics.md` — Theory (projections deep dive, lightweight deletes, window functions, dictionaries, parameterized views, buffer tables + async inserts)
- [x] `cluster/scripts/lab-advanced.sh` — 6 exercises (projections storage cost, ALTER DELETE vs DELETE FROM, window functions, dictionaries with range_hashed, parameterized views, buffer + async inserts)
- [x] `notes/14-advanced-lab.md` — Lab reference notes
- [x] `Makefile` target: `lab-advanced`

---

### Phase 9 — Learning Path & Resources ✅

**Goal:** Synthesize everything into decision frameworks and project ideas.

**Deliverables:**
- [x] `notes/15-decision-matrix.md` — 12 decision matrices (engines, ORDER BY, partitioning, skip indexes, projections vs MVs, sharding, compression, dictionaries, delete strategy, ingestion, monitoring, backup)
- [x] `notes/16-project-ideas.md` — 5 hands-on projects (analytics dashboard, user behavior, log aggregation, time-series metrics, A/B testing) with schemas and key queries
- [x] `notes/17-resources.md` — Official docs, learning resources, tools, community, sample datasets

---

## File Map

```
clickhouse/
├── PLAN.md                              ← this file
├── Makefile                             ← all targets
├── cluster/
│   ├── docker-compose.yml               ← 7-container cluster
│   ├── .env                             ← version pins
│   ├── config/                          ← Keeper + CH configs
│   └── scripts/
│       ├── init-cluster.sh              ← Phase 2
│       ├── health-check.sh              ← Phase 2
│       ├── lab-table-engines.sh         ← Phase 3
│       ├── lab-replication.sh           ← Phase 4
│       ├── lab-metadata.sh             ← Phase 5
│       ├── lab-optimization.sh         ← Phase 6
│       ├── lab-operations.sh           ← Phase 7
│       └── lab-advanced.sh            ← Phase 8
└── notes/
    ├── 01-architecture.md               ← Phase 1-2
    ├── 02-config-reference.md           ← Phase 2
    ├── 03-cluster-and-replication.md    ← Phase 4
    ├── 04-debugging-and-monitoring.md   ← Phase 5
    ├── 05-query-optimization.md         ← Phase 6
    ├── 06-cluster-setup-troubleshooting.md ← Phase 7 (troubleshooting logs)
    ├── 07-table-engines-lab.md          ← Phase 3
    ├── 08-replication-lab.md            ← Phase 4
    ├── 09-metadata-lab.md              ← Phase 5
    ├── 10-optimization-lab.md          ← Phase 6
    ├── 11-operations.md                ← Phase 7
    ├── 12-operations-lab.md            ← Phase 7
    ├── 13-advanced-topics.md           ← Phase 8
    ├── 14-advanced-lab.md              ← Phase 8
    ├── 15-decision-matrix.md           ← Phase 9
    ├── 16-project-ideas.md             ← Phase 9
    └── 17-resources.md                 ← Phase 9
```
