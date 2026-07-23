#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_MATRIX_CATALOG="$SCRIPT_DIR/../references/debug-verification-cases.tsv"
readonly DEFAULT_ADAPTER_CATALOG="$SCRIPT_DIR/../references/debug-adapters.tsv"
readonly OWNER_MARK="sub2api-debug-matrix-v1"
readonly LOCK_NAME=".run.lock"
readonly R0_REQUIRED=(R0-1 R0-2 R0-3 R0-4 R0-5 R0-6 R0-7 R0-8)
# Keep in lockstep with debug-canary-adapters/log-gate.sh fatal scan.
readonly FATAL_LOG_PATTERN='panic|fatal|migration[^[:alnum:]]*(failed|failure|error)|checksum[^[:alnum:]]*(mismatch|failed|failure|error)|out of memory|oom[-_ ]?killed|response\.failed'
readonly ADAPTER_RUNNER_ID='sub2api-debug-adapter-v1'

COMMAND=""
RUN_DIR=""
PLAN_PATH=""
REVISION=""
DIGEST=""
FIXTURE_MANIFEST=""
CONFIG_FINGERPRINT=""
MODE="dev"
CASE_ID=""
ATTEMPT=""
STATUS=""
EVIDENCE_PATH=""
LOG_WINDOW_PATH=""
NOTE=""
REASON=""
MATRIX_CATALOG="$DEFAULT_MATRIX_CATALOG"
ADAPTER_CATALOG="$DEFAULT_ADAPTER_CATALOG"
FORCE_NEW_ATTEMPT=0
CONFIG_DOCUMENT_JSON=""

usage() {
  cat <<'USAGE'
Usage:
  run-debug-matrix.sh init --run-dir <new-dir> --plan <plan.json> \
      --revision <40sha> --digest sha256:<64hex> \
      --fixture-manifest <path> --config-fingerprint <64hex> \
      [--mode dev|release] [--matrix-catalog <tsv>] [--adapter-catalog <tsv>]
  run-debug-matrix.sh start --run-dir <dir> --case <id> [--attempt N] [--new-attempt]
  run-debug-matrix.sh finish --run-dir <dir> --case <id> --status passed|failed|blocked|needs_manual|skipped_not_triggered \
      [--attempt N] [--evidence <file>] [--log-window <file>] [--note text]
  run-debug-matrix.sh status --run-dir <dir>
  run-debug-matrix.sh verify --run-dir <dir>
  run-debug-matrix.sh seal --run-dir <dir>
  run-debug-matrix.sh invalidate --run-dir <dir> --reason <text>

Recoverable evidence state machine. Does not eval arbitrary commands, does not
fabricate L3, does not connect to databases, and does not print raw sensitive logs.
USAGE
}

