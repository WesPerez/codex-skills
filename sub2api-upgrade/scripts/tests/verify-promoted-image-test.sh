#!/usr/bin/env bash
# Unit tests for verify-promoted-image.sh using PATH stubs (no real gh/docker).
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify-promoted-image.sh"
WORKDIR=""
PASS=0
FAIL=0
BASE_ARGS=()

die() { printf '%s\n' "test harness error: $*" >&2; exit 2; }

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
}

setup() {
  [[ -x "$SCRIPT" ]] || die "script missing or not executable: $SCRIPT"
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-promoted-image-test.XXXXXX")"
  chmod 700 "$WORKDIR"
  trap cleanup EXIT
  mkdir -m 700 -p "$WORKDIR/bin" "$WORKDIR/data"
}

REV="13b41759f68a85d86c38fba4dad12f13b4792682"
DIGEST="sha256:d274e49221a8240bb9057de802a314ea4e446f7a6eb5f20c8d93f12f4576b748"
EVIDENCE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
RUN_ID="9001"
SOURCE_RUN_ID="8001"
REPO="WesPerez/sub2api"
TAG="mine-sha-${REV}"

set_base_args() {
  BASE_ARGS=(
    --expected-revision "$REV"
    --expected-digest "$DIGEST"
    --promotion-run-id "$RUN_ID"
    --verification-evidence-sha256 "$EVIDENCE"
    --repo "$REPO"
  )
}

write_good_promotion() {
  local dest="$1"
  jq -n \
    --arg rev "$REV" \
    --arg dig "$DIGEST" \
    --arg evid "$EVIDENCE" \
    --arg run "$RUN_ID" \
    --arg src "$SOURCE_RUN_ID" \
    --arg tag "$TAG" \
    --arg short "mine-${REV:0:12}" \
    '{
      schema_version: 1,
      promotion_run_id: $run,
      source_run_id: $src,
      publisher_run_id: $src,
      publisher_run_attempt: "1",
      reused_existing_debug_image: false,
      revision: $rev,
      source_digest: $dig,
      target_digest: $dig,
      verification_evidence_sha256: $evid,
      evidence_binding_mode: "recorded-hash-production-apply-verifies-local-file",
      tags: [$tag, $short, "mine"]
    }' >"$dest"
  chmod 600 "$dest"
}

write_run_json() {
  local dest="$1"
  local name="${2:-Promote Debug Image}"
  local path="${3:-.github/workflows/promote-debug-image.yml}"
  local event="${4:-workflow_dispatch}"
  local branch="${5:-mine}"
  local sha="${6:-$REV}"
  local status="${7:-completed}"
  local conclusion="${8:-success}"
  jq -n \
    --arg name "$name" \
    --arg path "$path" \
    --arg event "$event" \
    --arg branch "$branch" \
    --arg sha "$sha" \
    --arg status "$status" \
    --arg conclusion "$conclusion" \
    --argjson id "$RUN_ID" \
    '{
      id: $id,
      name: $name,
      path: $path,
      event: $event,
      head_branch: $branch,
      head_sha: $sha,
      status: $status,
      conclusion: $conclusion
    }' >"$dest"
}

