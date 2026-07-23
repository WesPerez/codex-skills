#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly DEFAULT_DEBUG_DIR="/root/sub2api-debug-deploy"
readonly DEFAULT_PROD_DIR="/root/sub2api-prod-deploy"
readonly DEFAULT_ISOLATION_SCRIPT="$SCRIPT_DIR/check-debug-isolation.sh"
readonly OWNER_MARK="sub2api-debug-pg-snapshot-v1"
readonly SNAPSHOT_ROOT="/root/backups/sub2api/debug-snapshots"

APPLY=0
TEST_MODE=0
DEBUG_DIR="$DEFAULT_DEBUG_DIR"
PROD_DIR="$DEFAULT_PROD_DIR"
ISOLATION_SCRIPT="$DEFAULT_ISOLATION_SCRIPT"
TARGET_DIR=""
COMPOSE_BIN="docker"

usage() {
  cat <<'USAGE'
Usage:
  snapshot-debug-postgres.sh --target-dir <new-dir> [--apply]
    [--debug-dir <path>] [--prod-dir <path>] [--isolation-script <path>]
    [--test-mode]

Default is dry-run. --apply creates a PostgreSQL custom-format dump from the
debug compose postgres service only after isolation and health checks pass.
Outside test mode, target must be one new direct child of
/root/backups/sub2api/debug-snapshots. Never restores, deletes, prunes, touches
Redis, or touches production.
USAGE
}

