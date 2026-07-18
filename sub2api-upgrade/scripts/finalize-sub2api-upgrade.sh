#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly RUN_ROOT="/root/backups/sub2api/upgrade-runs"
readonly APP_HEALTH_URL="http://127.0.0.1:13080/health"
readonly ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
readonly PUBLIC_HOST="wooai.cc.cd"
readonly DEFAULT_MIN_AGE_MINUTES=1440
readonly DEFAULT_PRUNE_MIN_AGE_HOURS=168
readonly DEFAULT_KEEP_RUNS=2

ACTION=""
RUN_ID=""
APPLY=0
MIN_AGE_MINUTES="$DEFAULT_MIN_AGE_MINUTES"
PRUNE_MIN_AGE_HOURS="$DEFAULT_PRUNE_MIN_AGE_HOURS"
KEEP_RUNS="$DEFAULT_KEEP_RUNS"

usage() {
  cat <<'USAGE'
Usage:
  finalize-sub2api-upgrade.sh --run-id <run-id> [--min-age-minutes N] [--apply]
  finalize-sub2api-upgrade.sh --prune [--keep N] [--min-age-hours N] [--apply]

Without --apply, the script reports what it would do. Finalization preserves
the database dump and configuration snapshot; it only releases the rollback
image tag created by the named, healthy update run.
USAGE
}

info() {
  printf '%s\n' "[sub2api-upgrade] $*"
}

die() {
  printf '%s\n' "[sub2api-upgrade] error: $*" >&2
  exit 1
}

manifest_value() {
  local key="$1"
  local manifest="$2"
  awk -F= -v key="$key" '$1 == key {value = substr($0, length(key) + 2)} END {print value}' "$manifest"
}

run_dir_for() {
  local run_id="$1"
  [[ "$run_id" =~ ^upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "invalid run id"
  local path="$RUN_ROOT/$run_id"
  [[ -d "$path" ]] || die "run directory is missing: $path"
  [[ "$(realpath -e "$path")" == "$(realpath -e "$RUN_ROOT")/"* ]] || die "run directory escapes run root"
  [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || die "run is not owned by this skill"
  printf '%s\n' "$path"
}

check_status_json() {
  local url="$1"
  local expected_status="$2"
  local body
  body="$(curl --noproxy '*' --fail --silent --show-error --max-time 10 "$url")" || return 1
  jq -e --arg expected "$expected_status" 'type == "object" and .status == $expected' >/dev/null <<<"$body"
}

check_public_ready() {
  local body
  body="$(curl --noproxy '*' --ipv4 --fail --silent --show-error --max-time 10 \
    --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/ready")" || return 1
  jq -e 'type == "object" and .status == "ready"' >/dev/null <<<"$body"
}

resolve_router_ready_url() {
  [[ -f "$ROUTER_UPSTREAM_CONFIG" ]] || return 1
  local -a ports=()
  mapfile -t ports < <(sed -nE 's/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083);.*$/\1/p' "$ROUTER_UPSTREAM_CONFIG")
  [[ "${#ports[@]}" == "1" ]] || return 1
  printf 'http://127.0.0.1:%s/ready\n' "${ports[0]}"
}

check_baseline() {
  command -v docker >/dev/null 2>&1 || die "docker is unavailable"
  command -v curl >/dev/null 2>&1 || die "curl is unavailable"
  command -v jq >/dev/null 2>&1 || die "jq is unavailable"
  local router_ready_url
  router_ready_url="$(resolve_router_ready_url)" || die "could not resolve the active Router slot from Nginx"
  check_status_json "$APP_HEALTH_URL" "ok" || die "application health endpoint is not healthy"
  check_status_json "$router_ready_url" "ready" || die "active Router ready endpoint is not ready"
  check_public_ready || die "Nginx/SNI public ready endpoint is not ready"
}

run_age_minutes() {
  local path="$1"
  local now
  now="$(date +%s)"
  printf '%s\n' $(( (now - $(stat -c '%Y' "$path")) / 60 ))
}

assert_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]] || die "expected a positive integer, got: $1"
}

