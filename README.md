# dev-stack

Local infrastructure and orchestration for the two-repo platform: **guest-score**
and **market-mate**. One `make up` gives you PostgreSQL, Redis, Elasticsearch
and Mosquitto; one more gives you both applications on top.

Neither application repository knows this one exists. `dev-stack` builds their
images from sibling directories, so the coupling points one way only.

```
~/MyLib/github/
  guest-score/     Go stdlib backend + React 19/Vite frontend
  market-mate/     Go/gin backend + React 18/shadcn frontend
  dev-stack/       <- you are here
```

Everything in this repo is written against [`contract.md`](../contract.md) —
the authoritative list of service names, ports, env vars, image names, MQTT
topics and the Kubernetes layout. If something here disagrees with the
contract, the contract wins.

---

## Quick start

```sh
cp .env.example .env
make up            # infra only; blocks until everything is healthy
make smoke         # verify it
```

With both applications:

```sh
git clone <guest-score> ../guest-score
git clone <market-mate> ../market-mate
make up-all
```

`make help` lists every target.

---

## What runs

### Infrastructure (compose profile: default)

| Service | Image | Host port | Compose/cluster DNS |
|---|---|---|---|
| PostgreSQL | `postgres:17-alpine` | 5432 | `postgres` |
| Redis | `redis:7-alpine` | 6379 | `redis` |
| Elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch:8.15.3` | 9200 | `elasticsearch` |
| Mosquitto | `eclipse-mosquitto:2` | 1883, 9001 | `mosquitto` |

One Postgres server with two databases (`guestscore`, `marketmate`), created by
`postgres/init/01-databases.sh`. One Redis shared by logical DB index: Guest
Score owns 0, MarketMate owns 1.

### Applications (compose profile: `apps` / `all`)

| Service | Image | Port | Health |
|---|---|---|---|
| guest-score-api | `guest-score-api:dev` | 8090 | `GET /api/health` |
| guest-score-scoring | `guest-score-scoring:dev` | 9090 | gRPC `grpc.health.v1.Health` |
| guest-score-web | `guest-score-web:dev` | 5174 | `GET /` |
| marketmate-api | `marketmate-api:dev` | 8081 | `GET /api/health` |
| marketmate-web | `marketmate-web:dev` | 5173 | `GET /` |

Both APIs also serve `POST /graphql` and, when `*_GRAPHIQL=true`, an in-browser
explorer at `GET /graphiql`.

---

## Every dependency is optional

This is the rule that shapes the whole stack. Unset an env var and the feature
degrades to what the application does with no infrastructure at all:

| Unset | Falls back to |
|---|---|
| `GS_POSTGRES_DSN` | JSON `FileStore` |
| `GS_REDIS_ADDR` | no-op cache (every read is a miss) |
| `GS_ELASTIC_URL` | in-process substring search |
| `GS_MQTT_URL` | event ingest disabled |
| `GS_SCORING_GRPC` | scoring computed in-process |
| `MM_POSTGRES_DSN` | no durable transcript/extraction cache |
| `MM_REDIS_ADDR` | in-memory `go-cache` |
| `MM_ELASTIC_URL` | linear scan over cached recipes |

So `go run ./cmd/server` works with zero infrastructure, CI needs no
containers, and if Elasticsearch is what makes your laptop unhappy you can just
turn it off.

---

## Layout

```
dev-stack/
  docker-compose.yml                infra (default) + apps (profiles: apps, all)
  docker-compose.override.yml.example   per-developer tweaks, gitignored
  .env.example                      every variable, with the contract's defaults
  Makefile                          make help

  postgres/
    init/01-databases.sh            roles + DBs, POSIX sh, idempotent
    postgresql.conf                 laptop tuning + slow query log
  mosquitto/
    mosquitto.conf                  local: anonymous; prod reference in comments
    README.md
  elasticsearch/
    README.md                       vm.max_map_count, memory sizing, why yellow

  kind/cluster.yaml                 cluster "guest-platform", ingress + ports 80/443
  k8s/
    base/                           Namespace, ConfigMaps, Secret, workloads, Ingress
      config/                       GENERATED copies — see "Config duplication"
    overlays/local/                 1 replica, pullPolicy Never, GraphiQL on
    overlays/prod/                  3 API replicas, HPA, PDB, GraphiQL off, real secrets

  scripts/
    wait-for-healthy.sh             block until compose health goes green
    smoke.sh                        end-to-end checks, colourised, skips what is down
  docs/
    HOMEBREW.md                     the genuine no-Docker path on macOS
    RUNBOOK.md                      day-to-day commands and failure modes
