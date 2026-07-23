#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(cd -- "$TESTS_DIR/.." && pwd -P)"
RUNNER="$SCRIPTS_DIR/run-debug-adapter.sh"
MATRIX="$SCRIPTS_DIR/run-debug-matrix.sh"
source "$TESTS_DIR/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
export SUB2API_UPGRADE_TEST_MODE=1

assert_exit() {
  local name="$1" expect="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$expect" ]]; then
    echo "PASS $name (exit=$rc)"; PASS=$((PASS+1))
  else
    echo "FAIL $name (exit=$rc expected $expect)"; FAIL=$((FAIL+1))
  fi
}

make_valid_fixture "$TMP/fixture.json"
make_mini_catalog "$TMP/catalog.tsv"
make_mini_adapter_catalog "$TMP/adapters.tsv"
make_plan "$TMP/plan.json"

make_run() {
  local dir="$1" mode="${2:-dev}"
  bash "$MATRIX" init --run-dir "$dir" --plan "$TMP/plan.json" --revision "$REV" --digest "$DIGEST" \
    --fixture-manifest "$TMP/fixture.json" --config-fingerprint "$CFG" --mode "$mode" \
    --matrix-catalog "$TMP/catalog.tsv" --adapter-catalog "$TMP/adapters.tsv" >/dev/null
}

matrix_case_status() {
  local dir="$1" case_id="$2"
  jq -r --arg id "$case_id" '.cases[] | select(.id==$id) | .status' "$dir/state.json"
}

STUBS="$TMP/stubs"
mkdir -p "$STUBS" "$TMP/compose"
printf 'name: sub2api-debug\n' > "$TMP/compose/docker-compose.yml"

cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${SUB2API_DEBUG_ADAPTER_TEST_DOCKER_ARGV_FILE:-}" && "${1:-}" == "compose" && " $* " == *" logs "* ]]; then
  : > "$SUB2API_DEBUG_ADAPTER_TEST_DOCKER_ARGV_FILE"
  for a in "$@"; do printf '%s\n' "$a" >> "$SUB2API_DEBUG_ADAPTER_TEST_DOCKER_ARGV_FILE"; done
fi
if [[ "${1:-}" == "compose" ]]; then
  if [[ " $* " == *" logs "* ]]; then
    if [[ "${SUB2API_DEBUG_ADAPTER_TEST_LOG_FAIL:-0}" == "1" ]]; then echo fail >&2; exit 1; fi
    printf '%s\n' "${SUB2API_DEBUG_ADAPTER_TEST_LOG_CONTENT:-info healthy line}"
    exit 0
  fi
  if [[ " $* " == *" ps "* ]]; then printf 'cid123\n'; exit 0; fi
  if [[ " $* " == *" config --format json "* ]]; then
    printf '{"services":{"sub2api":{"ports":[{"host_ip":"127.0.0.1","published":13180}]}}}\n'
    exit 0
  fi
  exit 0
fi
if [[ "${1:-}" == "inspect" ]]; then
  fmt="${3:-}"
  case "$fmt" in
    *Health*) printf 'healthy\n' ;;
    *Status*) printf 'running\n' ;;
    *'{{.Image}}'*) printf 'sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' ;;
    *'{{.Config.Image}}'*) printf 'ghcr.io/wesperez/sub2api:debug\n' ;;
    *revision*) printf '%s\n' "${SUB2API_DEBUG_ADAPTER_TEST_REV:-}" ;;
    *ref.name*) printf 'debug\n' ;;
    *) printf '\n' ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "image" ]]; then
  fmt="${4:-}"
  case "$fmt" in
    *RepoDigests*) printf '["ghcr.io/wesperez/sub2api@%s"]\n' "${SUB2API_DEBUG_ADAPTER_TEST_DIGEST:-}" ;;
    *revision*) printf '%s\n' "${SUB2API_DEBUG_ADAPTER_TEST_REV:-}" ;;
    *ref.name*) printf 'debug\n' ;;
    *) printf 'sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' ;;
  esac
  exit 0
fi
exit 0
STUB
chmod 0755 "$STUBS/docker"

cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"status":"ok"}\n'
exit 0
STUB
chmod 0755 "$STUBS/curl"

cat > "$STUBS/isolation.sh" <<'STUB'
#!/usr/bin/env bash
jq -n '{isolated:true}'
STUB
chmod 0755 "$STUBS/isolation.sh"

