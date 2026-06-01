#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd jq

platform="${1:-${PLATFORM:-IOS}}"
upload_screenshots="${2:-false}"
require_review_details="${3:-false}"
version="$(target_version)"
app_info_id="$(resolve_app_info_id "$platform")"

Scripts/asc/validate_localizations.sh

if [[ "$require_review_details" == "true" ]]; then
  Scripts/asc/validate_review_details.sh
fi

version_id="$(Scripts/asc/ensure_version.sh "$platform" "$version")"

ASC_APP_INFO_ID="$app_info_id" Scripts/asc/sync_app_metadata.sh "$version_id" "$require_review_details" "$platform"

log "uploading app-info localizations"
asc localizations upload \
  --app "$APP_ID" \
  --app-info "$app_info_id" \
  --type app-info \
  --path "$ASC_APP_INFO_DIR" \
  --output json

log "uploading version localizations for $platform $version ($version_id)"
asc localizations upload \
  --version "$version_id" \
  --path "$ASC_VERSION_DIR" \
  --output json

if [[ "$upload_screenshots" == "true" ]]; then
  Scripts/asc/upload_screenshots.sh "$platform" "$version"
else
  log "screenshot upload disabled for $platform"
fi
