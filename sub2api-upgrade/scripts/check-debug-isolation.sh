#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly DEBUG_DIR="/root/sub2api-debug-deploy"
readonly DEBUG_COMPOSE="$DEBUG_DIR/docker-compose.yml"
readonly PROD_DIR="/root/sub2api-prod-deploy"
readonly IMAGE_REPOSITORY="ghcr.io/wesperez/sub2api"
readonly DEFAULT_DEBUG_IMAGE="$IMAGE_REPOSITORY:debug"

usage() {
  cat <<'USAGE'
Usage:
  check-debug-isolation.sh

Performs a read-only fail-closed check of the persistent Sub2API debug Compose
layout. It does not start containers, read secret values, query PostgreSQL, or
modify files.
USAGE
}

die() {
  printf '%s\n' "[sub2api-debug-isolation] error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

compose() {
  docker compose --project-directory "$DEBUG_DIR" -f "$DEBUG_COMPOSE" "$@"
}

main() {
  [[ $# == 0 ]] || { usage >&2; exit 1; }
  require_command docker
  require_command jq
  require_command realpath
  require_command ss

  [[ -d "$DEBUG_DIR" ]] || die "debug deployment directory is missing: $DEBUG_DIR"
  [[ -f "$DEBUG_COMPOSE" ]] || die "debug Compose file is missing: $DEBUG_COMPOSE"
  [[ "$(realpath -e "$DEBUG_DIR")" == "$DEBUG_DIR" ]] || die "debug directory is not the expected canonical path"
  [[ -d "$PROD_DIR" && "$(realpath -e "$PROD_DIR")" == "$PROD_DIR" ]] || die "production directory identity is unknown"
  grep -Eq '^name:[[:space:]]*sub2api-debug[[:space:]]*$' "$DEBUG_COMPOSE" || die "Compose project is not sub2api-debug"
  compose config --quiet >/dev/null || die "debug Compose configuration is invalid"

  local config_json
  config_json="$(compose config --format json)"
  local configured_image
  configured_image="$(jq -r '.services.sub2api.image // ""' <<<"$config_json")"
  if [[ "$configured_image" != "$DEFAULT_DEBUG_IMAGE" \
    && ! "$configured_image" =~ ^ghcr\.io/wesperez/sub2api:debug-sha-[0-9a-f]{40}(@sha256:[0-9a-f]{64})?$ ]]; then
    die "debug application image must be :debug or an immutable debug-sha-<40sha> reference, got $configured_image"
  fi
  jq -e '.services.sub2api.restart == "no"' >/dev/null <<<"$config_json" \
    || die "debug application restart policy must be no"
  jq -e '.services.sub2api.labels["com.centurylinklabs.watchtower.enable"] == "false"' >/dev/null <<<"$config_json" \
    || die "debug application must disable Watchtower"

  local -a volume_sources=()
  local volume_output
  volume_output="$(jq -r '.services[]?.volumes[]? | select(.type == "bind") | .source' <<<"$config_json" | sort -u)" \
    || die "could not enumerate debug bind mounts"
  if [[ -n "$volume_output" ]]; then
    mapfile -t volume_sources <<<"$volume_output"
  fi
  local source canonical_source
  for source in "${volume_sources[@]}"; do
    canonical_source="$(realpath -m "$source")"
    [[ "$canonical_source" == "$DEBUG_DIR"/* ]] || die "debug bind mount escapes debug directory: $canonical_source"
    [[ "$canonical_source" != "$PROD_DIR" && "$canonical_source" != "$PROD_DIR"/* ]] \
      || die "debug bind mount overlaps production: $canonical_source"
  done

  jq -e --arg source "$DEBUG_DIR/data/sub2api" \
    'any(.services.sub2api.volumes[]?; .type == "bind" and .source == $source and .target == "/app/data")' \
    >/dev/null <<<"$config_json" || die "debug application data bind mount is missing"
  jq -e --arg source "$DEBUG_DIR/data/postgres" \
    'any(.services.postgres.volumes[]?; .type == "bind" and .source == $source and .target == "/var/lib/postgresql/data")' \
    >/dev/null <<<"$config_json" || die "debug PostgreSQL data bind mount is missing"
  jq -e --arg source "$DEBUG_DIR/data/redis" \
    'any(.services.redis.volumes[]?; .type == "bind" and .source == $source and .target == "/data")' \
    >/dev/null <<<"$config_json" || die "debug Redis data bind mount is missing"
  jq -e '[.networks[]? | select(.external == true)] | length == 0' >/dev/null <<<"$config_json" \
    || die "debug Compose must not join an external network"

  local data_path
  for data_path in "$DEBUG_DIR/data/sub2api" "$DEBUG_DIR/data/postgres" "$DEBUG_DIR/data/redis"; do
    [[ -d "$data_path" ]] || die "persistent debug data directory is missing: $data_path"
    [[ "$(realpath -e "$data_path")" == "$DEBUG_DIR"/* ]] || die "debug data path escapes its deployment root: $data_path"
  done
  [[ -f "$DEBUG_DIR/data/postgres/PG_VERSION" ]] || die "debug PostgreSQL version marker is missing"
  [[ "$(tr -d '[:space:]' < "$DEBUG_DIR/data/postgres/PG_VERSION")" == "18" ]] || die "unexpected debug PostgreSQL data version"

  local port_count host_ip published_port
  port_count="$(jq '[.services.sub2api.ports[]?] | length' <<<"$config_json")"
  [[ "$port_count" == "1" ]] || die "debug application must publish exactly one port"
  host_ip="$(jq -r '.services.sub2api.ports[0].host_ip // ""' <<<"$config_json")"
  published_port="$(jq -r '.services.sub2api.ports[0].published | tostring' <<<"$config_json")"
  [[ "$host_ip" == "127.0.0.1" ]] || die "debug port must bind loopback, got: $host_ip"
  [[ "$published_port" == "13081" || "$published_port" == "13180" ]] \
    || die "debug port must be the target 13081 or transitional 13180, got: $published_port"
  [[ "$published_port" != "13080" && "$published_port" != "13082" && "$published_port" != "13083" ]] \
    || die "debug port overlaps production or Router"

  local container_id state="stopped"
  container_id="$(compose ps -q sub2api 2>/dev/null || true)"
  if [[ -n "$container_id" ]]; then
    state="$(docker inspect -f '{{.State.Status}}' "$container_id")"
    if [[ "$state" == "running" ]]; then
      [[ "$(docker port "$container_id" 8080/tcp)" == "$host_ip:$published_port" ]] \
        || die "running debug container publishes an unexpected port"
    elif ! ss -ltnH "sport = :$published_port" | jq -Rs -e 'length == 0' >/dev/null; then
      die "debug port $published_port is occupied while the debug application is not running"
    fi
  elif ss -ltnH "sport = :$published_port" | jq -Rs -e 'length == 0' >/dev/null; then
    :
  else
    die "debug port $published_port is occupied by a non-debug listener"
  fi

  jq -n \
    --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "sub2api-debug" \
    --arg deploy_dir "$DEBUG_DIR" \
    --arg image "$configured_image" \
    --arg host_ip "$host_ip" \
    --argjson port "$published_port" \
    --arg state "$state" \
    --argjson persistent_data_dirs "$(printf '%s\n' "$DEBUG_DIR/data/sub2api" "$DEBUG_DIR/data/postgres" "$DEBUG_DIR/data/redis" | jq -R . | jq -s .)" \
    '{
      checked_at: $checked_at,
      isolated: true,
      project: $project,
      deploy_dir: $deploy_dir,
      configured_image: $image,
      endpoint: {host: $host_ip, port: $port},
      application_state: $state,
      persistent_data_dirs: $persistent_data_dirs
    }'
}

main "$@"
