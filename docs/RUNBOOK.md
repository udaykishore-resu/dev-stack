# Runbook

Day-to-day operation of the dev-stack, and what to do when it breaks.

`make help` is the index; this is the prose.

---

## Daily loop

```sh
make up            # infra only — postgres, redis, elasticsearch, mosquitto
make ps            # container status + health column
make smoke         # verify everything that is up
make logs S=postgres
make down          # stop, keep the data
```

Working on both applications too:

```sh
make up-all        # builds the images and starts infra + apps
```

`make up` blocks until every service reports healthy (`scripts/wait-for-healthy.sh`),
so when it returns the stack is genuinely usable — not merely created.

### Where things listen

| Service | Host | In-cluster / compose DNS |
|---|---|---|
| PostgreSQL | `localhost:5432` | `postgres:5432` |
| Redis | `localhost:6379` | `redis:6379` |
| Elasticsearch | `localhost:9200` | `elasticsearch:9200` |
| Mosquitto | `localhost:1883`, ws `9001` | `mosquitto:1883` |
| guest-score-api | `localhost:8090` | `guest-score-api:8090` |
| guest-score-scoring | `localhost:9090` (gRPC) | `guest-score-scoring:9090` |
| guest-score-web | `localhost:5174` | `guest-score-web:5174` |
| marketmate-api | `localhost:8081` | `marketmate-api:8081` |
| marketmate-web | `localhost:5173` | `marketmate-web:5173` |

Health: `GET /api/health` on both APIs, `GET /` on both webs, gRPC
`grpc.health.v1.Health` on scoring.

### Running only some infra

Every dependency is optional (contract.md). To drop Elasticsearch:

```sh
docker compose stop elasticsearch
# and blank GS_ELASTIC_URL / MM_ELASTIC_URL in .env
```

The apps fall back to in-process search. Same pattern for Redis (no-op cache),
MQTT (ingest disabled) and even Postgres (Guest Score uses a JSON FileStore).

---

## Databases

### Get a shell

```sh
make psql                 # guestscore
make psql DB=marketmate
make psql DB=postgres     # the maintenance DB
```

### Inspect

```sql
\l                         -- databases
\du                        -- roles
\dt                        -- tables in the current DB
\d+ guests                 -- one table
SELECT pg_size_pretty(pg_database_size(current_database()));
```

### Reset ONE database, keep the other

The usual case: your migrations changed and you want a clean Guest Score
without touching MarketMate.

```sh
docker compose exec postgres psql -U postgres -d postgres <<'SQL'
-- Kick existing connections first: DROP DATABASE fails while the app holds a
-- pool open, and the error ("is being accessed by other users") does not say
-- which connection.
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE datname = 'guestscore' AND pid <> pg_backend_pid();

DROP DATABASE guestscore;
CREATE DATABASE guestscore OWNER guestscore;
SQL

docker compose exec postgres psql -U postgres -d guestscore <<'SQL'
ALTER SCHEMA public OWNER TO guestscore;
GRANT ALL ON SCHEMA public TO guestscore;
SQL

docker compose restart guest-score-api    # GS_MIGRATE=true re-creates the schema
```

Faster alternative when you only want the data gone, not the schema:

```sh
docker compose exec postgres psql -U guestscore -d guestscore \
  -c "TRUNCATE guests, stays, incidents RESTART IDENTITY CASCADE"
```

### Reset BOTH databases from scratch

```sh
make clean      # prompts, then removes dev-stack-pgdata and dev-stack-esdata
make up
```

