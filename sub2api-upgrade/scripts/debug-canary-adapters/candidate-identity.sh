#!/usr/bin/env bash
# Produce R0-1 candidate-identity evidence via fixed wait-branch-image + docker/gh.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
readonly EC_FAILED=70
readonly EC_BLOCKED=71

die() { printf '%s\n' "[adapter-candidate-identity] error: $*" >&2; exit "$EC_BLOCKED"; }
fail() { printf '%s\n' "[adapter-candidate-identity] failed: $*" >&2; exit "$EC_FAILED"; }

if (( $# > 0 )); then die "candidate-identity does not accept arguments"; fi
[[ -n "${ADAPTER_EVIDENCE_OUT:-}" ]] || die "ADAPTER_EVIDENCE_OUT is required"
[[ -n "${ADAPTER_REVISION:-}" && -n "${ADAPTER_DIGEST:-}" ]] || die "revision/digest required"
[[ "${ADAPTER_REVISION}" =~ ^[0-9a-f]{40}$ ]] || die "invalid revision"
[[ "${ADAPTER_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "invalid digest"

WAIT_SCRIPT="${ADAPTER_WAIT_BRANCH_SCRIPT:-}"
[[ -n "$WAIT_SCRIPT" && -f "$WAIT_SCRIPT" ]] || die "wait-branch script unavailable"
DOCKER_BIN="${ADAPTER_DOCKER_BIN:-docker}"
DEBUG_DIR="${ADAPTER_DEBUG_DIR:-/root/sub2api-debug-deploy}"
COMPOSE_FILE="${ADAPTER_COMPOSE_FILE:-$DEBUG_DIR/docker-compose.yml}"
[[ -f "$COMPOSE_FILE" ]] || die "debug compose file unavailable"

wait_json="$(bash "$WAIT_SCRIPT" --branch debug --expected-revision "$ADAPTER_REVISION" --no-wait --pull)" \
  || fail "wait-branch-image failed"

run_id="$(jq -r '.workflow.databaseId // .workflow.id // empty' <<<"$wait_json")"
conclusion="$(jq -r '.workflow.conclusion // empty' <<<"$wait_json")"
image_ref="$(jq -r '.image.reference // empty' <<<"$wait_json")"
image_digest="$(jq -r '.image.digest // empty' <<<"$wait_json")"
image_id="$(jq -r '.image.image_id // empty' <<<"$wait_json")"
img_revision="$(jq -r '.image.revision // empty' <<<"$wait_json")"
img_ref_name="$(jq -r '.image.ref_name // empty' <<<"$wait_json")"

[[ "$conclusion" == "success" ]] || fail "workflow conclusion is $conclusion"
[[ "$img_revision" == "$ADAPTER_REVISION" ]] || fail "image revision mismatch"
[[ "$img_ref_name" == "debug" ]] || fail "image ref mismatch"
[[ "$image_digest" == "$ADAPTER_DIGEST" ]] || fail "digest mismatch"
[[ "$run_id" =~ ^[0-9]+$ ]] || fail "workflow run id missing"

if [[ -z "$image_id" || "$image_id" == "null" ]]; then
  pinned="ghcr.io/wesperez/sub2api:debug-sha-${ADAPTER_REVISION}"
  image_id="$("$DOCKER_BIN" image inspect -f '{{.Id}}' "$pinned" 2>/dev/null || true)"
fi
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "container image id missing"

cid="$("$DOCKER_BIN" compose --project-directory "$DEBUG_DIR" -f "$COMPOSE_FILE" ps -q sub2api 2>/dev/null || true)"
[[ -n "$cid" ]] || fail "debug sub2api container is not running"
running_image_id="$("$DOCKER_BIN" inspect -f '{{.Image}}' "$cid" 2>/dev/null || true)"
[[ "$running_image_id" == "$image_id" ]] \
  || fail "running debug container does not use the verified immutable image"

reference="ghcr.io/wesperez/sub2api:debug-sha-${ADAPTER_REVISION}@${ADAPTER_DIGEST}"
if [[ -n "$image_ref" && "$image_ref" != "null" ]]; then
  if [[ "$image_ref" != *"$ADAPTER_REVISION"* ]]; then
    fail "image reference does not include expected revision"
  fi
fi

jq -n --arg revision "$ADAPTER_REVISION" --arg digest "$ADAPTER_DIGEST" --arg reference "$reference" \
  --arg run_id "$run_id" --arg image_id "$running_image_id" \
  '{schema_version:1,kind:"candidate-identity",revision:$revision,digest:$digest,image_reference:$reference,workflow_name:"Docker Branch Images",workflow_run_id:$run_id,ci_conclusion:"success",ref_name:"debug",container_image_id:$image_id}' \
  > "$ADAPTER_EVIDENCE_OUT"
chmod 0600 "$ADAPTER_EVIDENCE_OUT"
exit 0
