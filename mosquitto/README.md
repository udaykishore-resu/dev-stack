# Mosquitto (MQTT) in dev-stack

The event bus Guest Score ingests from. MarketMate does not use it.

- Broker: `eclipse-mosquitto:2`
- MQTT: `1883` (host and in-cluster)
- MQTT over WebSockets: `9001`
- In-cluster DNS: `mosquitto`
- App config: `GS_MQTT_URL=tcp://mosquitto:1883` (`tcp://localhost:1883` from the host)

If `GS_MQTT_URL` is unset the API starts fine and event ingest is simply
disabled — the broker is an optional dependency like everything else.

## Why there is a config file at all

Mosquitto 2.0 flipped the defaults: with no config it listens on `127.0.0.1`
only and rejects anonymous clients. In a container that means *no client can
ever connect*, and the failure looks like a network problem rather than a
config one. `mosquitto.conf` restores a usable local default:
`listener 1883 0.0.0.0` + `allow_anonymous true`.

This is safe **only** because the broker is reachable from the compose network
and `localhost` and nowhere else. The production path (password file, ACLs,
TLS on 8883) is written out in full at the bottom of `mosquitto.conf`.

## Topic scheme

```
guestscore/{property_id}/events    property -> backend: stay + incident events
guestscore/{property_id}/status    retained LWT: "online" / "offline"
guestscore/_bureau/acks            backend -> property: per-event acks
```

The ingest worker subscribes to `guestscore/+/events` — the `+` is a single
level wildcard matching one property id. Everything is QoS 1, and the worker
deduplicates on `event_id`, so an at-least-once redelivery cannot penalise a
guest twice.

## Day-to-day

Watch the whole bus:

```sh
make mqtt-sub                       # -t 'guestscore/#' -v
docker compose exec mosquitto mosquitto_sub -h localhost -t '#' -v
```

Publish a test event:

```sh
make mqtt-pub                       # publishes the sample below
```

```sh
docker compose exec -T mosquitto mosquitto_pub \
  -h localhost -q 1 -t 'guestscore/prop_mum_01/events' -m '{
  "event_id": "evt_7f3a",
  "type": "incident",
  "property_id": "prop_mum_01",
  "member_id": "m_taj",
  "guest_global_id": "GS-488122DBCBB0",
  "stay_id": "s_1187",
  "occurred_at": "2026-08-14T09:12:00Z",
  "incident": { "type": "noise_complaint", "severity": "moderate", "note": "after 23:00" }
}'
```

Confirm the backend acked it:

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t 'guestscore/_bureau/acks' -v
```

Inspect broker internals (client count, message counters, uptime):

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t '$SYS/#' -v -W 3
```

Check retained status messages without subscribing to live traffic:

```sh
docker compose exec mosquitto mosquitto_sub -h localhost -t 'guestscore/+/status' -v -W 2
```

Clear a stale retained status (publish an empty retained payload):

```sh
docker compose exec mosquitto mosquitto_pub -h localhost -r -n -t 'guestscore/prop_mum_01/status'
```

## Health

The compose healthcheck runs `mosquitto_sub ... -E`, which connects,
subscribes, and exits on SUBACK. That proves the broker is accepting
subscriptions, not merely holding the TCP port open — a broker that is up but
has exhausted its connection limit fails this check, as it should.

## Gotchas

- **Config not picked up.** The file is bind-mounted read-only at
  `/mosquitto/config/mosquitto.conf`. If you edit it, `docker compose restart
  mosquitto` — mosquitto does not reload on SIGHUP for listener changes.
- **`Error: Connection refused` from the host.** Check `MQTT_PORT` in `.env`;
  something else may own 1883 (another mosquitto from Homebrew is the usual
  culprit — `brew services stop mosquitto`).
- **A property looks permanently "online".** That is a retained LWT from a
  previous run. Persistence is off, so this only survives within a single
  broker lifetime; clear it with the `-r -n` publish above.
- **`$SYS` in a shell.** Quote it (`'$SYS/#'`), and in `docker-compose.yml`
  write it `$$SYS` so compose does not try to interpolate it.
