#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$(cd -- "$TESTS_DIR/.." && pwd -P)/update-sub2api.sh"

python3 - "$SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
errors = []

required = [
    "--promotion-run-id",
    "--verification-evidence",
    "verify-release-evidence.sh",
    "verify-promoted-image.sh",
    "verify_release_and_promotion",
    "check_remote_candidate_heads",
    "mine-sha-${EXPECTED_REVISION}@${EXPECTED_DIGEST}",
    "promotion-verification.json",
    "verification-release-evidence.json",
    "verification-adapter-catalog.tsv",
    "repo_digests_match",
    "prove_running_promoted_image",
    "rollback_image_safe",
    "SUCCESS_COMMIT_STARTED",
    "promotion source run does not match the sealed R0-1 workflow run",
    "copied verification input checksum changed",
    "evidence_source_run_id",
    "HOST_PROXY_NETWORK",
    "HOST_PROXY_IPV4",
    "HOST_PROXY_ENDPOINT",
    "HOST_PROXY_PORT",
    "recreate_application",
    'up --no-start --no-deps --force-recreate --pull never sub2api',
    'docker network connect --gw-priority -1 "$HOST_PROXY_NETWORK" "$container"',
    "container_has_host_proxy_network",
    "host_proxy_is_reachable",
    "NETWORK_ENTRYPOINT_FILE",
    'install -m 0700 "$NETWORK_ENTRYPOINT_FILE" "$RUN_DIR/network-entrypoint.sh"',
    "host_proxy_network_is_available_for",
    'command == ["/app/sub2api"]',
    "sub2api-host-proxy-gate-v2",
    "HOST_PROXY_ATTACH_TIMEOUT_SECONDS=25",
    "container_has_expected_process_spec",
    "container_host_proxy_ipv4",
    'docker network disconnect "$HOST_PROXY_NETWORK" "$container"',
    "APPLICATION_RECREATE_STARTED",
    "candidate_failed_before_recreate",
    "172.17.0.0/16",
    "172.17.0.1",
]
for needle in required:
    if needle not in text:
        errors.append(f"missing production evidence contract: {needle}")

for forbidden in [
    'CANDIDATE_IMAGE_REF="$APP_IMAGE_REPOSITORY:mine-${EXPECTED_REVISION:0:12}"',
    'candidate image is not labeled mine',
    '--verification-evidence-sha256)',
    'up -d --no-deps --force-recreate sub2api',
]:
    if forbidden in text:
        errors.append(f"legacy production authority remains: {forbidden}")

main = text[text.find("main() {"):]
order = [
    main.find("check_source_baseline"),
    main.find("verify_release_and_promotion"),
    main.find("check_remote_candidate_heads"),
    main.find("pull_verified_candidate"),
    main.find("create_run"),
    main.find("create_database_dump"),
    main.find("ROLLOUT_STARTED=1"),
    main.find("verify_candidate_runtime"),
    main.find("ROLLOUT_COMPLETE=1"),
]
if min(order) < 0 or order != sorted(order):
    errors.append("main rollout order does not preserve evidence -> pull -> backup -> runtime -> completion gates")
if main.find('record status "passed_pending_finalization"') > main.find("ROLLOUT_COMPLETE=1"):
    errors.append("successful rollout status must be persisted before ROLLOUT_COMPLETE")

recreate = text[text.find("recreate_application() {"):text.find("last_manifest_value() {")]
recreate_order = [
    recreate.find("up --no-start"),
    recreate.find('container_has_expected_process_spec "$container"'),
    recreate.find("compose start sub2api"),
    recreate.find("docker network connect --gw-priority -1"),
    recreate.find("container_has_host_proxy_network", recreate.find("docker network connect --gw-priority -1")),
    recreate.find('host_proxy_network_is_available_for "$container"', recreate.find("docker network connect --gw-priority -1")),
]
if min(recreate_order) < 0 or recreate_order != sorted(recreate_order):
    errors.append("application lifecycle must remain create -> process-spec check -> start gate -> live host-proxy connect -> exact-IP check")

