# Cluster Setup Troubleshooting Log

Real issues hit while bringing up the 7-node cluster (3 Keeper + 4 ClickHouse) on Docker Compose with ClickHouse 24.8.

---

## Bug 1: Keeper crash — `Not found: keeper_server.server_id`

**Symptom**
All 3 keeper containers crash-loop. `docker compose ps` shows them as `unhealthy`. Stdout only shows:
```
Processing configuration file '/etc/clickhouse-keeper/keeper_config.xml'.
Logging information to /var/log/clickhouse-keeper/clickhouse-keeper.log
```
No error in stdout — the real error is in the log file inside the container.

**Root Cause**
We had a base `keeper_config.xml` (without `server_id`) and per-node overrides in `config.d/node.xml` (containing `<server_id>1</server_id>`). This works for the **server** image which auto-merges `config.d/*.xml` files, but the **keeper** image does NOT support `config.d/` merging. It only reads the single `keeper_config.xml` file.

The keeper started, parsed `keeper_config.xml`, and when it tried to read `keeper_server.server_id` — it wasn't there.

**How We Found It**
Ran the keeper container interactively and read the log file:
```bash
docker run --rm --entrypoint bash clickhouse/clickhouse-keeper:24.8 -c \
  "clickhouse-keeper --config /etc/clickhouse-keeper/keeper_config.xml & \
   sleep 3; cat /var/log/clickhouse-keeper/clickhouse-keeper.err.log"
```
Error log showed:
```
Poco::Exception. Code: 1000, e.code() = 0, Not found: keeper_server.server_id
```

**Fix**
Created 3 complete standalone configs (`nodes/keeper1.xml`, `keeper2.xml`, `keeper3.xml`) each containing the full config WITH `server_id` embedded. Mounted each directly as `/etc/clickhouse-keeper/keeper_config.xml`:
```yaml
# docker-compose.yml — before (broken)
volumes:
  - ./config/keeper/keeper_config.xml:/etc/clickhouse-keeper/keeper_config.xml:ro
  - ./config/keeper/nodes/keeper1.xml:/etc/clickhouse-keeper/config.d/node.xml:ro

# after (working)
volumes:
  - ./config/keeper/nodes/keeper1.xml:/etc/clickhouse-keeper/keeper_config.xml:ro
```

**Lesson**
The `clickhouse-keeper` image and `clickhouse-server` image have different config loading behavior. Server merges `config.d/`, keeper does not. Always verify assumptions about config loading by checking the actual image behavior.

---

## Bug 2: Server crash — `max_memory_usage` at top level

**Symptom**
All 4 ClickHouse server nodes crash with exit code 137 (SIGKILL). `docker inspect` shows `OOMKilled: false` — so it's not OOM, the process is exiting on its own and Docker restarts it, eventually killing it.

**Root Cause**
`max_memory_usage` was placed at the top level of `config.xml`:
```xml
<clickhouse>
    <max_memory_usage>10000000000</max_memory_usage>  <!-- WRONG LOCATION -->
</clickhouse>
```
This is a **user-level setting** that must live in `users.xml` inside `<profiles><default>`. ClickHouse 24.8 enforces this and refuses to start if user-level settings appear at the server config level.

**How We Found It**
The error wasn't visible in `docker logs` because ClickHouse writes to its own log file. Had to read the error log from the Docker volume:
```bash
docker run --rm -v cluster_ch_s1r1_logs:/logs:ro alpine \
  tail -30 /logs/clickhouse-server.err.log
```
Error:
```
Code: 137. DB::Exception: A setting 'max_memory_usage' appeared at top level in config
/etc/clickhouse-server/config.xml. But it is user-level setting that should be located
in users.xml inside <profiles> section for specific profile.
```

**Fix**
Removed `<max_memory_usage>` from `config.xml`. It was already correctly defined in `users.xml` under `<profiles><default><max_memory_usage>`.

**Lesson**
ClickHouse has two categories of settings:
- **Server-level** (`config.xml`): ports, paths, caches, background pools
- **User-level** (`users.xml` → `<profiles>`): `max_memory_usage`, `max_execution_time`, `readonly`, etc.

Putting a user-level setting in server config is a hard error in 24.8+. The error message is helpful but only visible in the log file, not in stdout.

---

## Bug 3: Server crash — `background_pool_size` too small

**Symptom**
After fixing Bug 2, servers still crash. Exit code 36 this time.

