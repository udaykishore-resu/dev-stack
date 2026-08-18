#!/usr/bin/env bash
# Block until every compose service that declares a healthcheck reports
# healthy, or until the timeout expires.
#
# Why this exists: `docker compose up -d` returns as soon as the containers are
# CREATED, not when they are usable. `--wait` exists but it fails the whole
# command if any service lacks a healthcheck, and it gives you no useful output
# about which one is stuck. This prints progress and, on failure, the logs of
# the service that did not come up — which is the thing you actually want.
#
# Usage:
#   scripts/wait-for-healthy.sh [-t SECONDS] [service ...]
#
# With no service arguments it waits for every running service in the project.

set -euo pipefail

TIMEOUT="${WAIT_TIMEOUT:-180}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

while getopts ":t:h" opt; do
	case "$opt" in
	t) TIMEOUT="$OPTARG" ;;
	h)
		sed -n '2,15p' "$0"
		exit 0
		;;
	\?)
		echo "unknown option: -$OPTARG" >&2
		exit 2
		;;
	esac
done
shift $((OPTIND - 1))

cd "$(dirname "$0")/.."

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
	GREEN=''; RED=''; YELLOW=''; DIM=''; RESET=''
fi

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Resolve the service list. `compose ps --services` respects the active
# profiles, so an infra-only stack is not asked to wait for the app services.
if [ "$#" -gt 0 ]; then
	services=("$@")
else
	mapfile -t services < <(compose ps --services --status running 2>/dev/null || true)
fi

if [ "${#services[@]}" -eq 0 ]; then
	echo "${YELLOW}no running services — did you run 'make up' first?${RESET}" >&2
	exit 1
fi

echo "waiting up to ${TIMEOUT}s for: ${services[*]}"

# Health of one service. Echoes one of: healthy | unhealthy | starting |
# none (no healthcheck defined) | missing (no container).
service_health() {
	local svc="$1" cid
	cid="$(compose ps -q "$svc" 2>/dev/null | head -n1)"
	[ -n "$cid" ] || { echo missing; return; }

	# .State.Health is absent when the image declares no healthcheck; the
	# template below prints an empty string in that case.
	local state health
	state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)"
	health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)"

	if [ -n "$health" ]; then
		echo "$health"
	elif [ "$state" = "running" ]; then
		# No healthcheck (guest-score-scoring: gRPC only, nothing to curl).
		# Treat "running" as the best signal available rather than hanging.
		echo none
	else
		echo "$state"
	fi
}

deadline=$(( $(date +%s) + TIMEOUT ))
declare -A reported=()

while :; do
	all_ok=1
	for svc in "${services[@]}"; do
		h="$(service_health "$svc")"
		case "$h" in
		healthy)
			[ "${reported[$svc]:-}" = ok ] || { echo "  ${GREEN}healthy${RESET}   $svc"; reported[$svc]=ok; }
			;;
		none)
			[ "${reported[$svc]:-}" = ok ] || { echo "  ${DIM}running${RESET}   $svc ${DIM}(no healthcheck)${RESET}"; reported[$svc]=ok; }
			;;
		unhealthy)
			echo "  ${RED}unhealthy${RESET} $svc" >&2
			compose logs --tail 40 "$svc" >&2 || true
			exit 1
			;;
		*)
			all_ok=0
			;;
		esac
	done

	[ "$all_ok" -eq 1 ] && break

	if [ "$(date +%s)" -ge "$deadline" ]; then
		echo "${RED}timed out after ${TIMEOUT}s${RESET}" >&2
		for svc in "${services[@]}"; do
			h="$(service_health "$svc")"
			case "$h" in
			healthy | none) ;;
			*)
				echo "${RED}  $svc: $h${RESET}" >&2
				compose logs --tail 30 "$svc" >&2 || true
				;;
			esac
		done
		exit 1
	fi

	sleep 2
done

echo "${GREEN}all services healthy${RESET}"
