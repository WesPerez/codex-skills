#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly DEPLOY_DIR="/root/sub2api-prod-deploy"
readonly COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
readonly ENV_FILE="$DEPLOY_DIR/.env"
readonly RUN_ROOT="/root/backups/sub2api/upgrade-runs"
readonly APPLY_LOCK_FILE="/run/lock/sub2api-upgrade.lock"
readonly APP_IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
readonly APP_IMAGE="$APP_IMAGE_REPOSITORY:mine"
readonly APP_HEALTH_URL="http://127.0.0.1:13080/health"
readonly ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
readonly PUBLIC_HOST="wooai.cc.cd"
readonly HEALTH_TIMEOUT_SECONDS=180
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PLAN_SCRIPT="$SCRIPT_DIR/plan-sub2api-upgrade.sh"
readonly RELEASE_EVIDENCE_SCRIPT="$SCRIPT_DIR/verify-release-evidence.sh"
readonly PROMOTION_VERIFY_SCRIPT="$SCRIPT_DIR/verify-promoted-image.sh"
readonly SOURCE_REPO="/root/sub2api-repo"

MODE="preflight"
EXPECTED_REVISION=""
EXPECTED_DIGEST=""
PROMOTION_RUN_ID=""
VERIFICATION_EVIDENCE=""
VERIFICATION_EVIDENCE_SHA256=""
ROLLBACK_IMAGE_SAFE=0
RUN_ID=""
RUN_DIR=""
ROLLBACK_TAG=""
CURRENT_CONTAINER=""
CURRENT_IMAGE_ID=""
CURRENT_REVISION=""
CANDIDATE_IMAGE_ID=""
CANDIDATE_REVISION=""
CANDIDATE_IMAGE_REF=""
CANDIDATE_REPO_DIGESTS=""
SOURCE_PLAN_JSON=""
RELEASE_EVIDENCE_JSON=""
PROMOTION_VERIFICATION_JSON=""
CURRENT_REPO_DIGESTS=""
PRESERVE_ARTIFACTS=0
ROLLOUT_STARTED=0
ROLLOUT_COMPLETE=0
FAILURE_HANDLED=0
SUCCESS_COMMIT_STARTED=0

usage() {
  cat <<'USAGE'
Usage:
  update-sub2api.sh [--preflight]
  update-sub2api.sh --apply --expected-revision <40-char-git-sha> \
    --expected-digest <sha256:64-hex> --promotion-run-id <digits> \
    --verification-evidence <run-dir/release-evidence.json> \
    --rollback-image-safe

Default mode is read-only preflight. Apply mode only updates the production
sub2api service after it verifies a published mine image, creates a PostgreSQL
  sealed debug evidence, exact-digest promotion receipt, a PostgreSQL dump, and
  the currently running application image for rollback.
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

image_repo_digests_json() {
  docker image inspect -f '{{json .RepoDigests}}' "$1"
}

repo_digests_match() {
  local repo_digests="$1" expected="$2"
  jq -e --arg repo "$APP_IMAGE_REPOSITORY" --arg digest "$expected" '
    type=="array"
    and ([.[] | select(.==($repo + "@" + $digest))] | length)==1
  ' >/dev/null <<<"$repo_digests"
}

container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1"
}

last_manifest_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key {value = substr($0, length(key) + 2)} END {print value}' "$file"
}

