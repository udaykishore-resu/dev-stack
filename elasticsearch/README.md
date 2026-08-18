# Elasticsearch in dev-stack

- Image: `docker.elastic.co/elasticsearch/elasticsearch:8.15.3`
- HTTP: `9200` (host and in-cluster). Transport `9300` is deliberately not published.
- In-cluster DNS: `elasticsearch`
- Indices: `guest-score-guests`, `marketmate-recipes`

Both apps treat ES as optional. Unset `GS_ELASTIC_URL` and Guest Score falls
back to an in-process substring search; unset `MM_ELASTIC_URL` and MarketMate
does a linear scan over cached recipes. So if ES is the thing making your
laptop unhappy, turn it off rather than fighting it:

```sh
docker compose stop elasticsearch
GS_ELASTIC_URL= MM_ELASTIC_URL= docker compose --profile apps up -d
```

## `vm.max_map_count` — Linux only, and it is not optional there

Lucene memory-maps index segments. The kernel default of 65530 mmap regions is
below what ES needs, and ES 8 refuses to start rather than degrade:

```
bootstrap check failure: max virtual memory areas vm.max_map_count [65530]
is too low, increase to at least [262144]
```

Fix for the current boot:

```sh
sudo sysctl -w vm.max_map_count=262144
```

Make it survive a reboot:

```sh
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sudo sysctl --system
```

Check it:

```sh
sysctl vm.max_map_count
```

**macOS and Windows/WSL2 users**: the setting lives in the Linux VM that Docker
runs, not on your host.

- **Docker Desktop (mac)** already ships `vm.max_map_count=262144`. Nothing to do.
- **Colima**: `colima ssh -- sudo sysctl -w vm.max_map_count=262144`, or put
  `provision:` entries in `~/.colima/default/colima.yaml`.
- **Rancher Desktop**: `rdctl shell sudo sysctl -w vm.max_map_count=262144`.
- **WSL2**: add `vm.max_map_count=262144` to `/etc/sysctl.conf` inside the
  distro, or set `kernelCommandLine` in `.wslconfig`.

## Memory sizing

`ES_JAVA_OPTS=-Xms512m -Xmx512m`.

Three things to know:

1. **Xms must equal Xmx.** A growing heap means the JVM re-reserves and the GC
   re-tunes mid-run; pinning both avoids a class of latency spikes that look
   like ES being "randomly slow".
2. **The heap is not the whole cost.** Lucene keeps term dictionaries, doc
   values and the segment cache *off* heap, in the OS page cache. Budget
   roughly 2x the heap for the container: **~1 GB for a 512 MB heap**. That is
   the number in the `deploy.resources` comment in `docker-compose.yml` and the
   limit in `k8s/base/elasticsearch.yaml`.
3. **512 MB is a floor, not a target.** It indexes both corpora (a few thousand
   documents) comfortably. Below ~400 MB ES starts full-GC thrashing and every
   query gets slow before anything actually fails, which is the worst failure
   mode to debug. If you have RAM to spare:

   ```sh
   # .env
   ES_JAVA_OPTS=-Xms1g -Xmx1g
   ```

   Never go above ~50% of the container limit, and never above 31 GB (past that
   the JVM loses compressed object pointers and effectively *loses* usable
   heap).

### "It exited with code 137"

That is SIGKILL from the OOM killer, not an ES bug. Either the container limit
is below heap + off-heap, or Docker Desktop's whole VM is too small. Raise
Docker's memory allocation (Settings → Resources → Memory, 4 GB minimum for
this stack) before you touch `ES_JAVA_OPTS`. Lowering the heap to "fit" makes
ES thrash instead of crash.

## Why security is disabled locally

`xpack.security.enabled=false`.

With security on, ES 8 generates a self-signed CA on first boot, requires HTTPS,
and hands out an enrolment token that expires in 30 minutes. Every client — the
two Go services, `curl`, Kibana if you add it — then needs the CA cert. For a
single-node throwaway container that is real work for zero local benefit, and
it makes `GS_ELASTIC_URL=http://elasticsearch:9200` (the contract's value)
impossible.

The tradeoff is that **anyone who can reach port 9200 has full cluster admin,
including `DELETE /_all`**. That is acceptable when the listener is a container
port on your laptop. It is not acceptable anywhere else.

`k8s/overlays/prod/elasticsearch-patch.yaml` turns security back on and the
prod `Secret` carries `elastic` credentials; `GS_ELASTIC_USERNAME` /
`GS_ELASTIC_PASSWORD` (and the MarketMate equivalents) exist in the contract
precisely for that path. Do not copy the local settings into prod.

## Cluster health is yellow, and that is fine

Single node, and the default index template asks for one replica. A replica
shard can never be allocated to the same node as its primary, so it stays
unassigned and the cluster reports **yellow** forever. Yellow means "all
primaries allocated, all data readable and writable". Only **red** — a missing
primary — is a real problem.

`scripts/smoke.sh` and the compose healthcheck both accept yellow.

To get green on a single node, drop replicas:

```sh
curl -X PUT localhost:9200/_settings -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
```

## Useful commands

```sh
make es-health                                   # cluster health, pretty
curl -s localhost:9200/_cat/indices?v            # indices, doc counts, size
curl -s localhost:9200/_cat/shards?v             # per-shard allocation
curl -s localhost:9200/_cat/nodes?v&h=name,heap.percent,ram.percent,cpu
curl -s localhost:9200/guest-score-guests/_count
curl -s localhost:9200/guest-score-guests/_search?size=1&pretty
```

Delete an index to force the app to rebuild it on next boot:

```sh
curl -X DELETE localhost:9200/guest-score-guests
curl -X DELETE localhost:9200/marketmate-recipes
```

See `docs/RUNBOOK.md` for the full reindex procedure.