running_guard = recreate.find('[[ "$status" == "running" ]] || return 1')
connect_index = recreate.find('docker network connect --gw-priority -1')
wrong_ip_guard = recreate.find('if [[ -n "$actual_ip" && "$actual_ip" != "$HOST_PROXY_IPV4" ]]')
disconnect_index = recreate.find('docker network disconnect "$HOST_PROXY_NETWORK" "$container"')
final_exact_check = recreate.find('if ! container_has_host_proxy_network "$container"; then', connect_index)
final_available_check = recreate.find('host_proxy_network_is_available_for "$container"', final_exact_check)
if not (recreate.find("compose start sub2api") < running_guard < connect_index):
    errors.append("live attach must refuse a non-running container")
if not (wrong_ip_guard < disconnect_index < connect_index):
    errors.append("an unexpected bridge IP must be disconnected before retrying live attach")
if not (connect_index < final_exact_check < final_available_check):
    errors.append("live attach must perform a final exact-IP and ownership check after the retry loop")

process_spec = text[text.find("container_has_expected_process_spec() {"):text.find("host_proxy_network_is_available_for() {")]
for needle in [
    '.[0].Config.Entrypoint == ["/app/network-entrypoint.sh"]',
    '.[0].Config.Cmd == ["/app/sub2api"]',
]:
    if needle not in process_spec:
        errors.append(f"runtime process-spec contract is incomplete: {needle}")

network_guard = text[text.find("container_has_host_proxy_network() {"):text.find("container_host_proxy_ipv4() {")]
for needle in [
    '.NetworkSettings.Networks[$network].IPAddress',
    '| . == $ipv4',
]:
    if needle not in network_guard:
        errors.append(f"exact bridge IP contract is incomplete: {needle}")

network_ownership = text[text.find("host_proxy_network_is_available_for() {"):text.find("host_proxy_is_reachable() {")]
for needle in [
    '($containers | length) == 0',
    '($containers | length) == 1 and $containers[0] == $container',
]:
    if needle not in network_ownership:
        errors.append(f"bridge ownership contract is incomplete: {needle}")

rollback = text[text.find("rollback_application() {"):text.find("handle_candidate_failure() {")]
if 'recreate_application "$ROLLBACK_TAG"' not in rollback:
    errors.append("rollback must use the same host-proxy-aware application lifecycle")

static_layout = text[text.find("check_static_layout() {"):text.find("collect_running_state() {")]
for needle in [
    "production host-proxy entrypoint gate is missing, linked, or not executable",
    'entrypoint == ["/app/network-entrypoint.sh"]',
    'command == ["/app/sub2api"]',
    'target == "/app/network-entrypoint.sh" and .read_only == true',
    '.services.sub2api.networks | keys == ["default"]',
    'any(.[0].IPAM.Config[]?;',
    '.Subnet == "172.17.0.0/16" and .Gateway == "172.17.0.1"',
    "sub2api-host-proxy-gate-v2",
    'grep -Fq "inet $HOST_PROXY_IPV4/16" "$NETWORK_ENTRYPOINT_FILE"',
]:
    if needle not in static_layout:
        errors.append(f"missing host-proxy entrypoint gate contract: {needle}")

on_exit = text[text.find("on_exit() {"):text.find("on_signal() {")]
if "APPLICATION_RECREATE_STARTED == 1" not in on_exit:
    errors.append("unexpected-exit rollback must be gated on an actual application recreate")

main_rollout = text[text.find("main() {"):]
if "APPLICATION_RECREATE_STARTED=0" not in main_rollout or "candidate_failed_before_recreate" not in main_rollout:
    errors.append("pre-recreate candidate failures must be recorded without triggering rollback")

if errors:
    for error in errors:
        print("FAIL:", error)
    raise SystemExit(1)
print("PASS: update-sub2api production evidence contract")
PY
