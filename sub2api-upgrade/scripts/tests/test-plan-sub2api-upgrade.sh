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

assert_plan_jq() {
  local name="$1" running="$2" candidate="$3" filter="$4"
  shift 4
  local output
  if output="$(plan_cmd --running-revision "$running" --candidate-revision "$candidate" --json "$@")" \
      && jq -e "$filter" <<<"$output" >/dev/null; then
    echo "PASS $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    [[ -z "${output:-}" ]] || jq '{selected_suites, cases: [.cases[].id], selection}' <<<"$output" || true
    FAIL=$((FAIL + 1))
  fi
}

selection_candidate() {
  local branch="$1" path="$2" content="$3"
  git -C "$REPO" checkout -q -B "$branch" "$U162"
  mkdir -p "$(dirname -- "$REPO/$path")"
  printf '%s\n' "$content" > "$REPO/$path"
  commit_tree "$branch"
}

CAND_NEUTRAL="$(selection_candidate selection-neutral backend/pkg/neutral_feature.go neutral)"
assert_plan_jq "plan-r0-only-default" "$U162" "$CAND_NEUTRAL" '
  .selected_suites == ["core"]
  and ([.cases[].id] == ["R0-1","R0-2","R0-3","R0-4","R0-5","R0-6","R0-7","R0-8"])
  and .selection.policy.default == "r0_only"
  and .selection.counts.selected_cases == 8
  and .selection.active_inventory.present == false'

CAND_ASSET="$(selection_candidate selection-assets assets/partners/logos/nagora.png asset)"
assert_plan_jq "plan-false-positive-assets-sse" "$U162" "$CAND_ASSET" '
  .selected_suites == ["core"]
  and ([.selection.triggers[].suite] | index("streaming") == null)'

CAND_UPSTREAM_NAME="$(selection_candidate selection-upstream-name backend/internal/service/upstream_models.go neutral)"
assert_plan_jq "plan-false-positive-upstream-substring" "$U162" "$CAND_UPSTREAM_NAME" '
  .selected_suites == ["core"]
  and ([.selection.triggers[].suite] | index("streaming") == null)
  and ([.selection.triggers[].suite] | index("model_switch") == null)'

CAND_PROVENANCE="$(selection_candidate selection-provenance .github/workflows/promote-debug-image.yml workflow)"
assert_plan_jq "plan-image-provenance-is-deployment-only" "$U162" "$CAND_PROVENANCE" '
  (.selected_suites | index("deployment") != null)
  and (.selected_suites | index("vision_media") == null)
  and ([.cases[].id] | index("R2-2") != null)
  and ([.cases[].id] | map(select(startswith("R1-B"))) | length == 0)'

CAND_STREAM="$(selection_candidate selection-stream backend/pkg/stream_handler.go stream)"
assert_plan_jq "plan-true-positive-streaming-boundary" "$U162" "$CAND_STREAM" '
  (.selected_suites | index("streaming") != null)
  and ([.cases[].id] | index("R1-E1") != null)
  and ([.cases[].id] | index("R1-E2") != null)
  and ([.cases[].id] | index("R1-E3") != null)'

CAND_TEST_ONLY="$(selection_candidate selection-test-only backend/internal/service/openai_oauth_passthrough_test.go test)"
assert_plan_jq "plan-test-only-does-not-select-runtime" "$U162" "$CAND_TEST_ONLY" '
  .selected_suites == ["core"]
  and ([.selection.triggers[].suite] | index("auth") == null)'

CAND_IMAGE="$(selection_candidate selection-image backend/internal/handler/image_generation.go image)"
assert_plan_jq "plan-live-image-cases-require-inventory" "$U162" "$CAND_IMAGE" '
  ([.cases[].id] | index("R1-B1") != null)
  and ([.cases[].id] | index("R1-B2") == null)
  and ([.cases[].id] | index("R1-B4") == null)'

INVENTORY_IMAGE="$TMP/active-image.json"
printf '%s\n' '{"schema_version":1,"environment":"production","observed_at":"2026-07-24T00:00:00Z","source":"read-only aggregate","providers":["openai"],"features":["vision","image_generation"],"notes":[]}' > "$INVENTORY_IMAGE"
assert_plan_jq "plan-live-image-generation-with-inventory" "$U162" "$CAND_IMAGE" '
  ([.cases[].id] | index("R1-B4") != null)
  and .selection.active_inventory.present == true' \
  --active-inventory "$INVENTORY_IMAGE"