This is the only thing that re-runs `postgres/init/01-databases.sh`. See the
stale-volume entry in [Common failures](#common-failures) for why that matters.

### Back up and restore

```sh
docker compose exec -T postgres pg_dump -U postgres -Fc guestscore > guestscore.dump
docker compose exec -T postgres pg_restore -U postgres -d guestscore --clean --if-exists < guestscore.dump
```

### Find slow queries

`postgresql.conf` logs anything over 200 ms.

```sh
docker compose logs postgres | grep 'duration:'
```

To log everything for a minute while reproducing something:

```sh
docker compose exec postgres psql -U postgres -c "ALTER SYSTEM SET log_min_duration_statement = 0"
docker compose exec postgres psql -U postgres -c "SELECT pg_reload_conf()"
# ... reproduce ...
docker compose exec postgres psql -U postgres -c "ALTER SYSTEM RESET log_min_duration_statement"
docker compose exec postgres psql -U postgres -c "SELECT pg_reload_conf()"
```

(`ALTER SYSTEM` writes `postgresql.auto.conf` in the data directory, which is a
volume, so this survives a restart — remember to reset it.)

### See what is connected right now

```sql
SELECT datname, usename, application_name, state, query_start, left(query, 60)
  FROM pg_stat_activity
 WHERE backend_type = 'client backend'
 ORDER BY query_start;
```

---

## Redis

```sh
make redis-cli          # DB 0 — Guest Score
make redis-cli N=1      # DB 1 — MarketMate
```

```sh
redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
redis-cli --scan --pattern 'guest:*' | head
redis-cli -n 0 DBSIZE
redis-cli -n 0 FLUSHDB          # drop Guest Score's cache only
redis-cli FLUSHALL              # drop everything
redis-cli --stat                # live ops/sec, one line per second
redis-cli MONITOR               # every command; expensive, Ctrl-C promptly
```

There is no persistence and no volume, so "reset Redis" is
`docker compose restart redis`. Nothing is lost that was not derivable.

---

## MQTT

Watch everything:

```sh
make mqtt-sub          # mosquitto_sub -t 'guestscore/#' -v
```

Publish a sample incident:

```sh
make mqtt-pub
make mqtt-pub T='guestscore/prop_del_02/events' M='{"event_id":"evt_x","type":"commendation","property_id":"prop_del_02"}'
```

Topics (contract.md):

```
guestscore/{property_id}/events    property -> backend
guestscore/{property_id}/status    retained LWT: "online"/"offline"
guestscore/_bureau/acks            backend -> property
```

Confirm the backend is acking what you publish:

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t 'guestscore/_bureau/acks' -v
```

Broker internals — client count, dropped messages, uptime:

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t '$SYS/#' -v -W 3
```

Retained status messages only (does not wait for live traffic):

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t 'guestscore/+/status' -v -W 2
```

Clear a stale retained status — publish an empty retained message:

```sh
docker compose exec mosquitto mosquitto_pub -h localhost -r -n -t 'guestscore/prop_mum_01/status'
```

### Events publish but nothing happens

In order:

1. Is ingest even on? `docker compose exec guest-score-api env | grep GS_MQTT_URL`
   — empty means ingest is disabled by design.
2. Does the topic match the filter? `GS_MQTT_TOPIC=guestscore/+/events`. The
   `+` matches exactly **one** segment: `guestscore/prop_mum_01/events` matches,
   `guestscore/in/prop_mum_01/events` does not.
3. Is the payload valid JSON with an `event_id`? Malformed events are dropped.
4. Is it a **duplicate**? The worker deduplicates on `event_id` so an
   at-least-once redelivery cannot double-penalise a guest. Re-publishing the
   same `evt_7f3a` is a no-op. Change the id.
5. `docker compose logs -f guest-score-api | grep -i mqtt`

---

## Elasticsearch

```sh
make es-health
curl -s 'localhost:9200/_cat/indices?v'
curl -s 'localhost:9200/_cat/shards?v'
curl -s 'localhost:9200/guest-score-guests/_count'
curl -s 'localhost:9200/guest-score-guests/_search?size=2&pretty'
```

**Yellow is the correct steady state.** One node, and the default template asks
for one replica that can never be allocated to the same node as its primary.
Only red — an unallocated *primary* — is a problem.

### Reindex

Both apps build their index on boot when it is missing, so the reliable reset
is delete-then-restart:

```sh
curl -X DELETE localhost:9200/guest-score-guests
docker compose restart guest-score-api

curl -X DELETE localhost:9200/marketmate-recipes
docker compose restart marketmate-api
```

Watch it repopulate:

```sh
watch -n1 "curl -s 'localhost:9200/_cat/indices/guest-score-*?v'"
```

If you need to change a mapping without losing data, use the reindex API into
a new index and swap an alias:

```sh
curl -X PUT localhost:9200/guest-score-guests-v2 -H 'Content-Type: application/json' -d '{"mappings":{...}}'
curl -X POST localhost:9200/_reindex -H 'Content-Type: application/json' -d '{
  "source":{"index":"guest-score-guests"},
  "dest":{"index":"guest-score-guests-v2"}
}'
```

### Force green on a single node

```sh
curl -X PUT localhost:9200/_settings -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
```

### Indices went read-only

Usually a disk watermark. The container disables the watermark, but if you hit
it anyway:

```sh
curl -X PUT 'localhost:9200/_all/_settings' -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

