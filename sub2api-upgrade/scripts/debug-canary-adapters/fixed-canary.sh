#!/usr/bin/env bash
# Dispatch only same-directory cases/<CASE_ID>.sh. No external paths.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly EC_FAILED=70
readonly EC_NEEDS_MANUAL=78
readonly EC_BLOCKED=71

die() { printf '%s\n' "[adapter-fixed-canary] error: $*" >&2; exit "$EC_BLOCKED"; }

[[ -n "${ADAPTER_CASE_ID:-}" ]] || die "ADAPTER_CASE_ID is required"
[[ "$ADAPTER_CASE_ID" =~ ^[A-Z0-9]+(-[A-Z0-9]+)*$ ]] || die "invalid case id"
[[ -n "${ADAPTER_EVIDENCE_OUT:-}" ]] || die "ADAPTER_EVIDENCE_OUT is required"

# Refuse any external path style arguments (adapters are env-only).
if (( $# > 0 )); then
  die "fixed-canary does not accept arguments"
fi

case_script="$SCRIPT_DIR/cases/${ADAPTER_CASE_ID}.sh"
# Hard guarantee: case script must resolve under SCRIPT_DIR/cases
case_real="$(realpath -m "$case_script")"
cases_root="$(realpath -m "$SCRIPT_DIR/cases")"
[[ "$case_real" == "$cases_root"/* ]] || die "case script escapes cases directory"

if [[ ! -f "$case_script" || -L "$case_script" ]]; then
  printf '%s\n' "[adapter-fixed-canary] no fixed case script for $ADAPTER_CASE_ID" >&2
  exit "$EC_NEEDS_MANUAL"
fi

bash "$case_script"
rc=$?
exit "$rc"