finalize_run() {
  local path
  path="$(run_dir_for "$RUN_ID")"
  local manifest="$path/manifest.env"
  [[ -f "$manifest" ]] || die "run manifest is missing"
  local status
  status="$(manifest_value status "$manifest")"
  [[ "$status" == "passed_pending_finalization" || "$status" == "finalized" ]] || die "run is not an eligible successful rollout: $status"

  local age
  age="$(run_age_minutes "$path")"
  (( age >= MIN_AGE_MINUTES )) || die "run is only ${age}m old; preserve rollback evidence for at least ${MIN_AGE_MINUTES}m"

  local candidate_revision
  candidate_revision="$(manifest_value candidate_revision "$manifest")"
  [[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]] || die "run has no valid candidate revision"
  local running_container
  running_container="$(docker ps -q --filter 'name=^/sub2api-prod$')"
  [[ -n "$running_container" ]] || die "production application container is not uniquely running"
  local running_image
  local running_revision
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")"
  running_revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$running_image")"
  [[ "$running_revision" == "$candidate_revision" ]] || die "production revision differs from finalized candidate"
  check_baseline

  local rollback_tag
  rollback_tag="$(manifest_value rollback_tag "$manifest")"
  [[ "$rollback_tag" =~ ^ghcr\.io/wesperez/sub2api:rollback-upgrade-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}$ ]] || die "run has an unsafe rollback tag"
  if docker image inspect "$rollback_tag" >/dev/null 2>&1; then
    local references
    references="$(docker ps -aq --filter "ancestor=$rollback_tag")"
    [[ -z "$references" ]] || die "rollback image is still referenced by a container"
    if (( APPLY == 1 )); then
      docker image rm "$rollback_tag" >/dev/null
      info "released task-owned rollback tag: $rollback_tag"
    else
      info "would release task-owned rollback tag: $rollback_tag"
    fi
  else
    info "rollback tag is already absent: $rollback_tag"
  fi

  if (( APPLY == 1 )); then
    printf 'status=finalized\nfinalized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$manifest"
  fi
  info "preserved database dump, .env snapshot, Compose snapshot, and manifest in $path"
}

eligible_prune_run() {
  local path="$1"
  [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || return 1
  [[ "$(manifest_value status "$path/manifest.env" 2>/dev/null || true)" == "finalized" ]] || return 1
  local min_minutes=$(( PRUNE_MIN_AGE_HOURS * 60 ))
  (( $(run_age_minutes "$path") >= min_minutes ))
}

prune_runs() {
  [[ -d "$RUN_ROOT" ]] || { info "no skill-owned run root exists"; return 0; }
  assert_positive_integer "$KEEP_RUNS"
  assert_positive_integer "$PRUNE_MIN_AGE_HOURS"
  check_baseline

  local -a all_runs=()
  local path
  while IFS= read -r path; do
    all_runs+=("$path")
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -printf '%f\n' | sort -r)

  local index=0
  local retained=0
  local pruned=0
  for path in "${all_runs[@]}"; do
    path="$RUN_ROOT/$path"
    if ! eligible_prune_run "$path"; then
      continue
    fi
    if (( retained < KEEP_RUNS )); then
      retained=$((retained + 1))
      continue
    fi
    index=$((index + 1))
    if (( APPLY == 1 )); then
      [[ "$(run_dir_for "$(basename "$path")")" == "$path" ]] || die "owned run changed during prune"
      rm -rf -- "$path"
      info "removed expired task-owned recovery run: $(basename "$path")"
    else
      info "would remove expired task-owned recovery run: $(basename "$path")"
    fi
    pruned=$((pruned + 1))
  done
  info "retained finalized runs: $retained; prune candidates: $pruned"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --run-id)
        (( $# >= 2 )) || die "--run-id requires a value"
        ACTION="finalize"
        RUN_ID="$2"
        shift
        ;;
      --prune)
        ACTION="prune"
        ;;
      --apply)
        APPLY=1
        ;;
      --min-age-minutes)
        (( $# >= 2 )) || die "--min-age-minutes requires a value"
        MIN_AGE_MINUTES="$2"
        shift
        ;;
      --min-age-hours)
        (( $# >= 2 )) || die "--min-age-hours requires a value"
        PRUNE_MIN_AGE_HOURS="$2"
        shift
        ;;
      --keep)
        (( $# >= 2 )) || die "--keep requires a value"
        KEEP_RUNS="$2"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
  [[ -n "$ACTION" ]] || die "select --run-id or --prune"
  if [[ "$ACTION" == "finalize" ]]; then
    assert_positive_integer "$MIN_AGE_MINUTES"
  fi
}

main() {
  parse_args "$@"
  if [[ "$ACTION" == "finalize" ]]; then
    finalize_run
  else
    prune_runs
  fi
}

main "$@"
