#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly WORKFLOW_NAME="Docker Branch Images"
readonly IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"

BRANCH=""
EXPECTED_REVISION=""
GITHUB_REPOSITORY="WesPerez/sub2api"
TIMEOUT_SECONDS=3600
POLL_SECONDS=30
PULL_IMAGE=0
NO_WAIT=0

usage() {
  cat <<'USAGE'
Usage:
  wait-branch-image.sh --branch debug --expected-revision <40-char-sha>
    [--repo WesPerez/sub2api] [--timeout-seconds N] [--poll-seconds N]
    [--pull] [--no-wait]

Progress is written to stderr. On success stdout contains one JSON object that
binds the workflow run and immutable debug-sha-<40sha> image to the expected
SHA. Mine images are accepted only through the separate promotion verifier.
Without --pull the command only queries GitHub Actions.
USAGE
}

info() {
  printf '%s\n' "[sub2api-image] $*" >&2
}

die() {
  printf '%s\n' "[sub2api-image] error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

assert_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]] || die "expected a positive integer, got: $1"
}

image_label() {
  local image="$1"
  local label="$2"
  docker image inspect -f "{{index .Config.Labels \"$label\"}}" "$image"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --branch)
        (( $# >= 2 )) || die "--branch requires a value"
        BRANCH="$2"
        shift
        ;;
      --expected-revision)
        (( $# >= 2 )) || die "--expected-revision requires a value"
        EXPECTED_REVISION="$2"
        shift
        ;;
      --repo)
        (( $# >= 2 )) || die "--repo requires a value"
        GITHUB_REPOSITORY="$2"
        shift
        ;;
      --timeout-seconds)
        (( $# >= 2 )) || die "--timeout-seconds requires a value"
        TIMEOUT_SECONDS="$2"
        shift
        ;;
      --poll-seconds)
        (( $# >= 2 )) || die "--poll-seconds requires a value"
        POLL_SECONDS="$2"
        shift
        ;;
      --pull)
        PULL_IMAGE=1
        ;;
      --no-wait)
        NO_WAIT=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  require_command gh
  require_command jq
  require_command date
  require_command sleep

  [[ "$BRANCH" == "debug" ]] || die "branch must be debug; mine images require verified digest promotion"
  [[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "expected revision must be a lowercase 40-character SHA"
  assert_positive_integer "$TIMEOUT_SECONDS"
  assert_positive_integer "$POLL_SECONDS"
  (( PULL_IMAGE == 0 )) || require_command docker

  local deadline=$((SECONDS + TIMEOUT_SECONDS))
  local run_json selected status conclusion run_id
  while true; do
    run_json="$(gh run list \
      --repo "$GITHUB_REPOSITORY" \
      --workflow "$WORKFLOW_NAME" \
      --branch "$BRANCH" \
      --commit "$EXPECTED_REVISION" \
      --limit 20 \
      --json databaseId,status,conclusion,url,headSha,headBranch,createdAt,updatedAt)" \
      || die "GitHub Actions query failed"

    selected="$(jq -c --arg sha "$EXPECTED_REVISION" --arg branch "$BRANCH" \
      '[.[] | select(.headSha == $sha and .headBranch == $branch)] | sort_by(.createdAt) | reverse | .[0] // empty' \
      <<<"$run_json")"

    if [[ -n "$selected" ]]; then
      status="$(jq -r '.status' <<<"$selected")"
      conclusion="$(jq -r '.conclusion // ""' <<<"$selected")"
      run_id="$(jq -r '.databaseId' <<<"$selected")"
      if [[ "$status" == "completed" ]]; then
        [[ "$conclusion" == "success" ]] || die "workflow run $run_id completed with conclusion: $conclusion"
        break
      fi
      info "run $run_id is $status"
    else
      info "no exact workflow run is visible yet for $BRANCH@$EXPECTED_REVISION"
    fi

    (( NO_WAIT == 0 )) || die "exact successful workflow run is not ready"
    (( SECONDS < deadline )) || die "timed out waiting for $BRANCH@$EXPECTED_REVISION"
    sleep "$POLL_SECONDS"
  done

  local pinned_image="$IMAGE_REPOSITORY:debug-sha-$EXPECTED_REVISION"
  if (( PULL_IMAGE == 0 )); then
    jq -n --argjson run "$selected" --arg image "$pinned_image" --arg revision "$EXPECTED_REVISION" \
      '{workflow: $run, image: {reference: $image, expected_revision: $revision, pulled: false}}'
    return
  fi

  info "pulling immutable image $pinned_image"
  docker pull "$pinned_image" >/dev/null
  local image_id image_revision image_ref_name repo_digests image_digest
  image_id="$(docker image inspect -f '{{.Id}}' "$pinned_image")"
  image_revision="$(image_label "$pinned_image" 'org.opencontainers.image.revision')"
  image_ref_name="$(image_label "$pinned_image" 'org.opencontainers.image.ref.name')"
  [[ "$image_revision" == "$EXPECTED_REVISION" ]] || die "image revision $image_revision does not match $EXPECTED_REVISION"
  [[ "$image_ref_name" == "$BRANCH" ]] || die "image ref.name $image_ref_name does not match $BRANCH"
  repo_digests="$(docker image inspect -f '{{json .RepoDigests}}' "$pinned_image")"
  image_digest="$(jq -r --arg repository "$IMAGE_REPOSITORY" '
    [
      .[]
      | select(startswith($repository + "@"))
      | split("@")[1]
      | select(test("^sha256:[0-9a-f]{64}$"))
    ]
    | unique
    | if length == 1 then .[0] else "" end
  ' <<<"$repo_digests")"
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "pulled image has no valid repository digest"

  jq -n \
    --argjson run "$selected" \
    --arg reference "$pinned_image" \
    --arg image_id "$image_id" \
    --arg revision "$image_revision" \
    --arg ref_name "$image_ref_name" \
    --arg digest "$image_digest" \
    --argjson repo_digests "$repo_digests" \
    '{
      workflow: $run,
      image: {
        reference: $reference,
        image_id: $image_id,
        revision: $revision,
        ref_name: $ref_name,
        digest: $digest,
        repo_digests: $repo_digests,
        pulled: true
      }
    }'
}

main "$@"