```

---

## Compose profiles

- **no profile — infra.** `docker compose up -d` starts only the four
  infrastructure services. This is the default *on purpose*: the app services
  build from sibling directories that may not be checked out, and a fresh clone
  of `dev-stack` alone must still work.
- **`apps`** — the five application services.
- **`all`** — infra + apps.

```sh
make up-infra      # docker compose up -d
make up-all        # docker compose --profile all up -d --build
```

Compose never evaluates the build context of a service whose profile is
inactive, so a missing `../market-mate` cannot break `make up-infra`.
`make up-all` checks for the sibling repos up front and prints a readable
message instead of a buildkit stack trace.

---

## Health, not hope

Every infrastructure service has a real healthcheck — not a `sleep`:

| Service | Probe | Why this one |
|---|---|---|
| postgres | `pg_isready` | proves the server accepts connections, not just that the port is bound |
| redis | `redis-cli ping \| grep PONG` | a TCP check passes while Redis is blocked |
| elasticsearch | `_cluster/health?wait_for_status=yellow` | yellow is correct on a single node; red is not |
| mosquitto | `mosquitto_sub … -E` | exits on SUBACK, so it proves subscriptions work |

The application services then use `depends_on: {condition: service_healthy}`,
which is why `make up-all` does not produce the usual first-boot crash loop.

`scripts/wait-for-healthy.sh` (run automatically by `make up`) blocks until
every running service is green and dumps the logs of anything that is not.

---

## Volumes

Named volumes for `pgdata` and `esdata`: the databases and the Lucene indices
are expensive to rebuild and must survive `make down`.

**Redis deliberately has no volume.** It is a pure cache — every key is
derivable from Postgres or Elasticsearch, and every read path tolerates a miss.
Persisting it would only let a stale RDB outlive a schema change and produce
bugs that look impossible. The container is started with `--save ""
--appendonly no` so it never writes to disk at all.

`make clean` is the only thing that deletes `pgdata`/`esdata`, and it prompts.

---

## Kubernetes

Namespace `guest-platform`, Kustomize base + two overlays.

```sh
make kind-up       # create the cluster, install ingress-nginx
make kind-load     # build and side-load the app images (pullPolicy is Never)
make k8s-apply     # OVERLAY=local by default
make k8s-status
```

- http://guest-score.localtest.me
- http://marketmate.localtest.me

`localtest.me` resolves to 127.0.0.1 in public DNS, so nothing needs to go in
`/etc/hosts`. Infra is also exposed on the host at **offset** ports (15432,
16379, 19200, 11883) so it can never be confused with the compose stack.

Design notes worth knowing before you read the manifests:

- **Postgres and Elasticsearch are StatefulSets** with `volumeClaimTemplates`.
  Redis and Mosquitto are Deployments with an emptyDir, because neither has
  state worth keeping and neither clusters.
- **The scoring service uses the native `grpc:` probe** (k8s ≥ 1.24). The image
  is distroless, so there is no shell to exec `grpc_health_probe` from — the
  kubelet speaks `grpc.health.v1.Health` itself.
- **Each API has a `wait-for-postgres` initContainer.** There is no migration
  Job: the apps migrate on boot (`GS_MIGRATE`/`MM_MIGRATE`). But migrating on
  boot means the container hard-fails if Postgres is not ready, and
  CrashLoopBackOff's exponential backoff turns a 20-second database start into
  a 5-minute app start.
- **Everything runs non-root**, drops all capabilities, and uses
  `readOnlyRootFilesystem` wherever the image tolerates it. The namespace
  enforces the `restricted` Pod Security Standard so a future manifest cannot
  quietly regress. Elasticsearch is the one exception on the read-only root: its
  entrypoint writes a keystore into its own config directory at startup.
- **Ingress is host-based, not path-based.** Both products serve a SPA at `/`
  and an API at `/api` + `/graphql`; those collide, and mounting one under a
  sub-path would mean rebuilding the Vite bundle with a matching base href.

`overlays/local` — 1 replica, `imagePullPolicy: Never`, GraphiQL on, fixtures
on, tiny resource requests, small PVCs, `*.localtest.me`.

`overlays/prod` — 3 API replicas, HPA (3–12), PodDisruptionBudgets, GraphiQL
off and no `/graphiql` route, fixtures off, Elasticsearch security **on**,
larger PVCs on a real StorageClass, `imagePullPolicy: IfNotPresent`, and the
fake Secret deleted from the output so a real cluster's credentials cannot be
overwritten. It is a *shape*, not a turnkey deployment — read
[`k8s/overlays/prod/README.md`](k8s/overlays/prod/README.md), which also lists
honestly what is still missing (no Postgres HA, no NetworkPolicies, single-node
ES).

### Config duplication, and the check that keeps it honest

`mosquitto.conf`, `postgresql.conf` and `01-databases.sh` are consumed twice:
bind-mounted by compose from their canonical paths, and baked into ConfigMaps
by kustomize from copies in `k8s/base/config/`.

The copies exist because kustomize refuses to read a file outside its
kustomization root (and resolves symlinks before checking, so a symlink does
not help). The alternative — requiring `--load-restrictor=LoadRestrictionsNone`
on every build — turns a plain `kustomize build k8s/overlays/local` into a
failure, which is a trap.

So the duplication is guarded:

```sh
make k8s-sync-config     # refresh the copies from the canonical files
make k8s-check-config    # fail on drift — runs inside k8s-apply and validate
```

---

## Without Docker

`docs/HOMEBREW.md` is the real no-Docker path on macOS: `brew install
postgresql@17 redis mosquitto`, creating the two databases by hand, the `.env`
values that change (localhost instead of service DNS), and an honest account of
the Elasticsearch situation — it is no longer in Homebrew core, `elastic/tap`
is deprecated, and your options are a single Docker container, the official
tarball, or simply leaving `GS_ELASTIC_URL` empty.

```sh
make brew-install brew-start brew-createdb
```

---

## Validating a change

```sh
make validate
```

Runs `docker compose config` for both profiles, builds both kustomize overlays
and parses the YAML, syntax-checks and shellchecks the scripts, and verifies
`k8s/base/config/` has not drifted. It needs no running Docker daemon.

---

## Further reading

- [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — day-to-day commands, resetting a
  database, reindexing ES, inspecting the MQTT bus, and the failures you will
  actually hit (ES OOM, port in use, stale Postgres volume, kind image not
  loaded).
- [`elasticsearch/README.md`](elasticsearch/README.md) — `vm.max_map_count`,
  heap sizing, why the cluster is yellow and why security is off locally.
- [`mosquitto/README.md`](mosquitto/README.md) — the topic scheme, publishing
  test events, and clearing a stale retained LWT.
- [`k8s/overlays/prod/README.md`](k8s/overlays/prod/README.md) — what you must
  supply before a real deployment.
