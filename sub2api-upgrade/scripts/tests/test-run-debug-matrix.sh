#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_DIR/common.sh"
RUNNER="$SCRIPTS_DIR/run-debug-matrix.sh"
EVIDENCE_VERIFIER="$SCRIPTS_DIR/verify-release-evidence.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export SUB2API_UPGRADE_TEST_MODE=1

make_valid_fixture "$TMP/fixture.json"
make_mini_catalog "$TMP/catalog.tsv"
make_mini_adapter_catalog "$TMP/adapters.tsv"
make_plan "$TMP/plan.json"

init_run() {
  local dir="$1" mode="${2:-dev}"
  bash "$RUNNER" init --run-dir "$dir" --plan "$TMP/plan.json" --revision "$REV" --digest "$DIGEST" \
    --fixture-manifest "$TMP/fixture.json" --config-fingerprint "$CFG" --mode "$mode" \
    --matrix-catalog "$TMP/catalog.tsv" --adapter-catalog "$TMP/adapters.tsv"
}

pass_all_r0() {
  local dir="$1"
  local c ev log
  for c in R0-1 R0-2 R0-3 R0-4 R0-5 R0-6 R0-7 R0-8; do
    ev="$TMP/$(basename "$dir")-${c}-evidence.json"
    case "$c" in
      R0-1)
        jq -n --arg revision "$REV" --arg digest "$DIGEST" \
          --arg reference "ghcr.io/wesperez/sub2api:debug-sha-${REV}@${DIGEST}" \
          '{schema_version:1,kind:"candidate-identity",revision:$revision,digest:$digest,
            image_reference:$reference,workflow_name:"Docker Branch Images",workflow_run_id:"1001",
            ci_conclusion:"success",ref_name:"debug",
            container_image_id:"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' > "$ev"
        ;;
      R0-8)
        jq -n --arg revision "$REV" --arg digest "$DIGEST" \
          '{schema_version:1,kind:"rollback-compatibility",candidate_revision:$revision,
            candidate_digest:$digest,old_image_revision:"dddddddddddddddddddddddddddddddddddddddd",
            old_image_started:true,health_passed:true,core_readonly_passed:true,
            schema_compatible:true,database_restore_performed:false,tested_at:"2026-07-23T00:00:00Z"}' > "$ev"
        ;;
      R0-2) write_debug_case_evidence "$ev" "$c" debug-startup ;;
      R0-7) write_debug_case_evidence "$ev" "$c" log-gate ;;
      *) write_manual_verification_evidence "$ev" "$c" 1 ;;
    esac
    bash "$RUNNER" start --run-dir "$dir" --case "$c" >/dev/null
    if [[ "$c" == "R0-1" ]]; then
      plant_adapter_checkpoint "$dir" "$c" 1 candidate-identity candidate-identity "$ev"
      bash "$RUNNER" finish --run-dir "$dir" --case "$c" --status passed --evidence "$ev" >/dev/null
    elif [[ "$c" == "R0-2" ]]; then
      plant_adapter_checkpoint "$dir" "$c" 1 debug-startup debug-case-evidence "$ev"
      bash "$RUNNER" finish --run-dir "$dir" --case "$c" --status passed --evidence "$ev" >/dev/null
    elif [[ "$c" == "R0-7" ]]; then
      log="$TMP/$(basename "$dir")-${c}-log.txt"
      printf 'bounded debug log window for %s
' "$c" > "$log"
      plant_adapter_checkpoint "$dir" "$c" 1 log-gate debug-case-evidence "$ev" "$log"
      bash "$RUNNER" finish --run-dir "$dir" --case "$c" --status passed \
        --evidence "$ev" --log-window "$log" >/dev/null
    else
      bash "$RUNNER" finish --run-dir "$dir" --case "$c" --status passed --evidence "$ev" >/dev/null
    fi
  done
}

# happy path init/start/finish/status/verify
assert_ok "init" init_run "$TMP/run1" dev
assert_ok "start" bash "$RUNNER" start --run-dir "$TMP/run1" --case R0-1
printf 'evidence\n' > "$TMP/ev1.txt"
assert_ok "finish-passed" bash "$RUNNER" finish --run-dir "$TMP/run1" --case R0-1 --status passed --evidence "$TMP/ev1.txt"
assert_ok "status" bash "$RUNNER" status --run-dir "$TMP/run1"
assert_ok "verify" bash "$RUNNER" verify --run-dir "$TMP/run1"

