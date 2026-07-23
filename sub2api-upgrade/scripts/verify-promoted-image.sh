#!/usr/bin/env bash
# Verify a GitHub Actions promote-debug-image run and optional local image pull.
# Read-only against GitHub API / registry metadata by default. Progress -> stderr.
# Success stdout is exactly one JSON object.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly WORKFLOW_NAME="Promote Debug Image"
readonly WORKFLOW_PATH=".github/workflows/promote-debug-image.yml"
readonly IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
readonly ARTIFACT_NAME="promotion-json"
readonly PROMOTION_FILE="promotion.json"
readonly SCHEMA_VERSION="1"

EXPECTED_REVISION=""
EXPECTED_DIGEST=""
PROMOTION_RUN_ID=""
VERIFICATION_EVIDENCE_SHA256=""
GITHUB_REPOSITORY="WesPerez/sub2api"
PULL_IMAGE=0
WORKDIR=""

usage() {
  cat <<'USAGE'
Usage:
  verify-promoted-image.sh \
    --expected-revision <40-char-sha> \
    --expected-digest sha256:<64-hex> \
    --promotion-run-id <digits> \
    --verification-evidence-sha256 <64-hex> \
    [--repo WesPerez/sub2api] [--pull]

Queries the exact GitHub Actions promotion run, downloads its uniquely named
promotion-json artifact, validates promotion.json fail-closed, and optionally
pulls ghcr.io/wesperez/sub2api:mine-sha-<40>@<digest>. Progress is written to
stderr. On success stdout contains one JSON object. Does not accept legacy mine
rebuilds, floating tags, or short SHAs as authority.
USAGE
}

info() {
  printf '%s\n' "[sub2api-promote-verify] $*" >&2
}

