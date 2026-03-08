# ClickHouse Resources

Curated links for continued learning, organized by category.

---

## Official Documentation

| Resource | URL | Notes |
|----------|-----|-------|
| ClickHouse Docs | https://clickhouse.com/docs | Primary reference — comprehensive |
| SQL Reference | https://clickhouse.com/docs/en/sql-reference | Every function, statement, data type |
| System Tables | https://clickhouse.com/docs/en/operations/system-tables | All `system.*` tables documented |
| MergeTree Engine Family | https://clickhouse.com/docs/en/engines/table-engines/mergetree-family | Engine details, settings, behavior |
| Configuration Reference | https://clickhouse.com/docs/en/operations/server-configuration-parameters | Every config parameter |
| Changelog | https://clickhouse.com/docs/en/whats-new/changelog | Per-version changes |

---

## Learning & Tutorials

| Resource | Notes |
|----------|-------|
| ClickHouse Academy (https://learn.clickhouse.com) | Free official courses — Developer, Admin, Architecture |
| ClickHouse Knowledge Base (https://clickhouse.com/docs/knowledgebase) | Searchable FAQ and how-to articles |
| ClickHouse Playground (https://play.clickhouse.com) | In-browser SQL sandbox with sample datasets |
| ClickHouse YouTube (https://www.youtube.com/@ClickHouseDB) | Conference talks, tutorials, demos |

---

## Blogs & Articles

| Topic | Resource |
|-------|----------|
| Architecture deep dive | ClickHouse Blog: "How ClickHouse Primary Index Works" |
| Data modeling | ClickHouse Blog: "A Practical Introduction to Primary Indexes" |
| Materialized Views | ClickHouse Blog: "Using Materialized Views" |
| Compression | ClickHouse Blog: "Compression in ClickHouse" |
| Window functions | ClickHouse Blog: "ClickHouse Window Functions" |
| Real-world architectures | Altinity Blog (https://altinity.com/blog) — production patterns |
| Performance tuning | ClickHouse Blog: "Optimizing ClickHouse Queries" |

---

## Tools & Ecosystem

### Client Tools

| Tool | Type | Notes |
|------|------|-------|
| `clickhouse-client` | CLI | Built-in, supports multiline, history, formatting |
| DBeaver | GUI | Free, supports ClickHouse via JDBC driver |
| DataGrip | GUI | JetBrains IDE, excellent autocomplete |
| Tabix | Web UI | Lightweight web interface (https://tabix.io) |
| clickhouse-connect | Python | Official Python driver (https://github.com/ClickHouse/clickhouse-connect) |
| clickhouse-go | Go | Official Go driver |
| clickhouse-rs | Rust | Community Rust driver |

### Operations Tools

| Tool | Purpose | Link |
|------|---------|------|
| clickhouse-backup | Backup/restore with S3 support | https://github.com/Altinity/clickhouse-backup |
| clickhouse-operator | Kubernetes operator | https://github.com/Altinity/clickhouse-operator |
| clickhouse-exporter | Prometheus metrics | Built-in at `:9363/metrics` (enable in config) |
| chproxy | HTTP proxy with auth/caching | https://github.com/ContentSquare/chproxy |

### Visualization & Monitoring

| Tool | Integration |
|------|-------------|
| Grafana | ClickHouse data source plugin (official) |
| Prometheus | Built-in metrics endpoint + ClickHouse as Prometheus remote storage |
| Superset | Native ClickHouse connector |
| Metabase | ClickHouse driver available |

---

## Community

| Channel | Link |
|---------|------|
| GitHub | https://github.com/ClickHouse/ClickHouse |
| Slack (Altinity) | https://clickhousedb.slack.com |
| Stack Overflow | Tag: `clickhouse` |
| ClickHouse Meetups | https://clickhouse.com/company/events |
| X/Twitter | @ClickHouseDB |

---

## Key Conference Talks

| Talk | Speaker | Key Topic |
|------|---------|-----------|
| "ClickHouse: New Features" | Alexey Milovidov | Annual feature updates (search YouTube) |
| "MergeTree Under the Hood" | Various | Internal storage architecture |
| "ClickHouse at Scale" | Various companies | Production deployment stories |
| "Designing Schemas in ClickHouse" | Various | ORDER BY, partitioning, engines |

Search the ClickHouse YouTube channel for the latest versions of these recurring talks.

---

## Sample Datasets for Practice

| Dataset | Size | Good For |
|---------|------|----------|
| UK Property Prices | ~30M rows | Time-series, aggregation |
| NYC Taxi Rides | ~1.7B rows | Geospatial, large-scale |
| GitHub Events | ~3B rows | High-cardinality, text search |
| OpenSky Network | ~66M rows | Time-series, flight tracking |
| WikiStat | ~1T rows | Extreme scale, page view analytics |
| Recipes | ~2M rows | Full-text search, small starter dataset |

All available at: https://clickhouse.com/docs/en/getting-started/example-datasets

---

## This Project's Learning Path

For reference, here's the full path we followed:

```
Phase 1  Foundations           → Architecture, columnar storage, sparse indexes
Phase 2  Architecture          → Config, initialization, health checks
Phase 3  Table Engines         → MergeTree family (6 engines)
Phase 4  Replication           → Shards, replicas, Keeper, Distributed
Phase 5  Metadata              → system.* tables for operational visibility
Phase 6  Query Optimization    → ORDER BY, skip indexes, projections, MVs
Phase 7  Operations            → Backup, TTL, parts, mutations, monitoring
Phase 8  Advanced Topics       → Window funcs, dictionaries, async inserts
Phase 9  Synthesis             → Decision matrices, projects, resources
```

Each phase has theory notes (`notes/`) and hands-on labs (`cluster/scripts/`).
Run any lab with `make lab-<name>` (see `make help` for all targets).
