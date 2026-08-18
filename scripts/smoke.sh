#!/usr/bin/env bash
# End-to-end smoke test for the dev-stack.
#
# Checks, in order:
#   postgres        accepts a query against both application databases
#   redis           PING, and both logical DBs are reachable
#   elasticsearch   cluster health is green or yellow (yellow is correct on a
#                   single node — replica shards can never be allocated)
#   mqtt            publish + subscribe round-trip on the contract's topic
#   guest-score-api GET /api/health, POST /graphql
#   marketmate-api  GET /api/health, POST /graphql
#
# The app services live behind the `apps` compose profile. When that profile is
# down this script SKIPS them with a clear line rather than failing — an
# infra-only stack is a legitimate state, and a smoke test that cannot tell
# "not running" from "broken" is worse than no smoke test.
#
# Exit codes: 0 all checks passed (skips are not failures), 1 something failed.
#
# Usage:
#   scripts/smoke.sh              check everything that is up
#   scripts/smoke.sh --require-apps   treat a missing app profile as a failure
#   SMOKE_HOST=127.0.0.1 scripts/smoke.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env so the script uses the same ports the stack was started with.
# shellcheck disable=SC1091
if [ -f .env ]; then set -a; . ./.env; set +a; fi

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
HOST="${SMOKE_HOST:-127.0.0.1}"

GS_API_PORT="${GS_API_PORT:-8090}"
MM_API_PORT="${MM_API_PORT:-8081}"
ELASTIC_PORT="${ELASTIC_PORT:-9200}"

REQUIRE_APPS=0
# Written as a full `if`, not `[ ... ] && VAR=1`: under `set -e` a false
# AND-list at the top level terminates the script.
if [ "${1:-}" = "--require-apps" ]; then REQUIRE_APPS=1; fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
	GREEN=''; RED=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
fail() {
	FAIL=$((FAIL + 1))
	printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
	if [ -n "${2:-}" ]; then printf '        %s%s%s\n' "$DIM" "$2" "$RESET"; fi
	return 0
}
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s  %s %s(%s)%s\n' "$YELLOW" "$RESET" "$1" "$DIM" "${2:-not running}" "$RESET"; }
section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Is a compose service running? Note `compose ps -q` returns nothing for a
# service whose profile is not active, which is exactly the signal we want.
running() {
	local cid
	cid="$(compose ps -q "$1" 2>/dev/null | head -n1)" || return 1
	[ -n "$cid" ] || return 1
	[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" = "true" ]
}

# Run a command inside a service container. -T because there is no TTY in CI.
in_svc() {
	local svc="$1"
	shift
	compose exec -T "$svc" "$@"
}

# ---------------------------------------------------------------------------
printf '%sdev-stack smoke test%s  (host %s)\n' "$BOLD" "$RESET" "$HOST"

section 'PostgreSQL'
if running postgres; then
	for db in "${GS_DB_NAME:-guestscore}" "${MM_DB_NAME:-marketmate}"; do
		# `SELECT 1` proves the server parses and executes, not merely that the
		# port is open — pg_isready would pass during recovery.
		if out="$(in_svc postgres psql -qtAX -U "${POSTGRES_USER:-postgres}" -d "$db" -c 'SELECT 1' 2>&1)" &&
			[ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ]; then
			pass "postgres: SELECT 1 on database '$db'"
		else
			fail "postgres: SELECT 1 on database '$db'" "$out"
		fi
	done

	# The two roles must actually exist and be able to log in; a database that
	# exists but whose owner role is missing is a silent init-script failure.
	if out="$(in_svc postgres psql -qtAX -U "${POSTGRES_USER:-postgres}" -d postgres \
		-c "SELECT count(*) FROM pg_roles WHERE rolname IN ('${GS_DB_USER:-guestscore}','${MM_DB_USER:-marketmate}')" 2>&1)" &&
		[ "$(printf '%s' "$out" | tr -d '[:space:]')" = "2" ]; then
		pass "postgres: both application roles exist"
	else
		fail "postgres: both application roles exist" "got: $out"
	fi
else
	skip "postgres" "service not running"
fi

section 'Redis'
if running redis; then
	if out="$(in_svc redis redis-cli PING 2>&1)" && printf '%s' "$out" | grep -q PONG; then
		pass "redis: PING"
	else
		fail "redis: PING" "$out"
	fi

	# Guest Score uses DB 0, MarketMate DB 1 (contract.md). Prove both indices
	# are addressable — a Redis built with `databases 1` would break MarketMate
	# and nothing else would notice until a cache write failed.
	for db in "${GS_REDIS_DB:-0}" "${MM_REDIS_DB:-1}"; do
		if out="$(in_svc redis redis-cli -n "$db" SET __smoke__ ok EX 10 2>&1)" && printf '%s' "$out" | grep -q OK; then
			pass "redis: write to logical DB $db"
			in_svc redis redis-cli -n "$db" DEL __smoke__ >/dev/null 2>&1 || true
		else
			fail "redis: write to logical DB $db" "$out"
		fi
	done
else
	skip "redis" "service not running"
fi

section 'Elasticsearch'
if running elasticsearch; then
	if out="$(curl -fsS --max-time 10 "http://${HOST}:${ELASTIC_PORT}/_cluster/health" 2>&1)"; then
		status="$(printf '%s' "$out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
		case "$status" in
		green | yellow)
			# yellow is the expected steady state: one node, and the default
			# template asks for a replica that can never be allocated.
			pass "elasticsearch: cluster health is $status"
			;;
		red)
			fail "elasticsearch: cluster health is red" "$out"
			;;
		*)
			fail "elasticsearch: could not parse cluster health" "$out"
			;;
		esac
	else
		fail "elasticsearch: GET /_cluster/health" "$out"
	fi
