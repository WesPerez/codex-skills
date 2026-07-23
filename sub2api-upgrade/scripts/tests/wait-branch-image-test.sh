#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
readonly SCRIPT="$SCRIPT_DIR/wait-branch-image.sh"
readonly REVISION="1234567890abcdef1234567890abcdef12345678"
readonly DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wait-branch-image-test.XXXXXX")"
BIN_DIR="$TEST_ROOT/bin"
RUNS_JSON="$TEST_ROOT/runs.json"

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "failure did not contain '$expected': $output"
}

install -d -m 0700 "$BIN_DIR"

cat > "$BIN_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
  cat "$FAKE_RUNS_JSON"
  exit 0
fi
printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 2
STUB

cat > "$BIN_DIR/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pull" ]]; then
  exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" && "${3:-}" == "-f" ]]; then
  case "$4" in
    '{{.Id}}') printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    '{{json .RepoDigests}}') printf '%s\n' "$FAKE_REPO_DIGESTS" ;;
    *org.opencontainers.image.revision*) printf '%s\n' "$FAKE_IMAGE_REVISION" ;;
    *org.opencontainers.image.ref.name*) printf '%s\n' "$FAKE_IMAGE_REF_NAME" ;;
    *) printf 'unexpected inspect format: %s\n' "$4" >&2; exit 2 ;;
  esac
  exit 0
fi
printf 'unexpected fake docker invocation: %s\n' "$*" >&2
exit 2
STUB

chmod 0755 "$BIN_DIR/gh" "$BIN_DIR/docker"

cat > "$RUNS_JSON" <<EOF
[
  {
    "databaseId": 42,
    "status": "completed",
    "conclusion": "success",
    "url": "https://github.invalid/runs/42",
    "headSha": "$REVISION",
    "headBranch": "debug",
    "createdAt": "2026-07-23T00:00:00Z",
    "updatedAt": "2026-07-23T00:09:00Z"
  }
]
EOF

export PATH="$BIN_DIR:$PATH"
export FAKE_RUNS_JSON="$RUNS_JSON"
export FAKE_IMAGE_REVISION="$REVISION"
export FAKE_IMAGE_REF_NAME="debug"
export FAKE_REPO_DIGESTS="[\"example.invalid/other@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"ghcr.io/wesperez/sub2api@$DIGEST\"]"

output="$($SCRIPT --branch debug --expected-revision "$REVISION" --no-wait)"
jq -e --arg ref "ghcr.io/wesperez/sub2api:debug-sha-$REVISION" \
  '.workflow.databaseId == 42 and .image.reference == $ref and .image.pulled == false' \
  >/dev/null <<<"$output" || fail "no-pull output did not bind the full SHA tag"

output="$($SCRIPT --branch debug --expected-revision "$REVISION" --no-wait --pull)"
jq -e --arg digest "$DIGEST" --arg revision "$REVISION" \
  '.image.digest == $digest and .image.revision == $revision and .image.ref_name == "debug" and .image.pulled == true' \
  >/dev/null <<<"$output" || fail "pull output did not bind the repository digest"

FAKE_IMAGE_REF_NAME="mine"
export FAKE_IMAGE_REF_NAME
expect_failure "image ref.name mine does not match debug" \
  "$SCRIPT" --branch debug --expected-revision "$REVISION" --no-wait --pull

expect_failure "branch must be debug" \
  "$SCRIPT" --branch mine --expected-revision "$REVISION" --no-wait

printf 'wait-branch-image tests passed.\n'
