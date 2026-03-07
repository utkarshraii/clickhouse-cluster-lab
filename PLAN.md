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
| 5 | Metadata — system.* tables for operational visibility | `notes/04-debugging-and-monitoring.md` (written) | Lab script needed | ⬜ Next |
| 6 | Data Modeling & Query Optimization — ORDER BY, skip indexes, MVs | `notes/05-query-optimization.md` (written) | Lab script needed | ⬜ |
| 7 | Infrastructure & Operations — deployment, monitoring, backup | Partial (`notes/06-cluster-setup-troubleshooting.md`) | Lab script needed | ⬜ |
| 8 | Advanced Topics — projections, lightweight deletes, window functions | — | — | ⬜ |
| 9 | Learning Path & Resources — projects, decision matrix | — | — | ⬜ |

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

### Phase 5 — Metadata (system.* tables) ⬜

**Goal:** Use system tables for operational visibility — find slow queries, detect merge problems, monitor replication, debug issues.

**Existing theory:** `notes/04-debugging-and-monitoring.md` (404 lines, covers system.query_log, system.parts, system.replicas, system.merges, system.errors, EXPLAIN)

**TODO:**
- [ ] `cluster/scripts/lab-metadata.sh` — Hands-on exercises querying system tables
- [ ] `notes/09-metadata-lab.md` — Lab reference notes
- [ ] `Makefile` target: `lab-metadata`

**Suggested exercises:**
1. system.query_log — find slow queries, failed queries, read/write stats
2. system.parts — inspect part structure, detect too-many-parts, partition pruning
3. system.replicas — replication lag, queue depth, leader status across shards
4. system.merges — watch a merge in progress, understand merge triggers
5. system.columns — column sizes, compression ratios, type introspection
6. EXPLAIN — read query plans, understand pipeline stages, identify bottlenecks

---

### Phase 6 — Data Modeling & Query Optimization ⬜

**Goal:** Design ORDER BY keys for real workloads, use skip indexes, build materialized views, optimize query performance.

**Existing theory:** `notes/05-query-optimization.md` (379 lines, covers ORDER BY strategy, skip indexes, projections, MVs, EXPLAIN, performance patterns)

**TODO:**
- [ ] `cluster/scripts/lab-optimization.sh` — Hands-on optimization exercises
- [ ] `notes/10-optimization-lab.md` — Lab reference notes
- [ ] `Makefile` target: `lab-optimization`

**Suggested exercises:**
1. ORDER BY key design — compare query performance with good vs bad key choices
2. Skip indexes (bloom_filter, minmax, set) — measure granule skipping
3. Projections — create alternative sort orders, verify automatic projection selection
4. Materialized Views — build a pre-aggregation pipeline, compare query speed
5. PREWHERE vs WHERE — understand automatic optimization and manual control
6. Real-world scenario — model a time-series analytics workload end-to-end

---

### Phase 7 — Infrastructure & Operations ⬜

**Goal:** Production readiness — monitoring, backup/restore, capacity planning, operational runbooks.

**Existing notes:** `notes/06-cluster-setup-troubleshooting.md` (392 lines, real troubleshooting from cluster setup)

**TODO:**
- [ ] `notes/11-operations.md` — Production operations guide (backup, monitoring, capacity, upgrades)
- [ ] `cluster/scripts/lab-operations.sh` — Hands-on operations exercises
- [ ] `notes/12-operations-lab.md` — Lab reference notes
- [ ] `Makefile` target: `lab-operations`

**Suggested exercises:**
1. Backup & restore — `clickhouse-backup` or built-in BACKUP/RESTORE commands
2. TTL management — set up auto-expiry, verify data removal after merge
3. Disk management — inspect disk usage, understand part lifecycle
4. Too-many-parts — simulate the problem, understand the 300-part threshold
5. Mutations — ALTER UPDATE/DELETE, track progress in system.mutations
6. Monitoring integration — key metrics to export (Prometheus/Grafana patterns)

---

### Phase 8 — Advanced Topics ⬜

**Goal:** Power-user features for complex workloads.

**TODO:**
- [ ] `notes/13-advanced-topics.md` — Theory notes
- [ ] `cluster/scripts/lab-advanced.sh` — Hands-on exercises
- [ ] `notes/14-advanced-lab.md` — Lab reference notes
- [ ] `Makefile` target: `lab-advanced`

**Suggested exercises:**
1. Projections deep dive — multiple projections per table, storage cost analysis
2. Lightweight deletes (`DELETE FROM`) — compare with mutations, verify row masking
3. Window functions — running totals, rankings, session analysis
4. Dictionaries — external data enrichment, layout types, refresh strategies
5. Parameterized views — reusable query templates
6. Buffer tables + async inserts — high-frequency ingestion patterns

---

### Phase 9 — Learning Path & Resources ⬜

**Goal:** Synthesize everything into decision frameworks and project ideas.

**TODO:**
- [ ] `notes/15-decision-matrix.md` — When to use what (engines, sharding keys, indexes, MVs)
- [ ] `notes/16-project-ideas.md` — 3-5 hands-on projects to build real systems
- [ ] `notes/17-resources.md` — Official docs, blogs, talks, community links

**Project ideas:**
1. Real-time analytics dashboard — event ingestion → MV → pre-aggregated queries
2. User behavior tracking — hash-sharded, per-user queries, session analysis
3. Log aggregation system — high-cardinality, TTL, compression optimization
4. Time-series metrics store — rollup MVs, multi-resolution storage
5. A/B testing platform — statistical functions, window functions, experiment analysis

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
│       └── lab-replication.sh           ← Phase 4
└── notes/
    ├── 01-architecture.md               ← Phase 1-2
    ├── 02-config-reference.md           ← Phase 2
    ├── 03-cluster-and-replication.md    ← Phase 4
    ├── 04-debugging-and-monitoring.md   ← Phase 5 (theory ready)
    ├── 05-query-optimization.md         ← Phase 6 (theory ready)
    ├── 06-cluster-setup-troubleshooting.md ← Phase 7 (partial)
    ├── 07-table-engines-lab.md          ← Phase 3
    └── 08-replication-lab.md            ← Phase 4
```