cat > "$STUBS/fingerprint.sh" <<'STUB'
#!/usr/bin/env bash
jq -n --arg fingerprint "${SUB2API_DEBUG_ADAPTER_TEST_FP:-}" '{status:"ok",fingerprint:$fingerprint}'
STUB
chmod 0755 "$STUBS/fingerprint.sh"

cat > "$STUBS/wait-branch.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
rev=""
while (( $# > 0 )); do
  case "$1" in --expected-revision) rev="$2"; shift ;; esac
  shift
done
jq -n --arg rev "$rev" --arg dig "${SUB2API_DEBUG_ADAPTER_TEST_DIGEST:-}" \
  '{workflow:{databaseId:1001,conclusion:"success"},image:{reference:("ghcr.io/wesperez/sub2api:debug-sha-"+$rev),image_id:"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",revision:$rev,ref_name:"debug",digest:$dig,pulled:true}}'
STUB
chmod 0755 "$STUBS/wait-branch.sh"

export SUB2API_DEBUG_ADAPTER_TEST_COMPOSE="$TMP/compose/docker-compose.yml"
export SUB2API_DEBUG_ADAPTER_TEST_DOCKER="$STUBS/docker"
export SUB2API_DEBUG_ADAPTER_TEST_CURL="$STUBS/curl"
export SUB2API_DEBUG_ADAPTER_TEST_WAIT_BRANCH="$STUBS/wait-branch.sh"
export SUB2API_DEBUG_ADAPTER_TEST_ISOLATION="$STUBS/isolation.sh"
export SUB2API_DEBUG_ADAPTER_TEST_FINGERPRINT="$STUBS/fingerprint.sh"
export SUB2API_DEBUG_ADAPTER_TEST_FP="$CFG"
export SUB2API_DEBUG_ADAPTER_TEST_REV="$REV"
export SUB2API_DEBUG_ADAPTER_TEST_DIGEST="$DIGEST"

make_run "$TMP/run-success"
assert_exit "success-candidate" 0 bash "$RUNNER" run --run-dir "$TMP/run-success" --case R0-1
[[ "$(matrix_case_status "$TMP/run-success" R0-1)" == "passed" ]]
jq -e --arg rev "$REV" '.kind=="candidate-identity" and .revision==$rev' \
  "$TMP/run-success/cases/R0-1/attempt-001/evidence.json" >/dev/null
assert_ok "status-after-success" bash "$RUNNER" status --run-dir "$TMP/run-success" --case R0-1 >/dev/null

make_run "$TMP/run-startup"
assert_exit "success-startup" 0 bash "$RUNNER" run --run-dir "$TMP/run-startup" --case R0-2
[[ "$(matrix_case_status "$TMP/run-startup" R0-2)" == "passed" ]]

make_run "$TMP/run-release" release
assert_exit "release-evidence-contract" 0 bash "$RUNNER" run --run-dir "$TMP/run-release" --case R0-2
[[ "$(matrix_case_status "$TMP/run-release" R0-2)" == "passed" ]]

make_run "$TMP/run-manual"
assert_exit "manual-78" 78 bash "$RUNNER" run --run-dir "$TMP/run-manual" --case R0-6
[[ "$(matrix_case_status "$TMP/run-manual" R0-6)" == "needs_manual" ]]

make_run "$TMP/run-injection"
assert_exit "missing-case-blocked" 71 bash "$RUNNER" run --run-dir "$TMP/run-injection" --case R9-NOPE
assert_exit "injection-command" 71 bash "$RUNNER" run --run-dir "$TMP/run-injection" --case R0-1 --command id
assert_exit "injection-url" 71 bash "$RUNNER" run --run-dir "$TMP/run-injection" --case R0-1 --url http://invalid
assert_exit "injection-path" 71 bash "$RUNNER" run --run-dir "$TMP/run-injection" --case R0-1 --path /etc/passwd

make_run "$TMP/run-noreplay"
bash "$MATRIX" start --run-dir "$TMP/run-noreplay" --case R1-X1 >/dev/null
attempt_dir="$TMP/run-noreplay/cases/R1-X1/attempt-001"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg rev "$REV" --arg dig "$DIGEST" --arg cfg "$CFG" --arg now "$now" \
  '{schema_version:1,runner:"sub2api-debug-adapter-v1",case_id:"R1-X1",attempt:1,
    adapter_id:"fixed-canary",resume_policy:"no_replay",log_scope:"project",timeout_seconds:30,
    evidence_kind:"debug-case-evidence",phase:"executing",result:null,exit_code:null,
    started_at:$now,updated_at:$now,ended_at:null,log_since:$now,
    bindings:{revision:$rev,digest:$dig,config_fingerprint:$cfg}}' > "$attempt_dir/adapter-state.json"