info() { printf '%s\n' "[sub2api-debug-matrix] $*" >&2; }
die() { printf '%s\n' "[sub2api-debug-matrix] error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

parse_args() {
  (( $# >= 1 )) || { usage >&2; exit 1; }
  COMMAND="$1"; shift
  while (( $# > 0 )); do
    case "$1" in
      --run-dir) (( $# >= 2 )) || die "--run-dir requires a value"; RUN_DIR="$2"; shift ;;
      --plan) (( $# >= 2 )) || die "--plan requires a value"; PLAN_PATH="$2"; shift ;;
      --revision) (( $# >= 2 )) || die "--revision requires a value"; REVISION="$2"; shift ;;
      --digest) (( $# >= 2 )) || die "--digest requires a value"; DIGEST="$2"; shift ;;
      --fixture-manifest) (( $# >= 2 )) || die "--fixture-manifest requires a value"; FIXTURE_MANIFEST="$2"; shift ;;
      --config-fingerprint) (( $# >= 2 )) || die "--config-fingerprint requires a value"; CONFIG_FINGERPRINT="$2"; shift ;;
      --mode) (( $# >= 2 )) || die "--mode requires a value"; MODE="$2"; shift ;;
      --case) (( $# >= 2 )) || die "--case requires a value"; CASE_ID="$2"; shift ;;
      --attempt) (( $# >= 2 )) || die "--attempt requires a value"; ATTEMPT="$2"; shift ;;
      --status) (( $# >= 2 )) || die "--status requires a value"; STATUS="$2"; shift ;;
      --evidence) (( $# >= 2 )) || die "--evidence requires a value"; EVIDENCE_PATH="$2"; shift ;;
      --log-window) (( $# >= 2 )) || die "--log-window requires a value"; LOG_WINDOW_PATH="$2"; shift ;;
      --note) (( $# >= 2 )) || die "--note requires a value"; NOTE="$2"; shift ;;
      --reason) (( $# >= 2 )) || die "--reason requires a value"; REASON="$2"; shift ;;
      --matrix-catalog) (( $# >= 2 )) || die "--matrix-catalog requires a value"; MATRIX_CATALOG="$2"; shift ;;
      --adapter-catalog) (( $# >= 2 )) || die "--adapter-catalog requires a value"; ADAPTER_CATALOG="$2"; shift ;;
      --new-attempt) FORCE_NEW_ATTEMPT=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}

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

validate_candidate_identity_evidence() {
  local path="$1" revision="$2" digest="$3"
  jq -e --arg revision "$revision" --arg digest "$digest" \
    --arg reference "ghcr.io/wesperez/sub2api:debug-sha-${revision}@${digest}" '
    .schema_version==1
    and .kind=="candidate-identity"
    and .revision==$revision
    and .digest==$digest
    and .image_reference==$reference
    and .workflow_name=="Docker Branch Images"
    and (.workflow_run_id|tostring|test("^[0-9]+$"))
    and .ci_conclusion=="success"
    and .ref_name=="debug"
    and (.container_image_id|type=="string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$path" >/dev/null
}

validate_rollback_evidence() {
  local path="$1" revision="$2" digest="$3"
  jq -e --arg revision "$revision" --arg digest "$digest" '
    .schema_version==1
    and .kind=="rollback-compatibility"
    and .candidate_revision==$revision
    and .candidate_digest==$digest
    and (.old_image_revision|type=="string" and test("^[0-9a-f]{40}$"))
    and .old_image_started==true
    and .health_passed==true
    and .core_readonly_passed==true
    and .schema_compatible==true
    and .database_restore_performed==false
    and (.tested_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$path" >/dev/null
}

validate_debug_case_evidence() {
  local path="$1" case_id="$2" revision="$3" digest="$4" adapter_id="$5"
  jq -e --arg case_id "$case_id" --arg revision "$revision" --arg digest "$digest" --arg adapter_id "$adapter_id" '
    .schema_version==1
    and .kind=="debug-case-evidence"
    and .runner=="sub2api-debug-adapter-v1"
    and .case_id==$case_id
    and .revision==$revision
    and .digest==$digest
    and .adapter_id==$adapter_id
    and .status=="passed"
    and (.started_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.ended_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and .target.environment=="debug"
    and .target.compose_project=="sub2api-debug"
    and (.target.deploy_dir=="/root/sub2api-debug-deploy" or .target.test_mode==true)
    and (.assertions|type=="array" and length>0)
    and all(.assertions[];
      (.name|type=="string" and length>0)
      and .passed==true)
  ' "$path" >/dev/null
}

validate_manual_verification_evidence() {
  local path="$1" case_id="$2" revision="$3" digest="$4" attempt="$5"
  jq -e --arg case_id "$case_id" --arg revision "$revision" --arg digest "$digest" --argjson attempt "$attempt" '
    .schema_version==1
    and .kind=="manual-verification"
    and .case_id==$case_id
    and .revision==$revision
    and .digest==$digest
    and .attempt==$attempt
    and .adapter_id=="manual"
    and .target.environment=="debug"
    and .target.compose_project=="sub2api-debug"
    and (.target.deploy_dir=="/root/sub2api-debug-deploy" or .target.test_mode==true)
    and (.verifier|type=="string" and length>=3 and (test("^(unknown|todo|operator-id-or-name)$";"i")|not))
    and (.procedure|type=="string" and length>=20 and (test("^(describe|todo|placeholder)";"i")|not))
    and (.assertions|type=="array" and length>0)
    and (([.assertions[].name]|unique|length)==(.assertions|length))
    and all(.assertions[];
      (.name|type=="string" and length>=3)
      and .passed==true)
    and (.verified_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$path" >/dev/null
}

is_automatic_adapter_id() {
  case "$1" in
    manual) return 1 ;;
    candidate-identity|debug-startup|log-gate|fixed-canary) return 0 ;;
    *) return 1 ;;
  esac
}

scan_log_window_for_fatal() {
  local path="$1" label="$2"
  [[ -s "$path" && ! -L "$path" ]] || die "$label is missing, empty, or symlinked"
  if grep -Eiq -- "$FATAL_LOG_PATTERN" "$path"; then
    local hits
    hits="$(grep -Eic -- "$FATAL_LOG_PATTERN" "$path" || true)"
    die "$label contains fatal log patterns (count=$hits); refuse release pass"
  fi
}

assert_release_automatic_checkpoint() {
  local attempt_dir="$1" case_id="$2" attempt="$3" adapter_id="$4" evidence_kind="$5"
  local revision="$6" digest="$7" config_fingerprint="$8" status="$9" evidence_sha="${10}" log_sha="${11:-}"
  local state_path="$attempt_dir/adapter-state.json"
  [[ -f "$state_path" && ! -L "$state_path" ]] \
    || die "release automatic passed for $case_id requires adapter-state checkpoint from the adapter runner"
  jq -e --arg runner "$ADAPTER_RUNNER_ID" --arg case_id "$case_id" --argjson attempt "$attempt" \
    --arg adapter_id "$adapter_id" --arg evidence_kind "$evidence_kind" \
    --arg revision "$revision" --arg digest "$digest" --arg config_fingerprint "$config_fingerprint" --arg status "$status" \
    --arg evidence_sha "$evidence_sha" '
    .schema_version==1
    and .runner==$runner
    and .case_id==$case_id
    and .attempt==$attempt
    and .adapter_id==$adapter_id
    and .evidence_kind==$evidence_kind
    and .bindings.revision==$revision
    and .bindings.digest==$digest
    and .bindings.config_fingerprint==$config_fingerprint
    and (.phase=="logs_done" or .phase=="finished")
    and .result==$status
    and (.evidence != null)
    and .evidence.path=="evidence.json"
    and (.evidence.sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and .evidence.sha256==$evidence_sha
  ' "$state_path" >/dev/null \
    || die "adapter-state checkpoint binding/result/evidence sha mismatch for $case_id attempt=$attempt"
  if [[ -n "$log_sha" ]]; then
    jq -e --arg log_sha "$log_sha" '
      .log_window != null
      and .log_window.collected==true
      and .log_window.path=="log-window.raw"
      and (.log_window.sha256|type=="string" and test("^[0-9a-f]{64}$"))
      and .log_window.sha256==$log_sha
    ' "$state_path" >/dev/null \
      || die "adapter-state log-window sha mismatch for $case_id attempt=$attempt"
  fi
}

validate_evidence_by_kind() {
  local path="$1" evidence_kind="$2" case_id="$3" revision="$4" digest="$5" adapter_id="$6" attempt="$7"
  case "$evidence_kind" in
    candidate-identity)
      validate_candidate_identity_evidence "$path" "$revision" "$digest" \
        || die "$case_id evidence does not prove the exact CI/image/runtime identity"
      ;;
    rollback-compatibility)
      validate_rollback_evidence "$path" "$revision" "$digest" \
        || die "$case_id evidence does not prove image-only rollback compatibility"
      ;;
    debug-case-evidence)
      validate_debug_case_evidence "$path" "$case_id" "$revision" "$digest" "$adapter_id" \
        || die "$case_id evidence does not satisfy the audited debug adapter contract"
      ;;
    manual-verification)
      validate_manual_verification_evidence "$path" "$case_id" "$revision" "$digest" "$attempt" \
        || die "$case_id evidence is not a strict manual-verification JSON binding"
      ;;
    *)
      die "unsupported evidence kind for $case_id: $evidence_kind"
      ;;
  esac
}

revalidate_release_passed_cases() {
  local state="$1"
  local mode case_id status attempt attempt_dir meta_path evidence_rel evidence_file evidence_sha
  local log_rel log_file log_sha adapter_meta adapter_id evidence_kind revision digest config_fingerprint executor
  mode="$(jq -r '.mode' <<<"$state")"
  [[ "$mode" == "release" ]] || return 0
  revision="$(jq -r '.bindings.revision' <<<"$state")"
  digest="$(jq -r '.bindings.digest' <<<"$state")"
  config_fingerprint="$(jq -r '.bindings.config_fingerprint' <<<"$state")"
  while IFS=$'\t' read -r case_id status attempt executor; do
    [[ -n "$case_id" ]] || continue
    [[ "$status" == "passed" ]] || continue
    attempt_dir="$RUN_DIR/cases/$case_id/attempt-$(printf '%03d' "$attempt")"
    meta_path="$attempt_dir/meta.json"
    [[ -f "$meta_path" ]] || die "current attempt meta missing for $case_id"
    evidence_rel="$(jq -r '.evidence.path // empty' "$meta_path")"
    evidence_sha="$(jq -r '.evidence.sha256 // empty' "$meta_path")"
    [[ -n "$evidence_rel" && -n "$evidence_sha" ]] || die "passed $case_id lacks bound evidence path/sha"
    evidence_file="$RUN_DIR/$evidence_rel"
    [[ -f "$evidence_file" && ! -L "$evidence_file" ]] || die "passed $case_id evidence file missing: $evidence_rel"
    [[ "$(file_sha256 "$evidence_file")" == "$evidence_sha" ]] || die "passed $case_id evidence sha drift"
    adapter_meta="$(adapter_meta_from_catalog "$case_id")"
    adapter_id="$(jq -r '.adapter_id' <<<"$adapter_meta")"
    evidence_kind="$(jq -r '.evidence_kind' <<<"$adapter_meta")"
    validate_evidence_by_kind "$evidence_file" "$evidence_kind" "$case_id" "$revision" "$digest" "$adapter_id" "$attempt"
    log_rel="$(jq -r '.log_window.path // empty' "$meta_path")"
    log_sha="$(jq -r '.log_window.sha256 // empty' "$meta_path")"
    if [[ "$case_id" == "R0-7" || "$executor" == "logs" || "$adapter_id" == "log-gate" ]]; then
      [[ -n "$log_rel" && -n "$log_sha" ]] || die "log-gate case $case_id lacks bound log-window"
    fi
    if [[ -n "$log_rel" ]]; then
      log_file="$RUN_DIR/$log_rel"
      [[ -f "$log_file" && ! -L "$log_file" ]] || die "passed $case_id log-window missing: $log_rel"
      [[ "$(file_sha256 "$log_file")" == "$log_sha" ]] || die "passed $case_id log-window sha drift"
      if [[ "$case_id" == "R0-7" || "$adapter_id" == "log-gate" ]]; then
        scan_log_window_for_fatal "$log_file" "$case_id log-window"
      fi
    fi
    if is_automatic_adapter_id "$adapter_id"; then
      assert_release_automatic_checkpoint "$attempt_dir" "$case_id" "$attempt" "$adapter_id" \
        "$evidence_kind" "$revision" "$digest" "$config_fingerprint" "passed" "$evidence_sha" "$log_sha"
    fi
  done < <(jq -r '.cases[] | select(.status=="passed") | [.id, .status, (.current_attempt|tostring), (.executor // "")] | @tsv' <<<"$state")
}


atomic_write_json() {
  local dest="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp "$dest.tmp.XXXXXX")"
  printf '%s\n' "$content" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dest"
  chmod 0600 "$dest"
}

with_lock() {
  local lock="$RUN_DIR/$LOCK_NAME"
  require_command flock
  exec 9>"$lock"
  flock -n 9 || die "another matrix runner holds the lock for $RUN_DIR"
}

require_run_dir() {
  [[ -n "$RUN_DIR" ]] || die "--run-dir is required"
  [[ -d "$RUN_DIR" ]] || die "run directory missing: $RUN_DIR"
  [[ -f "$RUN_DIR/.owner" ]] || die "run owner marker missing"
  [[ "$(tr -d '[:space:]' <"$RUN_DIR/.owner")" == "$OWNER_MARK" ]] || die "run owner marker mismatch"
  [[ -f "$RUN_DIR/state.json" ]] || die "state.json missing"
}

load_state() {
  jq -c . "$RUN_DIR/state.json"
}

save_state() {
  local state="$1"
  atomic_write_json "$RUN_DIR/state.json" "$(jq -c . <<<"$state")"
}

assert_bindings_fresh() {
  local state="$1"
  local allow_sealed="${2:-0}"
  require_command find
  require_command sort
  local plan_hash fixture_hash catalog_hash adapter_catalog_hash adapter_bundle_hash config_document_hash
  plan_hash="$(file_sha256 "$RUN_DIR/plan.json")"
  fixture_hash="$(file_sha256 "$RUN_DIR/fixture-manifest.json")"
  catalog_hash="$(file_sha256 "$RUN_DIR/matrix-catalog.tsv")"
  adapter_catalog_hash="$(file_sha256 "$RUN_DIR/adapter-catalog.tsv")"
  adapter_bundle_hash="$(adapter_bundle_sha256)" || die "could not hash the debug adapter bundle"
  local expected
  expected="$(jq -r '.bindings.plan_sha256' <<<"$state")"
  [[ "$plan_hash" == "$expected" ]] || die "plan.json fingerprint drift"
  expected="$(jq -r '.bindings.fixture_manifest_sha256' <<<"$state")"
  [[ "$fixture_hash" == "$expected" ]] || die "fixture manifest fingerprint drift"
  expected="$(jq -r '.bindings.matrix_catalog_sha256' <<<"$state")"
  [[ "$catalog_hash" == "$expected" ]] || die "matrix catalog fingerprint drift"
  expected="$(jq -r '.bindings.adapter_catalog_sha256' <<<"$state")"
  [[ "$adapter_catalog_hash" == "$expected" ]] || die "adapter catalog fingerprint drift"
  expected="$(jq -r '.bindings.adapter_bundle_sha256' <<<"$state")"
  [[ "$adapter_bundle_hash" == "$expected" ]] || die "debug adapter bundle fingerprint drift"
  config_document_hash="$(file_sha256 "$RUN_DIR/config-fingerprint.json")"
  expected="$(jq -r '.bindings.config_fingerprint_document_sha256' <<<"$state")"
  [[ "$config_document_hash" == "$expected" ]] || die "config fingerprint document drift"
  local rev dig cfg
  rev="$(jq -r '.bindings.revision' <<<"$state")"
  dig="$(jq -r '.bindings.digest' <<<"$state")"
  cfg="$(jq -r '.bindings.config_fingerprint' <<<"$state")"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || die "invalid bound revision"
  [[ "$dig" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid bound digest"
  [[ "$cfg" =~ ^[0-9a-f]{64}$ ]] || die "invalid bound config fingerprint"
  local status
  status="$(jq -r '.status' <<<"$state")"
  [[ "$status" != "invalidated" ]] || die "run is invalidated"
  if [[ "$status" == "sealed" && "$allow_sealed" != "1" ]]; then
    die "run is sealed and immutable"
  fi
}

case_meta_from_catalog() {
  local case_id="$1"
  local line
  line="$(awk -F '\t' -v id="$case_id" '$1==id {print; exit}' "$RUN_DIR/matrix-catalog.tsv" || true)"
  [[ -n "$line" ]] || die "case not present in matrix catalog: $case_id"
  local suite level executor description assertion
  IFS=$'\t' read -r _ suite level executor description assertion <<<"$line"
  jq -n --arg id "$case_id" --arg suite "$suite" --arg level "$level" --arg executor "$executor" \
    --arg description "$description" --arg assertion "$assertion" \
    '{id:$id,suite:$suite,level:$level,executor:$executor,description:$description,assertion:$assertion}'
}

adapter_meta_from_catalog() {
  local case_id="$1"
  local line count
  count="$(awk -F '\t' -v id="$case_id" '$1==id {count++} END {print count+0}' "$RUN_DIR/adapter-catalog.tsv")"
  [[ "$count" == "1" ]] || die "case must have exactly one adapter catalog entry: $case_id (got $count)"
  line="$(awk -F '\t' -v id="$case_id" '$1==id {print; exit}' "$RUN_DIR/adapter-catalog.tsv")"
  local adapter_id resume_policy log_scope timeout_seconds evidence_kind
  IFS=$'\t' read -r _ adapter_id resume_policy log_scope timeout_seconds evidence_kind <<<"$line"
  jq -n --arg case_id "$case_id" --arg adapter_id "$adapter_id" --arg resume_policy "$resume_policy" \
    --arg log_scope "$log_scope" --argjson timeout_seconds "$timeout_seconds" --arg evidence_kind "$evidence_kind" \
    '{case_id:$case_id,adapter_id:$adapter_id,resume_policy:$resume_policy,log_scope:$log_scope,
      timeout_seconds:$timeout_seconds,evidence_kind:$evidence_kind}'
}

rebuild_results_tsv() {
  local state="$1" tmp
  tmp="$(mktemp "$RUN_DIR/results.tsv.tmp.XXXXXX")"
  {
    printf 'case_id\tstatus\tattempt\tstarted_at\tended_at\tevidence_sha256\tnote\n'
    jq -r '
      .cases[] as $case | $case.attempts[]? |
        [$case.id, .status, (.attempt|tostring), .started_at, (.ended_at // ""),
         (.evidence.sha256 // ""), (.note // "")]
      | @tsv
    ' <<<"$state"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$RUN_DIR/results.tsv"
  chmod 0600 "$RUN_DIR/results.tsv"
}

cmd_init() {
  require_command jq; require_command sha256sum; require_command install; require_command awk; require_command mktemp; require_command realpath
  require_command find; require_command sort
  [[ -n "$RUN_DIR" ]] || die "--run-dir is required"
  [[ ! -e "$RUN_DIR" ]] || die "run directory already exists: $RUN_DIR"
  [[ -f "$PLAN_PATH" ]] || die "plan missing: $PLAN_PATH"
  [[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || die "revision must be lowercase 40-char sha"
  [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "digest must be sha256:64-hex"
  [[ "$CONFIG_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || die "config-fingerprint must be 64-hex"
  [[ "$MODE" == "dev" || "$MODE" == "release" ]] || die "mode must be dev or release"
  [[ -f "$FIXTURE_MANIFEST" ]] || die "fixture manifest missing"
  [[ -f "$MATRIX_CATALOG" ]] || die "matrix catalog missing"
  [[ -f "$ADAPTER_CATALOG" ]] || die "adapter catalog missing"
  awk -F '\t' '
    NR==1 {
      if ($0 != "id\tsuite\tlevel\texecutor\tdescription\tassertion") exit 1
      next
    }
    NF != 6 || $1 !~ /^[A-Z0-9]+(-[A-Z0-9]+)*$/ || seen[$1]++ {exit 1}
    END {if (NR < 2) exit 1}
  ' "$MATRIX_CATALOG" || die "matrix catalog structure or unique case ids are invalid"
  awk -F '\t' '
    NR==1 {
      if ($0 != "case_id\tadapter_id\tresume_policy\tlog_scope\ttimeout_seconds\tevidence_kind") exit 1
      next
    }
    NF != 6 || $1 !~ /^[A-Z0-9]+(-[A-Z0-9]+)*$/ || seen[$1]++ {exit 1}
    $2 !~ /^(manual|candidate-identity|debug-startup|log-gate|fixed-canary)$/ {exit 1}
    $3 !~ /^(replay_safe|no_replay|session_resume)$/ {exit 1}
    $4 !~ /^(none|sub2api|project)$/ {exit 1}
    $5 !~ /^(0|[1-9][0-9]*)$/ || $5 > 3600 {exit 1}
    $6 !~ /^(manual-verification|candidate-identity|rollback-compatibility|debug-case-evidence)$/ {exit 1}
    $2 == "manual" && $5 != 0 {exit 1}
    $2 != "manual" && $5 < 1 {exit 1}
    $2 == "manual" && $6 != "manual-verification" && $6 != "rollback-compatibility" {exit 1}
    $2 != "manual" && $6 == "manual-verification" {exit 1}
    END {if (NR < 2) exit 1}
  ' "$ADAPTER_CATALOG" || die "adapter catalog structure or enum values are invalid"
  jq -e --arg revision "$REVISION" '
    type=="object"
    and .baseline_gate=="passed"
    and .candidate.revision==$revision
    and (.cases|type=="array" and length>0)
    and (([.cases[].id]|unique|length) == (.cases|length))
  ' "$PLAN_PATH" >/dev/null \
    || die "plan.json must be a passed, non-duplicated plan for the bound candidate revision"

  if [[ "$MODE" == "release" && "${SUB2API_UPGRADE_TEST_MODE:-}" != "1" ]]; then
    [[ -f "$SCRIPT_DIR/compute-debug-config-fingerprint.sh" ]] \
      || die "debug config fingerprint calculator is unavailable"
    CONFIG_DOCUMENT_JSON="$(bash "$SCRIPT_DIR/compute-debug-config-fingerprint.sh" --json)" \
      || die "could not compute live debug config fingerprint"
    [[ "$(jq -r '.fingerprint // empty' <<<"$CONFIG_DOCUMENT_JSON")" == "$CONFIG_FINGERPRINT" ]] \
      || die "provided config fingerprint does not match the live debug configuration"
  else
    if [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]]; then
      [[ "$(realpath -m "$RUN_DIR")" == /tmp/* ]] || die "test-mode matrix run must be below /tmp"
    fi
    CONFIG_DOCUMENT_JSON="$(jq -n --arg fingerprint "$CONFIG_FINGERPRINT" \
      --arg source "$(if [[ "$MODE" == "release" ]]; then printf test-mode; else printf caller-provided-dev; fi)" \
      '{status:"ok",fingerprint:$fingerprint,source:$source}')"
  fi

  [[ -f "$SCRIPT_DIR/check-debug-fixture-manifest.sh" ]] \
    || die "fixture validator is unavailable: $SCRIPT_DIR/check-debug-fixture-manifest.sh"
  bash "$SCRIPT_DIR/check-debug-fixture-manifest.sh" --manifest "$FIXTURE_MANIFEST" >/dev/null \
    || die "fixture manifest validation failed"

  install -d -m 0700 "$RUN_DIR"
  install -d -m 0700 "$RUN_DIR/cases" "$RUN_DIR/evidence"
  printf '%s\n' "$OWNER_MARK" > "$RUN_DIR/.owner"
  chmod 0600 "$RUN_DIR/.owner"
  install -m 0600 "$PLAN_PATH" "$RUN_DIR/plan.json"
  install -m 0600 "$FIXTURE_MANIFEST" "$RUN_DIR/fixture-manifest.json"
  install -m 0600 "$MATRIX_CATALOG" "$RUN_DIR/matrix-catalog.tsv"
  install -m 0600 "$ADAPTER_CATALOG" "$RUN_DIR/adapter-catalog.tsv"
  printf '%s\n' "$CONFIG_DOCUMENT_JSON" > "$RUN_DIR/config-fingerprint.json"
  chmod 0600 "$RUN_DIR/config-fingerprint.json"

  local plan_hash fixture_hash catalog_hash adapter_catalog_hash adapter_bundle_hash config_document_hash now cases_json
  plan_hash="$(file_sha256 "$RUN_DIR/plan.json")"
  fixture_hash="$(file_sha256 "$RUN_DIR/fixture-manifest.json")"
  catalog_hash="$(file_sha256 "$RUN_DIR/matrix-catalog.tsv")"
  adapter_catalog_hash="$(file_sha256 "$RUN_DIR/adapter-catalog.tsv")"
  adapter_bundle_hash="$(adapter_bundle_sha256)" || die "could not hash the debug adapter bundle"
  [[ "$adapter_bundle_hash" =~ ^[0-9a-f]{64}$ ]] || die "debug adapter bundle hash is invalid"
  config_document_hash="$(file_sha256 "$RUN_DIR/config-fingerprint.json")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cases_json="$(jq -c '
    [.cases[] | {
        id: .id,
        suite: (.suite // ""),
        level: (.level // ""),
        executor: (.executor // ""),
        status: "pending",
        attempts: [],
        current_attempt: 0
      }]
  ' "$RUN_DIR/plan.json")"

  # Bind plan metadata to the immutable case and adapter catalogs. A plan may
  # select cases, but it may not rewrite their executor/level/suite contract.
  local cid suite level executor catalog_line catalog_suite catalog_level catalog_executor adapter_count
  while IFS=$'\t' read -r cid suite level executor; do
    [[ -n "$cid" ]] || continue
    catalog_line="$(awk -F '\t' -v id="$cid" '$1==id {print; exit}' "$RUN_DIR/matrix-catalog.tsv")"
    [[ -n "$catalog_line" ]] || die "plan case missing from matrix catalog: $cid"
    IFS=$'\t' read -r _ catalog_suite catalog_level catalog_executor _ _ <<<"$catalog_line"
    [[ "$suite" == "$catalog_suite" && "$level" == "$catalog_level" && "$executor" == "$catalog_executor" ]] \
      || die "plan metadata differs from catalog for $cid"
    adapter_count="$(awk -F '\t' -v id="$cid" '$1==id {count++} END {print count+0}' "$RUN_DIR/adapter-catalog.tsv")"
    [[ "$adapter_count" == "1" ]] || die "plan case must have exactly one adapter entry: $cid"
  done < <(jq -r '.cases[] | [.id, (.suite // ""), (.level // ""), (.executor // "")] | @tsv' "$RUN_DIR/plan.json")

  local state
  state="$(jq -n \
    --arg created_at "$now" \
    --arg mode "$MODE" \
    --arg revision "$REVISION" \
    --arg digest "$DIGEST" \
    --arg config_fingerprint "$CONFIG_FINGERPRINT" \
    --arg plan_sha256 "$plan_hash" \
    --arg fixture_manifest_sha256 "$fixture_hash" \
    --arg matrix_catalog_sha256 "$catalog_hash" \
    --arg adapter_catalog_sha256 "$adapter_catalog_hash" \
    --arg adapter_bundle_sha256 "$adapter_bundle_hash" \
    --arg config_fingerprint_document_sha256 "$config_document_hash" \
    --argjson cases "$cases_json" \
    '{
      schema_version: 1,
      owner: "sub2api-debug-matrix-v1",
      status: "initialized",
      mode: $mode,
      created_at: $created_at,
      updated_at: $created_at,
      sealed_at: null,
      invalidated_at: null,
      invalidate_reason: null,
      bindings: {
        revision: $revision,
        digest: $digest,
        config_fingerprint: $config_fingerprint,
        plan_sha256: $plan_sha256,
        fixture_manifest_sha256: $fixture_manifest_sha256,
        matrix_catalog_sha256: $matrix_catalog_sha256,
        adapter_catalog_sha256: $adapter_catalog_sha256,
        adapter_bundle_sha256: $adapter_bundle_sha256,
        config_fingerprint_document_sha256: $config_fingerprint_document_sha256
      },
      cases: $cases
    }')"
  atomic_write_json "$RUN_DIR/state.json" "$state"
  printf 'case_id\tstatus\tattempt\tstarted_at\tended_at\tevidence_sha256\tnote\n' > "$RUN_DIR/results.tsv"
  chmod 0600 "$RUN_DIR/results.tsv"
  info "initialized run $RUN_DIR mode=$MODE cases=$(jq 'length' <<<"$cases_json")"
  printf 'status=initialized run_dir=%s cases=%s\n' "$RUN_DIR" "$(jq 'length' <<<"$cases_json")"
}

cmd_start() {
  require_command jq; require_command flock; require_command date; require_command install
  require_run_dir
  with_lock
  [[ -n "$CASE_ID" ]] || die "--case is required"
  local state
  state="$(load_state)"
  assert_bindings_fresh "$state"

  local case_json
  case_json="$(jq -c --arg id "$CASE_ID" '.cases[] | select(.id==$id)' <<<"$state")"
  [[ -n "$case_json" ]] || die "case not in plan: $CASE_ID"
  local cur_status
  cur_status="$(jq -r '.status' <<<"$case_json")"
  [[ "$cur_status" != "passed" ]] || die "case already passed; refuse overwrite (use a new run)"

  local next_attempt current_attempt
  current_attempt="$(jq -r '.current_attempt // 0' <<<"$case_json")"
  case "$cur_status" in
    pending)
      (( FORCE_NEW_ATTEMPT == 0 )) || die "--new-attempt is not valid for a pending case"
      next_attempt=1
      ;;
    running)
      (( FORCE_NEW_ATTEMPT == 0 )) || die "cannot start a new attempt while the current attempt is running"
      (( current_attempt >= 1 )) || die "running case has no current attempt"
      next_attempt="$current_attempt"
      ;;
    failed|blocked|needs_manual|skipped_not_triggered)
      (( FORCE_NEW_ATTEMPT == 1 )) \
        || die "case status is $cur_status; an explicit --new-attempt is required"
      next_attempt=$((current_attempt + 1))
      ;;
    *) die "case has unsupported status: $cur_status" ;;
  esac
  if [[ -n "$ATTEMPT" ]]; then
    [[ "$ATTEMPT" =~ ^[0-9]+$ && "$ATTEMPT" -ge 1 ]] || die "attempt must be positive integer"
    [[ "$ATTEMPT" == "$next_attempt" ]] \
      || die "attempt $ATTEMPT does not match the required attempt $next_attempt"
  fi

  # If last attempt is still running and same attempt requested without finish, allow resume start only if status running
  local attempt_dir started_at
  attempt_dir="$RUN_DIR/cases/$CASE_ID/attempt-$(printf '%03d' "$next_attempt")"
  if [[ -d "$attempt_dir" && -f "$attempt_dir/meta.json" ]]; then
    local prev meta revision digest
    prev="$(jq -r '.status // empty' "$attempt_dir/meta.json")"
    meta="$(jq -c . "$attempt_dir/meta.json")"
    revision="$(jq -r '.bindings.revision' <<<"$state")"
    digest="$(jq -r '.bindings.digest' <<<"$state")"
    jq -e --arg case_id "$CASE_ID" --argjson attempt "$next_attempt" --arg revision "$revision" --arg digest "$digest" '
      .case_id==$case_id and .attempt==$attempt and .revision==$revision and .digest==$digest
    ' <<<"$meta" >/dev/null || die "existing attempt metadata binding mismatch"
    if [[ "$prev" == "running" ]]; then
      state="$(jq -c --arg id "$CASE_ID" --argjson attempt "$next_attempt" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .updated_at=$updated
        | .status="running"
        | (.cases[] | select(.id==$id) | .status) = "running"
        | (.cases[] | select(.id==$id) | .current_attempt) = $attempt
      ' <<<"$state")"
      save_state "$state"
      info "resuming running attempt $next_attempt for $CASE_ID"
      printf 'status=running case=%s attempt=%s started_at=%s\n' "$CASE_ID" "$next_attempt" "$(jq -r '.started_at' "$attempt_dir/meta.json")"
      return 0
    fi
    case "$prev" in
      passed|failed|blocked|needs_manual|skipped_not_triggered)
        if [[ "$cur_status" == "running" ]]; then
          state="$(jq -c --arg id "$CASE_ID" --arg status "$prev" --argjson attempt "$next_attempt" \
            --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson meta "$meta" '
            .updated_at=$updated
            | (.cases[] | select(.id==$id) | .status) = $status
            | (.cases[] | select(.id==$id) | .current_attempt) = $attempt
            | (.cases[] | select(.id==$id) | .attempts) |=
                ((map(select(.attempt != $attempt)) + [$meta]) | sort_by(.attempt))
          ' <<<"$state")"
          save_state "$state"
          rebuild_results_tsv "$state"
          info "reconciled terminal attempt $next_attempt for $CASE_ID status=$prev"
          printf 'status=%s case=%s attempt=%s ended_at=%s reconciled=true\n' \
            "$prev" "$CASE_ID" "$next_attempt" "$(jq -r '.ended_at // empty' <<<"$meta")"
          return 0
        fi
        ;;
    esac
    die "attempt directory already exists with status=$prev; pass a new --attempt"
  fi

  install -d -m 0700 "$RUN_DIR/cases/$CASE_ID" "$attempt_dir"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local meta
  meta="$(jq -n --arg case_id "$CASE_ID" --argjson attempt "$next_attempt" --arg started_at "$started_at" \
    --arg revision "$(jq -r '.bindings.revision' <<<"$state")" --arg digest "$(jq -r '.bindings.digest' <<<"$state")" \
    '{case_id:$case_id,attempt:$attempt,status:"running",started_at:$started_at,ended_at:null,revision:$revision,digest:$digest,evidence:null,log_window:null,note:null}')"
  atomic_write_json "$attempt_dir/meta.json" "$meta"

  state="$(jq -c --arg id "$CASE_ID" --argjson attempt "$next_attempt" --arg started_at "$started_at" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .updated_at=$updated
    | .status="running"
    | (.cases[] | select(.id==$id) | .status) = "running"
    | (.cases[] | select(.id==$id) | .current_attempt) = $attempt
  ' <<<"$state")"
  save_state "$state"
  info "started $CASE_ID attempt=$next_attempt at $started_at"
  printf 'status=running case=%s attempt=%s started_at=%s\n' "$CASE_ID" "$next_attempt" "$started_at"
}

cmd_finish() {
  require_command jq; require_command flock; require_command date; require_command sha256sum
  require_run_dir
  with_lock
  [[ -n "$CASE_ID" ]] || die "--case is required"
  case "$STATUS" in
    passed|failed|blocked|needs_manual|skipped_not_triggered) ;;
    *) die "finish status must be passed|failed|blocked|needs_manual|skipped_not_triggered" ;;
  esac
  [[ "$NOTE" != *$'\n'* && "$NOTE" != *$'\r'* ]] || die "note must not contain line breaks"
  (( ${#NOTE} <= 2000 )) || die "note is too long"
  local state
  state="$(load_state)"
  assert_bindings_fresh "$state"

  local case_json
  case_json="$(jq -c --arg id "$CASE_ID" '.cases[] | select(.id==$id)' <<<"$state")"
  [[ -n "$case_json" ]] || die "case not in plan: $CASE_ID"
  local cur_status
  cur_status="$(jq -r '.status' <<<"$case_json")"
  if [[ "$cur_status" != "running" && "$cur_status" != "$STATUS" ]]; then
    die "case status is $cur_status; refuse finish as $STATUS"
  fi

  if [[ "$STATUS" == "skipped_not_triggered" ]]; then
    local level executor
    level="$(jq -r '.level // empty' <<<"$case_json")"
    executor="$(jq -r '.executor // empty' <<<"$case_json")"
    [[ "$level" != "R0" && "$executor" != "manual" ]] || die "R0/manual cases cannot be skipped_not_triggered"
    [[ -n "$NOTE" ]] || die "skipped_not_triggered requires an explanatory note"
  fi

  local attempt
  if [[ -n "$ATTEMPT" ]]; then
    attempt="$ATTEMPT"
  else
    attempt="$(jq -r '.current_attempt // 0' <<<"$case_json")"
  fi
  [[ "$attempt" =~ ^[0-9]+$ && "$attempt" -ge 1 ]] || die "no active attempt; run start first"
  [[ "$attempt" == "$(jq -r '.current_attempt // 0' <<<"$case_json")" ]] \
    || die "finish attempt must equal the case current_attempt"

  if (( FORCE_NEW_ATTEMPT == 1 )); then
    die "--new-attempt is only valid with start; finish the current attempt first"
  fi

  local attempt_dir meta_path
  attempt_dir="$RUN_DIR/cases/$CASE_ID/attempt-$(printf '%03d' "$attempt")"
  meta_path="$attempt_dir/meta.json"
  [[ -f "$meta_path" ]] || die "attempt meta missing: $meta_path"
  local meta_status existing_meta
  meta_status="$(jq -r '.status' "$meta_path")"
  existing_meta="$(jq -c . "$meta_path")"
  if [[ "$meta_status" != "running" ]]; then
    [[ "$meta_status" == "$STATUS" ]] \
      || die "attempt already ended as $meta_status, not requested status $STATUS"
    state="$(jq -c --arg id "$CASE_ID" --arg status "$meta_status" --argjson attempt "$attempt" \
      --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson meta "$existing_meta" '
      .updated_at=$updated
      | (.cases[] | select(.id==$id) | .status) = $status
      | (.cases[] | select(.id==$id) | .current_attempt) = $attempt
      | (.cases[] | select(.id==$id) | .attempts) |=
          ((map(select(.attempt != $attempt)) + [$meta]) | sort_by(.attempt))
    ' <<<"$state")"
    save_state "$state"
    rebuild_results_tsv "$state"
    info "finish already durable for $CASE_ID attempt=$attempt status=$meta_status"
    printf 'status=%s case=%s attempt=%s ended_at=%s reconciled=true\n' \
      "$meta_status" "$CASE_ID" "$attempt" "$(jq -r '.ended_at // empty' <<<"$existing_meta")"
    return 0
  fi

  local evidence_sha="" evidence_rel="" log_sha="" log_rel=""
  local run_mode executor adapter_meta adapter_id evidence_kind
  run_mode="$(jq -r '.mode' <<<"$state")"
  executor="$(jq -r '.executor // empty' <<<"$case_json")"
  adapter_meta="$(adapter_meta_from_catalog "$CASE_ID")"
  adapter_id="$(jq -r '.adapter_id' <<<"$adapter_meta")"
  evidence_kind="$(jq -r '.evidence_kind' <<<"$adapter_meta")"
  if [[ "$run_mode" == "release" && "$STATUS" == "passed" ]]; then
    [[ -n "$EVIDENCE_PATH" ]] || die "release-mode passed cases require an evidence file"
    if [[ "$CASE_ID" == "R0-7" || "$executor" == "logs" ]]; then
      [[ -n "$LOG_WINDOW_PATH" ]] || die "release log-gate cases require a log-window file"
    fi
  fi
  if [[ -n "$EVIDENCE_PATH" ]]; then
    [[ -s "$EVIDENCE_PATH" && ! -L "$EVIDENCE_PATH" ]] \
      || die "evidence file missing, empty, or symlinked: $EVIDENCE_PATH"
    local bound_revision bound_digest
    bound_revision="$(jq -r '.bindings.revision' <<<"$state")"
    bound_digest="$(jq -r '.bindings.digest' <<<"$state")"
    if [[ "$run_mode" == "release" && "$STATUS" == "passed" ]]; then
      validate_evidence_by_kind "$EVIDENCE_PATH" "$evidence_kind" "$CASE_ID" \
        "$bound_revision" "$bound_digest" "$adapter_id" "$attempt"
    fi
    evidence_sha="$(file_sha256 "$EVIDENCE_PATH")"
    local dest_ev
    dest_ev="$attempt_dir/evidence.json"
    if [[ "$(realpath -m "$EVIDENCE_PATH")" != "$(realpath -m "$dest_ev")" ]]; then
      install -m 0600 "$EVIDENCE_PATH" "$dest_ev"
    fi
    [[ "$(file_sha256 "$dest_ev")" == "$evidence_sha" ]] || die "persisted evidence checksum changed"
    evidence_rel="cases/$CASE_ID/attempt-$(printf '%03d' "$attempt")/evidence.json"
  fi
  if [[ -n "$LOG_WINDOW_PATH" ]]; then
    [[ -s "$LOG_WINDOW_PATH" && ! -L "$LOG_WINDOW_PATH" ]] \
      || die "log window file missing, empty, or symlinked: $LOG_WINDOW_PATH"
    local log_real
    log_real="$(realpath -e "$LOG_WINDOW_PATH")"
    [[ "$log_real" != "/root/sub2api-prod-deploy" && "$log_real" != /root/sub2api-prod-deploy/* ]] \
      || die "production logs cannot be used as debug matrix evidence"
    log_sha="$(file_sha256 "$LOG_WINDOW_PATH")"
    local dest_lw
    dest_lw="$attempt_dir/log-window.raw"
    if [[ "$(realpath -m "$LOG_WINDOW_PATH")" != "$(realpath -m "$dest_lw")" ]]; then
      install -m 0600 "$LOG_WINDOW_PATH" "$dest_lw"
    fi
    [[ "$(file_sha256 "$dest_lw")" == "$log_sha" ]] || die "persisted log window checksum changed"
    log_rel="cases/$CASE_ID/attempt-$(printf '%03d' "$attempt")/log-window.raw"
  fi


  if [[ "$run_mode" == "release" && "$STATUS" == "passed" ]]; then
    [[ -n "$evidence_sha" ]] || die "release-mode passed cases require bound evidence"
    if [[ "$CASE_ID" == "R0-7" || "$adapter_id" == "log-gate" || "$executor" == "logs" ]]; then
      [[ -n "$log_sha" && -n "$LOG_WINDOW_PATH" ]] || die "release log-gate cases require a log-window file"
      scan_log_window_for_fatal "$LOG_WINDOW_PATH" "$CASE_ID log-window"
    fi
    if is_automatic_adapter_id "$adapter_id"; then
      assert_release_automatic_checkpoint "$attempt_dir" "$CASE_ID" "$attempt" "$adapter_id" \
        "$evidence_kind" "$(jq -r '.bindings.revision' <<<"$state")" \
        "$(jq -r '.bindings.digest' <<<"$state")" "$(jq -r '.bindings.config_fingerprint' <<<"$state")" \
        "$STATUS" "$evidence_sha" "$log_sha"
    fi
  fi

  local ended_at
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local meta
  meta="$(jq -c --arg status "$STATUS" --arg ended_at "$ended_at" --arg note "$NOTE" \
    --arg evidence_path "$evidence_rel" --arg evidence_sha256 "$evidence_sha" \
    --arg log_window_path "$log_rel" --arg log_window_sha256 "$log_sha" '
    .status=$status
    | .ended_at=$ended_at
    | .note=(if $note=="" then null else $note end)
    | .evidence=(if $evidence_path=="" then null else {path:$evidence_path,sha256:$evidence_sha256} end)
    | .log_window=(if $log_window_path=="" then null else {path:$log_window_path,sha256:$log_window_sha256} end)
  ' "$meta_path")"
  atomic_write_json "$meta_path" "$meta"

  state="$(jq -c --arg id "$CASE_ID" --arg status "$STATUS" --argjson attempt "$attempt" --arg ended_at "$ended_at" \
    --arg evidence_sha "$evidence_sha" --arg note "$NOTE" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson meta "$meta" '
    .updated_at=$updated
    | (.cases[] | select(.id==$id) | .status) = $status
    | (.cases[] | select(.id==$id) | .attempts) |=
        ((map(select(.attempt != $attempt)) + [$meta]) | sort_by(.attempt))
    | (.cases[] | select(.id==$id) | .current_attempt) = $attempt
  ' <<<"$state")"
  save_state "$state"
  rebuild_results_tsv "$state"

  info "finished $CASE_ID attempt=$attempt status=$STATUS"
  printf 'status=%s case=%s attempt=%s ended_at=%s\n' "$STATUS" "$CASE_ID" "$attempt" "$ended_at"
}

cmd_status() {
  require_command jq
  require_run_dir
  local state
  state="$(load_state)"
  jq -c '{
    status, mode, created_at, updated_at, sealed_at, invalidated_at,
    bindings,
    summary: {
      total: (.cases|length),
      pending: ([.cases[]|select(.status=="pending")]|length),
      running: ([.cases[]|select(.status=="running")]|length),
      passed: ([.cases[]|select(.status=="passed")]|length),
      failed: ([.cases[]|select(.status=="failed")]|length),
      blocked: ([.cases[]|select(.status=="blocked")]|length),
      needs_manual: ([.cases[]|select(.status=="needs_manual")]|length),
      skipped_not_triggered: ([.cases[]|select(.status=="skipped_not_triggered")]|length)
    },
    cases: [.cases[] | {id, status, current_attempt, executor}]
  }' <<<"$state"
}

cmd_verify() {
  require_command jq; require_command sha256sum; require_command realpath
  require_run_dir
  local state
  state="$(load_state)"
  assert_bindings_fresh "$state" 1

  local bound_revision bound_digest bound_config
  bound_revision="$(jq -r '.bindings.revision' <<<"$state")"
  bound_digest="$(jq -r '.bindings.digest' <<<"$state")"
  bound_config="$(jq -r '.bindings.config_fingerprint' <<<"$state")"
  [[ -z "$REVISION" || "$REVISION" == "$bound_revision" ]] || die "requested revision does not match the sealed binding"
  [[ -z "$DIGEST" || "$DIGEST" == "$bound_digest" ]] || die "requested digest does not match the sealed binding"
  [[ -z "$CONFIG_FINGERPRINT" || "$CONFIG_FINGERPRINT" == "$bound_config" ]] \
    || die "requested config fingerprint does not match the sealed binding"

  # verify evidence sha bindings still match
  local bad="" rel sha f cur
  while IFS=$'	' read -r rel sha; do
    [[ -n "$rel" ]] || continue
    f="$RUN_DIR/$rel"
    if [[ ! -f "$f" ]]; then bad+="missing:$rel "; continue; fi
    if [[ "$(realpath -e "$f")" != "$(realpath -e "$RUN_DIR")"/* ]]; then bad+="escape:$rel "; continue; fi
    cur="$(file_sha256 "$f")"
    if [[ "$cur" != "$sha" ]]; then bad+="mismatch:$rel "; fi
  done < <(jq -r '.cases[].attempts[]? | select(.evidence != null) | [.evidence.path, .evidence.sha256] | @tsv' <<<"$state")
  [[ -z "$bad" ]] || die "evidence integrity failure: $bad"

  bad=""
  while IFS=$'\t' read -r rel sha; do
    [[ -n "$rel" ]] || continue
    f="$RUN_DIR/$rel"
    if [[ ! -f "$f" ]]; then bad+="missing:$rel "; continue; fi
    if [[ "$(realpath -e "$f")" != "$(realpath -e "$RUN_DIR")"/* ]]; then bad+="escape:$rel "; continue; fi
    cur="$(file_sha256 "$f")"
    if [[ "$cur" != "$sha" ]]; then bad+="mismatch:$rel "; fi
  done < <(jq -r '.cases[].attempts[]? | select(.log_window != null) | [.log_window.path, .log_window.sha256] | @tsv' <<<"$state")
  [[ -z "$bad" ]] || die "log-window integrity failure: $bad"

  revalidate_release_passed_cases "$state"


  if [[ "$(jq -r '.status' <<<"$state")" == "sealed" ]]; then
    local release_file="$RUN_DIR/release-evidence.json"
    local checksum_file="$RUN_DIR/release-evidence.json.sha256"
    [[ -f "$release_file" && -f "$checksum_file" ]] || die "sealed release evidence files are missing"
    local release_sum recorded_sum state_sum
    release_sum="$(file_sha256 "$release_file")"
    recorded_sum="$(awk 'NR==1 {print $1}' "$checksum_file")"
    state_sum="$(jq -r '.release_evidence_sha256 // empty' <<<"$state")"
    [[ "$release_sum" == "$recorded_sum" && "$release_sum" == "$state_sum" ]] \
      || die "sealed release evidence checksum mismatch"
    jq -e --arg revision "$bound_revision" --arg digest "$bound_digest" '
      .schema_version==1
      and .kind=="release-evidence"
      and .mode=="release"
      and .bindings.revision==$revision
      and .bindings.digest==$digest
      and (.bindings.source_run_id|tostring|test("^[0-9]+$"))
      and .r0.all_passed==true
      and ([.r0.required[] as $id | any(.cases[]; .id==$id and .status=="passed")] | all)
      and all(.cases[]; .status=="passed" or .status=="skipped_not_triggered")
    ' "$release_file" >/dev/null || die "sealed release evidence structure is invalid"
    local state_cases release_cases
    state_cases="$(jq -cS '[.cases[]|{id,status,current_attempt,executor,level,suite}]' <<<"$state")"
    release_cases="$(jq -cS '[.cases[]|{id,status,current_attempt,executor,level,suite}]' "$release_file")"
    [[ "$state_cases" == "$release_cases" ]] || die "sealed release evidence case summary differs from state"
  fi

  local mode total pending failed source_run_id
  mode="$(jq -r '.mode' <<<"$state")"
  total="$(jq '.cases|length' <<<"$state")"
  pending="$(jq '[.cases[]|select(.status=="pending" or .status=="running")]|length' <<<"$state")"
  failed="$(jq '[.cases[]|select(.status=="failed" or .status=="blocked")]|length' <<<"$state")"
  source_run_id="$(jq -r '.bindings.source_run_id // empty' <<<"$state")"
  if [[ -z "$source_run_id" && "$mode" == "release" && "$(jq -r '.status' <<<"$state")" == "sealed" ]]; then
    source_run_id="$(jq -r '.bindings.source_run_id // empty' "$RUN_DIR/release-evidence.json" 2>/dev/null || true)"
  fi
  info "verify ok mode=$mode total=$total pending=$pending failed=$failed source_run_id=${source_run_id:-none}"
  if [[ -n "$source_run_id" ]]; then
    printf 'status=verify_ok mode=%s total=%s pending=%s failed=%s source_run_id=%s\n' \
      "$mode" "$total" "$pending" "$failed" "$source_run_id"
  else
    printf 'status=verify_ok mode=%s total=%s pending=%s failed=%s\n' "$mode" "$total" "$pending" "$failed"
  fi
}

cmd_seal() {
  require_command jq; require_command sha256sum; require_command date
  require_run_dir
  with_lock
  local state
  state="$(load_state)"
  assert_bindings_fresh "$state"
  local mode
  mode="$(jq -r '.mode' <<<"$state")"
  [[ "$mode" == "release" ]] || die "seal only allowed in release mode"

  # Every plan case must be terminal passed or skipped_not_triggered
  local nonterm
  nonterm="$(jq -r '[.cases[] | select(.status != "passed" and .status != "skipped_not_triggered") | .id] | join(",")' <<<"$state")"
  [[ -z "$nonterm" ]] || die "seal blocked; non-terminal cases: $nonterm"

  # R0 and manual cannot be skipped
  local bad_skip
  bad_skip="$(jq -r '[.cases[] | select(.status=="skipped_not_triggered") | select((.level=="R0") or (.executor=="manual")) | .id] | join(",")' <<<"$state")"
  [[ -z "$bad_skip" ]] || die "R0/manual cases cannot be skipped: $bad_skip"

  jq -e '
    all(.cases[];
      if .status=="passed" then
        (.current_attempt > 0)
        and (.current_attempt as $current | .attempts | any(.status=="passed" and .attempt==$current and .evidence!=null))
        and (if .id=="R0-7" or .executor=="logs" then
               (.current_attempt as $current | .attempts | any(.status=="passed" and .attempt==$current and .log_window!=null))
             else true end)
      else
        .status=="skipped_not_triggered"
        and (.current_attempt as $current | .attempts | any(.status=="skipped_not_triggered" and .attempt==$current and (.note|type=="string" and length>0)))
      end)
  ' <<<"$state" >/dev/null || die "release cases lack current-attempt evidence or required log windows"

  # R0-1..R0-8 must all be present and passed
  local rid
  for rid in "${R0_REQUIRED[@]}"; do
    local st
    st="$(jq -r --arg id "$rid" '[.cases[]|select(.id==$id)|.status][0] // "missing"' <<<"$state")"
    [[ "$st" == "passed" ]] || die "seal requires $rid=passed (got $st)"
  done

  revalidate_release_passed_cases "$state"
  cmd_verify >/dev/null || die "seal integrity verification failed"

  local sealed_at evidence source_run_id r01_rel r01_file
  sealed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  r01_rel="$(jq -r '.cases[] | select(.id=="R0-1") | .current_attempt as $current
    | .attempts[] | select(.attempt==$current and .status=="passed") | .evidence.path' <<<"$state")"
  [[ -n "$r01_rel" ]] || die "seal cannot locate R0-1 evidence path"
  r01_file="$RUN_DIR/$r01_rel"
  [[ -f "$r01_file" && ! -L "$r01_file" ]] || die "R0-1 evidence file missing for source_run_id binding"
  source_run_id="$(jq -r '.workflow_run_id|tostring' "$r01_file")"
  [[ "$source_run_id" =~ ^[0-9]+$ ]] || die "R0-1 workflow_run_id is not a numeric source_run_id"
  state="$(jq -c --arg source_run_id "$source_run_id" '
    .bindings.source_run_id=$source_run_id
  ' <<<"$state")"
  evidence="$(jq -c --arg sealed_at "$sealed_at" --arg source_run_id "$source_run_id" '
    {
      schema_version: 1,
      kind: "release-evidence",
      sealed_at: $sealed_at,
      mode: .mode,
      bindings: (.bindings + {source_run_id: $source_run_id}),
      cases: [.cases[] | {id, status, current_attempt, executor, level, suite, attempts}],
      r0: {
        required: ["R0-1","R0-2","R0-3","R0-4","R0-5","R0-6","R0-7","R0-8"],
        all_passed: true
      }
    }
  ' <<<"$state")"
  atomic_write_json "$RUN_DIR/release-evidence.json" "$evidence"
  local sum
  sum="$(file_sha256 "$RUN_DIR/release-evidence.json")"
  printf '%s  release-evidence.json\n' "$sum" > "$RUN_DIR/release-evidence.json.sha256"
  chmod 0600 "$RUN_DIR/release-evidence.json.sha256"

  state="$(jq -c --arg sealed_at "$sealed_at" --arg sum "$sum" --arg updated "$sealed_at" '
    .status="sealed" | .sealed_at=$sealed_at | .updated_at=$updated | .release_evidence_sha256=$sum
  ' <<<"$state")"
  save_state "$state"
  info "sealed release evidence sha256=$sum"
  printf 'status=sealed release_evidence_sha256=%s\n' "$sum"
}

cmd_invalidate() {
  require_command jq; require_command date; require_command flock
  require_run_dir
  with_lock
  [[ -n "$REASON" ]] || die "--reason is required"
  local state
  state="$(load_state)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  state="$(jq -c --arg reason "$REASON" --arg now "$now" '
    .status="invalidated" | .invalidated_at=$now | .invalidate_reason=$reason | .updated_at=$now
  ' <<<"$state")"
  save_state "$state"
  info "invalidated: $REASON"
  printf 'status=invalidated reason=%s\n' "$REASON"
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    init) cmd_init ;;
    start) cmd_start ;;
    finish) cmd_finish ;;
    status) cmd_status ;;
    verify) cmd_verify ;;
    seal) cmd_seal ;;
    invalidate) cmd_invalidate ;;
    *) die "unknown command: $COMMAND (use init|start|finish|status|seal|verify|invalidate)" ;;
  esac
}

main "$@"
