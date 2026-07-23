#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"
PLAN="$SCRIPTS_DIR/plan-sub2api-upgrade.sh"

TMP="$(mktemp -d /tmp/plan-sub2api-upgrade-test.XXXXXX)"
NON_TMP_ROOT=""
cleanup() {
  rm -rf -- "$TMP"
  [[ -z "${NON_TMP_ROOT:-}" ]] || rm -rf -- "$NON_TMP_ROOT"
}
trap cleanup EXIT

REPO="$TMP/repo"
EVIDENCE_ROOT="$TMP/evidence-root"
mkdir -p "$REPO" "$EVIDENCE_ROOT"

git -C "$REPO" init -q
git -C "$REPO" config user.email "plan-test@example.com"
git -C "$REPO" config user.name "plan-test"
git -C "$REPO" checkout -q -b main

commit_tree() {
  local message="$1"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$message"
  git -C "$REPO" rev-parse HEAD
}

mkdir -p "$REPO/backend/cmd/server" "$REPO/backend/pkg"
printf '0.1.160\n' > "$REPO/backend/cmd/server/VERSION"
printf 'core-v160\n' > "$REPO/backend/pkg/core.go"
U160="$(commit_tree "upstream-0.1.160")"

printf '0.1.162\n' > "$REPO/backend/cmd/server/VERSION"
printf 'core-v162\n' > "$REPO/backend/pkg/core.go"
U162="$(commit_tree "upstream-0.1.162")"
git -C "$REPO" update-ref refs/remotes/upstream/main "$U162"

printf 'mine-running\n' > "$REPO/backend/pkg/mine_feature.go"
RUNNING="$(commit_tree "running-0.1.162-mine")"

printf 'mine-candidate\n' > "$REPO/backend/pkg/mine_feature2.go"
printf 'stream handler\n' > "$REPO/backend/pkg/stream_handler.go"
CAND_GOOD="$(commit_tree "candidate-0.1.162-mine")"

git -C "$REPO" checkout -q -b cand-old "$U160"
printf 'old-mine\n' > "$REPO/backend/pkg/old_mine.go"
CAND_OLD="$(commit_tree "candidate-old-baseline-0.1.160")"

git -C "$REPO" checkout -q -b cand-badver "$U162"
printf '0.1.160\n' > "$REPO/backend/cmd/server/VERSION"
printf 'feature\n' > "$REPO/backend/pkg/feature.go"
CAND_BADVER="$(commit_tree "candidate-version-0.1.160")"

git -C "$REPO" checkout -q main >/dev/null

plan_cmd() {
  # args after env vars already applied by caller
  bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main "$@"
}

OUT_GOOD="$EVIDENCE_ROOT/run-good"
if SUB2API_UPGRADE_TEST_MODE=1 plan_cmd \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --evidence-root "$EVIDENCE_ROOT" \
    --output-dir "$OUT_GOOD" \
    --json >/dev/null; then
  echo "PASS plan-0.1.162-positive"
  PASS=$((PASS + 1))
else
  echo "FAIL plan-0.1.162-positive"
  FAIL=$((FAIL + 1))
fi

if [[ -f "$OUT_GOOD/plan.json" && -f "$OUT_GOOD/.owner" && -f "$OUT_GOOD/manifest.env" ]] \
  && [[ "$(cat "$OUT_GOOD/.owner")" == "sub2api-upgrade-evidence-v1" ]] \
  && grep -q "status=planned" "$OUT_GOOD/manifest.env" \
  && jq -e '.baseline_gate == "passed" and .running.version == "0.1.162" and .candidate.version == "0.1.162"' \
       "$OUT_GOOD/plan.json" >/dev/null; then
  echo "PASS plan-0.1.162-positive-artifacts"
  PASS=$((PASS + 1))
else
  echo "FAIL plan-0.1.162-positive-artifacts"
  FAIL=$((FAIL + 1))
fi

assert_fail "plan-old-baseline-rejected" \
  env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_OLD"

assert_fail "plan-version-regression-rejected" \
  env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_BADVER"

assert_fail "output-rejects-arbitrary-path" \
  bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --output-dir "$TMP/outside-root"

mkdir -p "$EVIDENCE_ROOT/nested-parent"
assert_fail "output-rejects-nested-not-direct-child" \
  env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --evidence-root "$EVIDENCE_ROOT" \
    --output-dir "$EVIDENCE_ROOT/nested-parent/child"

assert_fail "output-rejects-existing-dir" \
  env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --evidence-root "$EVIDENCE_ROOT" \
    --output-dir "$OUT_GOOD"

assert_fail "evidence-root-requires-test-mode" \
  env -u SUB2API_UPGRADE_TEST_MODE bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --evidence-root "$EVIDENCE_ROOT" \
    --output-dir "$EVIDENCE_ROOT/should-not-create"

if NON_TMP_ROOT="$(mktemp -d /var/tmp/plan-evidence-root.XXXXXX 2>/dev/null)"; then
  if [[ "$(realpath -e "$NON_TMP_ROOT")" == /tmp/* ]]; then
    rm -rf -- "$NON_TMP_ROOT"
    NON_TMP_ROOT=""
    echo "SKIP evidence-root-must-be-under-tmp (non-tmp root unavailable)"
  else
    assert_fail "evidence-root-must-be-under-tmp" \
      env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
        --running-revision "$RUNNING" \
        --candidate-revision "$CAND_GOOD" \
        --evidence-root "$NON_TMP_ROOT" \
        --output-dir "$NON_TMP_ROOT/run1"
  fi
else
  echo "SKIP evidence-root-must-be-under-tmp (mktemp /var/tmp failed)"
fi

LINK_ROOT="$TMP/evidence-link"
ln -s "$EVIDENCE_ROOT" "$LINK_ROOT"
assert_fail "evidence-root-rejects-symlink" \
  env SUB2API_UPGRADE_TEST_MODE=1 bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --evidence-root "$LINK_ROOT" \
    --output-dir "$LINK_ROOT/run-link"

assert_fail "output-rejects-prod-deploy-path" \
  bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$RUNNING" \
    --candidate-revision "$CAND_GOOD" \
    --output-dir "/root/sub2api-prod-deploy/evil-evidence"

summary
