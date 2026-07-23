#!/usr/bin/env bash
# Scan runner-provided logs only. Match fatal patterns => 70.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
readonly EC_FAILED=70
readonly EC_BLOCKED=71

die() { printf '%s\n' "[adapter-log-gate] error: $*" >&2; exit "$EC_BLOCKED"; }

[[ -n "${ADAPTER_EVIDENCE_OUT:-}" ]] || die "ADAPTER_EVIDENCE_OUT is required"
[[ -n "${ADAPTER_CASE_ID:-}" ]] || die "ADAPTER_CASE_ID is required"
[[ -n "${ADAPTER_REVISION:-}" && -n "${ADAPTER_DIGEST:-}" ]] || die "revision/digest required"
[[ -n "${ADAPTER_LOG_FILE:-}" ]] || die "ADAPTER_LOG_FILE is required (runner-provided)"
[[ -f "$ADAPTER_LOG_FILE" ]] || die "log file missing: $ADAPTER_LOG_FILE"

if (( $# > 0 )); then
  die "log-gate does not accept arguments"
fi

pattern='panic|fatal|migration[^[:alnum:]]*(failed|failure|error)|checksum[^[:alnum:]]*(mismatch|failed|failure|error)|out of memory|oom[-_ ]?killed|response\.failed'
hits=0
if grep -Eiq -- "$pattern" "$ADAPTER_LOG_FILE"; then
  hits="$(grep -Eic -- "$pattern" "$ADAPTER_LOG_FILE" || true)"
fi

started="${ADAPTER_STARTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
deploy_dir="${ADAPTER_DEBUG_DIR:-/root/sub2api-debug-deploy}"
if [[ "${ADAPTER_TEST_MODE:-0}" == "1" ]]; then test_json=true; else test_json=false; fi

if (( hits > 0 )); then
  printf '%s\n' "[adapter-log-gate] fatal log patterns matched (count=$hits)" >&2
  jq -n --arg case_id "$ADAPTER_CASE_ID" --arg revision "$ADAPTER_REVISION" --arg digest "$ADAPTER_DIGEST" \
    --arg adapter_id "${ADAPTER_ADAPTER_ID:-log-gate}" --arg started "$started" --arg ended "$ended" \
    --arg deploy "$deploy_dir" --argjson test_mode "$test_json" --argjson hits "$hits" \
    '{schema_version:1,kind:"debug-case-evidence",runner:"sub2api-debug-adapter-v1",case_id:$case_id,revision:$revision,digest:$digest,adapter_id:$adapter_id,status:"failed",started_at:$started,ended_at:$ended,target:{environment:"debug",compose_project:"sub2api-debug",deploy_dir:$deploy,test_mode:$test_mode},assertions:[{name:"no_fatal_log_patterns",passed:false,hits:$hits}]}' > "$ADAPTER_EVIDENCE_OUT"
  chmod 0600 "$ADAPTER_EVIDENCE_OUT"
  exit "$EC_FAILED"
fi

jq -n --arg case_id "$ADAPTER_CASE_ID" --arg revision "$ADAPTER_REVISION" --arg digest "$ADAPTER_DIGEST" \
  --arg adapter_id "${ADAPTER_ADAPTER_ID:-log-gate}" --arg started "$started" --arg ended "$ended" \
  --arg deploy "$deploy_dir" --argjson test_mode "$test_json" \
  '{schema_version:1,kind:"debug-case-evidence",runner:"sub2api-debug-adapter-v1",case_id:$case_id,revision:$revision,digest:$digest,adapter_id:$adapter_id,status:"passed",started_at:$started,ended_at:$ended,target:{environment:"debug",compose_project:"sub2api-debug",deploy_dir:$deploy,test_mode:$test_mode},assertions:[{name:"no_fatal_log_patterns",passed:true}]}' > "$ADAPTER_EVIDENCE_OUT"
chmod 0600 "$ADAPTER_EVIDENCE_OUT"
exit 0
