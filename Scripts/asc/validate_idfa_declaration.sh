#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd curl
require_cmd jq

version_id="${1:-}"
[[ -n "$version_id" ]] || die "usage: $0 VERSION_ID"

desired_uses_idfa="$(json_string "$ASC_APP_METADATA" '.usesIdfa | if type == "boolean" then tostring else empty end')"
desired_uses_idfa="${desired_uses_idfa:-false}"

case "$desired_uses_idfa" in
  true|false) ;;
  *) die "usesIdfa must be true or false, got $desired_uses_idfa" ;;
esac

versions_update_help="$(asc versions update --help 2>&1 || true)"
if [[ "$versions_update_help" == *"--uses-idfa"* ]]; then
  log "setting usesIdfa=$desired_uses_idfa with asc versions update"
  asc versions update \
    --version-id "$version_id" \
    --uses-idfa="$desired_uses_idfa" \
    --output json >/dev/null
  exit 0
fi

schema_json="$(asc schema --method PATCH appStoreVersions)"
jq -e '
  any(.[]; .path == "/v1/appStoreVersions/{id}" and (.requestAttributes.usesIdfa == "boolean"))
' <<<"$schema_json" >/dev/null \
  || die "asc schema does not expose an official usesIdfa App Store version update field"

log "setting usesIdfa=$desired_uses_idfa with the official App Store Connect API"
token="$(asc auth token --confirm)"
request_body="$(jq -n \
  --arg id "$version_id" \
  --argjson usesIdfa "$desired_uses_idfa" \
  '{
    data: {
      type: "appStoreVersions",
      id: $id,
      attributes: {
        usesIdfa: $usesIdfa
      }
    }
  }')"

response="$(curl -fsS \
  -X PATCH \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  -d "$request_body" \
  "https://api.appstoreconnect.apple.com/v1/appStoreVersions/$version_id")"

actual_uses_idfa="$(jq -r '.data.attributes.usesIdfa // empty' <<<"$response")"
[[ "$actual_uses_idfa" == "$desired_uses_idfa" ]] \
  || die "App Store Connect returned usesIdfa=$actual_uses_idfa after setting $desired_uses_idfa"