# refuse overwrite passed
assert_fail "no-overwrite-passed" bash "$RUNNER" start --run-dir "$TMP/run1" --case R0-1

# owner mismatch
mkdir -p "$TMP/badowner"
printf 'wrong\n' > "$TMP/badowner/.owner"
printf '{}
' > "$TMP/badowner/state.json"
assert_fail "owner-wrong" bash "$RUNNER" status --run-dir "$TMP/badowner"

# fingerprint drift (plan.json tamper)
init_run "$TMP/run2" dev
echo " " >> "$TMP/run2/plan.json"
assert_fail "fingerprint-drift" bash "$RUNNER" start --run-dir "$TMP/run2" --case R0-2

# adapter catalog drift and plan/catalog metadata mismatch are both fail-closed.
init_run "$TMP/run2-adapter" dev
echo " " >> "$TMP/run2-adapter/adapter-catalog.tsv"
assert_fail "adapter-catalog-drift" bash "$RUNNER" start --run-dir "$TMP/run2-adapter" --case R0-2

init_run "$TMP/run2-bundle" dev
jq '.bindings.adapter_bundle_sha256="0000000000000000000000000000000000000000000000000000000000000000"' \
  "$TMP/run2-bundle/state.json" > "$TMP/run2-bundle/state.tmp"
mv "$TMP/run2-bundle/state.tmp" "$TMP/run2-bundle/state.json"
assert_fail "adapter-bundle-binding-drift" bash "$RUNNER" start --run-dir "$TMP/run2-bundle" --case R0-2

jq '(.cases[] | select(.id=="R0-4") | .executor)="manual"' "$TMP/plan.json" > "$TMP/plan-mismatch.json"
assert_fail "plan-catalog-metadata-mismatch" bash "$RUNNER" init --run-dir "$TMP/run-mismatch" \
  --plan "$TMP/plan-mismatch.json" --revision "$REV" --digest "$DIGEST" \
  --fixture-manifest "$TMP/fixture.json" --config-fingerprint "$CFG" --mode dev \
  --matrix-catalog "$TMP/catalog.tsv" --adapter-catalog "$TMP/adapters.tsv"

# missing case
init_run "$TMP/run3" dev
assert_fail "missing-case" bash "$RUNNER" start --run-dir "$TMP/run3" --case R9-NOPE

# R0 cannot skip
init_run "$TMP/run4" dev
bash "$RUNNER" start --run-dir "$TMP/run4" --case R0-1 >/dev/null
assert_fail "r0-skip" bash "$RUNNER" finish --run-dir "$TMP/run4" --case R0-1 --status skipped_not_triggered

# seal requires release mode
init_run "$TMP/run5" dev
pass_all_r0 "$TMP/run5"
bash "$RUNNER" start --run-dir "$TMP/run5" --case R1-X1 >/dev/null
bash "$RUNNER" finish --run-dir "$TMP/run5" --case R1-X1 --status passed >/dev/null
assert_fail "seal-dev-mode" bash "$RUNNER" seal --run-dir "$TMP/run5"

# seal release happy + evidence
init_run "$TMP/run6" release
pass_all_r0 "$TMP/run6"
bash "$RUNNER" start --run-dir "$TMP/run6" --case R1-X1 >/dev/null
bash "$RUNNER" finish --run-dir "$TMP/run6" --case R1-X1 --status skipped_not_triggered \
  --note "suite not selected by final diff" >/dev/null
assert_ok "seal-release" bash "$RUNNER" seal --run-dir "$TMP/run6"
assert_ok "verify-sealed-release" bash "$RUNNER" verify --run-dir "$TMP/run6" --revision "$REV" --digest "$DIGEST" --config-fingerprint "$CFG"
assert_ok "verify-release-evidence-consumer" bash "$EVIDENCE_VERIFIER" \
  --evidence "$TMP/run6/release-evidence.json" --expected-revision "$REV" --expected-digest "$DIGEST"
assert_ok "canonical-evidence-paths" jq -e \
  '[.cases[].attempts[] | select(.evidence != null) | .evidence.path | endswith("/evidence.json")] | all' \
  "$TMP/run6/release-evidence.json"