**Root Cause**
`background_pool_size` was set to `4` in config.xml. ClickHouse has a sanity check:
```
background_pool_size × background_merges_mutations_concurrency_ratio
  must be > number_of_free_entries_in_pool_to_execute_mutation
```
With our values: `4 × 2 = 8`, but the default for `number_of_free_entries_in_pool_to_execute_mutation` is `20`. So `8 < 20` → startup rejected.

**How We Found It**
Same technique — read the error log from the Docker volume:
```
Code: 36. DB::Exception: The value of 'number_of_free_entries_in_pool_to_execute_mutation'
setting (20) is greater than the value of 'background_pool_size' *
'background_merges_mutations_concurrency_ratio' (8)
```

**Fix**
Changed `background_pool_size` from `4` to `16` (the default).

**Lesson**
ClickHouse settings have interdependencies. Lowering one value can violate a constraint you didn't know about. The default values (16 for background_pool_size) are chosen to satisfy these constraints. When tuning for smaller containers, check the full sanity check chain rather than changing values in isolation.

---

## Bug 4 (minor): `user_directories` missing from config.xml

**Symptom**
Servers crash with:
```
Not found: user_directories.users_xml.path
```

**Root Cause**
Our custom `config.xml` completely replaces the default one. The default has a `<user_directories>` section that tells the server where to find `users.xml`. We didn't include it.

**Fix**
Added to `config.xml`:
```xml
<user_directories>
    <users_xml>
        <path>users.xml</path>
    </users_xml>
    <local_directory>
        <path>/var/lib/clickhouse/access/</path>
    </local_directory>
</user_directories>
```

**Lesson**
When providing a custom `config.xml` that replaces the default (not merging via `config.d/`), you must include ALL required sections. The default config has many sections that seem optional but are actually required for basic functionality. Check what the default config contains:
```bash
docker run --rm --entrypoint cat clickhouse/clickhouse-server:24.8 \
  /etc/clickhouse-server/config.xml | less
```

---

## Debugging Techniques Used

### 1. Read logs from Docker volumes when container is crash-looping
When a container keeps restarting, `docker exec` doesn't work. Mount the log volume into an alpine container:
```bash
docker run --rm -v cluster_ch_s1r1_logs:/logs:ro alpine \
  tail -50 /logs/clickhouse-server.err.log
```

### 2. Run the image interactively to capture startup errors
Override the entrypoint to start the process manually and read logs:
```bash
docker run --rm --entrypoint bash clickhouse/clickhouse-keeper:24.8 -c \
  "clickhouse-keeper --config /path/to/config & \
   sleep 3; cat /var/log/clickhouse-keeper/clickhouse-keeper.err.log"
```

### 3. Check what the default image ships with
Before replacing config files, see what the defaults contain:
```bash
docker run --rm --entrypoint cat clickhouse/clickhouse-server:24.8 \
  /etc/clickhouse-server/config.xml
```

### 4. Check the entrypoint behavior
The server image has a smart entrypoint that handles `chown`, user switching, etc. Read it to understand what it does:
```bash
docker run --rm --entrypoint cat clickhouse/clickhouse-server:24.8 /entrypoint.sh
```

### 5. Use `clickhouse-keeper-client` for keeper health checks
The keeper image ships BusyBox `nc` which doesn't handle four-letter commands reliably. Use the built-in client instead:
```bash
docker exec keeper1 clickhouse-keeper-client -h localhost -p 9181 --query 'ruok'
# Returns: imok
```

### 6. Exit code reference
| Exit Code | Meaning |
|-----------|---------|
| 137 | SIGKILL (could be OOM or Docker stop timeout, check `docker inspect --format='{{.State.OOMKilled}}'`) |
| 232 | ClickHouse-specific: user/permission mismatch |
| 174 | ClickHouse-specific: config validation failure |
| 36 | ClickHouse-specific: bad arguments / sanity check failure |

---

## Bug 5: Keeper health check failing — BusyBox `nc` incompatibility

**Symptom**
Keepers are actually running fine (logs show "Ready for connections") but Docker marks them as `unhealthy`. The health check command `echo ruok | nc localhost 9181 | grep -q imok` never succeeds.

**Root Cause**
The keeper image uses BusyBox `nc`, not GNU netcat. BusyBox `nc` doesn't handle the four-letter command protocol reliably — it sends `ruok` but doesn't wait for / receive the `imok` response properly.

**How We Found It**
Ran `clickhouse-keeper-client` manually inside the container and got `imok`, confirming keeper was fine. Then checked that `nc` was BusyBox:
```bash
docker exec keeper1 nc --help  # shows BusyBox usage
docker exec keeper1 clickhouse-keeper-client -h localhost -p 9181 --query 'ruok'  # returns imok
```

