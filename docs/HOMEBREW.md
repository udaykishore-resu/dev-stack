# Running the stack without Docker (macOS + Homebrew)

For when Docker Desktop is not installed, not licensed, or eating your battery.
This path gets you PostgreSQL, Redis and Mosquitto natively. **Elasticsearch is
the awkward one — read that section before you start.**

Everything here is macOS. On Linux use your distro's packages; the database and
config steps are identical.

---

## TL;DR

```sh
brew install postgresql@17 redis mosquitto     # make brew-install
brew services start postgresql@17 redis mosquitto   # make brew-start
make brew-createdb                              # roles + databases
# Elasticsearch: see below — either a single Docker container or the tarball,
# or just leave GS_ELASTIC_URL / MM_ELASTIC_URL empty.
```

Then run the apps with `.env.local` (see [Environment](#environment)).

---

## PostgreSQL 17

```sh
brew install postgresql@17
brew services start postgresql@17
```

`postgresql@17` is **keg-only** — Homebrew does not symlink it into `/usr/local`
or `/opt/homebrew` because it conflicts with other major versions. `psql` will
not be on your PATH until you add it:

```sh
# Apple silicon
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
# Intel
echo 'export PATH="/usr/local/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
exec $SHELL -l
psql --version    # should say 17.x
```

### Two important differences from the container

1. **There is no `postgres` superuser.** Homebrew's `initdb` creates a
   superuser named after your macOS account, and it uses **trust** auth on
   local connections. `psql -d postgres` just works with no password; `psql -U
   postgres` fails with "role postgres does not exist".
2. **The init script does not run.** `postgres/init/01-databases.sh` is wired
   into the container entrypoint. On Homebrew you create the roles and
   databases yourself.

### Creating the two databases

`make brew-createdb` does this, and is idempotent. By hand:

```sh
psql -d postgres <<'SQL'
SET password_encryption = 'scram-sha-256';

CREATE ROLE guestscore WITH LOGIN PASSWORD 'guestscore';
CREATE ROLE marketmate WITH LOGIN PASSWORD 'marketmate';
SQL

createdb -O guestscore guestscore
createdb -O marketmate marketmate

# The public schema is no longer world-writable as of PG 15, so the owner
# needs it explicitly before the apps' boot migrations can create tables.
psql -d guestscore -c 'ALTER SCHEMA public OWNER TO guestscore'
psql -d marketmate -c 'ALTER SCHEMA public OWNER TO marketmate'
```

Verify:

```sh
psql -d postgres -c '\du'    # roles
psql -d postgres -c '\l'     # databases
PGPASSWORD=guestscore psql -h 127.0.0.1 -U guestscore -d guestscore -c 'SELECT 1'
```

That last command is the one that matters: it goes over TCP with a password,
the same way the app connects. If it fails with "no password supplied" your
`pg_hba.conf` is set to `trust` for host connections — fine for local work, but
it means the DSN's password is being ignored, not validated.

### Config

Homebrew's data directory and config live at:

```
/opt/homebrew/var/postgresql@17/postgresql.conf     # Apple silicon
/usr/local/var/postgresql@17/postgresql.conf        # Intel
```

`postgres/postgresql.conf` in this repo is written for the container (it
replaces the whole file). Do not copy it wholesale over the Homebrew one — it
omits Homebrew-specific paths. If you want the slow query log, append just
these lines:

```conf
log_min_duration_statement = 200ms
log_statement = 'ddl'
log_line_prefix = '%m [%p] %q%u@%d %a '
```

then `brew services restart postgresql@17`.

Logs: `tail -f /opt/homebrew/var/log/postgresql@17.log`

---

## Redis

```sh
brew install redis
brew services start redis
redis-cli ping        # PONG
```

Nothing to configure. Guest Score uses logical DB 0 and MarketMate DB 1, which
works out of the box (Homebrew's default is 16 databases).

One thing worth changing: Homebrew's Redis **persists to disk** by default
(`~/.redis/dump.rdb` or `/opt/homebrew/var/db/redis/`). The container
deliberately does not, because a stale RDB surviving a schema change causes
"impossible" cache bugs. To match:

```sh
redis-cli CONFIG SET save ""
redis-cli CONFIG SET appendonly no
```

Or permanently, in `/opt/homebrew/etc/redis.conf`: comment out every `save`
line and set `appendonly no`, then `brew services restart redis`.

To wipe the cache at any time: `redis-cli FLUSHALL`.

---

## Mosquitto

```sh
brew install mosquitto
brew services start mosquitto
```

**Mosquitto 2.x defaults bite here too.** Homebrew's default config listens on
`127.0.0.1:1883` and — unlike a bare mosquitto 2 — Homebrew ships a config that
usually allows anonymous local connections. Check:

```sh
mosquitto_sub -h localhost -t 'test' -E     # should exit 0 immediately
```

If it fails with `Connection Refused: not authorised`, edit
`/opt/homebrew/etc/mosquitto/mosquitto.conf` and add:

```conf
listener 1883 127.0.0.1
allow_anonymous true
```

then `brew services restart mosquitto`.

You can also point Homebrew's mosquitto straight at this repo's config, which
keeps the two paths identical:

```sh
brew services stop mosquitto
mosquitto -c "$PWD/mosquitto/mosquitto.conf" -v
```

(Run in the foreground; `-v` shows every publish and subscribe.)

Test the round trip:

```sh
mosquitto_sub -h localhost -t 'guestscore/#' -v &
mosquitto_pub -h localhost -q 1 -t 'guestscore/prop_mum_01/events' -m '{"event_id":"evt_1","type":"check_in","property_id":"prop_mum_01"}'
```

---

## Elasticsearch — the honest situation

**There is no `brew install elasticsearch` that gives you a current version.**

What happened:

- Elasticsearch was removed from Homebrew core after Elastic relicensed it
  (SSPL/Elastic License 2.0 in 7.11); Homebrew core only accepts open-source
  licences. The formula that lingered was 7.17.x, the last Apache-2.0 build.
- Elastic ran their own `elastic/tap` with `elasticsearch-full`. **That tap is
  deprecated and no longer maintained** — Elastic's own docs now point at
  Docker or the archive downloads. Adding it today either fails or installs
  something years old.
- `brew install elasticsearch` today either errors, or installs
  `elasticsearch@7` from a third-party tap. Version 7 will not work: this stack
  is written against 8.15.3 API behaviour.

So pick one of three. In rough order of how much most people should prefer them:

### Option A — don't run it (genuinely fine)

Both apps treat Elasticsearch as optional. Leave the URLs empty:

```sh
GS_ELASTIC_URL=
MM_ELASTIC_URL=
```

Guest Score falls back to in-process substring search over the store;
MarketMate does a linear scan over cached recipes. Search results differ in
ranking and you lose fuzzy matching, but every endpoint keeps working and the
test suite passes. If you are working on anything other than search, do this.

### Option B — Docker for Elasticsearch only

You said no Docker, but "no Docker Desktop for the whole stack" and "one
container for ES" are different amounts of pain. This is the closest match to
what CI and the compose stack run:

```sh
docker run -d --name es \
  -p 9200:9200 \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  docker.elastic.co/elasticsearch/elasticsearch:8.15.3
```

Works with Colima, Rancher Desktop, OrbStack or podman just as well as Docker
Desktop:

```sh
brew install colima docker && colima start --memory 4
```

### Option C — the official tarball

No package manager, no container. Elastic publishes signed macOS archives.

```sh
# Apple silicon; use x86_64 on Intel
VER=8.15.3
curl -O "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${VER}-darwin-aarch64.tar.gz"
curl -O "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-${VER}-darwin-aarch64.tar.gz.sha512"
shasum -a 512 -c "elasticsearch-${VER}-darwin-aarch64.tar.gz.sha512"

tar -xzf "elasticsearch-${VER}-darwin-aarch64.tar.gz"
cd "elasticsearch-${VER}"
```

Disable security to match the contract's `http://localhost:9200`, in
`config/elasticsearch.yml`:

```yaml
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
```

Set the heap in `config/jvm.options.d/heap.options`:

```
-Xms512m
-Xmx512m
```

Run it:

```sh
./bin/elasticsearch
```

macOS will quarantine the downloaded binaries. If Gatekeeper blocks it:
`xattr -dr com.apple.quarantine .` inside the extracted directory.

There is no `brew services` integration; use a `launchd` plist or just keep a
terminal open. To keep it running in the background:

```sh
./bin/elasticsearch -d -p pid
kill "$(cat pid)"     # to stop
```

Verify any of the three options:

```sh
curl -s localhost:9200 | head
curl -s 'localhost:9200/_cluster/health?pretty'   # yellow is correct
```

---

## brew services reference

```sh
brew services list                    # what is running, and whether it errored
brew services start   postgresql@17
brew services stop    postgresql@17
brew services restart postgresql@17
brew services info    postgresql@17   # PID, log path, plist location
```

`make brew-start` / `make brew-stop` do all three services at once.

Logs live in `/opt/homebrew/var/log/`. When a service shows `error` in
`brew services list`, that directory is the first place to look — the exit
status alone tells you nothing.

---

## Environment

The container `.env` uses **service DNS names** (`postgres`, `redis`,
`elasticsearch`, `mosquitto`) because the apps run inside the compose network.
On the Homebrew path everything is on `localhost`, and Postgres has no
`postgres` superuser.

Keep them separate — `.env` for containers, `.env.local` for native:

```sh
# .env.local  — the no-Docker path

# Guest Score
GS_ADDR=:8090
GS_POSTGRES_DSN=postgres://guestscore:guestscore@localhost:5432/guestscore?sslmode=disable
GS_POSTGRES_MAX_CONNS=10
GS_MIGRATE=true
GS_REDIS_ADDR=localhost:6379
GS_REDIS_DB=0
GS_CACHE_TTL=60s
GS_ELASTIC_URL=http://localhost:9200        # or empty — see Option A
GS_ELASTIC_INDEX=guest-score-guests
GS_MQTT_URL=tcp://localhost:1883
GS_MQTT_CLIENT_ID=guest-score-ingest
GS_MQTT_TOPIC=guestscore/+/events
GS_SCORING_GRPC=localhost:9090              # or empty to score in-process
GS_GRAPHQL=true
GS_GRAPHIQL=true
GS_SEED=true

# MarketMate
PORT=8081
MM_POSTGRES_DSN=postgres://marketmate:marketmate@localhost:5432/marketmate?sslmode=disable
MM_MIGRATE=true
MM_REDIS_ADDR=localhost:6379
MM_REDIS_DB=1
MM_ELASTIC_URL=http://localhost:9200        # or empty
MM_ELASTIC_INDEX=marketmate-recipes
MM_STORE_CACHE_TTL=15m
MM_GRAPHQL=true
MM_GRAPHIQL=true
USE_FIXTURES=true
```

The only differences from the container values are the hostnames (`localhost`
everywhere instead of service DNS) and, if you dropped Elasticsearch, the two
empty URLs.

---

## Running the apps

Both are Go binaries with an embedded or sibling SPA. From each repo:

```sh
cd ../guest-score/backend
set -a; . ../../dev-stack/.env.local; set +a
go run ./cmd/server
```

```sh
# the gRPC scoring service, in a second terminal
cd ../guest-score/backend
set -a; . ../../dev-stack/.env.local; set +a
GS_GRPC_ADDR=:9090 go run ./cmd/scoring
```

```sh
cd ../market-mate/backend
set -a; . ../../dev-stack/.env.local; set +a
go run ./cmd/server
```

Front-ends, each in its own terminal:

```sh
cd ../guest-score/frontend && VITE_API_BASE_URL=http://localhost:8090 npm run dev -- --port 5174
cd ../market-mate/frontend && VITE_API_BASE_URL=http://localhost:8081 npm run dev -- --port 5173
```

`set -a` marks everything sourced afterwards for export, so a plain `KEY=value`
file becomes environment variables without a `export` on every line. `set +a`
turns it back off.

### Smoke test

`scripts/smoke.sh` drives the compose stack (`docker compose exec`), so it does
not apply here. The equivalent by hand:

```sh
PGPASSWORD=guestscore psql -h 127.0.0.1 -U guestscore -d guestscore -c 'SELECT 1'
PGPASSWORD=marketmate psql -h 127.0.0.1 -U marketmate -d marketmate -c 'SELECT 1'
redis-cli ping
curl -s 'localhost:9200/_cluster/health?pretty' | grep status
mosquitto_sub -h localhost -t 'guestscore/#' -C 1 -W 3 &
mosquitto_pub -h localhost -q 1 -t 'guestscore/x/events' -m '{"event_id":"e1"}'
curl -fsS localhost:8090/api/health
curl -fsS localhost:8081/api/health
curl -fsS -X POST localhost:8090/graphql -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}'
curl -fsS -X POST localhost:8081/graphql -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}'
```

---

## Known friction on this path

| Symptom | Cause | Fix |
|---|---|---|
| `psql: command not found` | postgresql@17 is keg-only | add its `bin` to PATH (above) |
| `role "postgres" does not exist` | Homebrew's superuser is your username | use `psql -d postgres`, or `CREATE ROLE postgres SUPERUSER LOGIN` |
| App connects but sees no tables | connected to the wrong Postgres (a leftover container on 5432) | `lsof -i :5432` and stop one of them |
| `Connection Refused: not authorised` from MQTT | mosquitto 2 default | `allow_anonymous true` in the Homebrew config |
| Cache returns data you deleted | Homebrew Redis persists; the container does not | `redis-cli FLUSHALL`, disable `save` |
| ES 7 installed from a random tap | see the Elasticsearch section | use 8.15.3 via Docker or the tarball |
| Ports 5432/6379/1883 already busy | compose stack still running | `make down`, or change `POSTGRES_PORT` etc. in `.env` |