assert_ok "canonical-log-window-path" jq -e \
  '.cases[] | select(.id=="R0-7") | .attempts[] | select(.status=="passed") | .log_window.path | endswith("/log-window.raw")' \
  "$TMP/run6/release-evidence.json"
assert_fail "sealed-release-wrong-revision" bash "$RUNNER" verify --run-dir "$TMP/run6" \
  --revision "$(printf 'd%.0s' {1..40})" --digest "$DIGEST" --config-fingerprint "$CFG"
[[ -f "$TMP/run6/release-evidence.json" ]]
[[ -f "$TMP/run6/release-evidence.json.sha256" ]]
sum_line="$(awk '{print $1}' "$TMP/run6/release-evidence.json.sha256")"
cur="$(sha256sum "$TMP/run6/release-evidence.json" | awk '{print $1}')"
[[ "$sum_line" == "$cur" ]]

cp -a "$TMP/run6" "$TMP/run6-tampered"
printf ' ' >> "$TMP/run6-tampered/release-evidence.json"
assert_fail "tampered-release-evidence" bash "$RUNNER" verify --run-dir "$TMP/run6-tampered"

# seal refuses R0 skip already covered; seal refuses incomplete
init_run "$TMP/run7" release
assert_fail "seal-incomplete" bash "$RUNNER" seal --run-dir "$TMP/run7"

# tampered evidence
init_run "$TMP/run8" dev
bash "$RUNNER" start --run-dir "$TMP/run8" --case R0-1 >/dev/null
printf 'good\n' > "$TMP/ev2.txt"
bash "$RUNNER" finish --run-dir "$TMP/run8" --case R0-1 --status passed --evidence "$TMP/ev2.txt" >/dev/null
printf 'tamper\n' > "$TMP/run8/cases/R0-1/attempt-001/evidence.json"
assert_fail "tampered-evidence" bash "$RUNNER" verify --run-dir "$TMP/run8"

# invalidate
init_run "$TMP/run9" dev
assert_ok "invalidate" bash "$RUNNER" invalidate --run-dir "$TMP/run9" --reason "fingerprint-change"
assert_fail "post-invalidate-start" bash "$RUNNER" start --run-dir "$TMP/run9" --case R0-1

# new attempt after failed
init_run "$TMP/run10" dev
bash "$RUNNER" start --run-dir "$TMP/run10" --case R0-4 >/dev/null
bash "$RUNNER" finish --run-dir "$TMP/run10" --case R0-4 --status failed >/dev/null
assert_fail "new-attempt-requires-flag" bash "$RUNNER" start --run-dir "$TMP/run10" --case R0-4 --attempt 2
assert_ok "new-attempt-after-fail" bash "$RUNNER" start --run-dir "$TMP/run10" --case R0-4 --attempt 2 --new-attempt
bash "$RUNNER" finish --run-dir "$TMP/run10" --case R0-4 --attempt 2 --status passed >/dev/null

# running start resumes the same attempt; release pass requires evidence and log evidence.
init_run "$TMP/run11" dev
bash "$RUNNER" start --run-dir "$TMP/run11" --case R0-4 >/dev/null
assert_ok "resume-running-attempt" bash "$RUNNER" start --run-dir "$TMP/run11" --case R0-4
[[ "$(find "$TMP/run11/cases/R0-4" -maxdepth 1 -type d -name 'attempt-*' | wc -l | tr -d ' ')" == "1" ]]

init_run "$TMP/run12" release
bash "$RUNNER" start --run-dir "$TMP/run12" --case R0-1 >/dev/null
assert_fail "release-pass-requires-evidence" bash "$RUNNER" finish --run-dir "$TMP/run12" --case R0-1 --status passed

init_run "$TMP/run13" release
printf 'log evidence\n' > "$TMP/run13-evidence.txt"
bash "$RUNNER" start --run-dir "$TMP/run13" --case R0-7 >/dev/null
assert_fail "release-log-gate-requires-window" bash "$RUNNER" finish --run-dir "$TMP/run13" --case R0-7 \
  --status passed --evidence "$TMP/run13-evidence.txt"

cp -a "$TMP/run6" "$TMP/run6-log-tampered"
printf 'tampered\n' >> "$TMP/run6-log-tampered/cases/R0-7/attempt-001/log-window.raw"
assert_fail "tampered-log-window" bash "$RUNNER" verify --run-dir "$TMP/run6-log-tampered" \
  --revision "$REV" --digest "$DIGEST" --config-fingerprint "$CFG"

