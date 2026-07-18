#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly DEPLOY_DIR="/root/sub2api-prod-deploy"
readonly COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
readonly ENV_FILE="$DEPLOY_DIR/.env"
readonly RUN_ROOT="/root/backups/sub2api/upgrade-runs"
readonly APPLY_LOCK_FILE="/run/lock/sub2api-upgrade.lock"
readonly APP_IMAGE="ghcr.io/wesperez/sub2api:mine"
readonly APP_HEALTH_URL="http://127.0.0.1:13080/health"
readonly ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
readonly PUBLIC_HOST="wooai.cc.cd"
readonly HEALTH_TIMEOUT_SECONDS=180

MODE="preflight"
EXPECTED_REVISION=""
ROLLBACK_IMAGE_SAFE=0
RUN_ID=""
RUN_DIR=""
ROLLBACK_TAG=""
CURRENT_CONTAINER=""
CURRENT_IMAGE_ID=""
CURRENT_REVISION=""
CANDIDATE_IMAGE_ID=""
CANDIDATE_REVISION=""
PRESERVE_ARTIFACTS=0
ROLLOUT_STARTED=0
ROLLOUT_COMPLETE=0
FAILURE_HANDLED=0

usage() {
  cat <<'USAGE'
Usage:
  update-sub2api.sh [--preflight]
  update-sub2api.sh --apply --expected-revision <40-char-git-sha> --rollback-image-safe

Default mode is read-only preflight. Apply mode only updates the production
sub2api service after it verifies a published mine image, creates a PostgreSQL
dump, and tags the currently running application image for rollback.
USAGE
}

info() {
  printf '%s\n' "[sub2api-upgrade] $*"
}

warn() {
  printf '%s\n' "[sub2api-upgrade] warning: $*" >&2
}

die() {
  printf '%s\n' "[sub2api-upgrade] error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

compose() {
  docker compose --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" "$@"
}

compose_with_image() {
  local image="$1"
  shift
  SUB2API_IMAGE="$image" docker compose --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" "$@"
}

image_label() {
  local image="$1"
  local label="$2"
  docker image inspect -f "{{index .Config.Labels \"$label\"}}" "$image"
}

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"
}

last_manifest_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key {value = substr($0, length(key) + 2)} END {print value}' "$file"
}

record() {
  local key="$1"
  local value="$2"
  [[ -n "$RUN_DIR" ]] || die "run directory is not initialized"
  [[ "$key" =~ ^[a-z0-9_]+$ ]] || die "unsafe manifest key: $key"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "unsafe manifest value for $key"
  printf '%s=%s\n' "$key" "$value" >> "$RUN_DIR/manifest.env"
}

release_rollback_tag() {
  [[ -n "$ROLLBACK_TAG" ]] || return 0
  if docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1; then
    docker image rm "$ROLLBACK_TAG" >/dev/null
  fi
}

discard_unrolled_run() {
  [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || return 0
  [[ "$(cat "$RUN_DIR/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || return 0
  case "$RUN_DIR" in
    "$RUN_ROOT"/upgrade-*) rm -rf -- "$RUN_DIR" ;;
    *) die "refusing to remove an unexpected run directory" ;;
  esac
}

on_exit() {
  local status="$1"
  trap - EXIT
  trap '' INT TERM
  if (( status != 0 && ROLLOUT_STARTED == 1 && ROLLOUT_COMPLETE == 0 && FAILURE_HANDLED == 0 )); then
    warn "rollout exited unexpectedly; attempting the proven application-only rollback"
    if [[ -n "$RUN_DIR" && -f "$RUN_DIR/manifest.env" ]]; then
      printf 'status=unexpected_exit\n' >> "$RUN_DIR/manifest.env" || true
    fi
    if (( ROLLBACK_IMAGE_SAFE == 1 )) && rollback_application; then
      if [[ -n "$RUN_DIR" && -f "$RUN_DIR/manifest.env" ]]; then
        printf 'status=rolled_back_after_unexpected_exit\nrolled_back_at=%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RUN_DIR/manifest.env" || true
      fi
      warn "unexpected-exit application rollback succeeded; preserve $RUN_DIR for investigation"
    else
      if [[ -n "$RUN_DIR" && -f "$RUN_DIR/manifest.env" ]]; then
        printf 'status=rollback_failed_after_unexpected_exit\n' >> "$RUN_DIR/manifest.env" || true
      fi
      warn "unexpected-exit application rollback failed; preserve $RUN_DIR and investigate immediately"
    fi
    return
  fi
  if (( status != 0 && PRESERVE_ARTIFACTS == 0 )); then
    release_rollback_tag || warn "could not remove pre-rollout rollback tag: $ROLLBACK_TAG"
    discard_unrolled_run || warn "could not remove incomplete pre-rollout run: $RUN_DIR"
  fi
}

on_signal() {
  local signal="$1"
  warn "received $signal; leaving through the guarded exit path"
  case "$signal" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    *) exit 1 ;;
  esac
}

