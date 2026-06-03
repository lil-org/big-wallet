#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd jq

platform="${1:-${PLATFORM:-IOS}}"
version="${2:-$(target_version)}"

log "resolving App Store version $version for $platform"

versions_json="$(asc versions list \
  --app "$APP_ID" \
  --version "$version" \
  --platform "$platform" \
  --paginate \
  --output json)"

version_id="$(extract_version_id "$version" "$platform" <<<"$versions_json")"

if [[ -z "$version_id" || "$version_id" == "null" ]]; then
  platform_versions_json="$(asc versions list \
    --app "$APP_ID" \
    --platform "$platform" \
    --paginate \
    --output json)"

  recovery_record="$(extract_recoverable_rejected_version_for "$platform" <<<"$platform_versions_json")"

  if [[ -n "$recovery_record" ]]; then
    IFS=$'\t' read -r version_id recovered_version recovered_state <<<"$recovery_record"

    [[ -n "$version_id" && "$version_id" != "null" ]] \
      || die "could not resolve recoverable rejected version for $platform"

    if [[ "$recovered_version" != "$version" ]]; then
      log "recovering rejected $platform version $recovered_version ($recovered_state) as $version"

      update_args=(
        versions update
        --version-id "$version_id"
        --version "$version"
        --output json
      )

      copyright="$(app_metadata_string '.copyright')"
      if [[ -n "$copyright" ]]; then
        update_args+=(--copyright "$copyright")
      fi

      updated_version_id="$(asc "${update_args[@]}" | extract_first_id)"
      if [[ -n "$updated_version_id" && "$updated_version_id" != "null" ]]; then
        version_id="$updated_version_id"
      fi
    else
      log "reusing rejected $platform version $version ($recovered_state)"
    fi
  fi
fi

if [[ -z "$version_id" || "$version_id" == "null" ]]; then
  log "creating App Store version $version for $platform"

  create_args=(
    versions create
    --app "$APP_ID"
    --version "$version"
    --platform "$platform"
    --output json
  )

  copyright="$(app_metadata_string '.copyright')"
  if [[ -n "$copyright" ]]; then
    create_args+=(--copyright "$copyright")
  fi

  version_id="$(asc "${create_args[@]}" | extract_first_id)"
fi

[[ -n "$version_id" && "$version_id" != "null" ]] \
  || die "could not resolve or create version $version for $platform"

printf '%s\n' "$version_id"
