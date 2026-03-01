# ClickHouse Cluster Lab — Makefile
# ==================================
# Run `make help` to see all available targets.

COMPOSE := docker compose -f cluster/docker-compose.yml --env-file cluster/.env
NODE    ?= ch-s1r1

# ── Cluster Lifecycle ─────────────────────────────────────────────

.PHONY: up
up: ## Start the cluster (all 7 containers)
	$(COMPOSE) up -d
	@echo ""
	@echo "Waiting for containers to become healthy..."
	@$(COMPOSE) ps

.PHONY: down
down: ## Stop the cluster (preserves data volumes)
	$(COMPOSE) down

.PHONY: destroy
destroy: ## Stop the cluster and DELETE all data volumes
	@echo "This will destroy all ClickHouse data. Press Ctrl+C to cancel."
	@sleep 3
	$(COMPOSE) down -v

.PHONY: restart
restart: ## Restart all containers
	$(COMPOSE) restart

.PHONY: ps
ps: ## Show container status and health
	$(COMPOSE) ps

.PHONY: pull
pull: ## Pull latest images (version from .env)
	$(COMPOSE) pull

# ── Initialization & Health ───────────────────────────────────────

.PHONY: init
init: ## Create sample tables, insert data, verify replication
	cluster/scripts/init-cluster.sh

.PHONY: health
health: ## Run full cluster health check
	cluster/scripts/health-check.sh

.PHONY: wait
wait: ## Wait until all containers are healthy (up to 90s)
	@echo "Waiting for all containers to be healthy..."
	@for i in $$(seq 1 18); do \
		unhealthy=$$($(COMPOSE) ps --format json 2>/dev/null | grep -v '"healthy"' | grep -c '"Health"' || true); \
		if $(COMPOSE) ps 2>/dev/null | grep -q "unhealthy\|starting"; then \
			printf "."; \
			sleep 5; \
		else \
			echo ""; \
			echo "All containers healthy."; \
			exit 0; \
		fi; \
	done; \
	echo ""; \
	echo "Timeout — some containers may still be starting:"; \
	$(COMPOSE) ps; \
	exit 1

.PHONY: bootstrap
bootstrap: up wait init health ## Start cluster, wait for health, init data, run health check

# ── Client Access ─────────────────────────────────────────────────

.PHONY: client
client: ## Open clickhouse-client on a node (default: ch-s1r1, override: make client NODE=ch-s2r1)
	docker exec -it $(NODE) clickhouse-client

.PHONY: query
query: ## Run a one-off query: make query Q="SELECT 1"
	@docker exec $(NODE) clickhouse-client --query "$(Q)"

# ── Logs ──────────────────────────────────────────────────────────

.PHONY: logs
logs: ## Tail logs from all containers
	$(COMPOSE) logs -f --tail=50

.PHONY: logs-keeper
logs-keeper: ## Tail logs from all keeper nodes
	$(COMPOSE) logs -f --tail=50 keeper1 keeper2 keeper3

.PHONY: logs-ch
logs-ch: ## Tail logs from all ClickHouse nodes
	$(COMPOSE) logs -f --tail=50 ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2

.PHONY: logs-node
logs-node: ## Tail logs from a specific node: make logs-node NODE=ch-s1r1
	$(COMPOSE) logs -f --tail=100 $(NODE)

# ── Debugging Shortcuts ──────────────────────────────────────────

.PHONY: cluster-info
cluster-info: ## Show cluster topology from system.clusters
	@docker exec $(NODE) clickhouse-client --query \
		"SELECT cluster, shard_num, replica_num, host_name, is_local FROM system.clusters WHERE cluster = 'ch_cluster' FORMAT PrettyCompact"

.PHONY: replicas
replicas: ## Show replication status across all nodes
	@for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do \
		echo "── $$node ──"; \
		docker exec $$node clickhouse-client --query \
			"SELECT database, table, replica_name, is_leader, absolute_delay, queue_size, active_replicas FROM system.replicas FORMAT PrettyCompact" 2>/dev/null || echo "  (no replicated tables)"; \
		echo ""; \
	done

.PHONY: parts
parts: ## Show part counts per table on each node
	@for node in ch-s1r1 ch-s1r2 ch-s2r1 ch-s2r2; do \
		echo "── $$node ──"; \
		docker exec $$node clickhouse-client --query \
			"SELECT database, table, count() AS parts, sum(rows) AS rows, formatReadableSize(sum(bytes_on_disk)) AS size FROM system.parts WHERE active AND database != 'system' GROUP BY database, table FORMAT PrettyCompact" 2>/dev/null || echo "  (no data)"; \
		echo ""; \
	done

.PHONY: merges
merges: ## Show active merges
	@docker exec $(NODE) clickhouse-client --query \
		"SELECT database, table, round(progress*100,1) AS pct, num_parts, formatReadableSize(total_size_bytes_compressed) AS size FROM system.merges FORMAT PrettyCompact"

.PHONY: slow-queries
slow-queries: ## Show recent slow queries (>1s)
	@docker exec $(NODE) clickhouse-client --query \
		"SELECT event_time, query_duration_ms, formatReadableSize(memory_usage) AS mem, read_rows, substring(query, 1, 100) AS query_prefix FROM system.query_log WHERE type = 'QueryFinish' AND query_duration_ms > 1000 ORDER BY event_time DESC LIMIT 10 FORMAT PrettyCompact"

.PHONY: errors
errors: ## Show recent errors
	@docker exec $(NODE) clickhouse-client --query \
		"SELECT name, value AS count, last_error_time, last_error_message FROM system.errors WHERE last_error_time > now() - INTERVAL 1 HOUR ORDER BY last_error_time DESC LIMIT 10 FORMAT PrettyCompact"

# ── Help ──────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