info() { printf '%s\n' "[sub2api-debug-snapshot] $*" >&2; }
die() { printf '%s\n' "[sub2api-debug-snapshot] error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"; }

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --target-dir) (( $# >= 2 )) || die "--target-dir requires a value"; TARGET_DIR="$2"; shift ;;
      --debug-dir) (( $# >= 2 )) || die "--debug-dir requires a value"; DEBUG_DIR="$2"; shift ;;
      --prod-dir) (( $# >= 2 )) || die "--prod-dir requires a value"; PROD_DIR="$2"; shift ;;
      --isolation-script) (( $# >= 2 )) || die "--isolation-script requires a value"; ISOLATION_SCRIPT="$2"; shift ;;
      --apply) APPLY=1 ;;
      --test-mode) TEST_MODE=1 ;;
      --help|-h) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
}

path_mentions_prod() {
  local p="$1"
  [[ "$p" != *prod* && "$p" != *PROD* && "$p" != *production* && "$p" != *Production* ]] || return 0
  return 1
}

assert_safe_paths() {
  [[ -n "$TARGET_DIR" ]] || die "--target-dir is required"
  [[ "$TARGET_DIR" != *$'\n'* && "$TARGET_DIR" != *$'\r'* ]] || die "target directory contains a newline"
  [[ ! -e "$TARGET_DIR" ]] || die "target directory already exists: $TARGET_DIR"

  if (( TEST_MODE == 0 )); then
    [[ "$DEBUG_DIR" == "$DEFAULT_DEBUG_DIR" ]] || die "debug-dir override requires --test-mode"
    [[ "$PROD_DIR" == "$DEFAULT_PROD_DIR" ]] || die "prod-dir override requires --test-mode"
    [[ "$ISOLATION_SCRIPT" == "$DEFAULT_ISOLATION_SCRIPT" ]] || die "isolation-script override requires --test-mode"
  else
    [[ "${SUB2API_UPGRADE_TEST_MODE:-}" == "1" ]] || die "--test-mode requires SUB2API_UPGRADE_TEST_MODE=1"
    path_mentions_prod "$DEBUG_DIR" && die "test-mode debug-dir must not contain prod string"
    path_mentions_prod "$TARGET_DIR" && die "test-mode target-dir must not contain prod string"
    path_mentions_prod "$ISOLATION_SCRIPT" && die "test-mode isolation-script path must not contain prod string"
  fi

  local debug_real prod_real target_parent target_real snapshot_root_real
  [[ -d "$DEBUG_DIR" ]] || die "debug directory missing: $DEBUG_DIR"
  debug_real="$(realpath -e "$DEBUG_DIR")"
  [[ -d "$PROD_DIR" ]] || die "production directory identity unknown: $PROD_DIR"
  prod_real="$(realpath -e "$PROD_DIR")"
  [[ "$debug_real" != "$prod_real" && "$debug_real" != "$prod_real"/* && "$prod_real" != "$debug_real"/* ]] \
    || die "debug and production paths overlap"

  target_parent="$(dirname -- "$TARGET_DIR")"
  target_real="$(realpath -m "$TARGET_DIR")"
  [[ "$target_real" != "$prod_real" && "$target_real" != "$prod_real"/* ]] || die "target overlaps production"
  [[ "$target_real" != "$debug_real" && "$target_real" != "$debug_real"/* ]] || die "target must not be inside debug data tree"
  if (( TEST_MODE == 0 )); then
    snapshot_root_real="$(realpath -m "$SNAPSHOT_ROOT")"
    [[ "$snapshot_root_real" == "$SNAPSHOT_ROOT" ]] || die "snapshot root resolves outside its canonical path"
    [[ "$target_parent" == "$SNAPSHOT_ROOT" && "$target_real" == "$SNAPSHOT_ROOT"/* ]] \
      || die "target must be a direct child of $SNAPSHOT_ROOT"
    if [[ -e "$SNAPSHOT_ROOT" ]]; then
      [[ -d "$SNAPSHOT_ROOT" && ! -L "$SNAPSHOT_ROOT" ]] || die "snapshot root must be a non-symlink directory"
    fi
  else
    [[ "$debug_real" == /tmp/* && "$target_real" == /tmp/* ]] \
      || die "test-mode paths must resolve below /tmp"
    [[ -d "$target_parent" ]] || die "test-mode target parent directory missing: $target_parent"
  fi
}

run_isolation_check() {
  [[ -x "$ISOLATION_SCRIPT" || -f "$ISOLATION_SCRIPT" ]] || die "isolation script missing: $ISOLATION_SCRIPT"
  if (( TEST_MODE == 1 )); then
    # shellcheck disable=SC1090
    bash "$ISOLATION_SCRIPT" || die "isolation check failed"
  else
    bash "$ISOLATION_SCRIPT" || die "isolation check failed"
  fi
}

compose() {
  "$COMPOSE_BIN" compose --project-directory "$DEBUG_DIR" -f "$DEBUG_DIR/docker-compose.yml" "$@"
}

assert_debug_postgres_healthy() {
  require_command docker
  local cid health
  cid="$(compose ps -q postgres 2>/dev/null || true)"
  [[ -n "$cid" ]] || die "debug postgres container is not running"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
  [[ "$health" == "healthy" || "$health" == "running" ]] || die "debug postgres is not healthy: ${health:-unknown}"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)"
  [[ "$running" == "true" ]] || die "debug postgres is not running"
}

dry_run_report() {
  info "dry-run: would create owner directory $TARGET_DIR"
  info "dry-run: would run: docker compose exec -T postgres sh -ec pg_dump -Fc (user/db from container env)"
  info "dry-run: would write postgres.dump.partial, verify size>1KB, sha256, atomic mv to postgres.dump"
  printf 'status=dry_run target=%s apply=0\n' "$TARGET_DIR"
}

apply_snapshot() {
  require_command sha256sum; require_command install; require_command stat; require_command mv
  run_isolation_check
  assert_debug_postgres_healthy

  if (( TEST_MODE == 0 )); then
    install -d -m 0700 "$SNAPSHOT_ROOT"
    [[ "$(realpath -e "$SNAPSHOT_ROOT")" == "$SNAPSHOT_ROOT" && ! -L "$SNAPSHOT_ROOT" ]] \
      || die "snapshot root identity changed before write"
  fi
  install -d -m 0700 "$TARGET_DIR"
  printf '%s\n' "$OWNER_MARK" > "$TARGET_DIR/.owner"
  chmod 0600 "$TARGET_DIR/.owner"

  local partial="$TARGET_DIR/postgres.dump.partial"
  local final="$TARGET_DIR/postgres.dump"
  local manifest="$TARGET_DIR/manifest.env"
  : > "$manifest"; chmod 0600 "$manifest"
  {
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'debug_dir=%s\n' "$(realpath -e "$DEBUG_DIR")"
    printf 'status=dump_pending\n'
  } >> "$manifest"

  info "creating debug PostgreSQL custom-format snapshot"
  if ! compose exec -T postgres sh -ec 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$partial"; then
    rm -f -- "$partial"
    printf 'status=dump_failed\n' >> "$manifest"
    die "pg_dump failed; partial removed; target dir retained for investigation"
  fi
  if [[ ! -s "$partial" ]]; then
    rm -f -- "$partial"
    printf 'status=dump_failed_empty\n' >> "$manifest"
    die "pg_dump produced empty output"
  fi
  local size
  size="$(stat -c '%s' "$partial")"
  if (( size <= 1024 )); then
    rm -f -- "$partial"
    printf 'status=dump_failed_small\n' >> "$manifest"
    die "pg_dump output unexpectedly small ($size bytes)"
  fi
  chmod 0600 "$partial"
  mv "$partial" "$final"
  chmod 0600 "$final"
  local sum
  sum="$(sha256sum "$final" | awk '{print $1}')"
  {
    printf 'database_dump=%s\n' "$final"
    printf 'database_dump_sha256=%s\n' "$sum"
    printf 'database_dump_bytes=%s\n' "$size"
    printf 'status=snapshot_complete\n'
  } >> "$manifest"
  info "snapshot complete sha256=$sum bytes=$size"
  printf 'status=snapshot_complete dump=%s sha256=%s bytes=%s\n' "$final" "$sum" "$size"
}

main() {
  parse_args "$@"
  require_command realpath; require_command date
  assert_safe_paths
  if (( APPLY == 0 )); then
    [[ -f "$ISOLATION_SCRIPT" ]] || die "isolation script missing: $ISOLATION_SCRIPT"
    bash "$ISOLATION_SCRIPT" >/dev/null || die "isolation check failed (dry-run)"
    dry_run_report
    return 0
  fi
  apply_snapshot
}

main "$@"