---

## Kubernetes (kind)

```sh
make kind-up         # create the cluster + ingress-nginx
make kind-load       # build the app images and side-load them
make k8s-apply       # kustomize build overlays/local | kubectl apply -f -
make k8s-status
```

Then:

- http://guest-score.localtest.me
- http://marketmate.localtest.me

`localtest.me` resolves to `127.0.0.1` in public DNS, so no `/etc/hosts` edit.

Infra is reachable from the host on **offset** ports, so it cannot be confused
with the compose stack:

| | kind | compose |
|---|---|---|
| Postgres | `localhost:15432` | `localhost:5432` |
| Redis | `localhost:16379` | `localhost:6379` |
| Elasticsearch | `localhost:19200` | `localhost:9200` |
| MQTT | `localhost:11883` | `localhost:1883` |

```sh
make k8s-build OVERLAY=prod | less     # render prod without applying
make k8s-delete                        # remove (PVCs survive)
make kind-down                         # destroy the cluster
```

### After changing mosquitto.conf, postgresql.conf or the init script

Those files are read by compose from their canonical path and by kustomize from
a copy in `k8s/base/config/` (kustomize refuses to read outside its root).

```sh
make k8s-sync-config     # refresh the copies
make k8s-check-config    # fail on drift; runs automatically inside k8s-apply
```

---

## Common failures

### Elasticsearch exits with code 137

The OOM killer. 137 = 128 + 9 (SIGKILL).

```sh
docker compose logs elasticsearch | tail -30
docker inspect dev-stack-elasticsearch --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
```

Fix, in order:

1. **Give Docker more memory.** Docker Desktop → Settings → Resources →
   Memory. 4 GB minimum for this stack, 6 GB comfortable.
2. Do **not** shrink `ES_JAVA_OPTS` to "make it fit". Below ~400 MB heap ES
   full-GC thrashes: everything gets slow instead of failing, which is much
   harder to diagnose. The container needs ~2x the heap because Lucene's
   segment cache is off-heap.
