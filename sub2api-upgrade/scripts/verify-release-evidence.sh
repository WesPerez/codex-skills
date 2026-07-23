#!/usr/bin/env bash
# Verify a sealed debug matrix release-evidence bundle without mutating it.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly MATRIX_RUNNER="$SCRIPT_DIR/run-debug-matrix.sh"
readonly OWNER_MARK="sub2api-debug-matrix-v1"
readonly -a R0_REQUIRED=(R0-1 R0-2 R0-3 R0-4 R0-5 R0-6 R0-7 R0-8)

EVIDENCE_PATH=""
EXPECTED_REVISION=""
EXPECTED_DIGEST=""

usage() {
  cat <<'USAGE'
Usage:
  verify-release-evidence.sh --evidence <run-dir/release-evidence.json> \
    --expected-revision <40-char-sha> --expected-digest sha256:<64-hex>

Re-hashes the sealed evidence and its immutable matrix inputs, verifies all
R0-1..R0-8 results and referenced evidence/log files, and prints one JSON object.
USAGE
}

die() { printf '%s\n' "[sub2api-release-evidence] error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --evidence) (( $# >= 2 )) || die "--evidence requires a value"; EVIDENCE_PATH="$2"; shift ;;
      --expected-revision) (( $# >= 2 )) || die "--expected-revision requires a value"; EXPECTED_REVISION="$2"; shift ;;
      --expected-digest) (( $# >= 2 )) || die "--expected-digest requires a value"; EXPECTED_DIGEST="$2"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}

safe_regular_file() {
  local path="$1" label="$2" mode tail
  [[ -f "$path" && ! -L "$path" ]] || die "$label must be a regular non-symlink file"
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%OLp' "$path")"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "could not read $label permissions"
  tail="${mode: -3}"
  (( (8#$tail & 8#022) == 0 )) || die "$label is group/world writable (mode $mode)"
}

main() {
  parse_args "$@"
  require_command jq
  require_command sha256sum
  require_command awk
  require_command realpath
  require_command stat
  [[ -f "$MATRIX_RUNNER" ]] || die "matrix verifier is unavailable: $MATRIX_RUNNER"
  [[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "expected revision must be lowercase 40-char SHA"
  [[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "expected digest must match sha256:<64-hex>"
  [[ -n "$EVIDENCE_PATH" ]] || die "--evidence is required"

  local evidence run_dir checksum_file owner state_file
  evidence="$(realpath -e "$EVIDENCE_PATH")" || die "evidence path is not resolvable"
  [[ "$(basename -- "$evidence")" == "release-evidence.json" ]] \
    || die "evidence filename must be release-evidence.json"
  run_dir="$(dirname -- "$evidence")"
  checksum_file="$run_dir/release-evidence.json.sha256"
  owner="$run_dir/.owner"
  state_file="$run_dir/state.json"
  safe_regular_file "$evidence" "release evidence"
  safe_regular_file "$checksum_file" "release evidence checksum"
  safe_regular_file "$owner" "matrix owner marker"
  safe_regular_file "$state_file" "matrix state"
  [[ "$(tr -d '[:space:]' < "$owner")" == "$OWNER_MARK" ]] || die "matrix owner marker mismatch"

  local calculated recorded recorded_name config_fingerprint
  calculated="$(sha256sum -- "$evidence" | awk '{print $1}')"
  recorded="$(awk 'NR==1 {print $1}' "$checksum_file")"
  recorded_name="$(awk 'NR==1 {$1=""; sub(/^[[:space:]]+/, ""); print}' "$checksum_file")"
  [[ "$recorded" =~ ^[0-9a-f]{64}$ && "$recorded" == "$calculated" ]] \
    || die "release evidence checksum mismatch"
  [[ "$recorded_name" == "release-evidence.json" ]] || die "checksum sidecar names an unexpected file"
  jq -e --arg sum "$calculated" --arg revision "$EXPECTED_REVISION" --arg digest "$EXPECTED_DIGEST" '
    .status=="sealed"
    and .mode=="release"
    and .release_evidence_sha256==$sum
    and .bindings.revision==$revision
    and .bindings.digest==$digest
  ' "$state_file" >/dev/null || die "matrix state is not sealed for this evidence binding"

  jq -e --arg revision "$EXPECTED_REVISION" --arg digest "$EXPECTED_DIGEST" '
    .schema_version==1
    and .kind=="release-evidence"
    and .mode=="release"
    and .bindings.revision==$revision
    and .bindings.digest==$digest
    and (.bindings.config_fingerprint|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.source_run_id|tostring|test("^[0-9]+$"))
    and (.bindings.plan_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.fixture_manifest_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.matrix_catalog_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.adapter_catalog_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.adapter_bundle_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and (.bindings.config_fingerprint_document_sha256|type=="string" and test("^[0-9a-f]{64}$"))
    and .r0.all_passed==true
    and .r0.required==["R0-1","R0-2","R0-3","R0-4","R0-5","R0-6","R0-7","R0-8"]
    and (.cases|type=="array" and length>=8)
    and (([.cases[].id]|unique|length)==(.cases|length))
    and all(.cases[]; .status=="passed" or .status=="skipped_not_triggered")
    and ([.r0.required[] as $id | any(.cases[]; .id==$id and .status=="passed")] | all)
    and all(.cases[];
      if .status=="passed" then
        .current_attempt as $current
        | .attempts | any(.attempt==$current and .status=="passed" and .evidence!=null)
      else
        .current_attempt as $current
        | .attempts | any(.attempt==$current and .status=="skipped_not_triggered" and (.note|type=="string" and length>0))
      end)
    and all(.cases[];
      if .executor=="logs" then
        .current_attempt as $current
        | .attempts | any(.attempt==$current and .status=="passed" and .log_window!=null)
      else true end)
  ' "$evidence" >/dev/null || die "release evidence structure or R0 proof is invalid"

  local identity_rel identity_file rollback_rel rollback_file
  identity_rel="$(jq -r '.cases[] | select(.id=="R0-1") | .current_attempt as $current
    | .attempts[] | select(.attempt==$current and .status=="passed") | .evidence.path' "$evidence")"
  rollback_rel="$(jq -r '.cases[] | select(.id=="R0-8") | .current_attempt as $current
    | .attempts[] | select(.attempt==$current and .status=="passed") | .evidence.path' "$evidence")"
  identity_file="$run_dir/$identity_rel"
  rollback_file="$run_dir/$rollback_rel"
  identity_file="$(realpath -e "$identity_file")" || die "R0-1 evidence path is not resolvable"
  rollback_file="$(realpath -e "$rollback_file")" || die "R0-8 evidence path is not resolvable"
  [[ "$identity_file" == "$run_dir"/* && "$rollback_file" == "$run_dir"/* ]] \
    || die "R0 evidence path escapes the sealed matrix run"
  safe_regular_file "$identity_file" "R0-1 candidate identity evidence"
  safe_regular_file "$rollback_file" "R0-8 rollback evidence"
  jq -e --arg revision "$EXPECTED_REVISION" --arg digest "$EXPECTED_DIGEST" \
    --arg reference "ghcr.io/wesperez/sub2api:debug-sha-${EXPECTED_REVISION}@${EXPECTED_DIGEST}" '
    .schema_version==1 and .kind=="candidate-identity"
    and .revision==$revision and .digest==$digest and .image_reference==$reference
    and .workflow_name=="Docker Branch Images"
    and (.workflow_run_id|tostring|test("^[0-9]+$"))
    and .ci_conclusion=="success" and .ref_name=="debug"
    and (.container_image_id|type=="string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$identity_file" >/dev/null || die "R0-1 candidate identity evidence is invalid"

  local source_run_id identity_run_id
  source_run_id="$(jq -r '.bindings.source_run_id|tostring' "$evidence")"
  [[ "$source_run_id" =~ ^[0-9]+$ ]] || die "release evidence bindings.source_run_id must be digits"
  identity_run_id="$(jq -r '.workflow_run_id|tostring' "$identity_file")"
  [[ "$identity_run_id" == "$source_run_id" ]] \
    || die "bindings.source_run_id does not match R0-1 workflow_run_id"

  jq -e --arg revision "$EXPECTED_REVISION" --arg digest "$EXPECTED_DIGEST" '
    .schema_version==1 and .kind=="rollback-compatibility"
    and .candidate_revision==$revision and .candidate_digest==$digest
    and (.old_image_revision|type=="string" and test("^[0-9a-f]{40}$"))
    and .old_image_started==true and .health_passed==true
    and .core_readonly_passed==true and .schema_compatible==true
    and .database_restore_performed==false
    and (.tested_at|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  ' "$rollback_file" >/dev/null || die "R0-8 rollback compatibility evidence is invalid"

  config_fingerprint="$(jq -r '.bindings.config_fingerprint' "$evidence")"
  bash "$MATRIX_RUNNER" verify --run-dir "$run_dir" \
    --revision "$EXPECTED_REVISION" --digest "$EXPECTED_DIGEST" \
    --config-fingerprint "$config_fingerprint" >/dev/null \
    || die "sealed matrix bundle verification failed"

  jq -n \
    --arg evidence "$evidence" \
    --arg run_dir "$run_dir" \
    --arg sha256 "$calculated" \
    --arg revision "$EXPECTED_REVISION" \
    --arg digest "$EXPECTED_DIGEST" \
    --arg config_fingerprint "$config_fingerprint" \
    --arg source_run_id "$source_run_id" \
    '{status:"verified", evidence:$evidence, run_dir:$run_dir, sha256:$sha256,
      revision:$revision, digest:$digest, config_fingerprint:$config_fingerprint,
      source_run_id:$source_run_id, rollback_image_safe:true}'
}

main "$@"
