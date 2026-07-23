#!/usr/bin/env bash
# Fixed-allowlist, recoverable debug adapter runner.
# Does not eval, does not accept command/url/path targets, does not print raw logs.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ADAPTER_DIR="$SCRIPT_DIR/debug-canary-adapters"
readonly OWNER_MARK="sub2api-debug-matrix-v1"
readonly RUNNER_ID="sub2api-debug-adapter-v1"
readonly DEFAULT_DEBUG_DIR="/root/sub2api-debug-deploy"
readonly DEFAULT_COMPOSE="$DEFAULT_DEBUG_DIR/docker-compose.yml"
readonly DEFAULT_ISOLATION="$SCRIPT_DIR/check-debug-isolation.sh"
readonly DEFAULT_FINGERPRINT="$SCRIPT_DIR/compute-debug-config-fingerprint.sh"
readonly DEFAULT_WAIT_BRANCH="$SCRIPT_DIR/wait-branch-image.sh"
readonly MATRIX_SCRIPT="$SCRIPT_DIR/run-debug-matrix.sh"
readonly TIMEOUT_BIN="/usr/bin/timeout"
readonly LOCK_NAME=".adapter.lock"
readonly BATCH_LOCK_NAME=".batch.lock"
readonly DEFAULT_GLOBAL_LOCK="/run/lock/sub2api-debug-adapter.lock"
readonly EC_PASSED=0
readonly EC_FAILED=70
readonly EC_NEEDS_MANUAL=78
readonly EC_BLOCKED=71

COMMAND=""; RUN_DIR=""; CASE_ID=""; ATTEMPT=""; FORCE_NEW_ATTEMPT=0
STOP_ON="end"
STOP_ON_SET=0
TEST_MODE=0
DEBUG_DIR="$DEFAULT_DEBUG_DIR"
COMPOSE_FILE="$DEFAULT_COMPOSE"
ISOLATION_SCRIPT="$DEFAULT_ISOLATION"
FINGERPRINT_SCRIPT="$DEFAULT_FINGERPRINT"
WAIT_BRANCH_SCRIPT="$DEFAULT_WAIT_BRANCH"
DOCKER_BIN="/usr/bin/docker"
CURL_BIN="/usr/bin/curl"
GLOBAL_LOCK_FILE="$DEFAULT_GLOBAL_LOCK"

usage() { cat <<'USAGE'
Usage:
  run-debug-adapter.sh run    --run-dir <dir> --case <id> [--attempt N] [--new-attempt]
  run-debug-adapter.sh resume --run-dir <dir> --case <id> [--attempt N]
  run-debug-adapter.sh status --run-dir <dir> --case <id> [--attempt N]
  run-debug-adapter.sh run-ready --run-dir <dir> [--stop-on end|first-nonpass]

Recoverable fixed-allowlist adapter runner. Reads adapter-catalog.tsv inside the
matrix run directory. Does not eval and does not accept command/url/path targets.
Exit codes: 0=passed, 70=failed, 78=needs_manual, 71=blocked.
run-ready processes unfinished matrix cases serially (R0-7 last); batch exit
priority is blocked(71) > failed(70) > needs_manual(78) > 0.
USAGE
}

info() { printf '%s\n' "[sub2api-debug-adapter] $*" >&2; }
die() { printf '%s\n' "[sub2api-debug-adapter] error: $*" >&2; exit "$EC_BLOCKED"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }
file_sha256() { sha256sum -- "$1" | awk '{print $1}'; }

adapter_bundle_sha256() {
  local file
  (
    cd "$SCRIPT_DIR"
    [[ -f run-debug-adapter.sh && ! -L run-debug-adapter.sh ]] || exit 1
    printf '%s\t%s\n' run-debug-adapter.sh "$(sha256sum run-debug-adapter.sh | awk '{print $1}')"
    while IFS= read -r file; do
      [[ -f "$file" && ! -L "$file" ]] || exit 1
      printf '%s\t%s\n' "$file" "$(sha256sum "$file" | awk '{print $1}')"
    done < <(find debug-canary-adapters -type f -print | LC_ALL=C sort)
  ) | sha256sum | awk '{print $1}'
}

atomic_write_json() {
  local dest="$1" content="$2" tmp
  tmp="$(mktemp "$dest.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dest"
  chmod 0600 "$dest"
}