init_run "$TMP/run14" release
printf '' > "$TMP/empty-evidence.txt"
bash "$RUNNER" start --run-dir "$TMP/run14" --case R0-2 >/dev/null
assert_fail "release-rejects-empty-evidence" bash "$RUNNER" finish --run-dir "$TMP/run14" --case R0-2 \
  --status passed --evidence "$TMP/empty-evidence.txt"

init_run "$TMP/run15" release
pass_all_r0 "$TMP/run15"
bash "$RUNNER" start --run-dir "$TMP/run15" --case R1-X1 >/dev/null
bash "$RUNNER" finish --run-dir "$TMP/run15" --case R1-X1 --status skipped_not_triggered \
  --note "suite not selected" >/dev/null
printf 'tampered\n' >> "$TMP/run15/cases/R0-2/attempt-001/evidence.json"
assert_fail "seal-rehashes-evidence" bash "$RUNNER" seal --run-dir "$TMP/run15"

# Reconcile start/finish tears without duplicating attempts or result rows.
init_run "$TMP/run16" dev
mkdir -p "$TMP/run16/cases/R0-4/attempt-001"
jq -n --arg revision "$REV" --arg digest "$DIGEST" \
  '{case_id:"R0-4",attempt:1,status:"running",started_at:"2026-07-23T00:00:00Z",ended_at:null,
    revision:$revision,digest:$digest,evidence:null,log_window:null,note:null}' \
  > "$TMP/run16/cases/R0-4/attempt-001/meta.json"
assert_ok "reconcile-torn-start" bash "$RUNNER" start --run-dir "$TMP/run16" --case R0-4
jq -e '.cases[] | select(.id=="R0-4") | .status=="running" and .current_attempt==1' \
  "$TMP/run16/state.json" >/dev/null

init_run "$TMP/run17" dev
bash "$RUNNER" start --run-dir "$TMP/run17" --case R0-4 >/dev/null
jq '.status="failed" | .ended_at="2026-07-23T00:00:01Z" | .note="interrupted after meta write"' \
  "$TMP/run17/cases/R0-4/attempt-001/meta.json" > "$TMP/run17/meta.tmp"
mv "$TMP/run17/meta.tmp" "$TMP/run17/cases/R0-4/attempt-001/meta.json"
assert_ok "reconcile-torn-finish" bash "$RUNNER" finish --run-dir "$TMP/run17" --case R0-4 --status failed
jq -e '.cases[] | select(.id=="R0-4") | .status=="failed" and (.attempts|length)==1' \
  "$TMP/run17/state.json" >/dev/null
[[ "$(awk 'END {print NR}' "$TMP/run17/results.tsv")" == "2" ]]

# Release evidence/log inputs must be regular, non-symlinked, and non-empty.
init_run "$TMP/run18" release
bash "$RUNNER" start --run-dir "$TMP/run18" --case R0-2 >/dev/null
write_debug_case_evidence "$TMP/run18-real-evidence.json" R0-2 debug-startup
ln -s "$TMP/run18-real-evidence.json" "$TMP/run18-evidence-link.json"
assert_fail "release-rejects-symlink-evidence" bash "$RUNNER" finish --run-dir "$TMP/run18" \
  --case R0-2 --status passed --evidence "$TMP/run18-evidence-link.json"

init_run "$TMP/run19" release
bash "$RUNNER" start --run-dir "$TMP/run19" --case R0-7 >/dev/null
write_debug_case_evidence "$TMP/run19-evidence.json" R0-7 log-gate
: > "$TMP/run19-empty.log"
assert_fail "release-rejects-empty-log-window" bash "$RUNNER" finish --run-dir "$TMP/run19" \
  --case R0-7 --status passed --evidence "$TMP/run19-evidence.json" --log-window "$TMP/run19-empty.log"

init_run "$TMP/run20" release
bash "$RUNNER" start --run-dir "$TMP/run20" --case R0-2 >/dev/null
write_debug_case_evidence "$TMP/run20-wrong-adapter.json" R0-2 log-gate
plant_adapter_checkpoint "$TMP/run20" R0-2 1 debug-startup debug-case-evidence "$TMP/run20-wrong-adapter.json"
assert_fail "release-rejects-wrong-adapter-evidence" bash "$RUNNER" finish --run-dir "$TMP/run20" \
  --case R0-2 --status passed --evidence "$TMP/run20-wrong-adapter.json"

