#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly MATRIX_FILE="$SCRIPT_DIR/../references/debug-verification-cases.tsv"

readonly DEFAULT_EVIDENCE_ROOT="/root/backups/sub2api/upgrade-evidence"
readonly PROD_DEPLOY_DIR="/root/sub2api-prod-deploy"
REPO="/root/sub2api-repo"
EVIDENCE_ROOT=""
RUNNING_REVISION=""
CANDIDATE_REVISION=""
UPSTREAM_REF="upstream/main"
OUTPUT_FORMAT="text"
OUTPUT_DIR=""
SHOW_FILES=0
ALL_SUITES=0
declare -a REQUESTED_SUITES=()

usage() {
  cat <<'USAGE'
Usage:
  plan-sub2api-upgrade.sh \
    --running-revision <40-char-sha> \
    --candidate-revision <40-char-sha> \
    [--upstream-ref upstream/main] [--repo /root/sub2api-repo] \
    [--suite <name>]... [--all-suites] [--show-files] [--json] \
    [--output-dir <new-evidence-directory>] \
    [--evidence-root <test-only-root-under-tmp>]

The command is read-only unless --output-dir is supplied. It rejects a
candidate whose upstream baseline or VERSION is older than the running
production revision, then selects debug suites from both the upgrade diff and
the candidate's remaining customization diff.

--output-dir must be a brand-new direct child of
/root/backups/sub2api/upgrade-evidence (or of --evidence-root in test mode).
--evidence-root is allowed only when SUB2API_UPGRADE_TEST_MODE=1 and must
resolve under /tmp.
USAGE
}

