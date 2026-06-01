#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd jq

platform="${1:-${PLATFORM:-IOS}}"
build_id="${2:-${BUILD_ID:-}}"
version="$(target_version)"
version_id="$(Scripts/asc/ensure_version.sh "$platform" "$version")"

Scripts/asc/validate_idfa_declaration.sh "$version_id"

log "setting $platform $version release type to AFTER_APPROVAL"
asc versions update \
  --version-id "$version_id" \
  --release-type AFTER_APPROVAL \
  --output json >/dev/null

if [[ -z "$build_id" ]]; then
  build_number="$(current_build_number)"
  log "resolving uploaded $platform build $version ($build_number)"
  build_json="$(asc builds info \
    --app "$APP_ID" \
    --version "$version" \
    --build-number "$build_number" \
    --platform "$platform" \
    --output json)"
  build_id="$(extract_first_id <<<"$build_json")"

  [[ -n "$build_id" && "$build_id" != "null" ]] \
    || die "could not resolve uploaded build $version ($build_number) for $platform"
fi

log "submitting $platform $version with build $build_id"
asc review submit \
  --app "$APP_ID" \
  --version-id "$version_id" \
  --build "$build_id" \
  --platform "$platform" \
  --confirm \
  --output json
