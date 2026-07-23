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
]
for needle in required:
    if needle not in text:
        errors.append(f"missing production evidence contract: {needle}")

for forbidden in [
    'CANDIDATE_IMAGE_REF="$APP_IMAGE_REPOSITORY:mine-${EXPECTED_REVISION:0:12}"',
    'candidate image is not labeled mine',
    '--verification-evidence-sha256)',
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

if errors:
    for error in errors:
        print("FAIL:", error)
    raise SystemExit(1)
print("PASS: update-sub2api production evidence contract")
PY