install_stubs() {
  cat >"$WORKDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="${1:-}"
if [[ "$cmd" == "api" ]]; then
  endpoint="${2:-}"
  if [[ "$endpoint" == repos/*/actions/runs/*/* ]]; then
    cat "$STUB_ARTIFACTS_JSON"
    exit 0
  fi
  if [[ "$endpoint" == repos/*/actions/runs/* ]]; then
    cat "$STUB_RUN_JSON"
    exit 0
  fi
  echo "unexpected gh api endpoint: $endpoint" >&2
  exit 99
fi
if [[ "$cmd" == "run" && "${2:-}" == "download" ]]; then
  dir=""
  while (( $# > 0 )); do
    case "$1" in
      --dir) dir="$2"; shift ;;
    esac
    shift || true
  done
  [[ -n "$dir" ]] || exit 98
  mkdir -p "$dir/promotion-json"
  if [[ "${STUB_MULTI_PROMO:-0}" == "1" ]]; then
    cp "$STUB_PROMO_SRC" "$dir/promotion-json/promotion.json"
    mkdir -p "$dir/promotion-json/nested"
    cp "$STUB_PROMO_SRC" "$dir/promotion-json/nested/promotion.json"
  else
    cp "$STUB_PROMO_SRC" "$dir/promotion-json/promotion.json"
    chmod 600 "$dir/promotion-json/promotion.json"
  fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 97
STUB
  chmod 700 "$WORKDIR/bin/gh"

  cat >"$WORKDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="${1:-}"
if [[ "$cmd" == "pull" ]]; then
  exit 0
fi
if [[ "$cmd" == "image" && "${2:-}" == "inspect" ]]; then
  fmt=""
  shift 2
  while (( $# > 0 )); do
    case "$1" in
      -f) fmt="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$fmt" in
    '{{.Id}}')
      printf '%s\n' "sha256:imageiddeadbeef"
      ;;
    '{{index .Config.Labels "org.opencontainers.image.revision"}}')
      if [[ "${STUB_DOCKER_MODE:-happy}" == "bad_revision" ]]; then
        printf '%s\n' "0000000000000000000000000000000000000000"
      else
        printf '%s\n' "$STUB_REV"
      fi
      ;;
    '{{index .Config.Labels "org.opencontainers.image.ref.name"}}')
      if [[ "${STUB_DOCKER_MODE:-happy}" == "bad_refname" ]]; then
        printf '%s\n' "mine"
      else
        printf '%s\n' "debug"
      fi
      ;;
    '{{json .RepoDigests}}')
      case "${STUB_DOCKER_MODE:-happy}" in
        bad_digest)
          printf '%s\n' '["ghcr.io/wesperez/sub2api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"]'
          ;;
        multi_repo)
          printf '%s\n' "[\"docker.io/library/sub2api@$STUB_DIGEST\",\"ghcr.io/wesperez/sub2api@$STUB_DIGEST\"]"
          ;;
        multi_match)
          printf '%s\n' "[\"ghcr.io/wesperez/sub2api@$STUB_DIGEST\",\"ghcr.io/wesperez/sub2api@$STUB_DIGEST\"]"
          ;;
        *)
          printf '%s\n' "[\"ghcr.io/other/sub2api@sha256:1111111111111111111111111111111111111111111111111111111111111111\",\"ghcr.io/wesperez/sub2api@$STUB_DIGEST\"]"
          ;;
      esac
      ;;
    *)
      echo "unexpected docker inspect format: $fmt" >&2
      exit 96
      ;;
  esac
  exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 95
STUB
  chmod 700 "$WORKDIR/bin/docker"
}

run_subject() {
  local out err rc
  out="$WORKDIR/out.json"
  err="$WORKDIR/err.txt"
  set +e
  env PATH="$WORKDIR/bin:/usr/bin:/bin" \
    STUB_RUN_JSON="$STUB_RUN_JSON" \
    STUB_ARTIFACTS_JSON="$STUB_ARTIFACTS_JSON" \
    STUB_PROMO_SRC="$STUB_PROMO_SRC" \
    STUB_MULTI_PROMO="${STUB_MULTI_PROMO:-0}" \
    STUB_DOCKER_MODE="${STUB_DOCKER_MODE:-happy}" \
    STUB_REV="$REV" \
    STUB_DIGEST="$DIGEST" \
    "$SCRIPT" "$@" >"$out" 2>"$err"
  rc=$?
  set -e
  SUBJECT_RC=$rc
  SUBJECT_OUT=$out
  SUBJECT_ERR=$err
}

expect_fail() {
  local title="$1"
  shift
  run_subject "$@"
  if (( SUBJECT_RC == 0 )); then
    printf 'FAIL %s (expected non-zero)\n' "$title" >&2
    cat "$SUBJECT_ERR" >&2 || true
    FAIL=$((FAIL + 1))
  else
    printf 'PASS %s (rc=%s)\n' "$title" "$SUBJECT_RC"
    PASS=$((PASS + 1))
  fi
}

expect_pass() {
  local title="$1"
  shift
  run_subject "$@"
  if (( SUBJECT_RC != 0 )); then
    printf 'FAIL %s (rc=%s)\n' "$title" "$SUBJECT_RC" >&2
    cat "$SUBJECT_ERR" >&2 || true
    FAIL=$((FAIL + 1))
    return
  fi
  if ! jq -e . >/dev/null <"$SUBJECT_OUT"; then
    printf 'FAIL %s (stdout not JSON)\n' "$title" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  local count
  count="$(jq -s 'length' <"$SUBJECT_OUT")"
  if [[ "$count" != "1" ]]; then
    printf 'FAIL %s (expected one JSON value, got %s)\n' "$title" "$count" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  printf 'PASS %s\n' "$title"
  PASS=$((PASS + 1))
}

prepare_happy_files() {
  STUB_RUN_JSON="$WORKDIR/data/run.json"
  STUB_ARTIFACTS_JSON="$WORKDIR/data/artifacts.json"
  STUB_PROMO_SRC="$WORKDIR/data/promotion.json"
  write_run_json "$STUB_RUN_JSON"
  write_good_promotion "$STUB_PROMO_SRC"
  jq -n --arg name "promotion-json" '{total_count:1, artifacts:[{id:1, name:$name, expired:false}]}' >"$STUB_ARTIFACTS_JSON"
  STUB_MULTI_PROMO=0
  STUB_DOCKER_MODE=happy
  install_stubs
}

main() {
  setup
  bash -n "$SCRIPT" || die "bash -n failed on subject script"
  set_base_args

  prepare_happy_files
  expect_pass "happy path metadata-only" "${BASE_ARGS[@]}"

  prepare_happy_files
  expect_pass "happy path with pull and RepoDigests filter" "${BASE_ARGS[@]}" --pull
  if (( SUBJECT_RC == 0 )); then
    if ! jq -e --arg dig "$DIGEST" --arg rev "$REV" \
      '.image.pulled == true and .image.digest == $dig and .image.revision == $rev and .image.ref_name == "debug"' \
      <"$SUBJECT_OUT" >/dev/null; then
      printf 'FAIL happy pull JSON assertions\n' >&2
      FAIL=$((FAIL + 1))
      PASS=$((PASS - 1))
    fi
  fi

  prepare_happy_files
  write_run_json "$STUB_RUN_JSON" "Promote Debug Image" ".github/workflows/promote-debug-image.yml" \
    "workflow_dispatch" "mine" "$REV" "completed" "failure"
  expect_fail "run conclusion failure" "${BASE_ARGS[@]}"

  prepare_happy_files
  write_run_json "$STUB_RUN_JSON" "Promote Debug Image" ".github/workflows/docker-branch.yml"
  expect_fail "wrong workflow path" "${BASE_ARGS[@]}"

  prepare_happy_files
  write_run_json "$STUB_RUN_JSON" "Promote Debug Image" ".github/workflows/promote-debug-image.yml" \
    "workflow_dispatch" "mine" "ffffffffffffffffffffffffffffffffffffffff"
  expect_fail "wrong head sha" "${BASE_ARGS[@]}"

  prepare_happy_files
  write_run_json "$STUB_RUN_JSON" "Promote Debug Image" ".github/workflows/promote-debug-image.yml" "push"
  expect_fail "wrong event push" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq -n '{total_count:2, artifacts:[{id:1,name:"promotion-json",expired:false},{id:2,name:"other",expired:false}]}' >"$STUB_ARTIFACTS_JSON"
  expect_fail "multiple artifacts" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq -n '{total_count:101, artifacts:[{id:1,name:"promotion-json",expired:false}]}' >"$STUB_ARTIFACTS_JSON"
  expect_fail "artifact pagination cannot prove uniqueness" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq -n '{total_count:1, artifacts:[{id:1,name:"promotion-json",expired:true}]}' >"$STUB_ARTIFACTS_JSON"
  expect_fail "expired artifact" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq -n '{total_count:1, artifacts:[{id:1,name:"not-promotion",expired:false}]}' >"$STUB_ARTIFACTS_JSON"
  expect_fail "wrong artifact name" "${BASE_ARGS[@]}"

  prepare_happy_files
  STUB_MULTI_PROMO=1
  install_stubs
  expect_fail "multiple promotion.json files" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq --arg d "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    '.source_digest=$d | .target_digest=$d' \
    "$STUB_PROMO_SRC" >"$WORKDIR/data/promotion.tampered.json"
  mv "$WORKDIR/data/promotion.tampered.json" "$STUB_PROMO_SRC"
  chmod 600 "$STUB_PROMO_SRC"
  expect_fail "artifact tampered digest" "${BASE_ARGS[@]}"

  prepare_happy_files
  expect_fail "evidence mismatch" \
    --expected-revision "$REV" \
    --expected-digest "$DIGEST" \
    --promotion-run-id "$RUN_ID" \
    --verification-evidence-sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    --repo "$REPO"

  prepare_happy_files
  jq '.evidence_binding_mode="workflow-claims-to-verify-unavailable-local-file"' \
    "$STUB_PROMO_SRC" >"$WORKDIR/data/promotion.bad-binding.json"
  mv "$WORKDIR/data/promotion.bad-binding.json" "$STUB_PROMO_SRC"
  chmod 600 "$STUB_PROMO_SRC"
  expect_fail "unsupported evidence binding mode" "${BASE_ARGS[@]}"

  prepare_happy_files
  python3 -c "from pathlib import Path; p=Path(r'''$STUB_PROMO_SRC'''); p.write_bytes(p.read_bytes().replace(b'\n', b'\r\n'))"
  expect_fail "CRLF promotion.json" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq '.tags=["mine","mine-13b41759f68a"]' "$STUB_PROMO_SRC" >"$WORKDIR/data/p2.json"
  mv "$WORKDIR/data/p2.json" "$STUB_PROMO_SRC"
  chmod 600 "$STUB_PROMO_SRC"
  expect_fail "missing mine-sha-40 tag" "${BASE_ARGS[@]}"

  prepare_happy_files
  jq '.tags += ["bad\nline"]' "$STUB_PROMO_SRC" >"$WORKDIR/data/p3.json"
  mv "$WORKDIR/data/p3.json" "$STUB_PROMO_SRC"
  chmod 600 "$STUB_PROMO_SRC"
  expect_fail "tag with newline" "${BASE_ARGS[@]}"

  prepare_happy_files
  STUB_DOCKER_MODE=bad_revision
  install_stubs
  expect_fail "pull wrong revision label" "${BASE_ARGS[@]}" --pull

  prepare_happy_files
  STUB_DOCKER_MODE=bad_refname
  install_stubs
  expect_fail "pull wrong ref.name mine" "${BASE_ARGS[@]}" --pull

  prepare_happy_files
  STUB_DOCKER_MODE=bad_digest
  install_stubs
  expect_fail "pull wrong digest" "${BASE_ARGS[@]}" --pull

  prepare_happy_files
  STUB_DOCKER_MODE=multi_match
  install_stubs
  expect_fail "RepoDigests duplicate for repository" "${BASE_ARGS[@]}" --pull

  prepare_happy_files
  STUB_DOCKER_MODE=multi_repo
  install_stubs
  expect_pass "RepoDigests foreign-first still matches exact repo" "${BASE_ARGS[@]}" --pull

  printf '\nSummary: %s passed, %s failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}

main "$@"
