#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$(cd -- "$TESTS_DIR/.." && pwd -P)/finalize-sub2api-upgrade.sh"

python3 - "$SCRIPT" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = [
    "candidate_image_id",
    "expected_digest",
    "production image id differs from finalized candidate",
    "production digest differs from finalized candidate",
    "verification-release-evidence.json",
    "verification-adapter-catalog.tsv",
    "adapter_catalog_sha256",
    "adapter_bundle_sha256",
    "promotion source run differs from the sealed R0-1 workflow run",
    "recorded-hash-production-apply-verifies-local-file",
    "promotion-verification.json",
    "promotion_verification_sha256",
    '.image.ref_name=="debug"',
    "run promotion verification no longer matches production",
]
missing = [item for item in required if item not in text]
if missing:
    for item in missing:
        print("FAIL: finalize missing evidence gate", item)
    raise SystemExit(1)

evidence_gate = text.find("run promotion verification no longer matches production")
rollback_release = text.find('docker image rm "$rollback_tag"')
if min(evidence_gate, rollback_release) < 0 or evidence_gate > rollback_release:
    print("FAIL: finalize releases rollback tag before digest/evidence verification")
    raise SystemExit(1)
print("PASS: finalize digest/evidence contract")
PY