die() {
  printf '%s\n' "[sub2api-upgrade-plan] error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

resolve_commit() {
  local revision="$1"
  git -C "$REPO" cat-file -e "${revision}^{commit}" 2>/dev/null || die "commit is unavailable locally: $revision"
  git -C "$REPO" rev-parse "${revision}^{commit}"
}

version_at() {
  local revision="$1"
  local version
  version="$(git -C "$REPO" show "${revision}:backend/cmd/server/VERSION" 2>/dev/null | tr -d '[:space:]')" \
    || die "backend/cmd/server/VERSION is unavailable at $revision"
  [[ -n "$version" ]] || die "VERSION is empty at $revision"
  printf '%s\n' "${version#v}"
}

version_is_older() {
  local candidate="$1"
  local running="$2"
  local sorted
  [[ "$candidate" != "$running" ]] || return 1
  sorted="$(printf '%s\n%s\n' "$candidate" "$running" | sort -V)" || die "could not compare VERSION values"
  [[ "${sorted%%$'\n'*}" == "$candidate" ]]
}

select_suite() {
  local suite="$1"
  [[ "$suite" =~ ^[a-z0-9_]+$ ]] || die "invalid suite name: $suite"
  SELECTED_SUITES["$suite"]=1
}

classify_path() {
  local path="$1"

  [[ "$path" =~ (compact|long_context|context_management|context_window) ]] && select_suite long_context
  [[ "$path" =~ (image|vision|media|batch_image|multimodal) ]] && select_suite vision_media
  [[ "$path" =~ (grok|tool_choice|additional_tools|namespace|tool_search|responses_lite|tool_continuation) ]] && select_suite grok_tools
  [[ "$path" =~ (model|reasoning|effort|catalog|mapping) ]] && select_suite model_switch
  [[ "$path" =~ (stream|sse|response_handling|passthrough|keepalive|websocket|_ws) ]] && select_suite streaming
  [[ "$path" =~ (codex|sharedchat|openai_gateway|http_upstream|proxy) ]] && select_suite codex_sharedchat
  [[ "$path" =~ (error|failover|retry|rate_limit|cooldown|no_account) ]] && select_suite error_policy
  [[ "$path" =~ (scheduler|sticky|pool|snapshot|outbox|account_selection) ]] && select_suite scheduling
  [[ "$path" =~ (billing|usage|quota|probe|refresh|cleanup|worker) ]] && select_suite billing_background
  [[ "$path" == frontend/* ]] && select_suite frontend
  [[ "$path" =~ (auth|oauth|api_key|middleware|login|session) ]] && select_suite auth
  [[ "$path" =~ (^|/)(migrations?|schema)(/|_) ]] && select_suite migration
  [[ "$path" =~ (^|/)(deploy|Dockerfile|docker-compose|\.github/workflows)(/|$) ]] && select_suite deployment
  [[ "$path" =~ (anthropic|claude|gemini|antigravity) ]] && select_suite provider_extended
  return 0
}

json_string_array() {
  if (( $# == 0 )); then
    printf '[]\n'
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --running-revision)
        (( $# >= 2 )) || die "--running-revision requires a value"
        RUNNING_REVISION="$2"
        shift
        ;;
      --candidate-revision)
        (( $# >= 2 )) || die "--candidate-revision requires a value"
        CANDIDATE_REVISION="$2"
        shift
        ;;
      --upstream-ref)
        (( $# >= 2 )) || die "--upstream-ref requires a value"
        UPSTREAM_REF="$2"
        shift
        ;;
      --repo)
        (( $# >= 2 )) || die "--repo requires a value"
        REPO="$2"
        shift
        ;;
      --suite)
        (( $# >= 2 )) || die "--suite requires a value"
        REQUESTED_SUITES+=("$2")
        shift
        ;;
      --all-suites)
        ALL_SUITES=1
        ;;
      --show-files)
        SHOW_FILES=1
        ;;
      --json)
        OUTPUT_FORMAT="json"
        ;;
      --output-dir)
        (( $# >= 2 )) || die "--output-dir requires a value"
        OUTPUT_DIR="$2"
        shift
        ;;
      --evidence-root)
        (( $# >= 2 )) || die "--evidence-root requires a value"
        EVIDENCE_ROOT="$2"
        shift
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

prepare_evidence_output_dir() {
  local requested="$1"
  [[ -n "$requested" ]] || return 0
  [[ "$requested" != *$'\n'* && "$requested" != *$'\r'* ]] || die "output directory contains a newline"
  [[ "$requested" == /* ]] || die "output directory must be an absolute path"

  local leaf parent root_raw root_real parent_real requested_real after_real after_parent prod_real
  leaf="$(basename -- "$requested")"
  parent="$(dirname -- "$requested")"
  [[ -n "$leaf" && "$leaf" != "." && "$leaf" != ".." && "$leaf" != "/" ]] \
    || die "output directory leaf name is invalid"
  [[ "$leaf" != *"/"* ]] || die "output directory leaf name is invalid"

  if [[ -n "$EVIDENCE_ROOT" ]]; then
    [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]] \
      || die "--evidence-root requires SUB2API_UPGRADE_TEST_MODE=1"
    root_raw="$EVIDENCE_ROOT"
    [[ "$root_raw" != *$'\n'* && "$root_raw" != *$'\r'* ]] || die "evidence root contains a newline"
    [[ "$root_raw" == /* ]] || die "evidence root must be an absolute path"
    [[ ! -L "$root_raw" ]] || die "evidence root must not be a symlink"
    [[ -d "$root_raw" ]] || die "evidence root must exist as a directory: $root_raw"
    root_real="$(realpath -e "$root_raw")" || die "evidence root is not resolvable: $root_raw"
    [[ "$root_real" == /tmp/* ]] || die "test-mode --evidence-root must resolve under /tmp"
    [[ ! -L "$root_real" ]] || die "evidence root realpath must not be a symlink"
  else
    root_raw="$DEFAULT_EVIDENCE_ROOT"
    # Reject wrong parent before creating/touching the fixed root.
    [[ "$parent" == "$root_raw" || "$(realpath -m "$parent")" == "$(realpath -m "$root_raw")" ]] \
      || die "output directory must be a direct child of $root_raw"
    if [[ -e "$root_raw" ]]; then
      [[ -d "$root_raw" && ! -L "$root_raw" ]] \
        || die "evidence root must be a non-symlink directory: $root_raw"
    else
      install -d -m 0700 "$root_raw"
      [[ -d "$root_raw" && ! -L "$root_raw" ]] \
        || die "failed to create evidence root: $root_raw"
    fi
    root_real="$(realpath -e "$root_raw")" || die "evidence root is not resolvable: $root_raw"
    [[ "$root_real" == "$DEFAULT_EVIDENCE_ROOT" ]] \
      || die "evidence root resolves outside its canonical path"
    [[ ! -L "$root_real" ]] || die "evidence root realpath must not be a symlink"
  fi

  [[ -d "$parent" && ! -L "$parent" ]] \
    || die "output parent must be an existing non-symlink directory: $parent"
  parent_real="$(realpath -e "$parent")" || die "output parent is not resolvable: $parent"
  [[ "$parent_real" == "$root_real" ]] \
    || die "output directory must be a direct child of $root_real"

  requested_real="$(realpath -m "$requested")"
  [[ "$requested_real" == "$root_real/$leaf" ]] \
    || die "output directory must be a single-level child of $root_real"

  if [[ -e "$PROD_DEPLOY_DIR" || -L "$PROD_DEPLOY_DIR" ]]; then
    prod_real="$(realpath -m "$PROD_DEPLOY_DIR")"
    [[ "$requested_real" != "$prod_real" && "$requested_real" != "$prod_real"/* \
      && "$prod_real" != "$requested_real" && "$prod_real" != "$requested_real"/* ]] \
      || die "output directory overlaps production path"
    [[ "$root_real" != "$prod_real" && "$root_real" != "$prod_real"/* \
      && "$prod_real" != "$root_real" && "$prod_real" != "$root_real"/* ]] \
      || die "evidence root overlaps production path"
  fi
  [[ "$requested_real" != /root/sub2api-prod-deploy && "$requested_real" != /root/sub2api-prod-deploy/* ]] \
    || die "output directory overlaps production path"

  [[ ! -e "$requested" && ! -L "$requested" ]] \
    || die "output directory already exists: $requested"

  # Create only the new leaf under the already-verified parent (no multi-level -p race).
  install -d -m 0700 "$requested" || die "failed to create output directory: $requested"

  # TOCTOU re-validation after create.
  [[ -d "$requested" && ! -L "$requested" ]] \
    || die "output directory identity invalid after create: $requested"
  after_real="$(realpath -e "$requested")" || die "output directory not resolvable after create"
  after_parent="$(dirname -- "$after_real")"
  [[ "$after_parent" == "$root_real" ]] \
    || die "output directory escaped evidence root after create"
  [[ "$after_real" == "$root_real/$leaf" ]] \
    || die "output directory path changed after create"
  [[ -d "$root_real" && ! -L "$root_real" ]] \
    || die "evidence root became invalid after create"
  [[ "$(realpath -e "$root_real")" == "$root_real" ]] \
    || die "evidence root identity changed after create"

  OUTPUT_DIR="$after_real"
}

main() {
  parse_args "$@"
  require_command git
  require_command jq
  require_command sort
  require_command install
  require_command realpath
  require_command cut

  [[ -d "$REPO/.git" ]] || die "repository is missing: $REPO"
  [[ -f "$MATRIX_FILE" ]] || die "matrix catalog is missing: $MATRIX_FILE"
  [[ "$RUNNING_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "running revision must be a lowercase 40-character SHA"
  [[ "$CANDIDATE_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "candidate revision must be a lowercase 40-character SHA"
  if [[ -n "$EVIDENCE_ROOT" ]]; then
    [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]] || die "--evidence-root requires SUB2API_UPGRADE_TEST_MODE=1"
    [[ -n "$OUTPUT_DIR" ]] || die "--evidence-root requires --output-dir"
  fi

  local running_sha candidate_sha upstream_sha
  running_sha="$(resolve_commit "$RUNNING_REVISION")"
  candidate_sha="$(resolve_commit "$CANDIDATE_REVISION")"
  upstream_sha="$(resolve_commit "$UPSTREAM_REF")"

  local running_base candidate_base
  running_base="$(git -C "$REPO" merge-base "$running_sha" "$upstream_sha")" \
    || die "running revision has no merge-base with $UPSTREAM_REF"
  candidate_base="$(git -C "$REPO" merge-base "$candidate_sha" "$upstream_sha")" \
    || die "candidate revision has no merge-base with $UPSTREAM_REF"
  git -C "$REPO" merge-base --is-ancestor "$running_base" "$candidate_base" \
    || die "candidate upstream baseline $candidate_base is older than running baseline $running_base"

  local running_version candidate_version
  running_version="$(version_at "$running_sha")"
  candidate_version="$(version_at "$candidate_sha")"
  version_is_older "$candidate_version" "$running_version" \
    && die "candidate VERSION $candidate_version is older than running VERSION $running_version"

  local -a changed_files=()
  local -a custom_files=()
  local changed_output custom_output
  changed_output="$(git -C "$REPO" diff --name-only "$running_sha" "$candidate_sha" | sort -u)" \
    || die "failed to list the production-to-candidate diff"
  custom_output="$(git -C "$REPO" diff --name-only "$candidate_base" "$candidate_sha" | sort -u)" \
    || die "failed to list the candidate customization diff"
  if [[ -n "$changed_output" ]]; then
    mapfile -t changed_files <<<"$changed_output"
  fi
  if [[ -n "$custom_output" ]]; then
    mapfile -t custom_files <<<"$custom_output"
  fi

  declare -gA SELECTED_SUITES=()
  select_suite core
  # Long context, vision, and in-conversation model switching are permanent
  # production canaries because all three crossed historically fragile paths.
  select_suite long_context
  select_suite vision_media
  select_suite model_switch
  local path suite
  for path in "${changed_files[@]}" "${custom_files[@]}"; do
    [[ -n "$path" ]] && classify_path "$path"
  done
  for suite in "${REQUESTED_SUITES[@]}"; do
    select_suite "$suite"
  done

  if (( ALL_SUITES == 1 )); then
    while IFS=$'\t' read -r _ suite _; do
      [[ "$suite" == "suite" || -z "$suite" ]] || select_suite "$suite"
    done < "$MATRIX_FILE"
  fi

  local -a selected_suites=()
  mapfile -t selected_suites < <(printf '%s\n' "${!SELECTED_SUITES[@]}" | sort)

  local -a case_lines=()
  local id level executor description assertion
  while IFS=$'\t' read -r id suite level executor description assertion; do
    [[ "$id" == "id" || -z "$id" ]] && continue
    if [[ -n "${SELECTED_SUITES[$suite]+selected}" ]]; then
      case_lines+=("$id"$'\t'"$suite"$'\t'"$level"$'\t'"$executor"$'\t'"$description"$'\t'"$assertion")
    fi
  done < "$MATRIX_FILE"

  local suites_json changed_json custom_json cases_json
  suites_json="$(json_string_array "${selected_suites[@]}")"
  changed_json="$(json_string_array "${changed_files[@]}")"
  custom_json="$(json_string_array "${custom_files[@]}")"
  if (( ${#case_lines[@]} == 0 )); then
    cases_json='[]'
  else
    cases_json="$(
      printf '%s\n' "${case_lines[@]}" | jq -Rn '
        [inputs | split("\t") | {
          id: .[0], suite: .[1], level: .[2], executor: .[3],
          description: .[4], assertion: .[5]
        }]'
    )"
  fi

  local plan_json
  plan_json="$(jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo "$(realpath -e "$REPO")" \
    --arg running_revision "$running_sha" \
    --arg candidate_revision "$candidate_sha" \
    --arg upstream_ref "$UPSTREAM_REF" \
    --arg upstream_revision "$upstream_sha" \
    --arg running_upstream_base "$running_base" \
    --arg candidate_upstream_base "$candidate_base" \
    --arg running_version "$running_version" \
    --arg candidate_version "$candidate_version" \
    --argjson selected_suites "$suites_json" \
    --argjson changed_files "$changed_json" \
    --argjson customization_files "$custom_json" \
    --argjson cases "$cases_json" \
    '{
      generated_at: $generated_at,
      repository: $repo,
      running: {revision: $running_revision, version: $running_version, upstream_base: $running_upstream_base},
      candidate: {revision: $candidate_revision, version: $candidate_version, upstream_base: $candidate_upstream_base},
      upstream: {ref: $upstream_ref, revision: $upstream_revision},
      baseline_gate: "passed",
      selected_suites: $selected_suites,
      changed_files: $changed_files,
      customization_files: $customization_files,
      cases: $cases
    }')"

  if [[ -n "$OUTPUT_DIR" ]]; then
    prepare_evidence_output_dir "$OUTPUT_DIR"
    printf '%s\n' 'sub2api-upgrade-evidence-v1' > "$OUTPUT_DIR/.owner"
    printf '%s\n' "$plan_json" > "$OUTPUT_DIR/plan.json"
    printf '%s\n' "${changed_files[@]}" > "$OUTPUT_DIR/changed-files.txt"
    printf '%s\n' "${custom_files[@]}" > "$OUTPUT_DIR/customization-files.txt"
    printf 'case_id\tstatus\tstarted_at\tended_at\tevidence\tnote\n' > "$OUTPUT_DIR/results.tsv"
    cat > "$OUTPUT_DIR/manifest.env" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
running_revision=$running_sha
candidate_revision=$candidate_sha
running_upstream_base=$running_base
candidate_upstream_base=$candidate_base
running_version=$running_version
candidate_version=$candidate_version
evidence_epoch=1
status=planned
EOF
    chmod 0600 "$OUTPUT_DIR/.owner" "$OUTPUT_DIR/plan.json" "$OUTPUT_DIR/changed-files.txt" \
      "$OUTPUT_DIR/customization-files.txt" "$OUTPUT_DIR/results.tsv" "$OUTPUT_DIR/manifest.env"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    printf '%s\n' "$plan_json"
    return
  fi

  printf 'running=%s version=%s upstream_base=%s\n' "$running_sha" "$running_version" "$running_base"
  printf 'candidate=%s version=%s upstream_base=%s\n' "$candidate_sha" "$candidate_version" "$candidate_base"
  printf 'baseline_gate=passed changed_files=%s customization_files=%s\n' "${#changed_files[@]}" "${#custom_files[@]}"
  printf 'selected_suites=%s\n' "$(IFS=,; printf '%s' "${selected_suites[*]}")"
  printf 'selected_cases=%s\n' "${#case_lines[@]}"
  for path in "${case_lines[@]}"; do
    printf '  %s\n' "$(cut -f1-5 <<<"$path")"
  done
  if (( SHOW_FILES == 1 )); then
    printf 'changed_files:\n'
    printf '  %s\n' "${changed_files[@]}"
    printf 'customization_files:\n'
    printf '  %s\n' "${custom_files[@]}"
  fi
  [[ -z "$OUTPUT_DIR" ]] || printf 'evidence_dir=%s\n' "$OUTPUT_DIR"
}

main "$@"