trap 'on_exit $?' EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

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
  mapfile -t ports < <(
    sed -nE '/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083)([[:space:]][^;]*)?;([[:space:]]*#.*)?$/ {
      /[[:space:]](backup|down)([[:space:]]|;)/d
      s/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083).*/\1/p
    }' "$ROUTER_UPSTREAM_CONFIG"
  )
  [[ "${#ports[@]}" == "1" ]] || return 1
  printf 'http://127.0.0.1:%s/ready\n' "${ports[0]}"
}

check_http_baseline() {
  info "checking application, Router, and Nginx readiness"
  local router_ready_url
  router_ready_url="$(resolve_router_ready_url)" || die "could not resolve the active Router slot from Nginx"
  check_status_json "$APP_HEALTH_URL" "ok" || die "application health endpoint is not healthy"
  check_status_json "$router_ready_url" "ready" || die "active Router ready endpoint is not ready"
  check_public_ready || die "Nginx/SNI public ready endpoint is not ready"
}

check_static_layout() {
  [[ "$(id -u)" == "0" ]] || die "run as root so backup permissions and Docker ownership remain controlled"
  [[ -z "${SUB2API_IMAGE:-}" ]] || die "SUB2API_IMAGE must not be inherited by the rollout process"
  [[ -d "$DEPLOY_DIR" ]] || die "production deployment directory is missing: $DEPLOY_DIR"
  [[ -f "$COMPOSE_FILE" ]] || die "production Compose file is missing: $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || die "production environment file is missing: $ENV_FILE"
  [[ "$(realpath -e "$DEPLOY_DIR")" == "$DEPLOY_DIR" ]] || die "deployment directory is not the expected canonical path"
  grep -Eq '^name:[[:space:]]*sub2api-prod[[:space:]]*$' "$COMPOSE_FILE" || die "Compose project is not sub2api-prod"
  compose config --quiet >/dev/null || die "Compose configuration is invalid"

  local configured_image
  configured_image="$(compose config --format json | jq -r '.services.sub2api.image')"
  [[ "$configured_image" == "$APP_IMAGE" ]] || die "sub2api image must be exactly $APP_IMAGE, got $configured_image"

  grep -Eq '^[[:space:]]*PGDATA:[[:space:]]*/var/lib/postgresql/data[[:space:]]*$' "$COMPOSE_FILE" || die "required PostgreSQL PGDATA protection is absent"
  for data_path in "$DEPLOY_DIR/data/sub2api" "$DEPLOY_DIR/data/postgres" "$DEPLOY_DIR/data/redis"; do
    [[ -d "$data_path" ]] || die "required production data directory is missing: $data_path"
  done
  [[ "$(tr -d '[:space:]' < "$DEPLOY_DIR/data/postgres/PG_VERSION")" == "18" ]] || die "unexpected PostgreSQL data version"
}

check_watchtower_guard() {
  docker container inspect watchtower >/dev/null 2>&1 || die "watchtower state is unknown; refuse a competing rollout"
  local command_line
  command_line="$(docker inspect -f '{{join .Config.Cmd " "}}' watchtower)"
  if [[ "$command_line" != *"--disable-containers sub2api-prod"* && "$command_line" != *"--disable-containers=sub2api-prod"* ]]; then
    die "watchtower does not prove sub2api-prod is disabled; refuse a rollout race"
  fi
}

acquire_apply_lock() {
  require_command flock
  exec 9>"$APPLY_LOCK_FILE"
  flock -n 9 || die "another Sub2API production rollout is already running"
}