assert_exit "no-replay-resume-blocked" 71 bash "$RUNNER" resume --run-dir "$TMP/run-noreplay" --case R1-X1
[[ "$(matrix_case_status "$TMP/run-noreplay" R1-X1)" == "blocked" ]]
jq -e '.phase=="finished" and .result=="blocked" and (.note|test("refuse re-dispatch"))' \
  "$attempt_dir/adapter-state.json" >/dev/null
echo "PASS no-replay-no-redispatch"; PASS=$((PASS+1))

make_run "$TMP/run-argv"
export SUB2API_DEBUG_ADAPTER_TEST_DOCKER_ARGV_FILE="$TMP/docker-argv.txt"
assert_exit "log-gate-clean" 0 bash "$RUNNER" run --run-dir "$TMP/run-argv" --case R0-7
mapfile -t argv_lines < "$TMP/run-argv/cases/R0-7/attempt-001/log-collect.argv"
[[ "${argv_lines[1]}" == "compose" && "${argv_lines[2]}" == "--project-directory" ]]
[[ "${argv_lines[4]}" == "-f" && "${argv_lines[5]}" == "$TMP/compose/docker-compose.yml" ]]
[[ "${argv_lines[6]}" == "logs" && "${argv_lines[9]}" == "--since" && "${argv_lines[11]}" == "--until" ]]
status_out="$(bash "$RUNNER" status --run-dir "$TMP/run-argv" --case R0-7)"
[[ "$status_out" != *"info healthy line"* ]]
echo "PASS fixed-docker-argv"; PASS=$((PASS+1))

make_run "$TMP/run-logfail"
export SUB2API_DEBUG_ADAPTER_TEST_LOG_FAIL=1
assert_exit "log-collect-fail-blocked" 71 bash "$RUNNER" run --run-dir "$TMP/run-logfail" --case R0-7
unset SUB2API_DEBUG_ADAPTER_TEST_LOG_FAIL
[[ "$(matrix_case_status "$TMP/run-logfail" R0-7)" == "blocked" ]]

make_run "$TMP/run-logfatal"
export SUB2API_DEBUG_ADAPTER_TEST_LOG_CONTENT="panic: boom response.failed"
assert_exit "log-gate-fatal-70" 70 bash "$RUNNER" run --run-dir "$TMP/run-logfatal" --case R0-7
unset SUB2API_DEBUG_ADAPTER_TEST_LOG_CONTENT
[[ "$(matrix_case_status "$TMP/run-logfatal" R0-7)" == "failed" ]]

make_run "$TMP/run-fixed-missing"
assert_exit "fixed-canary-missing-78" 78 bash "$RUNNER" run --run-dir "$TMP/run-fixed-missing" --case R1-X1
[[ "$(matrix_case_status "$TMP/run-fixed-missing" R1-X1)" == "needs_manual" ]]

attempt_count() {
  local dir="$1" case_id="$2"
  jq -r --arg id "$case_id" '.cases[] | select(.id==$id) | (.current_attempt|tostring)' "$dir/state.json"
}

# run-ready default: serial unfinished cases, R0-7 last, summary needs_manual=78
make_run "$TMP/run-ready-default"
assert_exit "run-ready-default-78" 78 bash "$RUNNER" run-ready --run-dir "$TMP/run-ready-default"
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-1)" == "passed" ]]
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-2)" == "passed" ]]
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-3)" == "needs_manual" ]]
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-6)" == "needs_manual" ]]
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-7)" == "passed" ]]
[[ "$(matrix_case_status "$TMP/run-ready-default" R0-8)" == "needs_manual" ]]
echo "PASS run-ready-reached-r0-7"; PASS=$((PASS+1))