die() {
  printf '%s\n' "[sub2api-promote-verify] error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
    rm -rf -- "$WORKDIR"
  fi
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --expected-revision)
        (( $# >= 2 )) || die "--expected-revision requires a value"
        EXPECTED_REVISION="$2"
        shift
        ;;
      --expected-digest)
        (( $# >= 2 )) || die "--expected-digest requires a value"
        EXPECTED_DIGEST="$2"
        shift
        ;;
      --promotion-run-id)
        (( $# >= 2 )) || die "--promotion-run-id requires a value"
        PROMOTION_RUN_ID="$2"
        shift
        ;;
      --verification-evidence-sha256)
        (( $# >= 2 )) || die "--verification-evidence-sha256 requires a value"
        VERIFICATION_EVIDENCE_SHA256="$2"
        shift
        ;;
      --repo)
        (( $# >= 2 )) || die "--repo requires a value"
        GITHUB_REPOSITORY="$2"
        shift
        ;;
      --pull)
        PULL_IMAGE=1
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

assert_inputs() {
  [[ "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]] \
    || die "expected revision must be a lowercase 40-character SHA"
  [[ "$EXPECTED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "expected digest must match sha256:<64-hex>"
  [[ "$PROMOTION_RUN_ID" =~ ^[0-9]+$ ]] \
    || die "promotion-run-id must be digits only"
  [[ "$VERIFICATION_EVIDENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || die "verification-evidence-sha256 must be a lowercase 64-character hex digest"
  [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "repo must look like owner/name"
}

fetch_promotion_run() {
  local run_json
  run_json="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${PROMOTION_RUN_ID}")" \
    || die "failed to query promotion run ${PROMOTION_RUN_ID}"

  local name path event head_branch head_sha status conclusion
  name="$(jq -r '.name // empty' <<<"$run_json")"
  path="$(jq -r '.path // empty' <<<"$run_json")"
  event="$(jq -r '.event // empty' <<<"$run_json")"
  head_branch="$(jq -r '.head_branch // empty' <<<"$run_json")"
  head_sha="$(jq -r '.head_sha // empty' <<<"$run_json")"
  status="$(jq -r '.status // empty' <<<"$run_json")"
  conclusion="$(jq -r '.conclusion // empty' <<<"$run_json")"

  [[ "$name" == "$WORKFLOW_NAME" ]] \
    || die "promotion run name is '$name', expected '$WORKFLOW_NAME'"
  [[ "$path" == "$WORKFLOW_PATH" ]] \
    || die "promotion run path is '$path', expected '$WORKFLOW_PATH'"
  [[ "$event" == "workflow_dispatch" ]] \
    || die "promotion run event is '$event', expected workflow_dispatch"
  [[ "$head_branch" == "mine" ]] \
    || die "promotion run head_branch is '$head_branch', expected mine"
  [[ "$head_sha" == "$EXPECTED_REVISION" ]] \
    || die "promotion run head_sha is '$head_sha', expected $EXPECTED_REVISION"
  [[ "$status" == "completed" ]] \
    || die "promotion run status is '$status', expected completed"
  [[ "$conclusion" == "success" ]] \
    || die "promotion run conclusion is '$conclusion', expected success"

  printf '%s' "$run_json"
}

download_promotion_json() {
  local artifacts_json count artifact_name download_dir found
  artifacts_json="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${PROMOTION_RUN_ID}/artifacts?per_page=100")" \
    || die "failed to list artifacts for promotion run ${PROMOTION_RUN_ID}"

  count="$(jq -r '.total_count // -1' <<<"$artifacts_json")"
  [[ "$count" == "1" && "$(jq -r '.artifacts|length' <<<"$artifacts_json")" == "1" ]] \
    || die "expected exactly one artifact on the promotion run, found total_count=$count"

  [[ "$(jq -r 'if (.artifacts[0] | has("expired")) then .artifacts[0].expired else true end' <<<"$artifacts_json")" == "false" ]] \
    || die "promotion artifact is expired"
  artifact_name="$(jq -r '.artifacts[0].name // empty' <<<"$artifacts_json")"
  [[ "$artifact_name" == "$ARTIFACT_NAME" ]] \
    || die "promotion artifact name is '$artifact_name', expected $ARTIFACT_NAME"

  download_dir="$WORKDIR/artifact"
  mkdir -m 0700 -p "$download_dir"

  info "downloading artifact ${ARTIFACT_NAME} from run ${PROMOTION_RUN_ID}"
  gh run download "$PROMOTION_RUN_ID" \
    --repo "$GITHUB_REPOSITORY" \
    --name "$ARTIFACT_NAME" \
    --dir "$download_dir" \
    >/dev/null \
    || die "gh run download failed for artifact ${ARTIFACT_NAME}"

  mapfile -t found < <(find "$download_dir" -type f -name "$PROMOTION_FILE" -print | LC_ALL=C sort)
  (( ${#found[@]} == 1 )) || die "expected exactly one ${PROMOTION_FILE} in artifact, found ${#found[@]}"

  local promo_path real_promo real_work mode perm_tail
  promo_path="${found[0]}"
  real_promo="$(realpath -e "$promo_path")" || die "promotion.json path is not resolvable"
  real_work="$(realpath -e "$WORKDIR")" || die "workdir is not resolvable"
  [[ "$real_promo" == "$real_work"/* ]] || die "promotion.json is outside the secure workdir"
  [[ -f "$real_promo" && ! -L "$promo_path" ]] || die "promotion.json must be a regular non-symlink file"
  mode="$(stat -c '%a' "$real_promo" 2>/dev/null || stat -f '%OLp' "$real_promo")"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || die "could not read promotion.json permissions"
  perm_tail="${mode: -3}"
  (( (8#${perm_tail} & 8#022) == 0 )) || die "promotion.json permissions are not safe: $mode"

  printf '%s' "$real_promo"
}

read_promotion_document() {
  local path="$1"
  local raw
  raw="$(cat -- "$path")" || die "failed to read promotion.json"
  [[ "$raw" != *$'\r'* ]] || die "promotion.json contains CR/CRLF; refuse"
  [[ -n "$raw" ]] || die "promotion.json is empty"
  jq -e . >/dev/null <<<"$raw" || die "promotion.json is not valid JSON"
  printf '%s' "$raw"
}

json_string_field() {
  local doc="$1"
  local field="$2"
  local value
  value="$(jq -r --arg f "$field" 'if has($f) then .[$f] else empty end | if type == "string" or type == "number" then tostring else empty end' <<<"$doc")"
  [[ -n "$value" ]] || die "promotion.json missing or non-scalar field: $field"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "promotion.json field $field contains line breaks"
  printf '%s' "$value"
}

validate_promotion_document() {
  local doc="$1"
  local schema_version promotion_run_id source_run_id publisher_run_id publisher_run_attempt revision source_digest target_digest evidence evidence_binding_mode tags_json required_tag

  jq -e '.schema_version == 1' >/dev/null <<<"$doc" \
    || die "promotion.json schema_version must be numeric 1"
  schema_version="$(json_string_field "$doc" "schema_version")"
  [[ "$schema_version" == "$SCHEMA_VERSION" ]] \
    || die "promotion.json schema_version is '$schema_version', expected '$SCHEMA_VERSION'"

  promotion_run_id="$(json_string_field "$doc" "promotion_run_id")"
  [[ "$promotion_run_id" == "$PROMOTION_RUN_ID" ]] \
    || die "promotion.json promotion_run_id is '$promotion_run_id', expected $PROMOTION_RUN_ID"

  source_run_id="$(json_string_field "$doc" "source_run_id")"
  [[ "$source_run_id" =~ ^[0-9]+$ ]] || die "promotion.json source_run_id must be digits"
  publisher_run_id="$(json_string_field "$doc" "publisher_run_id")"
  publisher_run_attempt="$(json_string_field "$doc" "publisher_run_attempt")"
  [[ "$publisher_run_id" =~ ^[0-9]+$ ]] || die "promotion.json publisher_run_id must be digits"
  [[ "$publisher_run_attempt" =~ ^[0-9]+$ ]] || die "promotion.json publisher_run_attempt must be digits"
  jq -e '.reused_existing_debug_image | type=="boolean"' >/dev/null <<<"$doc" \
    || die "promotion.json reused_existing_debug_image must be boolean"

  revision="$(json_string_field "$doc" "revision")"
  [[ "$revision" == "$EXPECTED_REVISION" ]] \
    || die "promotion.json revision is '$revision', expected $EXPECTED_REVISION"

  source_digest="$(json_string_field "$doc" "source_digest")"
  target_digest="$(json_string_field "$doc" "target_digest")"
  [[ "$source_digest" == "$EXPECTED_DIGEST" ]] \
    || die "promotion.json source_digest does not match expected digest"
  [[ "$target_digest" == "$EXPECTED_DIGEST" ]] \
    || die "promotion.json target_digest does not match expected digest"
  [[ "$source_digest" == "$target_digest" ]] \
    || die "promotion.json source_digest and target_digest differ"

  evidence="$(json_string_field "$doc" "verification_evidence_sha256")"
  [[ "$evidence" == "$VERIFICATION_EVIDENCE_SHA256" ]] \
    || die "promotion.json verification_evidence_sha256 does not match"
  evidence_binding_mode="$(json_string_field "$doc" "evidence_binding_mode")"
  [[ "$evidence_binding_mode" == "recorded-hash-production-apply-verifies-local-file" ]] \
    || die "promotion.json evidence binding mode is unsupported"

  jq -e 'has("tags") and (.tags | type == "array")' >/dev/null <<<"$doc" \
    || die "promotion.json tags must be an array"
  tags_json="$(jq -c '.tags' <<<"$doc")"
  jq -e 'all(.[]; type == "string" and length > 0 and (test("[\\r\\n]")|not))' \
    >/dev/null <<<"$tags_json" \
    || die "promotion.json tags must be non-empty strings without line breaks"

  required_tag="mine-sha-${EXPECTED_REVISION}"
  local short_tag="mine-${EXPECTED_REVISION:0:12}"
  jq -e --arg full "$required_tag" --arg short "$short_tag" \
    'sort == ([$full, $short, "mine"] | sort)' >/dev/null <<<"$tags_json" \
    || die "promotion.json tags must be exactly $required_tag, $short_tag, and mine"

  printf '%s' "$doc"
}

image_label() {
  local image="$1"
  local label="$2"
  docker image inspect -f "{{index .Config.Labels \"$label\"}}" "$image"
}

pull_and_verify_image() {
  local pinned_ref image_id image_revision image_ref_name repo_digests image_digest match_count
  pinned_ref="${IMAGE_REPOSITORY}:mine-sha-${EXPECTED_REVISION}@${EXPECTED_DIGEST}"

  info "pulling immutable promoted image $pinned_ref"
  docker pull "$pinned_ref" >/dev/null || die "docker pull failed for $pinned_ref"

  image_id="$(docker image inspect -f '{{.Id}}' "$pinned_ref")" \
    || die "docker image inspect failed"
  image_revision="$(image_label "$pinned_ref" 'org.opencontainers.image.revision')"
  image_ref_name="$(image_label "$pinned_ref" 'org.opencontainers.image.ref.name')"

  [[ "$image_revision" == "$EXPECTED_REVISION" ]] \
    || die "image revision '$image_revision' does not match $EXPECTED_REVISION"
  [[ "$image_ref_name" == "debug" ]] \
    || die "image ref.name is '$image_ref_name', expected debug (exact promote content identity)"

  repo_digests="$(docker image inspect -f '{{json .RepoDigests}}' "$pinned_ref")" \
    || die "failed to read RepoDigests"
  jq -e 'type == "array"' >/dev/null <<<"$repo_digests" || die "RepoDigests is not a JSON array"

  match_count="$(jq -r --arg repo "$IMAGE_REPOSITORY" \
    '[.[] | select(startswith($repo + "@"))] | length' <<<"$repo_digests")"
  [[ "$match_count" == "1" ]] \
    || die "expected exactly one RepoDigest for $IMAGE_REPOSITORY, found $match_count"

  image_digest="$(jq -r --arg repo "$IMAGE_REPOSITORY" \
    '.[] | select(startswith($repo + "@")) | split("@")[1]' <<<"$repo_digests")"
  [[ "$image_digest" == "$EXPECTED_DIGEST" ]] \
    || die "repository digest '$image_digest' does not match $EXPECTED_DIGEST"

  jq -n \
    --arg reference "$pinned_ref" \
    --arg image_id "$image_id" \
    --arg revision "$image_revision" \
    --arg ref_name "$image_ref_name" \
    --arg digest "$image_digest" \
    --argjson repo_digests "$repo_digests" \
    '{
      reference: $reference,
      image_id: $image_id,
      revision: $revision,
      ref_name: $ref_name,
      digest: $digest,
      repo_digests: $repo_digests,
      pulled: true
    }'
}

main() {
  parse_args "$@"
  require_command gh
  require_command jq
  require_command find
  require_command realpath
  require_command stat
  require_command mkdir
  require_command cat
  require_command mktemp
  (( PULL_IMAGE == 0 )) || require_command docker
  assert_inputs

  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-promoted-image.XXXXXX")"
  chmod 700 "$WORKDIR"
  trap cleanup EXIT

  info "querying exact promotion run $PROMOTION_RUN_ID on $GITHUB_REPOSITORY"
  local run_json promo_path promo_doc image_json
  run_json="$(fetch_promotion_run)"
  promo_path="$(download_promotion_json)"
  promo_doc="$(read_promotion_document "$promo_path")"
  promo_doc="$(validate_promotion_document "$promo_doc")"

  if (( PULL_IMAGE == 1 )); then
    image_json="$(pull_and_verify_image)"
  else
    image_json="$(jq -n \
      --arg reference "${IMAGE_REPOSITORY}:mine-sha-${EXPECTED_REVISION}@${EXPECTED_DIGEST}" \
      --arg revision "$EXPECTED_REVISION" \
      --arg digest "$EXPECTED_DIGEST" \
      '{
        reference: $reference,
        expected_revision: $revision,
        expected_digest: $digest,
        pulled: false
      }')"
  fi

  jq -n \
    --argjson run "$run_json" \
    --argjson promotion "$promo_doc" \
    --argjson image "$image_json" \
    --arg workflow_name "$WORKFLOW_NAME" \
    --arg workflow_path "$WORKFLOW_PATH" \
    '{
      workflow: {
        name: $workflow_name,
        path: $workflow_path,
        run: $run
      },
      promotion: $promotion,
      image: $image
    }'
}

main "$@"