collect_running_state() {
  local service
  local container
  local health
  for service in sub2api postgres redis; do
    container="$(compose ps -q "$service")"
    [[ -n "$container" ]] || die "required service is not running: $service"
    health="$(container_health "$container")"
    [[ "$health" == "healthy" ]] || die "required service is not healthy: $service ($health)"
    if [[ "$service" == "sub2api" ]]; then
      CURRENT_CONTAINER="$container"
    fi
  done

  CURRENT_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CURRENT_CONTAINER")"
  CURRENT_REVISION="$(image_label "$CURRENT_IMAGE_ID" "org.opencontainers.image.revision")"
  [[ "$CURRENT_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "running image has no valid Git revision label"
  [[ "$(image_label "$CURRENT_IMAGE_ID" "org.opencontainers.image.ref.name")" == "mine" ]] || die "running application image is not a mine image"
}

run_preflight() {
  require_command docker
  require_command curl
  require_command jq
  require_command sha256sum
  require_command realpath
  require_command stat
  check_static_layout
  check_watchtower_guard
  collect_running_state
  check_http_baseline
  info "preflight passed"
  printf 'current_image_id=%s\ncurrent_revision=%s\n' "$CURRENT_IMAGE_ID" "$CURRENT_REVISION"
}

create_run() {
  [[ -n "$RUN_ID" && -n "$ROLLBACK_TAG" ]] || die "run identity is not initialized"
  RUN_DIR="$RUN_ROOT/$RUN_ID"
  install -d -m 0700 "$RUN_ROOT"
  [[ ! -e "$RUN_DIR" ]] || die "run directory already exists: $RUN_DIR"
  install -d -m 0700 "$RUN_DIR"
  printf '%s\n' 'sub2api-upgrade-v1' > "$RUN_DIR/.owner"
  chmod 0600 "$RUN_DIR/.owner"
  : > "$RUN_DIR/manifest.env"
  chmod 0600 "$RUN_DIR/manifest.env"
  install -m 0600 "$COMPOSE_FILE" "$RUN_DIR/docker-compose.yml"
  install -m 0600 "$ENV_FILE" "$RUN_DIR/.env"
  record run_id "$RUN_ID"
  record created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record expected_revision "$EXPECTED_REVISION"
  record previous_image_id "$CURRENT_IMAGE_ID"
  record previous_revision "$CURRENT_REVISION"
  record candidate_image_id "$CANDIDATE_IMAGE_ID"
  record candidate_revision "$CANDIDATE_REVISION"
  record rollback_tag "$ROLLBACK_TAG"
  record status "backup_pending"
}

create_database_dump() {
  local partial_dump="$RUN_DIR/postgres.dump.partial"
  local dump="$RUN_DIR/postgres.dump"
  info "creating PostgreSQL custom-format rollback point"
  if ! compose exec -T postgres sh -ec 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$partial_dump"; then
    rm -f -- "$partial_dump"
    die "PostgreSQL dump failed; production was not changed"
  fi
  [[ -s "$partial_dump" ]] || die "PostgreSQL dump is empty; production was not changed"
  [[ "$(stat -c '%s' "$partial_dump")" -gt 1024 ]] || die "PostgreSQL dump is unexpectedly small; production was not changed"
  mv "$partial_dump" "$dump"
  chmod 0600 "$dump"
  record database_dump "$dump"
  record database_dump_sha256 "$(sha256sum "$dump" | awk '{print $1}')"
  record status "backup_complete"
}

record_background_writer_state() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local recovery_state
  local balance_timer_state
  recovery_state="$(systemctl is-active sub2api-recovery.service 2>/dev/null || true)"
  balance_timer_state="$(systemctl is-active sub2api-metapi-balance-sync.timer 2>/dev/null || true)"
  record recovery_service_state "${recovery_state:-unknown}"
  record balance_sync_timer_state "${balance_timer_state:-unknown}"
}

assert_unchanged_before_rollout() {
  local current_container
  local current_image
  current_container="$(compose ps -q sub2api)"
  [[ "$current_container" == "$CURRENT_CONTAINER" ]] || die "production application container changed during preflight; refuse a concurrent rollout"
  current_image="$(docker inspect -f '{{.Image}}' "$current_container")"
  [[ "$current_image" == "$CURRENT_IMAGE_ID" ]] || die "production application image changed during preflight; refuse a concurrent rollout"
  check_http_baseline
}

wait_for_application_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local container
  local health
  while (( SECONDS < deadline )); do
    container="$(compose ps -q sub2api)"
    if [[ -n "$container" ]]; then
      health="$(container_health "$container")"
      if [[ "$health" == "healthy" ]]; then
        return 0
      fi
      if [[ "$health" == "unhealthy" || "$health" == "exited" || "$health" == "dead" ]]; then
        return 1
      fi
    fi
    sleep 2
  done
  return 1
}

verify_candidate_runtime() {
  wait_for_application_health || return 1
  local running_container
  local running_image
  local running_revision
  local router_ready_url
  running_container="$(compose ps -q sub2api)" || return 1
  [[ -n "$running_container" ]] || return 1
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")" || return 1
  [[ "$running_image" == "$CANDIDATE_IMAGE_ID" ]] || return 1
  running_revision="$(image_label "$running_image" "org.opencontainers.image.revision")" || return 1
  [[ "$running_revision" == "$CANDIDATE_REVISION" ]] || return 1
  router_ready_url="$(resolve_router_ready_url)" || return 1
  check_status_json "$APP_HEALTH_URL" "ok" || return 1
  check_status_json "$router_ready_url" "ready" || return 1
  check_public_ready || return 1
}

