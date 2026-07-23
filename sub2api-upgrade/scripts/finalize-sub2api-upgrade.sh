#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly RUN_ROOT="/root/backups/sub2api/upgrade-runs"
readonly APP_HEALTH_URL="http://127.0.0.1:13080/health"
readonly ROUTER_UPSTREAM_CONFIG="/etc/nginx/conf.d/codex-unified-router-upstream.conf"
readonly PUBLIC_HOST="wooai.cc.cd"
readonly APP_IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
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
  finalize-sub2api-upgrade.sh --list
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
  mapfile -t ports < <(
    sed -nE '/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083)([[:space:]][^;]*)?;([[:space:]]*#.*)?$/ {
      /[[:space:]](backup|down)([[:space:]]|;)/d
      s/^[[:space:]]*server[[:space:]]+127\.0\.0\.1:(13082|13083).*/\1/p
    }' "$ROUTER_UPSTREAM_CONFIG"
  )
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
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is unavailable"
  command -v awk >/dev/null 2>&1 || die "awk is unavailable"
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

  local candidate_revision candidate_image_id expected_digest
  candidate_revision="$(manifest_value candidate_revision "$manifest")"
  candidate_image_id="$(manifest_value candidate_image_id "$manifest")"
  expected_digest="$(manifest_value expected_digest "$manifest")"
  [[ "$candidate_revision" =~ ^[0-9a-f]{40}$ ]] || die "run has no valid candidate revision"
  [[ "$candidate_image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "run has no valid candidate image id"
  [[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "run has no valid expected digest"
  local database_dump
  local database_dump_sha256
  database_dump="$(manifest_value database_dump "$manifest")"
  database_dump_sha256="$(manifest_value database_dump_sha256 "$manifest")"
  [[ "$database_dump" == "$path/postgres.dump" ]] || die "run manifest has an unexpected database dump path"
  [[ -s "$database_dump" ]] || die "run database dump is missing or empty"
  [[ "$database_dump_sha256" =~ ^[0-9a-f]{64}$ ]] || die "run database dump has no valid sha256"
  [[ "$(sha256sum "$database_dump" | awk '{print $1}')" == "$database_dump_sha256" ]] || die "run database dump sha256 does not match"
  local -a running_containers=()
  mapfile -t running_containers < <(docker ps -q --filter 'name=^/sub2api-prod$')
  [[ "${#running_containers[@]}" == "1" ]] || die "production application container is not uniquely running"
  local running_container="${running_containers[0]}"
  local running_image
  local running_revision
  running_image="$(docker inspect -f '{{.Image}}' "$running_container")"
  running_revision="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$running_image")"
  [[ "$running_image" == "$candidate_image_id" ]] || die "production image id differs from finalized candidate"
  [[ "$running_revision" == "$candidate_revision" ]] || die "production revision differs from finalized candidate"
  local running_repo_digests running_ref_name
  running_repo_digests="$(docker image inspect -f '{{json .RepoDigests}}' "$running_image")"
  jq -e --arg repo "$APP_IMAGE_REPOSITORY" --arg digest "$expected_digest" '
    type=="array" and ([.[] | select(.==($repo+"@"+$digest))] | length)==1
  ' >/dev/null <<<"$running_repo_digests" || die "production digest differs from finalized candidate"
  running_ref_name="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.ref.name"}}' "$running_image")"

  local promotion_run_id
  promotion_run_id="$(manifest_value promotion_run_id "$manifest")"
  if [[ -n "$promotion_run_id" ]]; then
    [[ "$promotion_run_id" =~ ^[0-9]+$ ]] || die "run has invalid promotion run id"
    [[ "$running_ref_name" == "debug" ]] || die "promoted production image content identity is not debug"
    local evidence_file evidence_sha promotion_file promotion_sha
    evidence_file="$(manifest_value verification_evidence_file "$manifest")"
    evidence_sha="$(manifest_value verification_evidence_sha256 "$manifest")"
    promotion_file="$(manifest_value promotion_verification_file "$manifest")"
    promotion_sha="$(manifest_value promotion_verification_sha256 "$manifest")"
    [[ "$evidence_file" == "$path/verification-release-evidence.json" && -f "$evidence_file" && ! -L "$evidence_file" ]] \
      || die "run release evidence copy is missing or unsafe"
    [[ "$promotion_file" == "$path/promotion-verification.json" && -f "$promotion_file" && ! -L "$promotion_file" ]] \
      || die "run promotion verification copy is missing or unsafe"
    [[ "$evidence_sha" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$evidence_file" | awk '{print $1}')" == "$evidence_sha" ]] \
      || die "run release evidence checksum differs"
    [[ "$promotion_sha" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$promotion_file" | awk '{print $1}')" == "$promotion_sha" ]] \
      || die "run promotion verification checksum differs"
    local plan_copy fixture_copy matrix_copy adapter_copy config_copy
    plan_copy="$path/verification-plan.json"
    fixture_copy="$path/verification-fixture-manifest.json"
    matrix_copy="$path/verification-matrix-catalog.tsv"
    adapter_copy="$path/verification-adapter-catalog.tsv"
    config_copy="$path/verification-config-fingerprint.json"
    local copy expected_copy_sha
    for copy in "$plan_copy" "$fixture_copy" "$matrix_copy" "$adapter_copy" "$config_copy"; do
      [[ -f "$copy" && ! -L "$copy" ]] || die "run verification input copy is missing or unsafe: $copy"
    done
    jq -e '.bindings.adapter_bundle_sha256|type=="string" and test("^[0-9a-f]{64}$")' \
      "$evidence_file" >/dev/null || die "run evidence has no valid adapter_bundle_sha256"
    while IFS=$'\t' read -r copy expected_copy_sha; do
      [[ "$expected_copy_sha" =~ ^[0-9a-f]{64}$ ]] || die "run verification input has no valid bound checksum: $copy"
      [[ "$(sha256sum "$copy" | awk '{print $1}')" == "$expected_copy_sha" ]] \
        || die "run verification input checksum differs: $copy"
    done < <(jq -r --arg plan "$plan_copy" --arg fixture "$fixture_copy" --arg matrix "$matrix_copy" \
      --arg adapter "$adapter_copy" --arg config "$config_copy" '
      [[$plan,.bindings.plan_sha256],
       [$fixture,.bindings.fixture_manifest_sha256],
       [$matrix,.bindings.matrix_catalog_sha256],
       [$adapter,.bindings.adapter_catalog_sha256],
       [$config,.bindings.config_fingerprint_document_sha256]][] | @tsv
    ' "$evidence_file")
    local evidence_source_run promotion_source_run
    evidence_source_run="$(jq -r '.bindings.source_run_id // empty | tostring' "$evidence_file")"
    promotion_source_run="$(jq -r '.promotion.source_run_id // empty | tostring' "$promotion_file")"
    [[ "$evidence_source_run" =~ ^[0-9]+$ && "$promotion_source_run" == "$evidence_source_run" ]] \
      || die "promotion source run differs from the sealed R0-1 workflow run"
    jq -e --arg run "$promotion_run_id" --arg revision "$candidate_revision" --arg digest "$expected_digest" \
      --arg evidence "$evidence_sha" --arg source_run "$evidence_source_run" '
      (.promotion.promotion_run_id|tostring)==$run
      and .promotion.revision==$revision
      and .promotion.source_digest==$digest
      and .promotion.target_digest==$digest
      and (.promotion.source_run_id|tostring)==$source_run
      and .promotion.verification_evidence_sha256==$evidence
      and .promotion.evidence_binding_mode=="recorded-hash-production-apply-verifies-local-file"
      and .image.pulled==true and .image.revision==$revision and .image.digest==$digest
      and .image.ref_name=="debug"
    ' "$promotion_file" >/dev/null || die "run promotion verification no longer matches production"
  else
    [[ "$running_ref_name" == "mine" ]] || die "legacy rollout image is not labeled mine"
  fi
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

  if (( APPLY == 1 )) && [[ "$status" != "finalized" ]]; then
    printf 'status=finalized\nfinalized_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$manifest"
  fi
  info "preserved database dump, .env snapshot, Compose snapshot, and manifest in $path"
}

list_runs() {
  if [[ ! -d "$RUN_ROOT" ]]; then
    info "no skill-owned run root exists"
    return
  fi
  printf 'run_id\tstatus\tage_minutes\tcandidate_revision\tdump\n'
  local path manifest status age revision dump dump_state
  while IFS= read -r path; do
    [[ "$(cat "$path/.owner" 2>/dev/null || true)" == "sub2api-upgrade-v1" ]] || continue
    manifest="$path/manifest.env"
    [[ -f "$manifest" ]] || continue
    status="$(manifest_value status "$manifest")"
    age="$(run_age_minutes "$path")"
    revision="$(manifest_value candidate_revision "$manifest")"
    dump="$(manifest_value database_dump "$manifest")"
    dump_state="missing"
    [[ -n "$dump" && -s "$dump" ]] && dump_state="present"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$path")" "$status" "$age" "${revision:0:12}" "$dump_state"
  done < <(find "$RUN_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print | sort -r)
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
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="finalize"
        RUN_ID="$2"
        shift
        ;;
      --prune)
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="prune"
        ;;
      --list)
        [[ -z "$ACTION" ]] || die "select only one action"
        ACTION="list"
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
  [[ -n "$ACTION" ]] || die "select --list, --run-id, or --prune"
  if [[ "$ACTION" == "finalize" ]]; then
    assert_positive_integer "$MIN_AGE_MINUTES"
  elif [[ "$ACTION" == "list" && "$APPLY" == "1" ]]; then
    die "--apply is not valid with --list"
  fi
}

main() {
  parse_args "$@"
  if [[ "$ACTION" == "finalize" ]]; then
    finalize_run
  elif [[ "$ACTION" == "list" ]]; then
    list_runs
  else
    prune_runs
  fi
}

main "$@"
