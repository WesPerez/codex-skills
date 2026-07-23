#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "$TESTS_DIR/common.sh"
CHECK="$SCRIPTS_DIR/check-debug-fixture-manifest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

make_valid_fixture "$TMP/good.json"
assert_ok "template-valid" bash "$CHECK" --manifest "$TMP/good.json"
assert_ok "json-out" bash "$CHECK" --manifest "$TMP/good.json" --json

cp "$TMP/good.json" "$TMP/good2.json"
assert_ok "compare-same" bash "$CHECK" --manifest "$TMP/good.json" --compare "$TMP/good2.json"

jq '.maps.header_overrides.field_set=["OnlyOne"]' "$TMP/good.json" > "$TMP/missing-map-field.json"
assert_fail "map-field-set-missing-compare" bash "$CHECK" --manifest "$TMP/good.json" --compare "$TMP/missing-map-field.json"

jq --arg h "$HEX64" '.objects[0].field_set_hash=$h' "$TMP/good.json" > "$TMP/wrong-field-hash.json"
assert_fail "field-set-hash-mismatch" bash "$CHECK" --manifest "$TMP/wrong-field-hash.json"

jq '.objects[0].field_set += ["new_field"]' "$TMP/good.json" > "$TMP/field-set-drift.json"
assert_fail "field-set-change-requires-new-hash" bash "$CHECK" --manifest "$TMP/field-set-drift.json"

jq '.api_token="x"' "$TMP/good.json" > "$TMP/secret-key.json"
assert_fail "secret-key" bash "$CHECK" --manifest "$TMP/secret-key.json"

jq '.maps.proxy.field_set=["host","password"]' "$TMP/good.json" > "$TMP/secret-field.json"
assert_fail "secret-field-set" bash "$CHECK" --manifest "$TMP/secret-field.json"

jq '.notes="postgres://fixture:cleartext-password@debug-db/example"' "$TMP/good.json" > "$TMP/secret-uri.json"
assert_fail "secret-uri-value" bash "$CHECK" --manifest "$TMP/secret-uri.json"

jq '.objects[1].stable_label=.objects[0].stable_label' "$TMP/good.json" > "$TMP/duplicate-label.json"
assert_fail "duplicate-object-label" bash "$CHECK" --manifest "$TMP/duplicate-label.json"

jq '.balances[0].max=0 | .balances[0].min=0' "$TMP/good.json" > "$TMP/bad-balance.json"
assert_fail "illegal-balance" bash "$CHECK" --manifest "$TMP/bad-balance.json"

jq '.synthetic_only=false' "$TMP/good.json" > "$TMP/not-synthetic.json"
assert_fail "synthetic-only" bash "$CHECK" --manifest "$TMP/not-synthetic.json"

jq '.oauth_refresh_owner="shared"' "$TMP/good.json" > "$TMP/bad-owner.json"
assert_fail "oauth-owner" bash "$CHECK" --manifest "$TMP/bad-owner.json"

summary
