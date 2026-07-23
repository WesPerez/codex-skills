#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_SCHEMA="$SCRIPT_DIR/../references/debug-fixture-manifest.schema.json"

MANIFEST=""
COMPARE_WITH=""
readonly SCHEMA_PATH="$DEFAULT_SCHEMA"
JSON_OUT=0

usage() {
  cat <<'USAGE'
Usage:
  check-debug-fixture-manifest.sh --manifest <path> [--compare <path>] [--json]

Validates a non-sensitive debug fixture manifest with jq. Never connects to a
database, never reads .env values, and never prints secret material.
USAGE
}

info() { printf '%s\n' "[sub2api-fixture] $*" >&2; }
die() { printf '%s\n' "[sub2api-fixture] error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --manifest) (( $# >= 2 )) || die "--manifest requires a value"; MANIFEST="$2"; shift ;;
      --compare) (( $# >= 2 )) || die "--compare requires a value"; COMPARE_WITH="$2"; shift ;;
      --json) JSON_OUT=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}

assert_json_file() {
  local path="$1"
  [[ -n "$path" && -f "$path" && -r "$path" ]] || die "file missing/unreadable: ${path:-<empty>}"
  jq -e . >/dev/null <"$path" || die "file is not valid JSON: $path"
}

reject_sensitive_keys() {
  local path="$1" hits field_hits
  hits="$(jq -r '
    def forbidden: test("(?i)(password|passwd|pwd|token|secret|authorization|cookie|credential|api[_-]?key|apikey|private[_-]?key|client[_-]?secret|connection[_-]?string|dsn|bearer)");
    def walk_keys($path):
      if type == "object" then
        to_entries[] |
          (if ($path|length) > 0 then ($path + "." + .key) else .key end) as $p |
          (if (.key|tostring|forbidden) then $p else empty end),
          (.value | walk_keys($p))
      elif type == "array" then .[] | walk_keys($path)
      else empty end;
    [walk_keys("")] | unique | .[]
  ' "$path" 2>/dev/null || true)"
  [[ -z "$hits" ]] || die "forbidden sensitive key/field name present"
  field_hits="$(jq -r '
    def forbidden: test("(?i)(password|passwd|pwd|token|secret|authorization|cookie|credential|api[_-]?key|apikey|private[_-]?key|client[_-]?secret|connection[_-]?string|dsn|bearer)");
    .. | objects | select(has("field_set")) | .field_set[]? | select(type=="string" and forbidden)
  ' "$path" 2>/dev/null || true)"
  [[ -z "$field_hits" ]] || die "forbidden sensitive field_set entry"
}

validate_structure() {
  local path="$1"
  jq -e '
    def is_hex64: type=="string" and test("^[0-9a-f]{64}$");
    def is_label: type=="string" and test("^[A-Za-z0-9._:-]+$");
    def is_field: type=="string" and test("^[A-Za-z0-9_.-]+$");
    def map_ok:
      type=="object"
      and (.field_set|type=="array" and length>=1)
      and all(.field_set[]; is_field)
      and ((.field_set|unique|length) == (.field_set|length))
      and (.field_set_hash|is_hex64);
    (type=="object")
    and ((keys - ["schema_version","synthetic_only","oauth_refresh_owner","fixture_version","last_verified_schema","objects","maps","balances","config_hash","notes"])|length==0)
    and (.schema_version == 1)
    and (.synthetic_only == true)
    and (.oauth_refresh_owner == "debug-only")
    and (.fixture_version|type=="string" and length>=1 and test("^[A-Za-z0-9._:-]+$"))
    and (.last_verified_schema|type=="string" and length>=1)
    and (.objects|type=="array" and length>=1)
    and all(.objects[];
        type=="object"
        and ((keys - ["kind","stable_label","field_set","field_set_hash"])|length==0)
        and (.kind|type=="string" and (IN("user","api_key","account","group","setting","pricing","other")))
        and (.stable_label|is_label)
        and (.field_set|type=="array" and length>=1)
        and all(.field_set[]; is_field)
        and ((.field_set|unique|length) == (.field_set|length))
        and (.field_set_hash|is_hex64))
    and (([.objects[].stable_label]|unique|length) == (.objects|length))
    and (.maps|type=="object")
    and ((.maps|keys|sort) == ["header_overrides","model_mapping","proxy"])
    and (.maps|has("header_overrides") and has("proxy") and has("model_mapping"))
    and (.maps.header_overrides|map_ok)
    and (.maps.proxy|map_ok)
    and (.maps.model_mapping|map_ok)
    and (.balances|type=="array" and length>=1)
    and all(.balances[];
        type=="object"
        and ((keys - ["stable_label","min","max"])|length==0)
        and (.stable_label|is_label)
        and (.min|type=="number") and (.max|type=="number")
        and (.max >= .min) and (.max > 0))
    and (([.balances[].stable_label]|unique|length) == (.balances|length))
    and ((has("config_hash")|not) or (.config_hash|is_hex64))
    and ((has("notes")|not) or (.notes|type=="string"))
  ' "$path" >/dev/null || die "manifest structural validation failed: $path"
}