3. If you have no memory to spare, turn ES off entirely — both apps degrade
   gracefully (see [Running only some infra](#running-only-some-infra)).

### Elasticsearch will not start: `max virtual memory areas vm.max_map_count [65530] is too low`

Linux only (including WSL2 and Colima). Node-level kernel setting:

```sh
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

Docker Desktop for macOS already ships this. Full detail in
`elasticsearch/README.md`.

### Port already in use

```
Error: bind: address already in use
```

Find the owner:

```sh
lsof -nP -iTCP:5432 -sTCP:LISTEN     # macOS/Linux
ss -ltnp 'sport = :5432'             # Linux
```

The usual suspects are a Homebrew `postgresql@17` / `redis` / `mosquitto`
(`brew services stop postgresql@17`) or a container from another project
(`docker ps --filter publish=5432`).

Either free the port or move ours — `.env`:

```sh
POSTGRES_PORT=55432
```

Only the **host** side of the mapping changes; nothing inside the compose
network is affected, so no DSN needs editing.

### Postgres volume with a stale schema

Symptom: migrations fail with "column already exists" or "relation does not
exist"; a password change in `.env` has no effect; a role you added to
`01-databases.sh` is missing.

Cause: **`postgres/init/01-databases.sh` runs exactly once**, on an empty data
directory. `dev-stack-pgdata` is a named volume, so it survives `make down`,
`docker compose down`, image upgrades and edits to the init script. Everything
in that script is invisible to an existing volume.

Confirm:

```sh
docker volume inspect dev-stack-pgdata --format '{{.CreatedAt}}'
docker compose exec postgres psql -U postgres -c '\du'   # is the role there?
```

Fix — nuclear:

```sh
make clean && make up
```

Fix — surgical, when you cannot lose the data (apply the same SQL by hand):

```sh
docker compose exec postgres psql -U postgres -d postgres <<'SQL'
SET password_encryption = 'scram-sha-256';
ALTER ROLE guestscore WITH LOGIN PASSWORD 'new-password';
SQL
```

### kind: `ErrImageNeverPull` / `ErrImagePull`

`overlays/local` sets `imagePullPolicy: Never`, because kind has no registry
and images arrive via `kind load docker-image`. `ErrImageNeverPull` means the
image is not in the node.

```sh
docker exec -it guest-platform-control-plane crictl images | grep guest-score
make kind-load
kubectl -n guest-platform rollout restart deployment/guest-score-api
```

Two things bite here:

- **`kind load` copies the image once.** Rebuilding it locally does not update
  the node. Every rebuild needs another `make kind-load`.
- **The tag must match exactly.** `guest-score-api:dev`, not `latest`. A
  mismatch shows as `ErrImageNeverPull` with no hint about which tag was wanted
  — `kubectl -n guest-platform describe pod <name>` shows the image it looked
  for.

`ErrImagePull` (as opposed to `Never`) on an *infra* image means the node
genuinely could not reach Docker Hub; that one is a network or rate-limit
problem.

### Pods stuck Pending

```sh
kubectl -n guest-platform describe pod <name> | tail -20
```

- `Insufficient cpu/memory` — the kind node is too small. Raise Docker's
  memory, or trim requests further in `overlays/local/patch-infra-small.yaml`.
- `pod has unbound immediate PersistentVolumeClaims` — normal for a few
  seconds; if it persists, `kubectl get sc` (kind ships `standard` as default).
- `node(s) had untolerated taint` — the ingress-nginx controller needs the
  `ingress-ready=true` label from `kind/cluster.yaml`.

### Ingress returns 404 for every path

```sh
kubectl -n ingress-nginx get pods
kubectl -n guest-platform get ingress
```

Causes, in order of likelihood:

1. ingress-nginx not installed — `make kind-up` does it; if you created the
   cluster by hand, apply the controller manifest.
2. Wrong `Host` header. The rules are host-based (both apps own `/`), so
   `curl localhost` gets nothing. Use `curl -H 'Host: guest-score.localtest.me'
   localhost` or the hostname directly.
3. Controller Pending because the node lacks `ingress-ready=true`.

### `depends_on: service_healthy` hangs forever

One of the infra healthchecks never goes green.

```sh
make ps                                        # look at the health column
docker inspect dev-stack-elasticsearch --format '{{json .State.Health}}' | python3 -m json.tool
```

The `Health.Log` array contains the last few probe outputs including stderr,
which is usually the whole answer.

### `make up-all` fails with "missing sibling repo"

The app profile builds from `../guest-score` and `../market-mate`. Either clone
them beside `dev-stack`, or point `.env` at where they actually are:

```sh
GUEST_SCORE_PATH=../guest-score
MARKET_MATE_PATH=../marketmate      # note: some clones use no hyphen
```

`make up-infra` never needs them.

### Everything is slow after a long session

```sh
docker system df                 # how much is build cache
docker builder prune             # reclaim build cache only
docker system prune              # containers/networks/dangling images
```

`docker system prune --volumes` would also delete `dev-stack-pgdata`. Do not
use it unless you mean `make clean`.

---

## Complete reset

```sh
make down
make clean            # prompts; deletes pgdata + esdata
make kind-down        # if you created a cluster
docker builder prune -f
make up
make smoke
```