# first-nonpass: stop at first needs_manual (R0-3); R0-7 remains pending
make_run "$TMP/run-ready-first"
assert_exit "run-ready-first-nonpass-78" 78 bash "$RUNNER" run-ready --run-dir "$TMP/run-ready-first" --stop-on first-nonpass
[[ "$(matrix_case_status "$TMP/run-ready-first" R0-1)" == "passed" ]]
[[ "$(matrix_case_status "$TMP/run-ready-first" R0-2)" == "passed" ]]
[[ "$(matrix_case_status "$TMP/run-ready-first" R0-3)" == "needs_manual" ]]
[[ "$(matrix_case_status "$TMP/run-ready-first" R0-4)" == "pending" ]]
[[ "$(matrix_case_status "$TMP/run-ready-first" R0-7)" == "pending" ]]
echo "PASS run-ready-first-nonpass-stops"; PASS=$((PASS+1))

# existing terminal cases are not re-run
make_run "$TMP/run-ready-terminal"
assert_exit "preseed-r0-1" 0 bash "$RUNNER" run --run-dir "$TMP/run-ready-terminal" --case R0-1
before_attempt="$(attempt_count "$TMP/run-ready-terminal" R0-1)"
assert_exit "run-ready-skip-terminal-78" 78 bash "$RUNNER" run-ready --run-dir "$TMP/run-ready-terminal"
after_attempt="$(attempt_count "$TMP/run-ready-terminal" R0-1)"
[[ "$before_attempt" == "1" && "$after_attempt" == "1" ]]
[[ "$(matrix_case_status "$TMP/run-ready-terminal" R0-1)" == "passed" ]]
echo "PASS run-ready-terminal-not-rerun"; PASS=$((PASS+1))

# running no_replay interrupted attempt becomes blocked via resume path
make_run "$TMP/run-ready-noreplay"
bash "$MATRIX" start --run-dir "$TMP/run-ready-noreplay" --case R1-X1 >/dev/null
attempt_dir="$TMP/run-ready-noreplay/cases/R1-X1/attempt-001"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg rev "$REV" --arg dig "$DIGEST" --arg cfg "$CFG" --arg now "$now" \
  '{schema_version:1,runner:"sub2api-debug-adapter-v1",case_id:"R1-X1",attempt:1,
    adapter_id:"fixed-canary",resume_policy:"no_replay",log_scope:"project",timeout_seconds:30,
    evidence_kind:"debug-case-evidence",phase:"executing",result:null,exit_code:null,
    started_at:$now,updated_at:$now,ended_at:null,log_since:$now,
    bindings:{revision:$rev,digest:$dig,config_fingerprint:$cfg}}' > "$attempt_dir/adapter-state.json"
assert_exit "run-ready-running-noreplay-blocked" 71 bash "$RUNNER" run-ready --run-dir "$TMP/run-ready-noreplay"
[[ "$(matrix_case_status "$TMP/run-ready-noreplay" R1-X1)" == "blocked" ]]
echo "PASS run-ready-running-noreplay-blocked"; PASS=$((PASS+1))

# concurrent exclusive batch lock blocks another run-ready / shared run
make_run "$TMP/run-ready-lock"
(
  exec 8>"$TMP/run-ready-lock/.batch.lock"
  flock 8
  sleep 8
) &
lock_pid=$!
sleep 0.2
assert_exit "run-ready-batch-lock-busy" 71 bash "$RUNNER" run-ready --run-dir "$TMP/run-ready-lock"
assert_exit "run-shared-batch-lock-busy" 71 bash "$RUNNER" run --run-dir "$TMP/run-ready-lock" --case R0-1
kill "$lock_pid" 2>/dev/null || true
wait "$lock_pid" 2>/dev/null || true

# concurrent adapter lock blocks single-case run (batch shared free)
make_run "$TMP/run-adapter-lock"
(
  exec 9>"$TMP/run-adapter-lock/.adapter.lock"
  flock 9
  sleep 8
) &
alock_pid=$!
sleep 0.2
assert_exit "run-adapter-lock-busy" 71 bash "$RUNNER" run --run-dir "$TMP/run-adapter-lock" --case R0-1
kill "$alock_pid" 2>/dev/null || true
wait "$alock_pid" 2>/dev/null || true

# all run directories share one fixed debug Compose/fixture, so cross-run work is serialized
make_run "$TMP/run-global-a"
make_run "$TMP/run-global-b"
exec 6>"$TMP/compose/.global-adapter.lock"
flock -x 6
assert_exit "run-global-debug-lock-busy" 71 bash "$RUNNER" run --run-dir "$TMP/run-global-a" --case R0-1
assert_exit "batch-global-debug-lock-busy" 71 bash "$RUNNER" run-ready --run-dir "$TMP/run-global-b"
flock -u 6
exec 6>&-

summary
