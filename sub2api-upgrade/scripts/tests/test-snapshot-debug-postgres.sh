#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$TESTS_DIR/common.sh"
SNAP="$SCRIPTS_DIR/snapshot-debug-postgres.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# isolation stub
cat > "$TMP/isolation-ok.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
SH
chmod 0755 "$TMP/isolation-ok.sh"

cat > "$TMP/isolation-fail.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
echo isolation failed >&2
exit 1
SH
chmod 0755 "$TMP/isolation-fail.sh"

# layout
mkdir -p "$TMP/debug-deploy" "$TMP/prod-deploy" "$TMP/targets"
touch "$TMP/debug-deploy/docker-compose.yml"

# docker stub that records invocations
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
LOG="${DOCKER_STUB_LOG:-/tmp/docker-stub.log}"
printf '%s\n' "$*" >> "$LOG"
args=" $* "
if [[ "$args" == *' compose '* && "$args" == *' ps '* ]]; then
  echo cid-postgres
  exit 0
fi
if [[ "${1:-}" == "inspect" ]]; then
  if [[ "$args" == *'Running'* ]]; then
    echo true
  else
    echo healthy
  fi
  exit 0
fi
if [[ "$args" == *'pg_dump'* || "$args" == *' exec '* ]]; then
  if [[ "${DOCKER_STUB_FAIL_DUMP:-0}" == "1" ]]; then
    exit 1
  fi
  python3 -c 'import sys; sys.stdout.buffer.write(b"P" * 2048)'
  exit 0
fi
exit 0
SH

chmod 0755 "$TMP/bin/docker"

export PATH="$TMP/bin:$PATH"
export DOCKER_STUB_LOG="$TMP/docker.log"
export SUB2API_UPGRADE_TEST_MODE=1
: > "$DOCKER_STUB_LOG"

assert_fail "test-mode-requires-env-gate" env -u SUB2API_UPGRADE_TEST_MODE bash "$SNAP" --test-mode \
  --debug-dir "$TMP/debug-deploy" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-ok.sh" \
  --target-dir "$TMP/targets/gate"

assert_fail "non-test-rejects-outside-snapshot-root" bash "$SNAP" \
  --target-dir "$TMP/targets/outside"

# dry-run must not write dump and may call isolation only
assert_ok "dry-run" bash "$SNAP" --test-mode \
  --debug-dir "$TMP/debug-deploy" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-ok.sh" \
  --target-dir "$TMP/targets/snap1"
[[ ! -e "$TMP/targets/snap1" ]]
# dry-run should not invoke docker dump
if grep -q pg_dump "$DOCKER_STUB_LOG"; then echo "FAIL dry-run-called-pg_dump"; FAIL=$((FAIL+1)); else echo "PASS dry-run-no-pg_dump"; PASS=$((PASS+1)); fi

# apply success
: > "$DOCKER_STUB_LOG"
assert_ok "apply-ok" bash "$SNAP" --test-mode --apply \
  --debug-dir "$TMP/debug-deploy" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-ok.sh" \
  --target-dir "$TMP/targets/snap2"
[[ -f "$TMP/targets/snap2/postgres.dump" ]]
[[ -f "$TMP/targets/snap2/.owner" ]]
[[ ! -f "$TMP/targets/snap2/postgres.dump.partial" ]]

# dump failure keeps safe state (no final dump, no partial)
export DOCKER_STUB_FAIL_DUMP=1
: > "$DOCKER_STUB_LOG"
assert_fail "apply-dump-fail" bash "$SNAP" --test-mode --apply \
  --debug-dir "$TMP/debug-deploy" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-ok.sh" \
  --target-dir "$TMP/targets/snap3"
[[ -d "$TMP/targets/snap3" ]]
[[ ! -f "$TMP/targets/snap3/postgres.dump" ]]
[[ ! -f "$TMP/targets/snap3/postgres.dump.partial" ]]
unset DOCKER_STUB_FAIL_DUMP

# reject prod string in test-mode paths
assert_fail "reject-prod-string" bash "$SNAP" --test-mode --apply \
  --debug-dir "$TMP/debug-prod-like" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-ok.sh" \
  --target-dir "$TMP/targets/snap4"

# isolation fail
assert_fail "isolation-fail" bash "$SNAP" --test-mode --apply \
  --debug-dir "$TMP/debug-deploy" --prod-dir "$TMP/prod-deploy" \
  --isolation-script "$TMP/isolation-fail.sh" \
  --target-dir "$TMP/targets/snap5"

summary
