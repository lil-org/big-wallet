#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd jq
require_cmd plutil

platform="${1:-${PLATFORM:-IOS}}"
upload_screenshots="${2:-false}"
require_review_details="${3:-false}"
version="$(target_version)"
versions_json="$(asc versions list \
  --app "$APP_ID" \
  --version "$version" \
  --platform "$platform" \
  --paginate \
  --output json)"
version_id="$(extract_version_id "$version" "$platform" <<<"$versions_json")"

if [[ -n "$version_id" && "$version_id" != "null" ]]; then
  version_state="$(extract_version_state_for "$version" "$platform" <<<"$versions_json")"

  if app_store_version_is_submitted_state "$version_state"; then
    log "$platform $version is already in App Store state $version_state; skipping metadata delivery"
    exit 0
  fi
fi

upload_app_info_localization() {
  local source_file="$1"
  local upload_locale="$2"
  local tmp_dir
  local status

  tmp_dir="$(mktemp -d)"
  cp "$source_file" "$tmp_dir/$upload_locale.strings"

  set +e
  asc localizations upload \
    --app "$APP_ID" \
    --app-info "$app_info_id" \
    --type app-info \
    --locale "$upload_locale" \
    --path "$tmp_dir/$upload_locale.strings" \
    --output json
  status=$?
  set -e

  rm -rf "$tmp_dir"
  return "$status"
}

sync_app_info_localizations() {
  local remote_json="$1"
  local file
  local locale
  local remote_locale
  local local_json
  local remote_attrs
  local local_value
  local remote_value
  local field
  local flag
  local update_args
  local changed_fields

  while IFS= read -r -d '' file; do
    locale="$(basename "$file" .strings)"
    remote_locale="$(app_store_locale "$locale")"
    local_json="$(plutil -convert json -o - -- "$file")"
    remote_attrs="$(jq -c --arg locale "$remote_locale" '
      [
        .data[]
        | select((.attributes.locale // "") == $locale)
        | .attributes
      ]
      | .[0] // empty
    ' <<<"$remote_json")"

    if [[ -z "$remote_attrs" ]]; then
      log "creating app-info localization $locale"
      upload_app_info_localization "$file" "$remote_locale"
      continue
    fi

    update_args=()
    changed_fields=()

    for field in name subtitle privacyPolicyUrl; do
      local_value="$(jq -r --arg field "$field" '.[$field] // empty' <<<"$local_json")"
      remote_value="$(jq -r --arg field "$field" '.[$field] // empty' <<<"$remote_attrs")"

      [[ "$local_value" != "$remote_value" ]] || continue

      case "$field" in
        name) flag="--name" ;;
        subtitle) flag="--subtitle" ;;
        privacyPolicyUrl) flag="--privacy-policy-url" ;;
      esac

      update_args+=("$flag" "$local_value")
      changed_fields+=("$field")
    done

    if [[ "${#update_args[@]}" -gt 0 ]]; then
      log "updating app-info localization $locale fields: ${changed_fields[*]}"
      asc localizations update \
        --app "$APP_ID" \
        --app-info "$app_info_id" \
        --type app-info \
        --locale "$remote_locale" \
        "${update_args[@]}" \
        --output json
    fi
  done < <(find "$ASC_APP_INFO_DIR" -name '*.strings' -type f -print0 | sort -z)
}

normalized_localization_dir() {
  local source_dir="$1"
  local output_dir
  local file
  local locale
  local normalized_locale

  output_dir="$(mktemp -d)"

  while IFS= read -r -d '' file; do
    locale="$(basename "$file" .strings)"
    normalized_locale="$(app_store_locale "$locale")"
    cp "$file" "$output_dir/$normalized_locale.strings"
  done < <(find "$source_dir" -name '*.strings' -type f -print0 | sort -z)

  printf '%s\n' "$output_dir"
}

Scripts/asc/validate_localizations.sh

if [[ "$require_review_details" == "true" ]]; then
  Scripts/asc/validate_review_details.sh
fi

if [[ -z "$version_id" || "$version_id" == "null" ]]; then
  version_id="$(Scripts/asc/ensure_version.sh "$platform" "$version")"
fi
app_info_id="$(resolve_app_info_id "$platform")"

ASC_APP_INFO_ID="$app_info_id" Scripts/asc/sync_app_metadata.sh "$version_id" "$require_review_details" "$platform"

log "syncing app-info localizations"
app_info_localizations_json="$(asc localizations list \
  --app "$APP_ID" \
  --app-info "$app_info_id" \
  --type app-info \
  --paginate \
  --output json)"

sync_app_info_localizations "$app_info_localizations_json"

log "uploading version localizations for $platform $version ($version_id)"
normalized_version_dir="$(normalized_localization_dir "$ASC_VERSION_DIR")"
trap 'rm -rf "$normalized_version_dir"' EXIT

asc localizations upload \
  --version "$version_id" \
  --path "$normalized_version_dir" \
  --output json

if [[ "$upload_screenshots" == "true" ]]; then
  Scripts/asc/upload_screenshots.sh "$platform" "$version"
else
  log "screenshot upload disabled for $platform"
fi