path_under_tmp() { local p; p="$(realpath -m "$1")"; [[ "$p" == /tmp/* ]]; }
assert_safe_case_id() { [[ "$1" =~ ^[A-Z0-9]+(-[A-Z0-9]+)*$ ]] || die "invalid case id: $1"; }

parse_args() {
  (( $# >= 1 )) || { usage >&2; exit "$EC_BLOCKED"; }
  COMMAND="$1"; shift
  while (( $# > 0 )); do
    case "$1" in
      --run-dir) (( $# >= 2 )) || die "--run-dir requires a value"; RUN_DIR="$2"; shift ;;
      --case) (( $# >= 2 )) || die "--case requires a value"; CASE_ID="$2"; shift ;;
      --attempt) (( $# >= 2 )) || die "--attempt requires a value"; ATTEMPT="$2"; shift ;;
      --new-attempt) FORCE_NEW_ATTEMPT=1 ;;
      --stop-on)
        (( $# >= 2 )) || die "--stop-on requires a value"
        case "$2" in end|first-nonpass) STOP_ON="$2"; STOP_ON_SET=1 ;; *) die "invalid --stop-on: $2 (use end|first-nonpass)" ;; esac
        shift
        ;;
      --help|-h) usage; exit 0 ;;
      --command|--cmd|--url|--path|--target|--script|--exec|--eval) die "refusing injection argument: $1" ;;
      *) die "unknown or disallowed argument: $1" ;;
    esac
    shift
  done
}

configure_test_mode() {
  if [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]]; then TEST_MODE=1; fi
  if (( TEST_MODE == 1 )); then
    [[ -n "$RUN_DIR" ]] || die "--run-dir is required"
    path_under_tmp "$RUN_DIR" || die "test-mode run-dir must resolve under /tmp"
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_COMPOSE:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_COMPOSE" || die "test compose override must be under /tmp"
      COMPOSE_FILE="$SUB2API_DEBUG_ADAPTER_TEST_COMPOSE"
      DEBUG_DIR="$(dirname -- "$COMPOSE_FILE")"
    fi
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_DOCKER:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_DOCKER" || die "test docker override must be under /tmp"
      DOCKER_BIN="$SUB2API_DEBUG_ADAPTER_TEST_DOCKER"
    fi
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_ISOLATION:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_ISOLATION" || die "test isolation override must be under /tmp"
      ISOLATION_SCRIPT="$SUB2API_DEBUG_ADAPTER_TEST_ISOLATION"
    fi
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT" || die "test fingerprint override must be under /tmp"
      FINGERPRINT_SCRIPT="$SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT"
    fi
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_WAIT_BRANCH:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_WAIT_BRANCH" || die "test wait-branch override must be under /tmp"
      WAIT_BRANCH_SCRIPT="$SUB2API_DEBUG_ADAPTER_TEST_WAIT_BRANCH"
    fi
    if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_CURL:-}" ]]; then
      path_under_tmp "$SUB2API_DEBUG_ADAPTER_TEST_CURL" || die "test curl override must be under /tmp"
      CURL_BIN="$SUB2API_DEBUG_ADAPTER_TEST_CURL"
    fi
    GLOBAL_LOCK_FILE="$DEBUG_DIR/.global-adapter.lock"
  else
    [[ -z "${SUB2API_DEBUG_ADAPTER_TEST_COMPOSE:-}" && -z "${SUB2API_DEBUG_ADAPTER_TEST_DOCKER:-}" && -z "${SUB2API_DEBUG_ADAPTER_TEST_ISOLATION:-}" && -z "${SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT:-}" && -z "${SUB2API_DEBUG_ADAPTER_TEST_WAIT_BRANCH:-}" && -z "${SUB2API_DEBUG_ADAPTER_TEST_CURL:-}" ]] || die "test overrides require SUB2API_UPGRADE_TEST_MODE=1"
    COMPOSE_FILE="$DEFAULT_COMPOSE"; DEBUG_DIR="$DEFAULT_DEBUG_DIR"
    ISOLATION_SCRIPT="$DEFAULT_ISOLATION"; FINGERPRINT_SCRIPT="$DEFAULT_FINGERPRINT"
    WAIT_BRANCH_SCRIPT="$DEFAULT_WAIT_BRANCH"; DOCKER_BIN="/usr/bin/docker"; CURL_BIN="/usr/bin/curl"
    GLOBAL_LOCK_FILE="$DEFAULT_GLOBAL_LOCK"
  fi
}
require_run_dir() {
  [[ -n "$RUN_DIR" ]] || die "--run-dir is required"
  [[ -d "$RUN_DIR" ]] || die "run directory missing: $RUN_DIR"
  [[ -f "$RUN_DIR/.owner" ]] || die "run owner marker missing"
  [[ "$(tr -d '[:space:]' <"$RUN_DIR/.owner")" == "$OWNER_MARK" ]] || die "run owner marker mismatch"
  [[ -f "$RUN_DIR/state.json" ]] || die "state.json missing"
  [[ -f "$RUN_DIR/adapter-catalog.tsv" ]] || die "adapter-catalog.tsv missing"
  [[ -f "$MATRIX_SCRIPT" ]] || die "matrix state machine is unavailable"
}

with_lock() {
  local lock="$RUN_DIR/$LOCK_NAME"
  require_command flock
  exec 9>"$lock"
  flock -n 9 || die "another adapter runner holds the lock for $RUN_DIR"
}

with_global_debug_lock() {
  require_command flock
  exec 7>"$GLOBAL_LOCK_FILE"
  flock -n 7 || die "another debug adapter run owns the shared debug environment"
}

with_batch_lock_exclusive() {
  local lock="$RUN_DIR/$BATCH_LOCK_NAME"
  require_command flock
  exec 8>"$lock"
  flock -n 8 || die "another batch runner holds the exclusive lock for $RUN_DIR"
}

with_batch_lock_shared() {
  local lock="$RUN_DIR/$BATCH_LOCK_NAME"
  require_command flock
  exec 8>"$lock"
  flock -n -s 8 || die "another batch runner holds the exclusive lock for $RUN_DIR"
}

release_adapter_lock() {
  flock -u 9 2>/dev/null || true
}

load_matrix_bindings() {
  jq -c '{revision:.bindings.revision,digest:.bindings.digest,config_fingerprint:.bindings.config_fingerprint,
    adapter_catalog_sha256:(.bindings.adapter_catalog_sha256 // null),
    adapter_bundle_sha256:(.bindings.adapter_bundle_sha256 // null),status:.status}' "$RUN_DIR/state.json"
}

assert_matrix_bindings() {
  local bindings="$1" status rev dig cfg
  status="$(jq -r '.status' <<<"$bindings")"
  [[ "$status" != "invalidated" && "$status" != "sealed" ]] || die "matrix run is $status"
  rev="$(jq -r '.revision' <<<"$bindings")"
  dig="$(jq -r '.digest' <<<"$bindings")"
  cfg="$(jq -r '.config_fingerprint' <<<"$bindings")"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "invalid bound revision"
  [[ "$dig" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid bound digest"
  [[ "$cfg" =~ ^[0-9a-f]{64}$ ]] || die "invalid bound config fingerprint"
  local catalog_hash cur
  catalog_hash="$(jq -r '.adapter_catalog_sha256 // empty' <<<"$bindings")"
  [[ "$catalog_hash" =~ ^[0-9a-f]{64}$ ]] || die "matrix has no valid adapter catalog binding"
  cur="$(file_sha256 "$RUN_DIR/adapter-catalog.tsv")"
  [[ "$cur" == "$catalog_hash" ]] || die "adapter catalog fingerprint drift"
  local bundle_hash
  bundle_hash="$(adapter_bundle_sha256)" || die "could not hash debug adapter bundle"
  [[ "$bundle_hash" == "$(jq -r '.adapter_bundle_sha256 // empty' <<<"$bindings")" ]] \
    || die "debug adapter bundle fingerprint drift"
}

load_adapter_meta() {
  local case_id="$1" line
  line="$(awk -F '\t' -v id="$case_id" 'NR==1 && $1=="case_id" {next} $1==id {print; exit}' "$RUN_DIR/adapter-catalog.tsv" || true)"
  [[ -n "$line" ]] || die "case not present in adapter catalog: $case_id"
  local adapter_id resume_policy log_scope timeout_seconds evidence_kind
  IFS=$'\t' read -r _ adapter_id resume_policy log_scope timeout_seconds evidence_kind <<<"$line"
  case "$adapter_id" in manual|fixed-canary|candidate-identity|debug-startup|log-gate) ;; *) die "unknown adapter_id (not on allowlist): $adapter_id" ;; esac
  case "$resume_policy" in replay_safe|no_replay|session_resume) ;; *) die "invalid resume_policy: $resume_policy" ;; esac
  case "$log_scope" in none|sub2api|project) ;; *) die "invalid log_scope: $log_scope" ;; esac
  [[ "$timeout_seconds" =~ ^(0|[1-9][0-9]*)$ && "$timeout_seconds" -le 3600 ]] \
    || die "invalid timeout_seconds: $timeout_seconds"
  case "$evidence_kind" in manual-verification|candidate-identity|rollback-compatibility|debug-case-evidence) ;; *) die "invalid evidence_kind: $evidence_kind" ;; esac
  if [[ "$adapter_id" == "manual" ]]; then
    [[ "$timeout_seconds" == "0" ]] || die "manual adapter timeout must be zero"
  else
    (( timeout_seconds > 0 )) || die "automatic adapter timeout must be positive"
  fi
  jq -n --arg case_id "$case_id" --arg adapter_id "$adapter_id" --arg resume_policy "$resume_policy" --arg log_scope "$log_scope" --argjson timeout_seconds "$timeout_seconds" --arg evidence_kind "$evidence_kind" '{case_id:$case_id,adapter_id:$adapter_id,resume_policy:$resume_policy,log_scope:$log_scope,timeout_seconds:$timeout_seconds,evidence_kind:$evidence_kind}'
}

adapter_script_for() {
  case "$1" in
    manual) printf '%s\n' "$ADAPTER_DIR/manual.sh" ;;
    fixed-canary) printf '%s\n' "$ADAPTER_DIR/fixed-canary.sh" ;;
    candidate-identity) printf '%s\n' "$ADAPTER_DIR/candidate-identity.sh" ;;
    debug-startup) printf '%s\n' "$ADAPTER_DIR/debug-startup.sh" ;;
    log-gate) printf '%s\n' "$ADAPTER_DIR/log-gate.sh" ;;
    *) die "adapter mapping failed: $1" ;;
  esac
}

attempt_dir_for() { printf '%s/cases/%s/attempt-%03d\n' "$RUN_DIR" "$CASE_ID" "$1"; }
state_path_for() { printf '%s/adapter-state.json\n' "$(attempt_dir_for "$1")"; }

matrix_case_json() {
  jq -c --arg id "$CASE_ID" '.cases[] | select(.id==$id)' "$RUN_DIR/state.json"
}

matrix_start() {
  local -a args=(start --run-dir "$RUN_DIR" --case "$CASE_ID")
  [[ -z "$ATTEMPT" ]] || args+=(--attempt "$ATTEMPT")
  (( FORCE_NEW_ATTEMPT == 0 )) || args+=(--new-attempt)
  bash "$MATRIX_SCRIPT" "${args[@]}" >/dev/null
}

matrix_resume_start() {
  local -a args=(start --run-dir "$RUN_DIR" --case "$CASE_ID")
  [[ -z "$ATTEMPT" ]] || args+=(--attempt "$ATTEMPT")
  bash "$MATRIX_SCRIPT" "${args[@]}" >/dev/null
}

matrix_finish() {
  local status="$1" attempt="$2" evidence="$3" log_window="$4" note="$5"
  local -a args=(finish --run-dir "$RUN_DIR" --case "$CASE_ID" --attempt "$attempt" --status "$status")
  [[ -z "$evidence" ]] || args+=(--evidence "$evidence")
  [[ -z "$log_window" ]] || args+=(--log-window "$log_window")
  [[ -z "$note" ]] || args+=(--note "$note")
  bash "$MATRIX_SCRIPT" "${args[@]}" >/dev/null
}

read_state() { [[ -f "$1" ]] || die "adapter-state.json missing: $1"; jq -c . "$1"; }
write_state() { atomic_write_json "$1" "$(jq -c . <<<"$2")"; }

assert_adapter_state_binding() {
  local state="$1" attempt="$2" meta="$3" bindings="$4"
  jq -e --arg runner "$RUNNER_ID" --arg case_id "$CASE_ID" --argjson attempt "$attempt" \
    --arg adapter_id "$(jq -r '.adapter_id' <<<"$meta")" \
    --arg resume_policy "$(jq -r '.resume_policy' <<<"$meta")" \
    --arg log_scope "$(jq -r '.log_scope' <<<"$meta")" \
    --arg evidence_kind "$(jq -r '.evidence_kind' <<<"$meta")" \
    --arg revision "$(jq -r '.revision' <<<"$bindings")" \
    --arg digest "$(jq -r '.digest' <<<"$bindings")" \
    --arg config "$(jq -r '.config_fingerprint' <<<"$bindings")" '
    .schema_version==1 and .runner==$runner and .case_id==$case_id and .attempt==$attempt
    and .adapter_id==$adapter_id and .resume_policy==$resume_policy and .log_scope==$log_scope
    and .evidence_kind==$evidence_kind and .bindings.revision==$revision
    and .bindings.digest==$digest and .bindings.config_fingerprint==$config
  ' >/dev/null <<<"$state" || die "adapter checkpoint binding mismatch"
}

result_to_exit() { case "$1" in passed) printf '%s\n' "$EC_PASSED" ;; failed) printf '%s\n' "$EC_FAILED" ;; needs_manual) printf '%s\n' "$EC_NEEDS_MANUAL" ;; *) printf '%s\n' "$EC_BLOCKED" ;; esac; }
exit_to_result() { case "$1" in 0) printf 'passed\n' ;; 70) printf 'failed\n' ;; 78) printf 'needs_manual\n' ;; *) printf 'blocked\n' ;; esac; }

run_preflight_non_test() {
  local bindings="$1" isolation_json live_fp bound_fp
  [[ -f "$ISOLATION_SCRIPT" ]] || die "isolation script missing"
  [[ -f "$FINGERPRINT_SCRIPT" ]] || die "fingerprint script missing"
  isolation_json="$(bash "$ISOLATION_SCRIPT")" || die "debug isolation check failed"
  jq -e '.isolated==true' >/dev/null <<<"$isolation_json" || die "debug isolation report is not isolated"
  live_fp="$(bash "$FINGERPRINT_SCRIPT" --json)" || die "could not compute debug config fingerprint"
  bound_fp="$(jq -r '.config_fingerprint' <<<"$bindings")"
  [[ "$(jq -r '.fingerprint // empty' <<<"$live_fp")" == "$bound_fp" ]] || die "live config fingerprint does not match matrix binding"
}

run_preflight_test() {
  local bindings="$1"
  if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_ISOLATION:-}" ]]; then bash "$ISOLATION_SCRIPT" >/dev/null || die "test isolation check failed"; fi
  if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT:-}" ]]; then
    local live_fp bound_fp
    live_fp="$(bash "$FINGERPRINT_SCRIPT" --json)" || die "test fingerprint failed"
    bound_fp="$(jq -r '.config_fingerprint' <<<"$bindings")"
    [[ "$(jq -r '.fingerprint // empty' <<<"$live_fp")" == "$bound_fp" ]] || die "test fingerprint does not match matrix binding"
  fi
}
collect_logs() {
  local attempt_dir="$1" log_scope="$2" since_utc="$3" until_utc="$4"
  local out="$attempt_dir/log-window.raw" argv_file="$attempt_dir/log-collect.argv" meta="$attempt_dir/log-window.meta.json"
  if [[ "$log_scope" == "none" ]]; then
    jq -n --arg since "$since_utc" --arg until "$until_utc" '{collected:false,scope:"none",since:$since,until:$until,path:null,sha256:null}' > "$meta"
    chmod 0600 "$meta"; return 0
  fi
  [[ -f "$COMPOSE_FILE" ]] || die "debug compose file missing: $COMPOSE_FILE"
  if (( TEST_MODE == 0 )); then
    [[ "$(realpath -e "$COMPOSE_FILE")" == "$DEFAULT_COMPOSE" ]] || die "compose path must be the fixed debug compose"
  else
    path_under_tmp "$COMPOSE_FILE" || die "test compose must be under /tmp"
  fi
  local -a cmd=("$DOCKER_BIN" compose --project-directory "$DEBUG_DIR" -f "$COMPOSE_FILE" logs --no-color --timestamps --since "$since_utc" --until "$until_utc")
  if [[ "$log_scope" == "sub2api" ]]; then
    cmd+=("sub2api")
  else
    cmd+=("sub2api" "postgres" "redis")
  fi
  : > "$argv_file"
  local a; for a in "${cmd[@]}"; do printf '%s\n' "$a" >> "$argv_file"; done
  chmod 0600 "$argv_file"
  local rc=0
  "${cmd[@]}" >"$out" 2>"$attempt_dir/log-collect.stderr" || rc=$?
  if (( rc != 0 )); then rm -f -- "$out"; return "$EC_BLOCKED"; fi
  chmod 0600 "$out"
  local sha; sha="$(file_sha256 "$out")"
  jq -n --arg since "$since_utc" --arg until "$until_utc" --arg scope "$log_scope" --arg path "log-window.raw" --arg sha256 "$sha" --arg compose "$COMPOSE_FILE" '{collected:true,scope:$scope,since:$since,until:$until,path:$path,sha256:$sha256,compose_file:$compose,raw_printed:false}' > "$meta"
  chmod 0600 "$meta"; return 0
}

validate_debug_case_evidence() {
  local path="$1" case_id="$2" revision="$3" digest="$4" adapter_id="$5"
  jq -e --arg case_id "$case_id" --arg revision "$revision" --arg digest "$digest" --arg adapter_id "$adapter_id" --arg runner "$RUNNER_ID" '
    .schema_version==1 and .kind=="debug-case-evidence" and .runner==$runner and .case_id==$case_id
    and .revision==$revision and .digest==$digest and .adapter_id==$adapter_id and .status=="passed"
    and (.started_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.ended_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .target.environment=="debug" and .target.compose_project=="sub2api-debug"
    and (.target.deploy_dir=="/root/sub2api-debug-deploy" or .target.test_mode==true)
    and (.assertions|type=="array" and length>0)
    and all(.assertions[]; (.name|type=="string" and length>0) and .passed==true)
  ' "$path" >/dev/null
}

validate_candidate_identity_evidence() {
  local path="$1" revision="$2" digest="$3"
  jq -e --arg revision "$revision" --arg digest "$digest" --arg reference "ghcr.io/wesperez/sub2api:debug-sha-${revision}@${digest}" '
    .schema_version==1 and .kind=="candidate-identity" and .revision==$revision and .digest==$digest
    and .image_reference==$reference and .workflow_name=="Docker Branch Images"
    and (.workflow_run_id|tostring|test("^[0-9]+$")) and .ci_conclusion=="success" and .ref_name=="debug"
    and (.container_image_id|type=="string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$path" >/dev/null
}

validate_staged_evidence() {
  local path="$1" evidence_kind="$2" case_id="$3" revision="$4" digest="$5" adapter_id="$6"
  [[ -s "$path" ]] || return 1
  case "$evidence_kind" in
    debug-case-evidence) validate_debug_case_evidence "$path" "$case_id" "$revision" "$digest" "$adapter_id" ;;
    candidate-identity) validate_candidate_identity_evidence "$path" "$revision" "$digest" ;;
    manual-verification|rollback-compatibility) return 0 ;;
    *) return 1 ;;
  esac
}

execute_adapter() {
  local attempt_dir="$1" meta="$2" bindings="$3" state="$4"
  local adapter_id script timeout_seconds evidence_kind revision digest cfg
  adapter_id="$(jq -r '.adapter_id' <<<"$meta")"
  script="$(adapter_script_for "$adapter_id")"
  [[ -f "$script" && ! -L "$script" ]] || die "adapter script missing or symlinked: $script"
  [[ "$(realpath -e "$script")" == "$ADAPTER_DIR"/* ]] || die "adapter script escapes fixed bundle"
  timeout_seconds="$(jq -r '.timeout_seconds' <<<"$meta")"
  evidence_kind="$(jq -r '.evidence_kind' <<<"$meta")"
  revision="$(jq -r '.revision' <<<"$bindings")"
  digest="$(jq -r '.digest' <<<"$bindings")"
  cfg="$(jq -r '.config_fingerprint' <<<"$bindings")"
  local staging="$attempt_dir/staging"; install -d -m 0700 "$staging"
  local evidence_out="$staging/evidence.json"; rm -f -- "$evidence_out"
  local log_file=""; [[ -f "$attempt_dir/log-window.raw" ]] && log_file="$attempt_dir/log-window.raw"
  local started_at; started_at="$(jq -r '.adapter_started_at // .started_at' <<<"$state")"
  if [[ -z "$started_at" || "$started_at" == "null" ]]; then started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
  export ADAPTER_RUNNER="$RUNNER_ID" ADAPTER_CASE_ID="$CASE_ID"
  export ADAPTER_ATTEMPT="$(jq -r '.attempt' <<<"$state")" ADAPTER_RUN_DIR="$RUN_DIR" ADAPTER_ATTEMPT_DIR="$attempt_dir"
  export ADAPTER_EVIDENCE_OUT="$evidence_out" ADAPTER_REVISION="$revision" ADAPTER_DIGEST="$digest"
  export ADAPTER_CONFIG_FINGERPRINT="$cfg" ADAPTER_TIMEOUT_SECONDS="$timeout_seconds"
  export ADAPTER_LOG_SCOPE="$(jq -r '.log_scope' <<<"$meta")" ADAPTER_RESUME_POLICY="$(jq -r '.resume_policy' <<<"$meta")"
  export ADAPTER_EVIDENCE_KIND="$evidence_kind" ADAPTER_ADAPTER_ID="$adapter_id" ADAPTER_STARTED_AT="$started_at"
  export ADAPTER_DEBUG_DIR="$DEBUG_DIR" ADAPTER_COMPOSE_FILE="$COMPOSE_FILE"
  export ADAPTER_DOCKER_BIN="$DOCKER_BIN" ADAPTER_CURL_BIN="$CURL_BIN"
  export ADAPTER_WAIT_BRANCH_SCRIPT="$WAIT_BRANCH_SCRIPT" ADAPTER_TEST_MODE="$TEST_MODE"
  if [[ -n "$log_file" ]]; then export ADAPTER_LOG_FILE="$log_file"; else unset ADAPTER_LOG_FILE || true; fi
  local rc=0 stdout_file="$attempt_dir/adapter.stdout" stderr_file="$attempt_dir/adapter.stderr"
  : > "$stdout_file"; : > "$stderr_file"
  chmod 0600 "$stdout_file" "$stderr_file"
  if (( timeout_seconds > 0 )); then
    "$TIMEOUT_BIN" --signal=TERM --kill-after=5s "$timeout_seconds" bash "$script" \
      >"$stdout_file" 2>"$stderr_file" || rc=$?
  else
    bash "$script" >"$stdout_file" 2>"$stderr_file" || rc=$?
  fi
  if (( rc == 124 )); then rc=$EC_BLOCKED; fi
  local ended_at; ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\t%s\t%s\n' "$rc" "$started_at" "$ended_at"
}
finalize_result() {
  local attempt_dir="$1" state_path="$2" state="$3" meta="$4" bindings="$5" adapter_rc="$6" started_at="$7" ended_at="$8"
  local result note evidence_kind revision digest adapter_id evidence_out attempt
  result="$(exit_to_result "$adapter_rc")"
  note="$(jq -r '.note // empty' <<<"$state")"
  evidence_kind="$(jq -r '.evidence_kind' <<<"$meta")"
  revision="$(jq -r '.revision' <<<"$bindings")"
  digest="$(jq -r '.digest' <<<"$bindings")"
  adapter_id="$(jq -r '.adapter_id' <<<"$meta")"
  evidence_out="$attempt_dir/staging/evidence.json"
  if [[ "$result" == "passed" ]]; then
    if [[ "$evidence_kind" == "debug-case-evidence" || "$evidence_kind" == "candidate-identity" ]]; then
      if ! validate_staged_evidence "$evidence_out" "$evidence_kind" "$CASE_ID" "$revision" "$digest" "$adapter_id"; then
        result="failed"; adapter_rc=$EC_FAILED; note="evidence contract validation failed"
      fi
    fi
  fi
  local evidence_rel="" evidence_sha=""
  if [[ -s "$evidence_out" ]]; then
    install -m 0600 "$evidence_out" "$attempt_dir/evidence.json"
    evidence_sha="$(file_sha256 "$attempt_dir/evidence.json")"; evidence_rel="evidence.json"
  fi
  local log_json="null"
  [[ -f "$attempt_dir/log-window.meta.json" ]] && log_json="$(jq -c . "$attempt_dir/log-window.meta.json")"
  local log_path=""
  if [[ "$(jq -r '.log_scope' <<<"$meta")" != "none" ]]; then
    if [[ -s "$attempt_dir/log-window.raw" ]]; then
      log_path="$attempt_dir/log-window.raw"
    elif [[ "$result" == "passed" ]]; then
      result="blocked"; adapter_rc=$EC_BLOCKED; note="debug log window is empty"
    fi
  fi
  if [[ "$result" == "passed" && ! -s "$attempt_dir/evidence.json" ]]; then
    result="failed"; adapter_rc=$EC_FAILED; note="passed adapter produced no evidence"
  fi
  attempt="$(jq -r '.attempt' <<<"$state")"
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state="$(jq -c --arg phase "logs_done" --arg result "$result" --argjson exit_code "$adapter_rc" --arg started_at "$started_at" --arg ended_at "$ended_at" --arg updated_at "$now" --arg note "$note" --arg evidence_path "$evidence_rel" --arg evidence_sha "$evidence_sha" --argjson log_window "$log_json" '.phase=$phase | .result=$result | .exit_code=$exit_code | .adapter_started_at=$started_at | .ended_at=$ended_at | .updated_at=$updated_at | .note=(if $note=="" then null else $note end) | .evidence=(if $evidence_path=="" then null else {path:$evidence_path,sha256:$evidence_sha} end) | .log_window=$log_window' <<<"$state")"
  write_state "$state_path" "$state"
  if ! matrix_finish "$result" "$attempt" "$(if [[ -s "$attempt_dir/evidence.json" ]]; then printf '%s' "$attempt_dir/evidence.json"; fi)" "$log_path" "$note"; then
    info "matrix finish failed; checkpoint remains logs_done"
    return "$EC_BLOCKED"
  fi
  state="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.phase="finished" | .updated_at=$now' <<<"$state")"
  write_state "$state_path" "$state"
  info "finished case=$CASE_ID attempt=$(jq -r '.attempt' <<<"$state") result=$result"
  printf 'status=%s case=%s attempt=%s phase=finished exit_code=%s\n' "$result" "$CASE_ID" "$(jq -r '.attempt' <<<"$state")" "$adapter_rc"
  return "$adapter_rc"
}

mark_blocked() {
  local state_path="$1" state="$2" note="$3" now attempt attempt_dir evidence_path="" log_path=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  attempt="$(jq -r '.attempt' <<<"$state")"
  attempt_dir="$(attempt_dir_for "$attempt")"
  [[ -s "$attempt_dir/evidence.json" ]] && evidence_path="$attempt_dir/evidence.json"
  [[ -s "$attempt_dir/log-window.raw" ]] && log_path="$attempt_dir/log-window.raw"
  state="$(jq -c --arg note "$note" --arg now "$now" '.phase="logs_done" | .result="blocked" | .exit_code=71 | .ended_at=$now | .updated_at=$now | .note=$note' <<<"$state")"
  write_state "$state_path" "$state"
  if ! matrix_finish blocked "$attempt" "$evidence_path" "$log_path" "$note"; then
    info "matrix finish failed while marking blocked; checkpoint remains logs_done"
    return "$EC_BLOCKED"
  fi
  state="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.phase="finished" | .updated_at=$now' <<<"$state")"
  write_state "$state_path" "$state"
  info "blocked: $note"
  printf 'status=blocked case=%s attempt=%s phase=finished exit_code=71\n' "$CASE_ID" "$(jq -r '.attempt' <<<"$state")"
  return "$EC_BLOCKED"
}
drive_from_phase() {
  local attempt_dir="$1" state_path="$2" state="$3" meta="$4" bindings="$5"
  local phase resume_policy log_scope
  phase="$(jq -r '.phase' <<<"$state")"
  resume_policy="$(jq -r '.resume_policy' <<<"$meta")"
  log_scope="$(jq -r '.log_scope' <<<"$meta")"
  case "$phase" in
    finished)
      local result exit_code
      result="$(jq -r '.result // "blocked"' <<<"$state")"
      local matrix_case matrix_status matrix_attempt
      matrix_case="$(matrix_case_json)"
      [[ -n "$matrix_case" ]] || die "case disappeared from matrix state"
      matrix_status="$(jq -r '.status' <<<"$matrix_case")"
      matrix_attempt="$(jq -r '.current_attempt' <<<"$matrix_case")"
      [[ "$matrix_status" == "$result" && "$matrix_attempt" == "$(jq -r '.attempt' <<<"$state")" ]] \
        || die "finished adapter checkpoint does not match matrix state"
      exit_code="$(result_to_exit "$result")"
      printf 'status=%s case=%s attempt=%s phase=finished exit_code=%s\n' "$result" "$CASE_ID" "$(jq -r '.attempt' <<<"$state")" "$exit_code"
      return "$exit_code"
      ;;
    ambiguous)
      mark_blocked "$state_path" "$state" "attempt left in ambiguous phase"
      return "$EC_BLOCKED"
      ;;
    executing)
      if [[ "$resume_policy" == "no_replay" || "$resume_policy" == "session_resume" ]]; then
        if [[ "$log_scope" != "none" ]]; then
          local interrupted_since interrupted_until
          interrupted_since="$(jq -r '.log_since // .started_at' <<<"$state")"
          interrupted_until="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          if collect_logs "$attempt_dir" "$log_scope" "$interrupted_since" "$interrupted_until"; then
            state="$(jq -c --arg until "$interrupted_until" --arg now "$interrupted_until" \
              --argjson log_window "$(jq -c . "$attempt_dir/log-window.meta.json")" \
              '.log_until=$until | .updated_at=$now | .log_window=$log_window' <<<"$state")"
            write_state "$state_path" "$state"
          fi
        fi
        mark_blocked "$state_path" "$state" "interrupted during executing with resume_policy=$resume_policy; refuse re-dispatch"
        return "$EC_BLOCKED"
      fi
      if [[ "$resume_policy" != "replay_safe" ]]; then
        mark_blocked "$state_path" "$state" "cannot safely resume executing phase"
        return "$EC_BLOCKED"
      fi
      ;;
    prepared|adapter_done|logs_done) ;;
    *)
      mark_blocked "$state_path" "$state" "unknown phase: $phase"
      return "$EC_BLOCKED"
      ;;
  esac

  local since_utc until_utc
  if [[ "$phase" == "prepared" || "$phase" == "executing" ]]; then
    if [[ "$(jq -r '.adapter_id' <<<"$meta")" == "log-gate" && "$log_scope" != "none" ]]; then
      since_utc="$(jq -r '.log_since // .started_at' <<<"$state")"
      until_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if ! collect_logs "$attempt_dir" "$log_scope" "$since_utc" "$until_utc"; then
        mark_blocked "$state_path" "$state" "log collection failed before log-gate"
        return "$EC_BLOCKED"
      fi
      state="$(jq -c --arg until "$until_utc" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson log_window "$(jq -c . "$attempt_dir/log-window.meta.json")" '.log_until=$until | .updated_at=$now | .log_window=$log_window' <<<"$state")"
      write_state "$state_path" "$state"
    fi
    state="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.phase="executing" | .updated_at=$now | .adapter_started_at=(.adapter_started_at // $now)' <<<"$state")"
    write_state "$state_path" "$state"
    local exec_out adapter_rc started_at ended_at execute_status=0
    if exec_out="$(execute_adapter "$attempt_dir" "$meta" "$bindings" "$state")"; then
      execute_status=0
    else
      execute_status=$?
    fi
    if (( execute_status != 0 )); then
      adapter_rc=$EC_BLOCKED
      started_at="$(jq -r '.adapter_started_at // .started_at' <<<"$state")"
      ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      adapter_rc="$(printf '%s\n' "$exec_out" | tail -n1 | cut -f1)"
      started_at="$(printf '%s\n' "$exec_out" | tail -n1 | cut -f2)"
      ended_at="$(printf '%s\n' "$exec_out" | tail -n1 | cut -f3)"
      [[ "$adapter_rc" =~ ^[0-9]+$ ]] || adapter_rc=$EC_BLOCKED
      [[ "$started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || started_at="$(jq -r '.adapter_started_at // .started_at' <<<"$state")"
      [[ "$ended_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    state="$(jq -c --arg now "$ended_at" --argjson rc "$adapter_rc" '.phase="adapter_done" | .updated_at=$now | .adapter_exit_code=$rc | .adapter_ended_at=$now' <<<"$state")"
    write_state "$state_path" "$state"
    phase="adapter_done"
  fi

  if [[ "$phase" == "adapter_done" ]]; then
    if [[ "$(jq -r '.adapter_id' <<<"$meta")" != "log-gate" && "$log_scope" != "none" ]]; then
      since_utc="$(jq -r '.log_since // .started_at' <<<"$state")"
      until_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if ! collect_logs "$attempt_dir" "$log_scope" "$since_utc" "$until_utc"; then
        mark_blocked "$state_path" "$state" "log collection failed after adapter"
        return "$EC_BLOCKED"
      fi
      state="$(jq -c --arg until "$until_utc" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson log_window "$(jq -c . "$attempt_dir/log-window.meta.json")" '.phase="logs_done" | .log_until=$until | .updated_at=$now | .log_window=$log_window' <<<"$state")"
    else
      state="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.phase="logs_done" | .updated_at=$now' <<<"$state")"
    fi
    write_state "$state_path" "$state"
    phase="logs_done"
  fi

  if [[ "$phase" == "logs_done" ]]; then
    local adapter_rc started_at ended_at
    adapter_rc="$(jq -r '.adapter_exit_code // 71' <<<"$state")"
    started_at="$(jq -r '.adapter_started_at // .started_at' <<<"$state")"
    ended_at="$(jq -r '.adapter_ended_at // empty' <<<"$state")"
    [[ -n "$ended_at" ]] || ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    finalize_result "$attempt_dir" "$state_path" "$state" "$meta" "$bindings" "$adapter_rc" "$started_at" "$ended_at"
    return $?
  fi
  mark_blocked "$state_path" "$state" "internal phase drive failure"
  return "$EC_BLOCKED"
}
init_prepared_state() {
  local attempt="$1" meta="$2" bindings="$3" attempt_dir state_path now log_since state
  attempt_dir="$(attempt_dir_for "$attempt")"
  state_path="$(state_path_for "$attempt")"
  install -d -m 0700 "$RUN_DIR/cases/$CASE_ID" "$attempt_dir" "$attempt_dir/staging"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log_since="$now"
  if [[ "$(jq -r '.adapter_id' <<<"$meta")" == "log-gate" ]]; then
    log_since="$(jq -r '.created_at // empty' "$RUN_DIR/state.json")"
    [[ "$log_since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || die "matrix run has no valid created_at for log-gate"
  fi
  state="$(jq -n \
    --arg runner "$RUNNER_ID" \
    --arg case_id "$CASE_ID" \
    --argjson attempt "$attempt" \
    --arg adapter_id "$(jq -r '.adapter_id' <<<"$meta")" \
    --arg resume_policy "$(jq -r '.resume_policy' <<<"$meta")" \
    --arg log_scope "$(jq -r '.log_scope' <<<"$meta")" \
    --argjson timeout_seconds "$(jq -r '.timeout_seconds' <<<"$meta")" \
    --arg evidence_kind "$(jq -r '.evidence_kind' <<<"$meta")" \
    --arg revision "$(jq -r '.revision' <<<"$bindings")" \
    --arg digest "$(jq -r '.digest' <<<"$bindings")" \
    --arg config_fingerprint "$(jq -r '.config_fingerprint' <<<"$bindings")" \
    --arg started_at "$now" \
    --arg log_since "$log_since" \
    --argjson test_mode "$TEST_MODE" \
    '{schema_version:1,runner:$runner,case_id:$case_id,attempt:$attempt,adapter_id:$adapter_id,resume_policy:$resume_policy,log_scope:$log_scope,timeout_seconds:$timeout_seconds,evidence_kind:$evidence_kind,phase:"prepared",result:null,exit_code:null,started_at:$started_at,updated_at:$started_at,ended_at:null,log_since:$log_since,log_until:null,log_window:null,evidence:null,note:null,test_mode:($test_mode==1),bindings:{revision:$revision,digest:$digest,config_fingerprint:$config_fingerprint}}')"
  write_state "$state_path" "$state"
  printf '%s\n' "$state"
}

cmd_status() {
  require_command jq
  require_run_dir
  assert_safe_case_id "$CASE_ID"
  local attempt state_path matrix_case
  matrix_case="$(matrix_case_json)"
  [[ -n "$matrix_case" ]] || die "case not present in matrix state"
  attempt="$(jq -r '.current_attempt // 0' <<<"$matrix_case")"
  if [[ -n "$ATTEMPT" ]]; then
    [[ "$ATTEMPT" =~ ^[0-9]+$ && "$ATTEMPT" -ge 1 ]] || die "attempt must be positive integer"
    attempt="$ATTEMPT"
  fi
  (( attempt >= 1 )) || die "case has no matrix attempt"
  state_path="$(state_path_for "$attempt")"
  [[ -f "$state_path" ]] || die "adapter-state.json missing for attempt $attempt"
  jq -c '{case_id,attempt,adapter_id,resume_policy,log_scope,phase,result,exit_code,started_at,updated_at,ended_at,note,evidence,log_window,bindings}' "$state_path"
}

cmd_run() {
  require_command jq; require_command sha256sum; require_command install; require_command date
  require_command awk; require_command mktemp; require_command realpath; require_command flock; require_command find; require_command sort
  require_run_dir
  [[ -n "$CASE_ID" ]] || die "--case is required"
  assert_safe_case_id "$CASE_ID"
  with_global_debug_lock
  with_batch_lock_shared
  with_lock
  run_case_core
}

run_case_core() {
  local bindings meta attempt attempt_dir state_path state matrix_case matrix_status
  bindings="$(load_matrix_bindings)"
  assert_matrix_bindings "$bindings"
  meta="$(load_adapter_meta "$CASE_ID")"
  if (( TEST_MODE == 1 )); then run_preflight_test "$bindings"; else run_preflight_non_test "$bindings"; fi
  matrix_start || die "matrix start refused the requested adapter attempt"
  matrix_case="$(matrix_case_json)"
  [[ -n "$matrix_case" ]] || die "case not present in matrix state"
  matrix_status="$(jq -r '.status' <<<"$matrix_case")"
  [[ "$matrix_status" == "running" ]] || die "matrix case is $matrix_status after start"
  attempt="$(jq -r '.current_attempt' <<<"$matrix_case")"
  attempt_dir="$(attempt_dir_for "$attempt")"
  state_path="$(state_path_for "$attempt")"
  if [[ -f "$state_path" ]]; then
    state="$(read_state "$state_path")"
    assert_adapter_state_binding "$state" "$attempt" "$meta" "$bindings"
    local phase; phase="$(jq -r '.phase' <<<"$state")"
    if [[ "$phase" == "finished" ]]; then die "attempt $attempt already finished; pass --new-attempt"; fi
    if [[ "$phase" != "prepared" ]]; then die "attempt $attempt is in phase=$phase; use resume"; fi
  else
    state="$(init_prepared_state "$attempt" "$meta" "$bindings")"
  fi
  drive_from_phase "$attempt_dir" "$state_path" "$state" "$meta" "$bindings"
}

cmd_resume() {
  require_command jq; require_command sha256sum; require_command install; require_command date
  require_command awk; require_command mktemp; require_command realpath; require_command flock; require_command find; require_command sort
  require_run_dir
  [[ -n "$CASE_ID" ]] || die "--case is required"
  assert_safe_case_id "$CASE_ID"
  (( FORCE_NEW_ATTEMPT == 0 )) || die "--new-attempt is only valid with run"
  with_global_debug_lock
  with_batch_lock_shared
  with_lock
  resume_case_core
}

resume_case_core() {
  local bindings meta attempt attempt_dir state_path state matrix_case matrix_status
  bindings="$(load_matrix_bindings)"
  assert_matrix_bindings "$bindings"
  meta="$(load_adapter_meta "$CASE_ID")"
  if (( TEST_MODE == 1 )); then run_preflight_test "$bindings"; else run_preflight_non_test "$bindings"; fi
  matrix_case="$(matrix_case_json)"
  [[ -n "$matrix_case" ]] || die "case not present in matrix state"
  matrix_status="$(jq -r '.status' <<<"$matrix_case")"
  case "$matrix_status" in
    pending|running)
      matrix_resume_start || die "matrix could not resume the requested attempt"
      matrix_case="$(matrix_case_json)"
      ;;
    passed|failed|blocked|needs_manual|skipped_not_triggered) ;;
    *) die "matrix case has unsupported status: $matrix_status" ;;
  esac
  attempt="$(jq -r '.current_attempt // 0' <<<"$matrix_case")"
  if [[ -n "$ATTEMPT" && "$ATTEMPT" != "$attempt" ]]; then
    die "requested attempt $ATTEMPT is not matrix current_attempt $attempt"
  fi
  (( attempt >= 1 )) || die "matrix case has no current attempt"
  attempt_dir="$(attempt_dir_for "$attempt")"
  state_path="$(state_path_for "$attempt")"
  if [[ -f "$state_path" ]]; then
    state="$(read_state "$state_path")"
  else
    [[ "$(jq -r '.status' <<<"$matrix_case")" == "running" ]] \
      || die "terminal matrix attempt has no adapter checkpoint"
    state="$(init_prepared_state "$attempt" "$meta" "$bindings")"
  fi
  assert_adapter_state_binding "$state" "$attempt" "$meta" "$bindings"
  drive_from_phase "$attempt_dir" "$state_path" "$state" "$meta" "$bindings"
}

matrix_status_to_exit() {
  case "$1" in
    passed|skipped_not_triggered) printf '%s\n' "$EC_PASSED" ;;
    failed) printf '%s\n' "$EC_FAILED" ;;
    needs_manual) printf '%s\n' "$EC_NEEDS_MANUAL" ;;
    blocked) printf '%s\n' "$EC_BLOCKED" ;;
    *) printf '%s\n' "$EC_BLOCKED" ;;
  esac
}

exit_rank() {
  # Higher rank wins: blocked(71) > failed(70) > needs_manual(78) > 0
  case "$1" in
    0) printf '1\n' ;;
    78) printf '2\n' ;;
    70) printf '3\n' ;;
    71) printf '4\n' ;;
    *) printf '4\n' ;;
  esac
}

worse_exit() {
  local cur="$1" next="$2"
  local cur_rank next_rank
  cur_rank="$(exit_rank "$cur")"
  next_rank="$(exit_rank "$next")"
  if (( next_rank > cur_rank )); then
    case "$next" in 0|70|71|78) printf '%s\n' "$next" ;; *) printf '%s\n' "$EC_BLOCKED" ;; esac
  else
    printf '%s\n' "$cur"
  fi
}

list_ready_case_order() {
  # Preserve plan/state case order; force R0-7 absolutely last when present.
  jq -r '
    (.cases | map(.id)) as $ids
    | (($ids | map(select(. != "R0-7"))) + ($ids | map(select(. == "R0-7"))))
    | .[]
  ' "$RUN_DIR/state.json"
}

cmd_run_ready() {
  require_command jq; require_command sha256sum; require_command install; require_command date
  require_command awk; require_command mktemp; require_command realpath; require_command flock; require_command find; require_command sort
  require_run_dir
  case "$STOP_ON" in end|first-nonpass) ;; *) die "invalid --stop-on: $STOP_ON" ;; esac
  [[ -z "$CASE_ID" ]] || die "run-ready does not accept --case"
  [[ -z "$ATTEMPT" ]] || die "run-ready does not accept --attempt"
  (( FORCE_NEW_ATTEMPT == 0 )) || die "run-ready does not accept --new-attempt"

  with_global_debug_lock
  with_batch_lock_exclusive

  local bindings
  bindings="$(load_matrix_bindings)"
  assert_matrix_bindings "$bindings"
  if (( TEST_MODE == 1 )); then run_preflight_test "$bindings"; else run_preflight_non_test "$bindings"; fi

  local worst=0 case_id status rc=0 processed=0 skipped=0
  local -a order=()
  mapfile -t order < <(list_ready_case_order)
  (( ${#order[@]} > 0 )) || die "matrix state has no cases"

  info "run-ready start stop_on=$STOP_ON cases=${#order[@]}"
  for case_id in "${order[@]}"; do
    CASE_ID="$case_id"
    ATTEMPT=""
    FORCE_NEW_ATTEMPT=0
    assert_safe_case_id "$CASE_ID"
    status="$(jq -r --arg id "$CASE_ID" '.cases[] | select(.id==$id) | .status' "$RUN_DIR/state.json")"
    [[ -n "$status" ]] || die "case missing from matrix state: $CASE_ID"

    case "$status" in
      passed|failed|blocked|needs_manual|skipped_not_triggered)
        rc="$(matrix_status_to_exit "$status")"
        skipped=$((skipped + 1))
        info "run-ready skip terminal case=$CASE_ID status=$status"
        worst="$(worse_exit "$worst" "$rc")"
        if [[ "$STOP_ON" == "first-nonpass" && "$rc" != "0" ]]; then
          info "run-ready stop-on first-nonpass at terminal case=$CASE_ID exit=$rc"
          break
        fi
        continue
        ;;
      pending|running) ;;
      *)
        die "unsupported matrix case status for run-ready: $status"
        ;;
    esac

    with_lock
    if [[ "$status" == "pending" ]]; then
      if run_case_core; then rc=0; else rc=$?; fi
    else
      if resume_case_core; then rc=0; else rc=$?; fi
    fi
    release_adapter_lock
    processed=$((processed + 1))
    case "$rc" in 0|70|71|78) ;; *) rc=$EC_BLOCKED ;; esac
    worst="$(worse_exit "$worst" "$rc")"
    info "run-ready case=$CASE_ID prior_status=$status exit=$rc worst=$worst"
    if [[ "$STOP_ON" == "first-nonpass" && "$rc" != "0" ]]; then
      info "run-ready stop-on first-nonpass at case=$CASE_ID exit=$rc"
      break
    fi
  done

  printf 'status=run_ready stop_on=%s processed=%s skipped_terminal=%s exit_code=%s\n' \
    "$STOP_ON" "$processed" "$skipped" "$worst"
  return "$worst"
}

main() {
  parse_args "$@"
  configure_test_mode
  if [[ "$COMMAND" != "run-ready" && "$STOP_ON_SET" -eq 1 ]]; then
    die "--stop-on is only valid with run-ready"
  fi
  case "$COMMAND" in
    run)
      [[ -n "$CASE_ID" ]] || die "--case is required"
      cmd_run; return $?
      ;;
    resume)
      [[ -n "$CASE_ID" ]] || die "--case is required"
      cmd_resume; return $?
      ;;
    status)
      [[ -n "$CASE_ID" ]] || die "--case is required"
      cmd_status; return $?
      ;;
    run-ready)
      cmd_run_ready; return $?
      ;;
    *) die "unknown command: $COMMAND (use run|resume|status|run-ready)" ;;
  esac
}

main "$@"