prove_running_promoted_image() {
  [[ -d "$RUN_ROOT" ]] || return 1
  local run_dir manifest status revision digest image_id promotion_run evidence_sha
  local evidence_copy promotion_copy evidence_copy_sha promotion_copy_sha recorded_promotion_sha
  local evidence_source_run promotion_source_run
  local -a runs=()
  shopt -s nullglob
  runs=("$RUN_ROOT"/upgrade-*)
  shopt -u nullglob
  local index
  for (( index=${#runs[@]}-1; index>=0; index-- )); do
    run_dir="${runs[$index]}"
    [[ -d "$run_dir" ]] || continue
    [[ "$(cat "$run_dir/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    manifest="$run_dir/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(last_manifest_value status "$manifest")"
    [[ "$status" == "passed_pending_finalization" || "$status" == "finalized" ]] || continue
    revision="$(last_manifest_value candidate_revision "$manifest")"
    digest="$(last_manifest_value expected_digest "$manifest")"
    image_id="$(last_manifest_value candidate_image_id "$manifest")"
    promotion_run="$(last_manifest_value promotion_run_id "$manifest")"
    evidence_sha="$(last_manifest_value verification_evidence_sha256 "$manifest")"
    [[ "$revision" == "$CURRENT_REVISION" && "$image_id" == "$CURRENT_IMAGE_ID" ]] || continue
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || continue
    repo_digests_match "$CURRENT_REPO_DIGESTS" "$digest" || continue
    [[ "$promotion_run" =~ ^[0-9]+$ && "$evidence_sha" =~ ^[0-9a-f]{64}$ ]] || continue

    evidence_copy="$run_dir/verification-release-evidence.json"
    promotion_copy="$run_dir/promotion-verification.json"
    [[ -f "$evidence_copy" && ! -L "$evidence_copy" && -f "$promotion_copy" && ! -L "$promotion_copy" ]] || continue
    evidence_copy_sha="$(sha256sum "$evidence_copy" | awk '{print $1}')"
    promotion_copy_sha="$(sha256sum "$promotion_copy" | awk '{print $1}')"
    recorded_promotion_sha="$(last_manifest_value promotion_verification_sha256 "$manifest")"
    [[ "$evidence_copy_sha" == "$evidence_sha" && "$promotion_copy_sha" == "$recorded_promotion_sha" ]] || continue
    evidence_source_run="$(jq -r '.bindings.source_run_id // empty | tostring' "$evidence_copy")"
    promotion_source_run="$(jq -r '.promotion.source_run_id // empty | tostring' "$promotion_copy")"
    [[ "$evidence_source_run" =~ ^[0-9]+$ && "$promotion_source_run" == "$evidence_source_run" ]] || continue
    jq -e --arg run "$promotion_run" --arg revision "$revision" --arg digest "$digest" --arg evidence "$evidence_sha" \
      --arg source_run "$evidence_source_run" '
      (.promotion.promotion_run_id|tostring)==$run
      and .promotion.revision==$revision
      and .promotion.source_digest==$digest
      and .promotion.target_digest==$digest
      and (.promotion.source_run_id|tostring)==$source_run
      and .promotion.verification_evidence_sha256==$evidence
      and .image.pulled==true
      and .image.revision==$revision
      and .image.digest==$digest
      and .image.ref_name=="debug"
    ' "$promotion_copy" >/dev/null || continue
    return 0
  done
  return 1
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

restore_local_app_tag() {
  [[ -n "$CURRENT_IMAGE_ID" && -n "$CANDIDATE_IMAGE_ID" ]] || return 0
  docker image tag "$CURRENT_IMAGE_ID" "$APP_IMAGE" >/dev/null
  [[ "$(docker image inspect -f '{{.Id}}' "$APP_IMAGE")" == "$CURRENT_IMAGE_ID" ]]
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
    if (( SUCCESS_COMMIT_STARTED == 1 )) && [[ -n "$RUN_DIR" && -f "$RUN_DIR/manifest.env" ]] \
      && [[ "$(last_manifest_value status "$RUN_DIR/manifest.env")" == "passed_pending_finalization" ]] \
      && [[ "$(docker image inspect -f '{{.Id}}' "$APP_IMAGE" 2>/dev/null || true)" == "$CANDIDATE_IMAGE_ID" ]] \
      && [[ "$(docker inspect -f '{{.Image}}' "$(compose ps -q sub2api 2>/dev/null)" 2>/dev/null || true)" == "$CANDIDATE_IMAGE_ID" ]]; then
      ROLLOUT_COMPLETE=1
      warn "rollout completion was already committed; preserving the verified candidate instead of rolling it back"
      return
    fi
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
    restore_local_app_tag || warn "could not restore the local mine tag to the running image"
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
  CURRENT_REPO_DIGESTS="$(image_repo_digests_json "$CURRENT_IMAGE_ID")"
  [[ "$CURRENT_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "running image has no valid Git revision label"
  local current_ref_name
  current_ref_name="$(image_label "$CURRENT_IMAGE_ID" "org.opencontainers.image.ref.name")"
  case "$current_ref_name" in
    mine)
      ;;
    debug)
      prove_running_promoted_image \
        || die "running debug-labeled image has no matching successful owner-marked promotion rollout proof"
      ;;
    *)
      die "running application image has unsupported ref.name: ${current_ref_name:-<missing>}"
      ;;
  esac
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
  local evidence_source evidence_run_dir promotion_source_run evidence_source_run
  evidence_source="$(jq -r '.evidence' <<<"$RELEASE_EVIDENCE_JSON")"
  evidence_run_dir="$(jq -r '.run_dir' <<<"$RELEASE_EVIDENCE_JSON")"
  promotion_source_run="$(jq -r '.promotion.source_run_id|tostring' <<<"$PROMOTION_VERIFICATION_JSON")"
  evidence_source_run="$(jq -r '.source_run_id|tostring' <<<"$RELEASE_EVIDENCE_JSON")"
  [[ "$promotion_source_run" == "$evidence_source_run" ]] \
    || die "promotion source run differs from the sealed R0-1 workflow run"
  [[ -f "$evidence_source" && "$(dirname -- "$evidence_source")" == "$evidence_run_dir" ]] \
    || die "verified release evidence source disappeared before run creation"
  install -m 0600 "$evidence_source" "$RUN_DIR/verification-release-evidence.json"
  install -m 0600 "$evidence_run_dir/plan.json" "$RUN_DIR/verification-plan.json"
  install -m 0600 "$evidence_run_dir/fixture-manifest.json" "$RUN_DIR/verification-fixture-manifest.json"
  install -m 0600 "$evidence_run_dir/matrix-catalog.tsv" "$RUN_DIR/verification-matrix-catalog.tsv"
  install -m 0600 "$evidence_run_dir/adapter-catalog.tsv" "$RUN_DIR/verification-adapter-catalog.tsv"
  install -m 0600 "$evidence_run_dir/config-fingerprint.json" "$RUN_DIR/verification-config-fingerprint.json"
  printf '%s\n' "$PROMOTION_VERIFICATION_JSON" > "$RUN_DIR/promotion-verification.json"
  chmod 0600 "$RUN_DIR/promotion-verification.json"
  [[ "$(sha256sum "$RUN_DIR/verification-release-evidence.json" | awk '{print $1}')" == "$VERIFICATION_EVIDENCE_SHA256" ]] \
    || die "copied release evidence checksum changed"
  local copied_path copied_sha
  while IFS=$'\t' read -r copied_path copied_sha; do
    [[ "$copied_sha" =~ ^[0-9a-f]{64}$ ]] || die "sealed evidence has an invalid copied-input checksum"
    [[ "$(sha256sum "$copied_path" | awk '{print $1}')" == "$copied_sha" ]] \
      || die "copied verification input checksum changed: $copied_path"
  done < <(jq -r \
    --arg plan "$RUN_DIR/verification-plan.json" \
    --arg fixture "$RUN_DIR/verification-fixture-manifest.json" \
    --arg matrix "$RUN_DIR/verification-matrix-catalog.tsv" \
    --arg adapter "$RUN_DIR/verification-adapter-catalog.tsv" \
    --arg config "$RUN_DIR/verification-config-fingerprint.json" '
      [[$plan,.bindings.plan_sha256],
       [$fixture,.bindings.fixture_manifest_sha256],
       [$matrix,.bindings.matrix_catalog_sha256],
       [$adapter,.bindings.adapter_catalog_sha256],
       [$config,.bindings.config_fingerprint_document_sha256]][] | @tsv
    ' "$RUN_DIR/verification-release-evidence.json")
  record run_id "$RUN_ID"
  record created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  record expected_revision "$EXPECTED_REVISION"
  record expected_digest "$EXPECTED_DIGEST"
  record previous_image_id "$CURRENT_IMAGE_ID"
  record previous_revision "$CURRENT_REVISION"
  record candidate_image_id "$CANDIDATE_IMAGE_ID"
  record candidate_revision "$CANDIDATE_REVISION"
  record candidate_image_ref "$CANDIDATE_IMAGE_REF"
  record candidate_repo_digests "$CANDIDATE_REPO_DIGESTS"
  record promotion_run_id "$PROMOTION_RUN_ID"
  record promotion_source_run_id "$promotion_source_run"
  record evidence_source_run_id "$evidence_source_run"
  record verification_evidence_sha256 "$VERIFICATION_EVIDENCE_SHA256"
  record verification_evidence_source "$evidence_source"
  record verification_evidence_file "$RUN_DIR/verification-release-evidence.json"
  record promotion_verification_file "$RUN_DIR/promotion-verification.json"
  record promotion_verification_sha256 "$(sha256sum "$RUN_DIR/promotion-verification.json" | awk '{print $1}')"
  record running_upstream_base "$(jq -r '.running.upstream_base' <<<"$SOURCE_PLAN_JSON")"
  record candidate_upstream_base "$(jq -r '.candidate.upstream_base' <<<"$SOURCE_PLAN_JSON")"
  record running_version "$(jq -r '.running.version' <<<"$SOURCE_PLAN_JSON")"
  record candidate_version "$(jq -r '.candidate.version' <<<"$SOURCE_PLAN_JSON")"
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

check_source_baseline() {
  [[ -x "$PLAN_SCRIPT" ]] || die "source baseline gate is unavailable: $PLAN_SCRIPT"
  [[ -d "$SOURCE_REPO/.git" ]] || die "source repository is unavailable: $SOURCE_REPO"
  SOURCE_PLAN_JSON="$("$PLAN_SCRIPT" \
    --repo "$SOURCE_REPO" \
    --running-revision "$CURRENT_REVISION" \
    --candidate-revision "$EXPECTED_REVISION" \
    --upstream-ref upstream/main \
    --json)" || die "candidate failed the source baseline and VERSION gate"
  jq -e '.baseline_gate == "passed"' >/dev/null <<<"$SOURCE_PLAN_JSON" \
    || die "candidate source baseline evidence is invalid"
}

verify_release_and_promotion() {
  [[ -f "$RELEASE_EVIDENCE_SCRIPT" ]] || die "release evidence verifier is unavailable: $RELEASE_EVIDENCE_SCRIPT"
  [[ -f "$PROMOTION_VERIFY_SCRIPT" ]] || die "promotion verifier is unavailable: $PROMOTION_VERIFY_SCRIPT"
  RELEASE_EVIDENCE_JSON="$(bash "$RELEASE_EVIDENCE_SCRIPT" \
    --evidence "$VERIFICATION_EVIDENCE" \
    --expected-revision "$EXPECTED_REVISION" \
    --expected-digest "$EXPECTED_DIGEST")" \
    || die "sealed debug release evidence verification failed"
  VERIFICATION_EVIDENCE_SHA256="$(jq -r '.sha256 // empty' <<<"$RELEASE_EVIDENCE_JSON")"
  [[ "$VERIFICATION_EVIDENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "release evidence verifier returned no valid checksum"
  [[ "$(jq -r '.rollback_image_safe // false' <<<"$RELEASE_EVIDENCE_JSON")" == "true" ]] \
    || die "release evidence does not prove R0-8 image rollback compatibility"

  PROMOTION_VERIFICATION_JSON="$(bash "$PROMOTION_VERIFY_SCRIPT" \
    --expected-revision "$EXPECTED_REVISION" \
    --expected-digest "$EXPECTED_DIGEST" \
    --promotion-run-id "$PROMOTION_RUN_ID" \
    --verification-evidence-sha256 "$VERIFICATION_EVIDENCE_SHA256" \
    --pull)" || die "exact-digest promotion verification failed"
  jq -e --arg revision "$EXPECTED_REVISION" --arg digest "$EXPECTED_DIGEST" \
    --arg evidence "$VERIFICATION_EVIDENCE_SHA256" --arg run "$PROMOTION_RUN_ID" '
      (.promotion.promotion_run_id|tostring)==$run
      and .promotion.revision==$revision
      and .promotion.source_digest==$digest
      and .promotion.target_digest==$digest
      and .promotion.verification_evidence_sha256==$evidence
      and .image.pulled==true
      and .image.revision==$revision
      and .image.digest==$digest
      and .image.ref_name=="debug"
    ' >/dev/null <<<"$PROMOTION_VERIFICATION_JSON" \
    || die "promotion verifier output is not bound to the sealed candidate"
  local evidence_source_run promotion_source_run
  evidence_source_run="$(jq -r '.source_run_id // empty | tostring' <<<"$RELEASE_EVIDENCE_JSON")"
  promotion_source_run="$(jq -r '.promotion.source_run_id // empty | tostring' <<<"$PROMOTION_VERIFICATION_JSON")"
  [[ "$evidence_source_run" =~ ^[0-9]+$ ]] \
    || die "sealed release evidence has no valid R0-1 source workflow run"
  [[ "$promotion_source_run" == "$evidence_source_run" ]] \
    || die "promotion source run does not match the sealed R0-1 workflow run"
}

check_remote_candidate_heads() {
  local refs mine_sha debug_sha
  refs="$(git -C "$SOURCE_REPO" ls-remote --exit-code origin refs/heads/mine refs/heads/debug)" \
    || die "could not read current origin/mine and origin/debug heads"
  mine_sha="$(awk '$2=="refs/heads/mine" {print $1}' <<<"$refs")"
  debug_sha="$(awk '$2=="refs/heads/debug" {print $1}' <<<"$refs")"
  [[ "$mine_sha" == "$EXPECTED_REVISION" && "$debug_sha" == "$EXPECTED_REVISION" ]] \
    || die "remote branch heads no longer match promoted revision: mine=${mine_sha:-missing} debug=${debug_sha:-missing}"
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
  local running_ref_name
  local running_repo_digests
  local router_ready_url
  running_container="$(compose ps -q sub2api)" || return 1
  [[ -n "$running_container" ]] || return 1
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")" || return 1
  [[ "$running_image" == "$CANDIDATE_IMAGE_ID" ]] || return 1
  running_revision="$(image_label "$running_image" "org.opencontainers.image.revision")" || return 1
  [[ "$running_revision" == "$CANDIDATE_REVISION" ]] || return 1
  running_ref_name="$(image_label "$running_image" "org.opencontainers.image.ref.name")" || return 1
  [[ "$running_ref_name" == "debug" ]] || return 1
  running_repo_digests="$(image_repo_digests_json "$running_image")" || return 1
  repo_digests_match "$running_repo_digests" "$EXPECTED_DIGEST" || return 1
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
  CANDIDATE_IMAGE_REF="$APP_IMAGE_REPOSITORY:mine-sha-${EXPECTED_REVISION}@${EXPECTED_DIGEST}"
  docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1 && die "rollback tag unexpectedly exists: $ROLLBACK_TAG"
  docker image tag "$CURRENT_IMAGE_ID" "$ROLLBACK_TAG"
  info "binding the promotion-verified candidate image: $CANDIDATE_IMAGE_REF"
  CANDIDATE_IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$CANDIDATE_IMAGE_REF")"
  CANDIDATE_REVISION="$(image_label "$CANDIDATE_IMAGE_REF" "org.opencontainers.image.revision")"
  CANDIDATE_REPO_DIGESTS="$(image_repo_digests_json "$CANDIDATE_IMAGE_REF")"

  [[ "$(image_label "$CANDIDATE_IMAGE_REF" "org.opencontainers.image.ref.name")" == "debug" ]] \
    || die "promoted candidate content identity is not labeled debug"
  [[ "$CANDIDATE_REVISION" == "$EXPECTED_REVISION" ]] || die "pulled revision $CANDIDATE_REVISION does not match verified revision $EXPECTED_REVISION"
  repo_digests_match "$CANDIDATE_REPO_DIGESTS" "$EXPECTED_DIGEST" \
    || die "candidate repository digest does not match $EXPECTED_DIGEST"

  if [[ "$CANDIDATE_IMAGE_ID" == "$CURRENT_IMAGE_ID" ]]; then
    docker image tag "$CANDIDATE_IMAGE_ID" "$APP_IMAGE"
    [[ "$(docker image inspect -f '{{.Id}}' "$APP_IMAGE")" == "$CURRENT_IMAGE_ID" ]] || die "could not bind the local mine tag to the running image"
    release_rollback_tag
    info "no newer application image is available; production was not restarted"
    exit 0
  fi
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
      --expected-digest)
        (( $# >= 2 )) || die "--expected-digest requires a value"
        EXPECTED_DIGEST="$2"
        shift
        ;;
      --promotion-run-id)
        (( $# >= 2 )) || die "--promotion-run-id requires a value"
        PROMOTION_RUN_ID="$2"
        shift
        ;;
      --verification-evidence)
        (( $# >= 2 )) || die "--verification-evidence requires a value"
        VERIFICATION_EVIDENCE="$2"
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
    [[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "apply mode requires a sha256 image digest"
    [[ "$PROMOTION_RUN_ID" =~ ^[0-9]+$ ]] || die "apply mode requires --promotion-run-id with digits only"
    [[ -n "$VERIFICATION_EVIDENCE" && "$VERIFICATION_EVIDENCE" != *$'\n'* && "$VERIFICATION_EVIDENCE" != *$'\r'* ]] \
      || die "apply mode requires a safe --verification-evidence path"
    (( ROLLBACK_IMAGE_SAFE == 1 )) || die "apply mode requires an explicit proof of image rollback safety"
  fi
}

main() {
  parse_args "$@"
  if [[ "$MODE" == "apply" ]]; then
    require_command git
    acquire_apply_lock
  fi
  run_preflight
  [[ "$MODE" == "apply" ]] || exit 0
  check_source_baseline

  RUN_ID="upgrade-$(date -u +%Y%m%dT%H%M%SZ)-${EXPECTED_REVISION:0:12}"
  verify_release_and_promotion
  check_remote_candidate_heads
  pull_verified_candidate
  create_run
  create_database_dump
  record_background_writer_state
  assert_unchanged_before_rollout
  PRESERVE_ARTIFACTS=1
  ROLLOUT_STARTED=1

  info "replacing only the sub2api application container"
  if ! compose_with_image "$CANDIDATE_IMAGE_REF" up -d --no-deps --force-recreate sub2api; then
    handle_candidate_failure
  fi
  if ! verify_candidate_runtime; then
    handle_candidate_failure
  fi

  SUCCESS_COMMIT_STARTED=1
  if ! docker image tag "$CANDIDATE_IMAGE_ID" "$APP_IMAGE" \
    || [[ "$(docker image inspect -f '{{.Id}}' "$APP_IMAGE")" != "$CANDIDATE_IMAGE_ID" ]] \
    || ! record passed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    || ! record status "passed_pending_finalization"; then
    handle_candidate_failure
  fi
  ROLLOUT_COMPLETE=1
  info "rollout succeeded"
  printf 'run_id=%s\nrun_dir=%s\nprevious_revision=%s\ncandidate_revision=%s\n' \
    "$RUN_ID" "$RUN_DIR" "$CURRENT_REVISION" "$CANDIDATE_REVISION"
}

main "$@"
