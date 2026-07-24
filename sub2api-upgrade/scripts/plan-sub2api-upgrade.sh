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
PERMANENT_CANARIES=0
ACTIVE_INVENTORY=""
INVENTORY_PRESENT=0
declare -a REQUESTED_SUITES=()

usage() {
  cat <<'USAGE'
Usage:
  plan-sub2api-upgrade.sh \
    --running-revision <40-char-sha> \
    --candidate-revision <40-char-sha> \
    [--upstream-ref upstream/main] [--repo /root/sub2api-repo] \
    [--suite <name>]... [--all-suites] [--permanent-canaries] \
    [--active-inventory <production-capabilities.json>] \
    [--show-files] [--json] \
    [--output-dir <new-evidence-directory>] \
    [--evidence-root <test-only-root-under-tmp>]

The command is read-only unless --output-dir is supplied. It rejects a
candidate whose upstream baseline or VERSION is older than the running
production revision. R0 is always selected. R1/R2 cases are selected from
separate upstream and customization diffs, precise path rules, and an optional
non-sensitive production capability inventory. --suite and --all-suites are
explicit overrides; --permanent-canaries restores the former broad canaries.

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

append_unique_csv() {
  local map_name="$1" key="$2" value="$3" current
  local -n map_ref="$map_name"
  current="${map_ref[$key]-}"
  case ",$current," in
    *",$value,"*) ;;
    *) map_ref["$key"]="${current:+$current,}$value" ;;
  esac
}

select_suite() {
  local suite="$1" source="${2:-requested}"
  [[ "$suite" =~ ^[a-z0-9_]+$ ]] || die "invalid suite name: $suite"
  TRIGGERED_SUITES["$suite"]=1
  append_unique_csv SUITE_SOURCES "$suite" "$source"
}

record_trigger() {
  local suite="$1" source="$2" path="$3" rule_id="$4" confidence="${5:-high}"
  select_suite "$suite" "$source"
  append_unique_csv SUITE_RULES "$suite" "$rule_id"
  TRIGGER_EVENTS+=("$source"$'\t'"$suite"$'\t'"$path"$'\t'"$rule_id"$'\t'"$confidence")
}

is_test_only_path() {
  local path="$1"
  [[ "$path" =~ _test\.go$ || "$path" =~ (^|/)tests?(/|$) || "$path" =~ \.test\.[^/]+$ || "$path" =~ \.spec\.[^/]+$ ]]
}

