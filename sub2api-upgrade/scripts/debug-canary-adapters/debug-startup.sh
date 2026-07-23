#!/usr/bin/env bash
# Read-only checks for fixed debug compose container/health/revision/ref and /health.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
readonly EC_FAILED=70
readonly EC_BLOCKED=71
readonly DEFAULT_COMPOSE="/root/sub2api-debug-deploy/docker-compose.yml"
readonly DEFAULT_DEBUG_DIR="/root/sub2api-debug-deploy"

die() { printf '%s\n' "[adapter-debug-startup] error: $*" >&2; exit "$EC_BLOCKED"; }
fail() { printf '%s\n' "[adapter-debug-startup] failed: $*" >&2; exit "$EC_FAILED"; }

if (( $# > 0 )); then die "debug-startup does not accept arguments"; fi
[[ -n "${ADAPTER_EVIDENCE_OUT:-}" ]] || die "ADAPTER_EVIDENCE_OUT is required"
[[ -n "${ADAPTER_CASE_ID:-}" && -n "${ADAPTER_REVISION:-}" && -n "${ADAPTER_DIGEST:-}" ]] || die "case/revision/digest required"

DOCKER_BIN="${ADAPTER_DOCKER_BIN:-docker}"
CURL_BIN="${ADAPTER_CURL_BIN:-curl}"
COMPOSE_FILE="${ADAPTER_COMPOSE_FILE:-$DEFAULT_COMPOSE}"
DEBUG_DIR="${ADAPTER_DEBUG_DIR:-$DEFAULT_DEBUG_DIR}"
TEST_MODE="${ADAPTER_TEST_MODE:-0}"

if [[ "$TEST_MODE" != "1" ]]; then
  [[ "$(realpath -e "$COMPOSE_FILE")" == "$DEFAULT_COMPOSE" ]] || die "compose must be fixed debug path"
  DEBUG_DIR="$DEFAULT_DEBUG_DIR"
  COMPOSE_FILE="$DEFAULT_COMPOSE"
fi

[[ -f "$COMPOSE_FILE" ]] || die "compose missing: $COMPOSE_FILE"

compose() {
  "$DOCKER_BIN" compose --project-directory "$DEBUG_DIR" -f "$COMPOSE_FILE" "$@"
}

started="${ADAPTER_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
declare -a assertions=()

cid="$(compose ps -q sub2api 2>/dev/null || true)"
[[ -n "$cid" ]] || fail "debug sub2api container is not running"
assertions+=("container_present:true")

status="$("$DOCKER_BIN" inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
[[ "$status" == "running" ]] || fail "container status is $status"
assertions+=("container_running:true")

health="$("$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
if [[ "$health" != "none" && "$health" != "healthy" ]]; then
  fail "container health is $health"
fi
assertions+=("container_health:true")

image="$("$DOCKER_BIN" inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "running container image id is invalid"
rev_label="$("$DOCKER_BIN" image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image" 2>/dev/null || true)"
ref_label="$("$DOCKER_BIN" image inspect -f '{{index .Config.Labels "org.opencontainers.image.ref.name"}}' "$image" 2>/dev/null || true)"
[[ "$rev_label" == "$ADAPTER_REVISION" ]] || fail "revision label $rev_label != $ADAPTER_REVISION"
[[ "$ref_label" == "debug" ]] || fail "ref.name label is $ref_label"
assertions+=("revision_label:true")
assertions+=("ref_label:true")

repo_digests="$("$DOCKER_BIN" image inspect -f '{{json .RepoDigests}}' "$image" 2>/dev/null || true)"
jq -e --arg digest "$ADAPTER_DIGEST" '
  type=="array" and ([.[] | select(.==("ghcr.io/wesperez/sub2api@"+$digest))] | length)==1
' >/dev/null <<<"$repo_digests" || fail "running image digest does not match candidate"
assertions+=("image_digest:true")

# Resolve exactly the port proven by the fixed debug Compose configuration.
config_json="$(compose config --format json)" || die "could not render debug compose config"
host_ip="$(jq -r '.services.sub2api.ports[0].host_ip // empty' <<<"$config_json")"
published_port="$(jq -r '.services.sub2api.ports[0].published // empty | tostring' <<<"$config_json")"
[[ "$host_ip" == "127.0.0.1" && ( "$published_port" == "13081" || "$published_port" == "13180" ) ]] \
  || fail "debug compose endpoint is not an allowed loopback port"
health_json="$("$CURL_BIN" -fsS --max-time 5 "http://${host_ip}:${published_port}/health")" \
  || fail "/health check failed"
jq -e '.status=="ok"' >/dev/null <<<"$health_json" || fail "/health response is not status=ok"
assertions+=("http_health:true")

ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$TEST_MODE" == "1" ]]; then test_json=true; else test_json=false; fi
assertions_json="$(printf '%s\n' "${assertions[@]}" | awk -F: '{printf "{\"name\":\"%s\",\"passed\":%s}\n", $1, $2}' | jq -s .)"

jq -n --arg case_id "$ADAPTER_CASE_ID" --arg revision "$ADAPTER_REVISION" --arg digest "$ADAPTER_DIGEST" \
  --arg adapter_id "${ADAPTER_ADAPTER_ID:-debug-startup}" --arg started "$started" --arg ended "$ended" \
  --arg deploy "$DEBUG_DIR" --argjson test_mode "$test_json" --argjson assertions "$assertions_json" \
  --arg image "$image" --arg cid "$cid" \
  '{schema_version:1,kind:"debug-case-evidence",runner:"sub2api-debug-adapter-v1",case_id:$case_id,revision:$revision,digest:$digest,adapter_id:$adapter_id,status:"passed",started_at:$started,ended_at:$ended,target:{environment:"debug",compose_project:"sub2api-debug",deploy_dir:$deploy,test_mode:$test_mode,container_id:$cid,image:$image},assertions:$assertions}' > "$ADAPTER_EVIDENCE_OUT"
chmod 0600 "$ADAPTER_EVIDENCE_OUT"
exit 0