rollback_application() {
  info "candidate verification failed; restoring the proven rollback image"
  docker image tag "$CURRENT_IMAGE_ID" "$APP_IMAGE" || return 1
  [[ "$(docker image inspect -f '{{.Id}}' "$APP_IMAGE")" == "$CURRENT_IMAGE_ID" ]] || return 1
  compose_with_image "$ROLLBACK_TAG" up -d --no-deps --force-recreate sub2api || return 1
  wait_for_application_health || return 1
  local running_container
  local running_image
  local router_ready_url
  running_container="$(compose ps -q sub2api)" || return 1
  [[ -n "$running_container" ]] || return 1
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")" || return 1
  [[ "$running_image" == "$CURRENT_IMAGE_ID" ]] || return 1
  router_ready_url="$(resolve_router_ready_url)" || return 1
  check_status_json "$APP_HEALTH_URL" "ok" || return 1
  check_status_json "$router_ready_url" "ready" || return 1
  check_public_ready || return 1
}

handle_candidate_failure() {
  FAILURE_HANDLED=1
  trap '' INT TERM
  record status "candidate_failed"
  if (( ROLLBACK_IMAGE_SAFE == 0 )); then
    record status "rollback_withheld"
    die "candidate failed and image rollback was not proven safe; database restore is never automatic"
  fi
  if rollback_application; then
    record status "rolled_back"
    record rolled_back_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record local_app_tag_image_id "$CURRENT_IMAGE_ID"
    info "application rollback succeeded; preserve $RUN_DIR for investigation"
    exit 2
  fi
  record status "rollback_failed"
  die "candidate and rollback validation failed; preserve $RUN_DIR and investigate immediately"
}

pull_verified_candidate() {
  ROLLBACK_TAG="ghcr.io/wesperez/sub2api:rollback-$RUN_ID"
  docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1 && die "rollback tag unexpectedly exists: $ROLLBACK_TAG"
  docker image tag "$CURRENT_IMAGE_ID" "$ROLLBACK_TAG"
  info "pulling only the sub2api application image"
  compose pull sub2api
  CANDIDATE_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$APP_IMAGE")"
  CANDIDATE_REVISION="$(image_label "$CANDIDATE_IMAGE_ID" "org.opencontainers.image.revision")"

  if [[ "$CANDIDATE_IMAGE_ID" == "$CURRENT_IMAGE_ID" ]]; then
    release_rollback_tag
    info "no newer application image is available; production was not restarted"
    exit 0
  fi
  [[ "$(image_label "$CANDIDATE_IMAGE_ID" "org.opencontainers.image.ref.name")" == "mine" ]] || die "pulled image is not labeled mine"
  [[ "$CANDIDATE_REVISION" == "$EXPECTED_REVISION" ]] || die "pulled revision $CANDIDATE_REVISION does not match verified revision $EXPECTED_REVISION"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --preflight)
        MODE="preflight"
        ;;
      --apply)
        MODE="apply"
        ;;
      --expected-revision)
        (( $# >= 2 )) || die "--expected-revision requires a value"
        EXPECTED_REVISION="$2"
        shift
        ;;
      --rollback-image-safe)
        ROLLBACK_IMAGE_SAFE=1
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
  if [[ "$MODE" == "apply" ]]; then
    [[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "apply mode requires a lowercase 40-character Git SHA"
    (( ROLLBACK_IMAGE_SAFE == 1 )) || die "apply mode requires an explicit proof of image rollback safety"
  fi
}

main() {
  parse_args "$@"
  if [[ "$MODE" == "apply" ]]; then
    acquire_apply_lock
  fi
  run_preflight
  [[ "$MODE" == "apply" ]] || exit 0

  RUN_ID="upgrade-$(date -u +%Y%m%dT%H%M%SZ)-${EXPECTED_REVISION:0:12}"
  pull_verified_candidate
  create_run
  create_database_dump
  record_background_writer_state
  assert_unchanged_before_rollout
  PRESERVE_ARTIFACTS=1
  ROLLOUT_STARTED=1

  info "replacing only the sub2api application container"
  if ! compose up -d --no-deps --force-recreate sub2api; then
    handle_candidate_failure
  fi
  if ! verify_candidate_runtime; then
    handle_candidate_failure
  fi

  ROLLOUT_COMPLETE=1
  record status "passed_pending_finalization"
  record passed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  info "rollout succeeded"
  printf 'run_id=%s\nrun_dir=%s\nprevious_revision=%s\ncandidate_revision=%s\n' \
    "$RUN_ID" "$RUN_DIR" "$CURRENT_REVISION" "$CANDIDATE_REVISION"
}

main "$@"
