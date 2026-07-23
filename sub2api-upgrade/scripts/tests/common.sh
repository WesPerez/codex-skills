#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$TESTS_DIR/.." && pwd -P)"
SKILL_DIR="$(cd -- "$SCRIPTS_DIR/.." && pwd -P)"
FIXTURES="$TESTS_DIR/fixtures"
PASS=0; FAIL=0

assert_ok() { local name="$1"; shift; if "$@"; then echo "PASS $name"; PASS=$((PASS+1)); else echo "FAIL $name"; FAIL=$((FAIL+1)); fi; }
assert_fail() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL $name (expected failure)"; FAIL=$((FAIL+1)); else echo "PASS $name"; PASS=$((PASS+1)); fi; }
summary() { echo "--- summary pass=$PASS fail=$FAIL ---"; [[ "$FAIL" -eq 0 ]]; }

HEX64="$(printf 'a%.0s' {1..64})"
REV="$(printf 'b%.0s' {1..40})"
DIGEST="sha256:$(printf 'c%.0s' {1..64})"
CFG="$HEX64"

make_valid_fixture() {
  local dest="$1"
  cp "$SKILL_DIR/references/debug-fixture-manifest.template.json" "$dest"
}

make_mini_catalog() {
  local dest="$1"
  cat > "$dest" <<'TSV'
id	suite	level	executor	description	assertion
R0-1	core	R0	metadata	ident	ok
R0-2	core	R0	debug	boot	ok
R0-3	core	R0	debug	base	ok
R0-4	core	R0	canary	resp	ok
R0-5	core	R0	canary	err	ok
R0-6	core	R0	manual	duty	ok
R0-7	core	R0	logs	logs	ok
R0-8	core	R0	debug	rollback	ok
R1-X1	extra	R1	canary	optional	ok
TSV
}

make_mini_adapter_catalog() {
  local dest="$1"
  cat > "$dest" <<'TSV'
case_id	adapter_id	resume_policy	log_scope	timeout_seconds	evidence_kind
R0-1	candidate-identity	replay_safe	sub2api	30	candidate-identity
R0-2	debug-startup	replay_safe	project	30	debug-case-evidence
R0-3	manual	no_replay	none	0	manual-verification
R0-4	manual	no_replay	none	0	manual-verification
R0-5	manual	no_replay	none	0	manual-verification
R0-6	manual	no_replay	none	0	manual-verification
R0-7	log-gate	replay_safe	project	30	debug-case-evidence
R0-8	manual	no_replay	none	0	rollback-compatibility
R1-X1	fixed-canary	no_replay	project	30	debug-case-evidence
TSV
}

write_debug_case_evidence() {
  local dest="$1" case_id="$2" adapter_id="$3"
  jq -n --arg case_id "$case_id" --arg revision "$REV" --arg digest "$DIGEST" --arg adapter_id "$adapter_id" '
    {schema_version:1,kind:"debug-case-evidence",runner:"sub2api-debug-adapter-v1",
     case_id:$case_id,revision:$revision,digest:$digest,adapter_id:$adapter_id,status:"passed",
     started_at:"2026-07-23T00:00:00Z",ended_at:"2026-07-23T00:00:01Z",
     target:{environment:"debug",compose_project:"sub2api-debug",deploy_dir:"/tmp/test-debug",test_mode:true},
     assertions:[{name:"test assertion",passed:true}]}
  ' > "$dest"
}

write_manual_verification_evidence() {
  local dest="$1" case_id="$2" attempt="${3:-1}"
  jq -n --arg case_id "$case_id" --arg revision "$REV" --arg digest "$DIGEST" --argjson attempt "$attempt" '
    {schema_version:1,kind:"manual-verification",
     case_id:$case_id,revision:$revision,digest:$digest,attempt:$attempt,adapter_id:"manual",
     target:{environment:"debug",compose_project:"sub2api-debug",deploy_dir:"/tmp/test-debug",test_mode:true},
     verifier:"test-operator",procedure:"manual structured verification for matrix contract tests",
     assertions:[{name:"manual_check_passed",passed:true}],
     verified_at:"2026-07-23T00:00:00Z"}
  ' > "$dest"
}

plant_adapter_checkpoint() {
  local run_dir="$1" case_id="$2" attempt="$3" adapter_id="$4" evidence_kind="$5" evidence_file="$6"
  local log_file="${7:-}"
  local attempt_dir evidence_sha log_json now
  attempt_dir="$run_dir/cases/$case_id/attempt-$(printf '%03d' "$attempt")"
  mkdir -p "$attempt_dir"
  evidence_sha="$(sha256sum -- "$evidence_file" | awk '{print $1}')"
  now="2026-07-23T00:00:00Z"
  if [[ -n "$log_file" ]]; then
    local log_sha
    log_sha="$(sha256sum -- "$log_file" | awk '{print $1}')"
    log_json="$(jq -n --arg sha "$log_sha" '{collected:true,scope:"project",since:"2026-07-23T00:00:00Z",until:"2026-07-23T00:00:01Z",path:"log-window.raw",sha256:$sha,compose_file:"/tmp/compose.yml",raw_printed:false}')"
  else
    log_json='null'
  fi
  jq -n --arg case_id "$case_id" --argjson attempt "$attempt" --arg adapter_id "$adapter_id" \
    --arg evidence_kind "$evidence_kind" --arg revision "$REV" --arg digest "$DIGEST" --arg cfg "$CFG" \
    --arg evidence_sha "$evidence_sha" --argjson log_window "$log_json" --arg now "$now" '
    {schema_version:1,runner:"sub2api-debug-adapter-v1",case_id:$case_id,attempt:$attempt,
     adapter_id:$adapter_id,resume_policy:"replay_safe",log_scope:(if $adapter_id=="candidate-identity" then "sub2api" else "project" end),
     timeout_seconds:30,evidence_kind:$evidence_kind,phase:"logs_done",result:"passed",exit_code:0,
     started_at:$now,updated_at:$now,ended_at:$now,log_since:$now,log_until:$now,
     log_window:$log_window,evidence:{path:"evidence.json",sha256:$evidence_sha},note:null,test_mode:true,
     bindings:{revision:$revision,digest:$digest,config_fingerprint:$cfg}}
  ' > "$attempt_dir/adapter-state.json"
  chmod 0600 "$attempt_dir/adapter-state.json"
}

make_plan() {
  local dest="$1"
  jq -n --arg revision "$REV" '
    {generated_at:"2026-07-23T00:00:00Z", baseline_gate:"passed", candidate:{revision:$revision}, cases:[
      {id:"R0-1",suite:"core",level:"R0",executor:"metadata"},
      {id:"R0-2",suite:"core",level:"R0",executor:"debug"},
      {id:"R0-3",suite:"core",level:"R0",executor:"debug"},
      {id:"R0-4",suite:"core",level:"R0",executor:"canary"},
      {id:"R0-5",suite:"core",level:"R0",executor:"canary"},
      {id:"R0-6",suite:"core",level:"R0",executor:"manual"},
      {id:"R0-7",suite:"core",level:"R0",executor:"logs"},
      {id:"R0-8",suite:"core",level:"R0",executor:"debug"},
      {id:"R1-X1",suite:"extra",level:"R1",executor:"canary"}
    ]}
  ' > "$dest"
}