else
	skip "elasticsearch" "service not running"
fi

section 'MQTT'
if running mosquitto; then
	topic="guestscore/_smoke/events"
	payload="{\"event_id\":\"evt_smoke_$$\",\"type\":\"check_in\",\"property_id\":\"_smoke\"}"
	tmp="$(mktemp)"
	# shellcheck disable=SC2064  # expand tmp now, not at trap time
	trap "rm -f '$tmp'" EXIT

	# Subscriber first, in the background, so the retained-flag-free publish
	# below is guaranteed to have a listener. -W 5 bounds the wait; -C 1 exits
	# after the first message.
	( in_svc mosquitto mosquitto_sub -h 127.0.0.1 -p 1883 -t "$topic" -q 1 -C 1 -W 5 >"$tmp" 2>&1 ) &
	sub_pid=$!
	sleep 1

	if pub_out="$(in_svc mosquitto mosquitto_pub -h 127.0.0.1 -p 1883 -t "$topic" -q 1 -m "$payload" 2>&1)"; then
		:
	else
		fail "mqtt: publish to $topic" "$pub_out"
	fi

	if wait "$sub_pid" 2>/dev/null; then
		if grep -q 'evt_smoke_' "$tmp"; then
			pass "mqtt: publish/subscribe round-trip on $topic (QoS 1)"
		else
			fail "mqtt: round-trip payload mismatch" "$(cat "$tmp")"
		fi
	else
		fail "mqtt: subscriber did not receive the message within 5s" "$(cat "$tmp")"
	fi
	rm -f "$tmp"
	trap - EXIT
else
	skip "mosquitto" "service not running"
fi

# ---------------------------------------------------------------------------
# Applications. Behind the `apps` profile — absent is a SKIP, not a FAIL,
# unless --require-apps was passed.
# ---------------------------------------------------------------------------
app_missing() {
	if [ "$REQUIRE_APPS" -eq 1 ]; then
		fail "$1" "service not running and --require-apps was given"
	else
		skip "$1" "apps profile is down; start it with 'make up-all'"
	fi
}

check_health() {
	local label="$1" url="$2" out
	if out="$(curl -fsS --max-time 10 "$url" 2>&1)"; then
		pass "$label: GET $url"
	else
		fail "$label: GET $url" "$out"
	fi
}

check_graphql() {
	local label="$1" url="$2" out
	# `{ __typename }` is the one query guaranteed to be valid against any
	# schema, so this tests the transport and the executor without knowing
	# anything about the domain model.
	if out="$(curl -fsS --max-time 10 -X POST "$url" \
		-H 'Content-Type: application/json' \
		--data '{"query":"{ __typename }"}' 2>&1)"; then
		if printf '%s' "$out" | grep -q '"data"'; then
			pass "$label: POST $url  { __typename }"
		else
			# A 200 with only "errors" means the endpoint is there but the
			# executor rejected the query — worth failing on.
			fail "$label: POST $url returned no data field" "$out"
		fi
	else
		fail "$label: POST $url" "$out"
	fi
}

section 'guest-score-api'
if running guest-score-api; then
	check_health "guest-score-api" "http://${HOST}:${GS_API_PORT}/api/health"
	check_graphql "guest-score-api" "http://${HOST}:${GS_API_PORT}/graphql"
else
	app_missing "guest-score-api"
fi

section 'marketmate-api'
if running marketmate-api; then
	check_health "marketmate-api" "http://${HOST}:${MM_API_PORT}/api/health"
	check_graphql "marketmate-api" "http://${HOST}:${MM_API_PORT}/graphql"
else
	app_missing "marketmate-api"
fi

section 'guest-score-scoring (gRPC)'
if running guest-score-scoring; then
	# No HTTP surface and the image is distroless, so there is nothing to curl
	# and no shell to exec grpc_health_probe from. The best a compose-level
	# smoke test can do is prove the port is listening and the process is up.
	# Kubernetes checks grpc.health.v1.Health natively — see
	# k8s/base/guest-score-scoring.yaml.
	port="${GS_SCORING_PORT:-9090}"
	if (exec 3<>"/dev/tcp/${HOST}/${port}") 2>/dev/null; then
		pass "guest-score-scoring: TCP ${HOST}:${port} accepting connections"
		exec 3<&- 2>/dev/null || true
	else
		fail "guest-score-scoring: TCP ${HOST}:${port}" "nothing listening"
	fi
else
	app_missing "guest-score-scoring"
fi

section 'Web front-ends'
for entry in "guest-score-web:${GS_WEB_PORT:-5174}" "marketmate-web:${MM_WEB_PORT:-5173}"; do
	svc="${entry%%:*}"
	port="${entry##*:}"
	if running "$svc"; then
		check_health "$svc" "http://${HOST}:${port}/"
	else
		app_missing "$svc"
	fi
done

# ---------------------------------------------------------------------------
printf '\n%s──────────────────────────────────%s\n' "$DIM" "$RESET"
printf '%s%d passed%s' "$GREEN" "$PASS" "$RESET"
# `|| true` on each: under `set -e` a bare `[ ... ] && printf` whose test is
# false makes the whole AND-list return 1 and kills the script right before it
# reports the result.
if [ "$SKIP" -gt 0 ]; then printf ', %s%d skipped%s' "$YELLOW" "$SKIP" "$RESET"; fi
if [ "$FAIL" -gt 0 ]; then printf ', %s%d failed%s' "$RED" "$FAIL" "$RESET"; fi
printf '\n'

if [ "$FAIL" -gt 0 ]; then
	printf '%ssmoke test FAILED%s\n' "$RED" "$RESET"
	exit 1
fi
printf '%ssmoke test passed%s\n' "$GREEN" "$RESET"
