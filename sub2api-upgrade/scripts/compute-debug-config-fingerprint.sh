#!/usr/bin/env bash
# Compute a stable, non-sensitive fingerprint for the persistent debug runtime.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEBUG_DIR="/root/sub2api-debug-deploy"
readonly COMPOSE_FILE="$DEBUG_DIR/docker-compose.yml"
readonly ENV_FILE="$DEBUG_DIR/.env"
readonly CONFIG_FILE="$DEBUG_DIR/data/sub2api/config.yaml"
readonly PG_VERSION_FILE="$DEBUG_DIR/data/postgres/PG_VERSION"
readonly ISOLATION_SCRIPT="$SCRIPT_DIR/check-debug-isolation.sh"

JSON_OUT=0

usage() {
  cat <<'USAGE'
Usage: compute-debug-config-fingerprint.sh [--json]

Hashes only stable, non-sensitive debug configuration structure. It never
prints .env/config values. Runtime health and fixture content are separate gates.
USAGE
}

die() { printf '%s\n' "[sub2api-debug-config] error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

while (( $# > 0 )); do
  case "$1" in
    --json) JSON_OUT=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

require_command jq
require_command sha256sum
require_command python3
require_command stat
[[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || die "debug compose file missing or unsafe"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || die "debug .env missing or unsafe"
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || die "debug config.yaml missing or unsafe"
[[ -f "$PG_VERSION_FILE" && ! -L "$PG_VERSION_FILE" ]] || die "debug PG_VERSION missing or unsafe"
[[ -f "$ISOLATION_SCRIPT" ]] || die "debug isolation verifier missing"

isolation_json="$(bash "$ISOLATION_SCRIPT")" || die "debug isolation check failed"
stable_isolation="$(jq -cS 'del(.checked_at, .application_state)' <<<"$isolation_json")"
compose_sha="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"
pg_version="$(tr -d '[:space:]' < "$PG_VERSION_FILE")"
[[ "$pg_version" =~ ^[0-9]+$ ]] || die "invalid debug PostgreSQL version marker"
config_mode="$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || stat -f '%OLp' "$CONFIG_FILE")"

env_keys_json="$(python3 - "$ENV_FILE" <<'PY'
import json
import re
import sys

keys = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = re.match(r"(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
    if not match:
        raise SystemExit("invalid .env assignment shape")
    keys.append(match.group(1))
if len(keys) != len(set(keys)):
    raise SystemExit("duplicate .env key")
print(json.dumps(sorted(keys), separators=(",", ":")))
PY
)" || die "could not derive debug .env key set"

config_paths_json="$(python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML unavailable: {exc}")

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(data, dict):
    raise SystemExit("config root must be a mapping")

paths = []
def visit(value, prefix=""):
    if isinstance(value, dict):
        for key in sorted(value):
            path = f"{prefix}.{key}" if prefix else str(key)
            paths.append(path)
            visit(value[key], path)
    elif isinstance(value, list):
        paths.append(prefix + "[]")

visit(data)
print(json.dumps(paths, separators=(",", ":")))
PY
)" || die "could not derive debug config key paths"

env_keyset_sha="$(printf '%s\n' "$env_keys_json" | sha256sum | awk '{print $1}')"
config_keypaths_sha="$(printf '%s\n' "$config_paths_json" | sha256sum | awk '{print $1}')"
canonical="$(jq -cS -n \
  --argjson isolation "$stable_isolation" \
  --arg compose_sha256 "$compose_sha" \
  --arg env_keyset_sha256 "$env_keyset_sha" \
  --arg config_keypaths_sha256 "$config_keypaths_sha" \
  --arg config_mode "$config_mode" \
  --arg pg_version "$pg_version" \
  '{schema_version:1,isolation:$isolation,compose_sha256:$compose_sha256,
    env_keyset_sha256:$env_keyset_sha256,config_keypaths_sha256:$config_keypaths_sha256,
    config_mode:$config_mode,pg_version:$pg_version}')"
fingerprint="$(printf '%s\n' "$canonical" | sha256sum | awk '{print $1}')"

if (( JSON_OUT == 1 )); then
  jq -n --arg status ok --arg fingerprint "$fingerprint" --argjson components "$canonical" \
    '{status:$status,fingerprint:$fingerprint,components:$components}'
else
  printf 'status=ok fingerprint=%s\n' "$fingerprint"
fi