validate_field_set_hashes() {
  local path="$1"
  python3 - "$path" <<'PY'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)

descriptors = []
for index, item in enumerate(manifest.get("objects", [])):
    descriptors.append((f"objects[{index}]", item))
for name, item in (manifest.get("maps") or {}).items():
    descriptors.append((f"maps.{name}", item))

bad = []
for location, item in descriptors:
    canonical = json.dumps(sorted(item["field_set"]), ensure_ascii=True, separators=(",", ":")) + "\n"
    actual = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    if item.get("field_set_hash") != actual:
        bad.append(location)

if bad:
    print("field_set_hash mismatch at " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
}

canonical_fingerprint() {
  local path="$1"
  jq -cS '
    {
      schema_version, synthetic_only, oauth_refresh_owner, fixture_version, last_verified_schema,
      config_hash: (.config_hash // null),
      objects: (.objects | map({kind, stable_label, field_set: (.field_set|sort), field_set_hash}) | sort_by(.stable_label)),
      maps: {
        header_overrides: {field_set: (.maps.header_overrides.field_set|sort), field_set_hash: .maps.header_overrides.field_set_hash},
        proxy: {field_set: (.maps.proxy.field_set|sort), field_set_hash: .maps.proxy.field_set_hash},
        model_mapping: {field_set: (.maps.model_mapping.field_set|sort), field_set_hash: .maps.model_mapping.field_set_hash}
      },
      balances: (.balances | map({stable_label, min, max}) | sort_by(.stable_label))
    }
  ' "$path" | sha256sum | awk '{print $1}'
}

compare_manifests() {
  local left="$1" right="$2" left_fp right_fp missing
  left_fp="$(canonical_fingerprint "$left")"
  right_fp="$(canonical_fingerprint "$right")"
  missing="$(jq -n --argjson a "$(jq -c '.maps' "$left")" --argjson b "$(jq -c '.maps' "$right")" '
    def keys_of($m): $m | keys;
    (keys_of($a) - keys_of($b)) as $miss_b
    | (keys_of($b) - keys_of($a)) as $miss_a
    | {
        missing_in_right: $miss_b, missing_in_left: $miss_a,
        field_set_diffs: [keys_of($a)[] as $k
          | select(($b|has($k)))
          | select((($a[$k].field_set|sort) != ($b[$k].field_set|sort)) or ($a[$k].field_set_hash != $b[$k].field_set_hash))
          | $k]
      }
      | select((.missing_in_right|length)>0 or (.missing_in_left|length)>0 or (.field_set_diffs|length)>0)
  ' 2>/dev/null || true)"
  [[ -z "$missing" ]] || die "map field set mismatch between manifests"
  [[ "$left_fp" == "$right_fp" ]] || die "canonical fixture fingerprint mismatch"
}

main() {
  parse_args "$@"
  require_command jq; require_command sha256sum; require_command awk; require_command python3
  [[ -n "$MANIFEST" ]] || die "--manifest is required"
  assert_json_file "$MANIFEST"
  assert_json_file "$SCHEMA_PATH"
  reject_sensitive_keys "$MANIFEST"
  validate_structure "$MANIFEST"
  validate_field_set_hashes "$MANIFEST" || die "field_set_hash does not match canonical sorted field_set JSON"
  local secretish
  secretish="$(jq -r '
    .. | strings | select(test("(?i)(sk-[A-Za-z0-9]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\\.|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|(password|passwd|pwd|token|secret|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}|-----BEGIN[[:space:]][A-Z0-9 ]*PRIVATE KEY-----|[a-z]+://[^:/[:space:]]+:[^@[:space:]]+@)"))
  ' "$MANIFEST" 2>/dev/null || true)"
  [[ -z "$secretish" ]] || die "manifest contains secret-like string values; refuse to accept"
  if [[ -n "$COMPARE_WITH" ]]; then
    assert_json_file "$COMPARE_WITH"
    reject_sensitive_keys "$COMPARE_WITH"
    validate_structure "$COMPARE_WITH"
    validate_field_set_hashes "$COMPARE_WITH" || die "comparison field_set_hash does not match canonical sorted field_set JSON"
    compare_manifests "$MANIFEST" "$COMPARE_WITH"
  fi
  local fp size compare_path=""
  fp="$(canonical_fingerprint "$MANIFEST")"
  size="$(wc -c <"$MANIFEST" | tr -d '[:space:]')"
  if (( JSON_OUT == 1 )); then
    [[ -z "$COMPARE_WITH" ]] || compare_path="$(realpath -m "$COMPARE_WITH")"
    jq -n --arg status ok --arg manifest "$(realpath -m "$MANIFEST")" --arg schema "$(realpath -m "$SCHEMA_PATH")" \
      --arg fingerprint "$fp" --argjson bytes "$size" --arg compare "$compare_path" \
      '{status:$status,manifest:$manifest,schema:$schema,fingerprint:$fingerprint,bytes:$bytes,compare:(if $compare=="" then null else $compare end)}'
  else
    info "manifest ok fingerprint=$fp"
    printf 'status=ok fingerprint=%s\n' "$fp"
  fi
}

main "$@"