**Fix**
Changed the health check in `docker-compose.yml` from `nc` to `clickhouse-keeper-client`:
```yaml
# before (broken with BusyBox nc)
healthcheck:
  test: ["CMD-SHELL", "echo ruok | nc localhost 9181 | grep -q imok"]

# after (works reliably)
healthcheck:
  test: ["CMD-SHELL", "clickhouse-keeper-client -h localhost -p 9181 --query 'ruok' | grep -q imok"]
```

**Lesson**
Always verify which version of a tool is available in the container image. BusyBox provides minimal implementations that may not support all features of the full tool.

---

## Bug 6: Keeper only listening on localhost

**Symptom**
Keepers are healthy, CH server nodes start, but `ON CLUSTER` DDL commands fail with:
```
Connection refused (version 24.8.14.39), 172.24.0.3:9181
```

**Root Cause**
Keeper's TCP port (9181) was only bound to `127.0.0.1`, not `0.0.0.0`. The Raft port (9234) defaults to all interfaces, but the client port defaults to localhost only.

Verified with:
```bash
docker exec keeper1 netstat -tlnp
# Shows: tcp 0 0 127.0.0.1:9181 ... LISTEN
# Should be: tcp 0 0 0.0.0.0:9181 ... LISTEN
```

**Fix**
Added `<listen_host>0.0.0.0</listen_host>` to each keeper config:
```xml
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <!-- rest of config -->
</clickhouse>
```

**Lesson**
In a Docker network, containers communicate via their internal IPs (172.x.x.x), not localhost. Any service that needs to accept connections from other containers must listen on `0.0.0.0`.

---

## Bug 7: Docker image restricts `default` user to localhost

**Symptom**
Steps 1-5 of init-cluster.sh succeed (DDL via `ON CLUSTER` and local INSERTs work), but Distributed queries fail:
```
AUTHENTICATION_FAILED: default: Authentication failed: password is incorrect,
or there is no user with such name
```

**Root Cause**
The `clickhouse-server` Docker image auto-creates `/etc/clickhouse-server/users.d/default-user.xml` which restricts the `default` user to localhost:
```xml
<users><default><networks>
    <ip>::1</ip>
    <ip>127.0.0.1</ip>
</networks></default></users>
```
When a Distributed query on ch-s1r1 reaches out to ch-s2r2, it connects as `default` from a non-localhost IP → rejected.

`ON CLUSTER` DDL works because it goes through Keeper (not direct node-to-node connections).

**How We Found It**
The error message was clear: "Authentication failed". Checked what Docker injects:
```bash
docker exec ch-s1r1 ls /etc/clickhouse-server/users.d/
docker exec ch-s1r1 cat /etc/clickhouse-server/users.d/default-user.xml
```

**Fix**
Created `default-user-override.xml` and mounted it over the Docker-injected file:
```xml
<clickhouse>
    <users><default><networks>
        <ip>::/0</ip>
    </networks></default></users>
</clickhouse>
```
```yaml
volumes:
  - ./config/clickhouse/default-user-override.xml:/etc/clickhouse-server/users.d/default-user.xml:ro
```

**Lesson**
The ClickHouse Docker image injects its own config files in `config.d/` and `users.d/`. When providing custom configs, always check what the image adds:
```bash
docker exec <container> ls /etc/clickhouse-server/users.d/
docker exec <container> ls /etc/clickhouse-server/config.d/
```
These injected files merge with (and can override) your custom config.

---

## Bug 8: `SimpleAggregateFunction` type mismatch for Decimal

**Symptom**
Creating the Materialized View target table fails:
```
Incompatible data types between aggregate function 'sum' which returns
Decimal(38, 2) and column storage type Decimal(18, 2)
```

**Root Cause**
`sum(Decimal(18,2))` returns `Decimal(38,2)` (ClickHouse widens the precision to avoid overflow). The `SimpleAggregateFunction(sum, Decimal(18,2))` column type must match the return type exactly.

**Fix**
Changed the column definition:
```sql
-- before
total_amount SimpleAggregateFunction(sum, Decimal(18, 2))

-- after
total_amount SimpleAggregateFunction(sum, Decimal(38, 2))
```

**Lesson**
`SimpleAggregateFunction(func, Type)` — the `Type` must match the **return type** of the aggregate function, not the input type. For `sum`, the return type is widened to avoid overflow.
