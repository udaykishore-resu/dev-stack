# prod overlay

This overlay is a **shape**, not a turnkey deployment. It encodes the decisions
that differ from local; it does not encode your registry, your domains, your
StorageClass or your secrets. Building it produces valid YAML that will not
work until you substitute those four things.

```sh
kustomize build k8s/overlays/prod           # inspect
kustomize build k8s/overlays/prod | kubectl apply -f -
```

## What you must supply before applying

### 1. The `platform-secrets` Secret

The base overlay ships a fake `platform-secrets` with values like
`POSTGRES_PASSWORD: postgres`. This overlay **deletes it** from the build
output (`patch-delete-fake-secret.yaml`) so a `kubectl apply` cannot overwrite
the real one.

Create it out of band, with exactly these keys:

| Key                    | Notes |
|------------------------|-------|
| `POSTGRES_USER`        | superuser name |
| `POSTGRES_PASSWORD`    | superuser password |
| `GS_DB_PASSWORD`       | password for the `guestscore` role |
| `MM_DB_PASSWORD`       | password for the `marketmate` role |
| `GS_POSTGRES_DSN`      | must match `GS_DB_PASSWORD`; `sslmode=require` |
| `MM_POSTGRES_DSN`      | must match `MM_DB_PASSWORD`; `sslmode=require` |
| `GS_REDIS_PASSWORD`    | set a real one and add `--requirepass` to the Redis args |
| `GS_ELASTIC_PASSWORD`  | doubles as `ELASTIC_PASSWORD` for the ES bootstrap user |
| `MM_ELASTIC_PASSWORD`  | |
| `GS_MQTT_PASSWORD`     | must match an entry in the `mosquitto-auth` password file |
| `GS_IDENTITY_KEY`      | high-entropy HMAC key. **Rotating it invalidates every previously issued `guest_global_id`.** Treat it as permanent. |
| `OPENAI_API_KEY`       | required: `USE_FIXTURES=false` here |
| `GOOGLE_MAPS_API_KEY`  | |
| `YOUTUBE_API_KEY`      | |

A missing key surfaces as `CreateContainerConfigError` on the pod before it
ever serves traffic, which is the failure you want.

Recommended sources, in order of preference: External Secrets Operator
pointing at your cloud secret manager, Vault Agent Injector, or SOPS-encrypted
manifests applied by your GitOps controller. Do not `kubectl create secret`
from a laptop and call it done.

### 2. `mosquitto-auth` (and optionally `mosquitto-tls`)

`mosquitto-prod.conf` sets `allow_anonymous false` and reads
`/mosquitto/secrets/passwd` + `/mosquitto/secrets/acl`.

```sh
mkdir -p secrets
docker run --rm -v "$PWD/secrets:/s" eclipse-mosquitto:2 \
  mosquitto_passwd -c -b /s/passwd guest-score-ingest "$GS_MQTT_PASSWORD"
docker run --rm -v "$PWD/secrets:/s" eclipse-mosquitto:2 \
  mosquitto_passwd -b /s/passwd prop_mum_01 "$PROP_PASSWORD"

cat > secrets/acl <<'ACL'
user guest-score-ingest
topic read  guestscore/+/events
topic read  guestscore/+/status
topic write guestscore/_bureau/acks

user prop_mum_01
topic write guestscore/prop_mum_01/events
topic write guestscore/prop_mum_01/status
topic read  guestscore/_bureau/acks
ACL

kubectl -n guest-platform create secret generic mosquitto-auth \
  --from-file=passwd=secrets/passwd --from-file=acl=secrets/acl
```

`mosquitto-tls` (keys `ca.crt`, `tls.crt`, `tls.key`) is marked `optional`, so
the pod starts without it — but the 8883 listener will fail to bind. Issue it
with cert-manager if you need external MQTT.

### 3. Images

`kustomization.yaml` points at `registry.example.com/guest-platform/*:1.0.0`.
Set yours, ideally by digest:

```sh
cd k8s/overlays/prod
kustomize edit set image \
  guest-score-api=registry.acme.io/guest-score-api@sha256:...
```

`imagePullPolicy` stays `IfNotPresent`. Not `Always` — that makes every pod
start depend on registry availability, and with immutable tags it buys
nothing.

### 4. StorageClass and hostnames

`fast-ssd` in the PVC patches and `*.example.com` in the ingress patch are
placeholders.

Note that a StatefulSet's `volumeClaimTemplates` are **immutable after
creation**. Changing a size later requires `kubectl delete statefulset
--cascade=orphan` and a re-apply, plus a separate PVC expansion (only upward,
only with `allowVolumeExpansion: true`). Size these before the first apply.

## What this overlay changes, and why

| Change | Reason |
|---|---|
| GraphiQL off (`GS_GRAPHIQL`/`MM_GRAPHIQL=false`, no `/graphiql` ingress route) | unauthenticated schema introspection UI; the missing route is defence in depth if the flag is ever flipped by mistake |
| `USE_FIXTURES=false` | fixtures return canned data; prod must call the real providers |
| `GS_SEED=false` | never seed a demo dataset into a real database |
| `xpack.security.enabled=true`, `https://elasticsearch:9200` | with it off, anyone with network reach to 9200 can `DELETE /_all` |
| 3 API replicas + HPA (3-12) | rolling updates without a gap, and headroom for spikes |
| PodDisruptionBudgets | a node drain cannot take the last replica; the Postgres PDB deliberately blocks drains entirely so they must be a conscious act |
| `topologySpreadConstraints` | otherwise all three API pods can land on one node and the PDB is decorative |
| requests raised to 500m/512Mi | the HPA scales on CPU as a percentage of the **request**; tiny requests make the target meaningless |
| 100Gi / 200Gi PVCs on `fast-ssd` | ES wants ~2x steady-state index size for merges |
| `terminationGracePeriodSeconds: 45` on the APIs | in-flight requests finish before SIGKILL |

## Still missing for a real production deployment

Called out honestly rather than pretended away:

- **Postgres is a single pod with a single PVC.** No replication, no
  point-in-time recovery, no automated failover. For anything real use CNPG,
  Crunchy PGO, or a managed service, and point the DSNs at it.
- **Elasticsearch is a single node.** `discovery.type=single-node` means no
  quorum and no replica shards. A real cluster needs 3 master-eligible nodes
  and `number_of_replicas >= 1`.
- **Mosquitto is a single pod** with an emptyDir even though
  `persistence true` is set in the config. Mosquitto does not cluster; if MQTT
  is load-bearing, move to EMQX or VerneMQ.
- **No NetworkPolicy.** Every pod can reach every other pod. Add default-deny
  plus explicit allows.
- **No ServiceAccount per workload** and no `automountServiceAccountToken:
  false`. None of these pods talk to the API server.
- **No metrics/tracing wiring** (`ServiceMonitor`, OTLP endpoint).
- **Redis has no password** and no `--requirepass`; the key exists in the
  Secret so wiring it up is a two-line change.