classify_path() {
  local path="$1" source="$2" lower base
  lower="${path,,}"
  base="${lower##*/}"

  # Test-only edits do not alter a production path. Their execution remains
  # covered by CI; runtime canaries are driven by implementation/config paths.
  is_test_only_path "$lower" && return 0

  if [[ "$lower" == .github/workflows/* || "$lower" == deploy/* || "$base" == dockerfile* \
      || "$base" == docker-compose* || "$base" == compose.y*ml ]]; then
    record_trigger deployment "$source" "$path" dep.release
  fi
  if [[ "$lower" == backend/migrations/* || "$lower" == backend/ent/schema/* \
      || "$lower" == backend/ent/migrate/* ]]; then
    record_trigger migration "$source" "$path" mig.schema
  fi
  [[ "$lower" == frontend/* ]] && record_trigger frontend "$source" "$path" fe.frontend

  [[ "$lower" =~ (compact|long_context|context_management|context_window) ]] \
    && record_trigger long_context "$source" "$path" lc.context
  [[ "$lower" =~ (long_context_billing|context_billing) ]] \
    && record_trigger long_context "$source" "$path" lc.billing

  if [[ "$base" =~ ^(openai_images|grok_media)\.go$ || "$lower" =~ (^|[/_.-])(vision|multimodal)([/_.-]|$) ]]; then
    record_trigger vision_media "$source" "$path" vm.bridge
  fi
  [[ "$base" == grok_media.go ]] && record_trigger vision_media "$source" "$path" vm.grok_media
  [[ "$lower" =~ (image_generation|batch_image|media_generation) ]] \
    && record_trigger vision_media "$source" "$path" vm.generation

  if [[ "$base" =~ (openai_gateway_grok|grok_upstream|responses_to_chatcompletions|websearch) \
      || "$lower" =~ (tool_choice|additional_tools|responses_namespace|tool_search|tool_continuation) ]]; then
    record_trigger grok_tools "$source" "$path" gt.tools
  fi

  [[ "$lower" =~ (reasoning_effort|model_catalog|gateway_models|available_models|composite_model_route) ]] \
    && record_trigger model_switch "$source" "$path" ms.routing
  [[ "$lower" =~ reasoning_effort ]] && record_trigger model_switch "$source" "$path" ms.effort

  if [[ "$lower" =~ (^|[/_.-])(stream|streaming|non_streaming|sse)([/_.-]|$) \
      || "$lower" =~ (response_handling|passthrough|keepalive|websocket|openai_ws_|first_output_timeout|upstream_response) ]]; then
    record_trigger streaming "$source" "$path" st.stream
  fi

  if [[ "$lower" =~ (codex|sharedchat|openai_gateway|openai_chat_completions|openai_images|http_upstream|responses_to_chatcompletions) ]]; then
    record_trigger codex_sharedchat "$source" "$path" cs.gateway
  fi
  [[ "$lower" =~ (passthrough|http_upstream) ]] \
    && record_trigger codex_sharedchat "$source" "$path" cs.passthrough
  [[ "$lower" =~ (account_test|responses_probe) ]] \
    && record_trigger codex_sharedchat "$source" "$path" cs.probe

  if [[ "$lower" =~ (^|[/_.-])(error|errors|failover|retry|rate_limit|cooldown|no_account|timeout)([/_.-]|$) \
      || "$lower" =~ (upstream_errors|transport_error|runtime_block) ]]; then
    record_trigger error_policy "$source" "$path" ep.error
  fi
  [[ "$lower" =~ (retry|failover|pool_sse) ]] \
    && record_trigger error_policy "$source" "$path" ep.retry

  if [[ "$lower" =~ (scheduler|sticky|openai_pool|account_selection|gateway_scheduling) ]]; then
    record_trigger scheduling "$source" "$path" sch.sticky_pool
  fi
  [[ "$lower" =~ (scheduler_cache|snapshot|outbox) ]] \
    && record_trigger scheduling "$source" "$path" sch.cache

  [[ "$lower" =~ (^|[/_.-])(billing|usage|quota)([/_.-]|$) ]] \
    && record_trigger billing_background "$source" "$path" bb.usage
  [[ "$lower" =~ (account_test|responses_probe|apikey_responses_probe) ]] \
    && record_trigger billing_background "$source" "$path" bb.probe
  [[ "$lower" =~ (oauth_refresh|refresh_worker|token_refresh) ]] \
    && record_trigger billing_background "$source" "$path" bb.oauth_refresh

  if [[ "$lower" =~ (^|/)(auth|oauth)(/|_|\.|$) || "$lower" =~ (api_key_auth|login_callback|auth_middleware) ]]; then
    record_trigger auth "$source" "$path" au.auth
  fi
  if [[ "$lower" =~ (anthropic|claude|gemini|antigravity) ]]; then
    record_trigger provider_extended "$source" "$path" px.provider
    case "$lower" in
      *anthropic*|*claude*) ACTIVE_PROVIDER_HITS[anthropic]=1 ;;
      *gemini*) ACTIVE_PROVIDER_HITS[gemini]=1 ;;
      *antigravity*) ACTIVE_PROVIDER_HITS[antigravity]=1 ;;
    esac
  fi
  return 0
}

suite_has_rule() {
  local suite="$1" pattern="$2" rules=",${SUITE_RULES[$suite]-},"
  [[ "$rules" =~ $pattern ]]
}

inventory_has_feature() {
  local feature="$1"
  (( INVENTORY_PRESENT == 1 )) || return 1
  jq -e --arg feature "$feature" '.features | index($feature) != null' "$ACTIVE_INVENTORY" >/dev/null
}

inventory_has_provider_hit() {
  local provider
  (( INVENTORY_PRESENT == 1 )) || return 1
  for provider in "${!ACTIVE_PROVIDER_HITS[@]}"; do
    jq -e --arg provider "$provider" '.providers | index($provider) != null' "$ACTIVE_INVENTORY" >/dev/null \
      && return 0
  done
  return 1
}

case_path_triggered() {
  local id="$1"
  case "$id" in
    R0-*) return 0 ;;
    R1-A1) suite_has_rule long_context '(^|,)lc\.(context|compact)(,|$)' ;;
    R1-A2|R1-A3) suite_has_rule long_context '(^|,)lc\.context(,|$)' ;;
    R1-A4) suite_has_rule long_context '(^|,)lc\.billing(,|$)' ;;
    R1-M*) suite_has_rule migration '(^|,)mig\.schema(,|$)' ;;
    R1-B1) suite_has_rule vision_media '(^|,)vm\.' ;;
    R1-B2) suite_has_rule vision_media '(^|,)vm\.(bridge|grok_media)(,|$)' && inventory_has_feature vision ;;
    R1-B3) suite_has_rule vision_media '(^|,)vm\.grok_media(,|$)' && inventory_has_feature composer ;;
    R1-B4) suite_has_rule vision_media '(^|,)vm\.generation(,|$)' && inventory_has_feature image_generation ;;
    R1-C*) suite_has_rule grok_tools '(^|,)gt\.tools(,|$)' ;;
    R1-D1) suite_has_rule model_switch '(^|,)ms\.routing(,|$)' && inventory_has_feature model_switch ;;
    R1-D2) suite_has_rule model_switch '(^|,)ms\.effort(,|$)' && inventory_has_feature sharedchat ;;
    R1-D3) suite_has_rule model_switch '(^|,)ms\.routing(,|$)' ;;
    R1-E*) suite_has_rule streaming '(^|,)st\.stream(,|$)' ;;
    R1-F1) suite_has_rule codex_sharedchat '(^|,)cs\.gateway(,|$)' && inventory_has_feature codex ;;
    R1-F2) suite_has_rule codex_sharedchat '(^|,)cs\.passthrough(,|$)' && inventory_has_feature sharedchat ;;
    R1-F3) suite_has_rule codex_sharedchat '(^|,)cs\.probe(,|$)' ;;
    R1-G1) suite_has_rule error_policy '(^|,)ep\.error(,|$)' ;;
    R1-G2) suite_has_rule error_policy '(^|,)ep\.retry(,|$)' ;;
    R1-H1|R1-H2) suite_has_rule scheduling '(^|,)sch\.sticky_pool(,|$)' ;;
    R1-H3) suite_has_rule scheduling '(^|,)sch\.cache(,|$)' ;;
    R1-I1) suite_has_rule billing_background '(^|,)bb\.usage(,|$)' ;;
    R1-I2) suite_has_rule billing_background '(^|,)bb\.oauth_refresh(,|$)' && inventory_has_feature oauth_refresh ;;
    R1-I3) suite_has_rule billing_background '(^|,)bb\.probe(,|$)' ;;
    R1-J1) suite_has_rule frontend '(^|,)fe\.frontend(,|$)' ;;
    R2-1) suite_has_rule auth '(^|,)au\.auth(,|$)' ;;
    R2-2) suite_has_rule deployment '(^|,)dep\.release(,|$)' ;;
    R2-3) suite_has_rule provider_extended '(^|,)px\.provider(,|$)' && inventory_has_provider_hit ;;
    *) return 1 ;;
  esac
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
      --permanent-canaries)
        PERMANENT_CANARIES=1
        ;;
      --active-inventory)
        (( $# >= 2 )) || die "--active-inventory requires a value"
        ACTIVE_INVENTORY="$2"
        shift
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

load_active_inventory() {
  [[ -n "$ACTIVE_INVENTORY" ]] || return 0
  [[ "$ACTIVE_INVENTORY" == /* ]] || die "active inventory path must be absolute"
  [[ -f "$ACTIVE_INVENTORY" && ! -L "$ACTIVE_INVENTORY" ]] \
    || die "active inventory must be a regular non-symlink file"
  ACTIVE_INVENTORY="$(realpath -e "$ACTIVE_INVENTORY")" \
    || die "active inventory is not resolvable"
  jq -e '
    type == "object"
    and ((keys - ["environment", "features", "notes", "observed_at", "providers", "schema_version", "source"]) | length == 0)
    and .schema_version == 1
    and .environment == "production"
    and (.observed_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.source | type == "string" and length >= 3)
    and (.providers | type == "array" and all(.[]; type == "string" and test("^[a-z0-9_]+$")))
    and (.features | type == "array" and all(.[]; type == "string" and test("^[a-z0-9_]+$")))
    and ((.notes // []) | type == "array" and all(.[]; type == "string"))
    and ((.providers | unique | length) == (.providers | length))
    and ((.features | unique | length) == (.features | length))
  ' "$ACTIVE_INVENTORY" >/dev/null || die "active inventory schema is invalid or contains unsupported fields"
  INVENTORY_PRESENT=1
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
  require_command sha256sum

  [[ -d "$REPO/.git" ]] || die "repository is missing: $REPO"
  [[ -f "$MATRIX_FILE" ]] || die "matrix catalog is missing: $MATRIX_FILE"
  [[ "$RUNNING_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "running revision must be a lowercase 40-character SHA"
  [[ "$CANDIDATE_REVISION" =~ ^[0-9a-f]{40}$ ]] || die "candidate revision must be a lowercase 40-character SHA"
  if [[ -n "$EVIDENCE_ROOT" ]]; then
    [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]] || die "--evidence-root requires SUB2API_UPGRADE_TEST_MODE=1"
    [[ -n "$OUTPUT_DIR" ]] || die "--evidence-root requires --output-dir"
  fi
  load_active_inventory

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
  local -a upstream_files=()
  local -a running_custom_files=()
  local -a custom_files=()
  local changed_output upstream_output running_custom_output custom_output
  changed_output="$(git -C "$REPO" diff --name-only "$running_sha" "$candidate_sha" | sort -u)" \
    || die "failed to list the production-to-candidate diff"
  upstream_output="$(git -C "$REPO" diff --name-only "$running_base" "$candidate_base" | sort -u)" \
    || die "failed to list the upstream baseline diff"
  running_custom_output="$(git -C "$REPO" diff --name-only "$running_base" "$running_sha" | sort -u)" \
    || die "failed to list the running customization diff"
  custom_output="$(git -C "$REPO" diff --name-only "$candidate_base" "$candidate_sha" | sort -u)" \
    || die "failed to list the candidate customization diff"
  if [[ -n "$changed_output" ]]; then
    mapfile -t changed_files <<<"$changed_output"
  fi
  if [[ -n "$custom_output" ]]; then
    mapfile -t custom_files <<<"$custom_output"
  fi
  if [[ -n "$upstream_output" ]]; then
    mapfile -t upstream_files <<<"$upstream_output"
  fi
  if [[ -n "$running_custom_output" ]]; then
    mapfile -t running_custom_files <<<"$running_custom_output"
  fi

  declare -gA TRIGGERED_SUITES=()
  declare -gA SELECTED_SUITES=()
  declare -gA FORCED_SUITES=()
  declare -gA SUITE_SOURCES=()
  declare -gA SUITE_RULES=()
  declare -gA ACTIVE_PROVIDER_HITS=()
  declare -ga TRIGGER_EVENTS=()

  select_suite core r0_default
  FORCED_SUITES[core]=1
  local path suite
  for path in "${upstream_files[@]}"; do
    [[ -n "$path" ]] && classify_path "$path" upstream
  done
  for path in "${running_custom_files[@]}"; do
    [[ -n "$path" ]] && classify_path "$path" running_customization
  done
  for path in "${custom_files[@]}"; do
    [[ -n "$path" ]] && classify_path "$path" customization
  done
  for suite in "${REQUESTED_SUITES[@]}"; do
    select_suite "$suite" requested
    FORCED_SUITES["$suite"]=1
  done

  if (( PERMANENT_CANARIES == 1 )); then
    for suite in long_context vision_media model_switch; do
      select_suite "$suite" legacy_permanent
      FORCED_SUITES["$suite"]=1
    done
  fi

  if (( ALL_SUITES == 1 )); then
    while IFS=$'\t' read -r _ suite _; do
      if [[ "$suite" != "suite" && -n "$suite" ]]; then
        select_suite "$suite" all_suites
        FORCED_SUITES["$suite"]=1
      fi
    done < "$MATRIX_FILE"
  fi

  local -a case_lines=()
  local -a skipped_case_lines=()
  local id level executor description assertion
  while IFS=$'\t' read -r id suite level executor description assertion; do
    [[ "$id" == "id" || -z "$id" ]] && continue
    local selected=0 sources rules skip_reason skip_detail
    sources="${SUITE_SOURCES[$suite]-}"
    rules="${SUITE_RULES[$suite]-}"
    skip_reason="suite_not_triggered"
    skip_detail="no implementation/config path or explicit override selected this suite"
    if [[ "$level" == "R0" || -n "${FORCED_SUITES[$suite]+forced}" ]]; then
      selected=1
      [[ -n "$sources" ]] || sources="r0_default"
      [[ -n "$rules" ]] || rules="r0"
    elif [[ -n "${TRIGGERED_SUITES[$suite]+triggered}" ]]; then
      if case_path_triggered "$id"; then
        selected=1
      else
        skip_reason="case_rule_or_active_capability_not_met"
        skip_detail="suite was triggered, but this case's path rule or production capability was not"
      fi
    fi
    if (( selected == 1 )); then
      SELECTED_SUITES["$suite"]=1
      case_lines+=("$id"$'\t'"$suite"$'\t'"$level"$'\t'"$executor"$'\t'"$description"$'\t'"$assertion"$'\t'"$sources"$'\t'"$rules")
    else
      skipped_case_lines+=("$id"$'\t'"$suite"$'\t'"$skip_reason"$'\t'"$skip_detail")
    fi
  done < "$MATRIX_FILE"

  local -a selected_suites=()
  local -a triggered_suites=()
  mapfile -t selected_suites < <(printf '%s\n' "${!SELECTED_SUITES[@]}" | sort)
  mapfile -t triggered_suites < <(printf '%s\n' "${!TRIGGERED_SUITES[@]}" | sort)

  local suites_json triggered_suites_json changed_json upstream_json running_custom_json custom_json
  local cases_json skipped_cases_json triggers_json suite_sources_json inventory_json
  suites_json="$(json_string_array "${selected_suites[@]}")"
  triggered_suites_json="$(json_string_array "${triggered_suites[@]}")"
  changed_json="$(json_string_array "${changed_files[@]}")"
  upstream_json="$(json_string_array "${upstream_files[@]}")"
  running_custom_json="$(json_string_array "${running_custom_files[@]}")"
  custom_json="$(json_string_array "${custom_files[@]}")"
  if (( ${#case_lines[@]} == 0 )); then
    cases_json='[]'
  else
    cases_json="$(
      printf '%s\n' "${case_lines[@]}" | jq -Rn '
        [inputs | split("\t") | {
          id: .[0], suite: .[1], level: .[2], executor: .[3],
          description: .[4], assertion: .[5],
          selection: {
            sources: (.[6] | split(",") | map(select(length > 0))),
            rules: (.[7] | split(",") | map(select(length > 0)))
          }
        }]'
    )"
  fi
  if (( ${#skipped_case_lines[@]} == 0 )); then
    skipped_cases_json='[]'
  else
    skipped_cases_json="$(printf '%s\n' "${skipped_case_lines[@]}" | jq -Rn '
      [inputs | split("\t") | {id: .[0], suite: .[1], reason: .[2], detail: .[3]}]')"
  fi
  if (( ${#TRIGGER_EVENTS[@]} == 0 )); then
    triggers_json='[]'
  else
    triggers_json="$(printf '%s\n' "${TRIGGER_EVENTS[@]}" | jq -Rn '
      [inputs | split("\t") | {
        source: .[0], suite: .[1], path: .[2], rule_id: .[3], confidence: .[4]
      }] | unique_by([.source, .suite, .path, .rule_id])')"
  fi
  suite_sources_json="$({
    for suite in "${!SUITE_SOURCES[@]}"; do
      printf '%s\t%s\n' "$suite" "${SUITE_SOURCES[$suite]}"
    done
  } | sort | jq -Rn 'reduce inputs as $line ({};
    ($line | split("\t")) as $parts |
    .[$parts[0]] = ($parts[1] | split(",") | map(select(length > 0))))')"
  if (( INVENTORY_PRESENT == 1 )); then
    inventory_json="$(jq --arg sha256 "$(sha256sum "$ACTIVE_INVENTORY" | cut -d' ' -f1)" '
      {present: true, sha256: $sha256, environment, observed_at, source, providers, features, notes: (.notes // [])}
    ' "$ACTIVE_INVENTORY")"
  else
    inventory_json='{"present":false,"providers":[],"features":[],"notes":[]}'
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
    --argjson triggered_suites "$triggered_suites_json" \
    --argjson changed_files "$changed_json" \
    --argjson upstream_files "$upstream_json" \
    --argjson running_customization_files "$running_custom_json" \
    --argjson customization_files "$custom_json" \
    --argjson cases "$cases_json" \
    --argjson triggers "$triggers_json" \
    --argjson suite_sources "$suite_sources_json" \
    --argjson skipped_cases "$skipped_cases_json" \
    --argjson active_inventory "$inventory_json" \
    --argjson permanent_canaries "$PERMANENT_CANARIES" \
    --argjson all_suites "$ALL_SUITES" \
    '{
      generated_at: $generated_at,
      repository: $repo,
      running: {revision: $running_revision, version: $running_version, upstream_base: $running_upstream_base},
      candidate: {revision: $candidate_revision, version: $candidate_version, upstream_base: $candidate_upstream_base},
      upstream: {ref: $upstream_ref, revision: $upstream_revision},
      baseline_gate: "passed",
      selected_suites: $selected_suites,
      changed_files: $changed_files,
      upstream_files: $upstream_files,
      running_customization_files: $running_customization_files,
      customization_files: $customization_files,
      cases: $cases,
      selection: {
        policy: {
          default: "r0_only",
          path_sources: ["upstream", "running_customization", "customization"],
          total_diff_selects_cases: false,
          test_only_paths_select_runtime_cases: false,
          permanent_canaries: ($permanent_canaries == 1),
          all_suites: ($all_suites == 1)
        },
        triggered_suites: $triggered_suites,
        suite_sources: $suite_sources,
        triggers: $triggers,
        skipped_cases: $skipped_cases,
        active_inventory: $active_inventory,
        counts: {
          total_files: ($changed_files | length),
          upstream_files: ($upstream_files | length),
          running_customization_files: ($running_customization_files | length),
          customization_files: ($customization_files | length),
          triggered_suites: ($triggered_suites | length),
          selected_suites: ($selected_suites | length),
          selected_cases: ($cases | length),
          skipped_cases: ($skipped_cases | length)
        }
      }
    }')"

  if [[ -n "$OUTPUT_DIR" ]]; then
    prepare_evidence_output_dir "$OUTPUT_DIR"
    printf '%s\n' 'sub2api-upgrade-evidence-v1' > "$OUTPUT_DIR/.owner"
    printf '%s\n' "$plan_json" > "$OUTPUT_DIR/plan.json"
    printf '%s\n' "${changed_files[@]}" > "$OUTPUT_DIR/changed-files.txt"
    printf '%s\n' "${upstream_files[@]}" > "$OUTPUT_DIR/upstream-files.txt"
    printf '%s\n' "${running_custom_files[@]}" > "$OUTPUT_DIR/running-customization-files.txt"
    printf '%s\n' "${custom_files[@]}" > "$OUTPUT_DIR/customization-files.txt"
    printf 'source\tsuite\tpath\trule_id\tconfidence\n' > "$OUTPUT_DIR/selection-triggers.tsv"
    if (( ${#TRIGGER_EVENTS[@]} > 0 )); then
      printf '%s\n' "${TRIGGER_EVENTS[@]}" >> "$OUTPUT_DIR/selection-triggers.tsv"
    fi
    printf 'case_id\tstatus\tstarted_at\tended_at\tevidence\tnote\n' > "$OUTPUT_DIR/results.tsv"
    cat > "$OUTPUT_DIR/manifest.env" <<EOF
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
running_revision=$running_sha
candidate_revision=$candidate_sha
running_upstream_base=$running_base
candidate_upstream_base=$candidate_base
running_version=$running_version
candidate_version=$candidate_version
evidence_epoch=2
status=planned
EOF
    chmod 0600 "$OUTPUT_DIR/.owner" "$OUTPUT_DIR/plan.json" "$OUTPUT_DIR/changed-files.txt" \
      "$OUTPUT_DIR/upstream-files.txt" "$OUTPUT_DIR/running-customization-files.txt" \
      "$OUTPUT_DIR/customization-files.txt" "$OUTPUT_DIR/selection-triggers.tsv" \
      "$OUTPUT_DIR/results.tsv" "$OUTPUT_DIR/manifest.env"
  fi

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    printf '%s\n' "$plan_json"
    return
  fi

  printf 'running=%s version=%s upstream_base=%s\n' "$running_sha" "$running_version" "$running_base"
  printf 'candidate=%s version=%s upstream_base=%s\n' "$candidate_sha" "$candidate_version" "$candidate_base"
  printf 'baseline_gate=passed changed_files=%s upstream_files=%s running_customization_files=%s customization_files=%s\n' \
    "${#changed_files[@]}" "${#upstream_files[@]}" "${#running_custom_files[@]}" "${#custom_files[@]}"
  printf 'selection_policy=r0_only permanent_canaries=%s active_inventory=%s skipped_cases=%s\n' \
    "$PERMANENT_CANARIES" "$INVENTORY_PRESENT" "${#skipped_case_lines[@]}"
  printf 'selected_suites=%s\n' "$(IFS=,; printf '%s' "${selected_suites[*]}")"
  printf 'selected_cases=%s\n' "${#case_lines[@]}"
  for path in "${case_lines[@]}"; do
    printf '  %s\n' "$(cut -f1-5 <<<"$path")"
  done
  if (( SHOW_FILES == 1 )); then
    printf 'changed_files:\n'
    printf '  %s\n' "${changed_files[@]}"
    printf 'upstream_files:\n'
    printf '  %s\n' "${upstream_files[@]}"
    printf 'running_customization_files:\n'
    printf '  %s\n' "${running_custom_files[@]}"
    printf 'customization_files:\n'
    printf '  %s\n' "${custom_files[@]}"
  fi
  [[ -z "$OUTPUT_DIR" ]] || printf 'evidence_dir=%s\n' "$OUTPUT_DIR"
}

main "$@"