# H1: release automatic passed cannot be handwritten without adapter-state checkpoint.
init_run "$TMP/run-h1" release
bash "$RUNNER" start --run-dir "$TMP/run-h1" --case R0-2 >/dev/null
write_debug_case_evidence "$TMP/run-h1-ev.json" R0-2 debug-startup
assert_fail "h1-release-auto-pass-requires-adapter-checkpoint" bash "$RUNNER" finish --run-dir "$TMP/run-h1" \
  --case R0-2 --status passed --evidence "$TMP/run-h1-ev.json"

# H1 legitimate: matching adapter-state evidence/log sha allows automatic release pass.
init_run "$TMP/run-h1-ok" release
bash "$RUNNER" start --run-dir "$TMP/run-h1-ok" --case R0-2 >/dev/null
write_debug_case_evidence "$TMP/run-h1-ok-ev.json" R0-2 debug-startup
plant_adapter_checkpoint "$TMP/run-h1-ok" R0-2 1 debug-startup debug-case-evidence "$TMP/run-h1-ok-ev.json"
assert_ok "h1-release-auto-pass-with-checkpoint" bash "$RUNNER" finish --run-dir "$TMP/run-h1-ok" \
  --case R0-2 --status passed --evidence "$TMP/run-h1-ok-ev.json"

# H2: release manual opaque text is rejected.
init_run "$TMP/run-h2" release
bash "$RUNNER" start --run-dir "$TMP/run-h2" --case R0-6 >/dev/null
printf 'opaque garbage pass\n' > "$TMP/run-h2-opaque.txt"
assert_fail "h2-release-rejects-opaque-manual-text" bash "$RUNNER" finish --run-dir "$TMP/run-h2" \
  --case R0-6 --status passed --evidence "$TMP/run-h2-opaque.txt"

# H2 legitimate structured manual-verification.
init_run "$TMP/run-h2-ok" release
bash "$RUNNER" start --run-dir "$TMP/run-h2-ok" --case R0-6 >/dev/null
write_manual_verification_evidence "$TMP/run-h2-ok.json" R0-6 1
assert_ok "h2-release-accepts-manual-verification" bash "$RUNNER" finish --run-dir "$TMP/run-h2-ok" \
  --case R0-6 --status passed --evidence "$TMP/run-h2-ok.json"

# R0-7 fatal log re-scan must fail even with passed evidence + checkpoint.
init_run "$TMP/run-r07-fatal" release
bash "$RUNNER" start --run-dir "$TMP/run-r07-fatal" --case R0-7 >/dev/null
write_debug_case_evidence "$TMP/run-r07-ev.json" R0-7 log-gate
printf 'panic: runtime error\nfatal migration failed\nresponse.failed\n' > "$TMP/run-r07-bad.log"
plant_adapter_checkpoint "$TMP/run-r07-fatal" R0-7 1 log-gate debug-case-evidence "$TMP/run-r07-ev.json" "$TMP/run-r07-bad.log"
assert_fail "r07-finish-rescans-fatal-log" bash "$RUNNER" finish --run-dir "$TMP/run-r07-fatal" \
  --case R0-7 --status passed --evidence "$TMP/run-r07-ev.json" --log-window "$TMP/run-r07-bad.log"

# Seal/verify binds R0-1 workflow_run_id as source_run_id.
init_run "$TMP/run-src" release
pass_all_r0 "$TMP/run-src"
bash "$RUNNER" start --run-dir "$TMP/run-src" --case R1-X1 >/dev/null
bash "$RUNNER" finish --run-dir "$TMP/run-src" --case R1-X1 --status skipped_not_triggered \
  --note "suite not selected by final diff" >/dev/null
assert_ok "seal-binds-source-run-id" bash "$RUNNER" seal --run-dir "$TMP/run-src"
jq -e '.bindings.source_run_id=="1001"' "$TMP/run-src/release-evidence.json" >/dev/null
out="$(bash "$EVIDENCE_VERIFIER" --evidence "$TMP/run-src/release-evidence.json" --expected-revision "$REV" --expected-digest "$DIGEST")"
printf '%s\n' "$out" | jq -e '.status=="verified" and .source_run_id=="1001"' >/dev/null


summary