CAND_GEMINI="$(selection_candidate selection-gemini backend/internal/handler/gemini_v1beta_handler.go gemini)"
INVENTORY_NO_GEMINI="$TMP/active-no-gemini.json"
printf '%s\n' '{"schema_version":1,"environment":"production","observed_at":"2026-07-24T00:00:00Z","source":"read-only aggregate","providers":["openai","grok"],"features":[],"notes":[]}' > "$INVENTORY_NO_GEMINI"
assert_plan_jq "plan-provider-case-inactive" "$U162" "$CAND_GEMINI" '
  (.selection.triggered_suites | index("provider_extended") != null)
  and ([.cases[].id] | index("R2-3") == null)' \
  --active-inventory "$INVENTORY_NO_GEMINI"

INVENTORY_GEMINI="$TMP/active-gemini.json"
printf '%s\n' '{"schema_version":1,"environment":"production","observed_at":"2026-07-24T00:00:00Z","source":"read-only aggregate","providers":["gemini"],"features":[],"notes":[]}' > "$INVENTORY_GEMINI"
assert_plan_jq "plan-provider-case-active" "$U162" "$CAND_GEMINI" '
  (.selected_suites | index("provider_extended") != null)
  and ([.cases[].id] | index("R2-3") != null)' \
  --active-inventory "$INVENTORY_GEMINI"

assert_plan_jq "plan-permanent-canaries-explicit-only" "$U162" "$CAND_NEUTRAL" '
  (.selected_suites | index("long_context") != null)
  and (.selected_suites | index("vision_media") != null)
  and (.selected_suites | index("model_switch") != null)
  and .selection.policy.permanent_canaries == true' \
  --permanent-canaries

INVALID_INVENTORY="$TMP/invalid-inventory.json"
printf '%s\n' '{"schema_version":1,"environment":"production","observed_at":"2026-07-24T00:00:00Z","source":"read-only aggregate","providers":[],"features":[],"api_key":"must-not-appear"}' > "$INVALID_INVENTORY"
assert_fail "plan-inventory-rejects-unsupported-sensitive-fields" \
  bash "$PLAN" --repo "$REPO" --upstream-ref upstream/main \
    --running-revision "$U162" --candidate-revision "$CAND_NEUTRAL" \
    --active-inventory "$INVALID_INVENTORY" --json

git -C "$REPO" checkout -q -B upstream-0.1.163 "$U162"
printf '0.1.163\n' > "$REPO/backend/cmd/server/VERSION"
mkdir -p "$REPO/backend/migrations"
printf 'select 1;\n' > "$REPO/backend/migrations/185_selection_source_test.sql"
U163="$(commit_tree upstream-0.1.163)"
git -C "$REPO" update-ref refs/remotes/upstream/main "$U163"

git -C "$REPO" checkout -q -B running-source-split "$U162"
printf 'old customization\n' > "$REPO/backend/pkg/running_customization.go"
RUNNING_SPLIT="$(commit_tree running-source-split)"

git -C "$REPO" checkout -q -B candidate-source-split "$U163"
mkdir -p "$REPO/backend/internal/service"
printf 'pool implementation\n' > "$REPO/backend/internal/service/openai_pool_selection.go"
CAND_SPLIT="$(commit_tree candidate-source-split)"
assert_plan_jq "plan-upstream-and-customization-sources-are-separated" "$RUNNING_SPLIT" "$CAND_SPLIT" '
  (.upstream_files | index("backend/migrations/185_selection_source_test.sql") != null)
  and (.running_customization_files | index("backend/pkg/running_customization.go") != null)
  and (.customization_files | index("backend/internal/service/openai_pool_selection.go") != null)
  and (.selection.suite_sources.migration | index("upstream") != null)
  and (.selection.suite_sources.scheduling | index("customization") != null)
  and ([.cases[].id] | index("R1-M1") != null)
  and ([.cases[].id] | index("R1-H2") != null)'

git -C "$REPO" update-ref refs/remotes/upstream/main "$U162"

git -C "$REPO" checkout -q main

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
