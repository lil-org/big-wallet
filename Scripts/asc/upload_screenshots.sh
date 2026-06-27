#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc

platform="${1:-${PLATFORM:-IOS}}"
version="${2:-$(target_version)}"

case "$platform" in
  IOS)
    path="$ASC_IOS_SCREENSHOTS"
    screenshot_sets=(
      "iphone:APP_IPHONE_67"
      "ipad:APP_IPAD_PRO_3GEN_129"
    )
    ;;
  MAC_OS)
    path="$ASC_MACOS_SCREENSHOTS"
    screenshot_sets=("desktop:APP_DESKTOP")
    ;;
  VISION_OS)
    path="$ASC_VISIONOS_SCREENSHOTS"
    screenshot_sets=("vision-pro:APP_APPLE_VISION_PRO")
    ;;
  *)
    die "unsupported screenshot platform: $platform"
    ;;
esac

[[ -d "$path" ]] || die "missing screenshots path: $path"

prepare_device_screenshot_tree() {
  local source_path="$1"
  local source_dir="$2"
  local device="$3"
  local device_source_path="$source_path/$source_dir"
  local staging_root="$ASC_TMP_DIR/screenshots/$platform/$device"
  local locale_count=0
  local file_count=0

  [[ -d "$device_source_path" ]] || return 1

  rm -rf "$staging_root"
  mkdir -p "$staging_root"

  while IFS= read -r -d '' locale_dir; do
    local locale
    local target_dir
    locale="$(basename "$locale_dir")"
    target_dir="$staging_root/$locale"
    locale_count=$((locale_count + 1))

    while IFS= read -r -d '' file; do
      local relative_file
      relative_file="${file#"$locale_dir"/}"
      mkdir -p "$target_dir/$(dirname "$relative_file")"
      cp "$file" "$target_dir/$relative_file"
      file_count=$((file_count + 1))
    done < <(find "$locale_dir" \( -type d -name '.*' -prune \) -o \( -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) ! -name '.*' -print0 \) | sort -z)
  done < <(find "$device_source_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

  [[ "$locale_count" -gt 0 ]] \
    || die "$device_source_path must contain locale directories for screenshot upload"

  if [[ "$file_count" -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "$staging_root"
}

validate_device_screenshot_tree() {
  local staging_root="$1"
  local device="$2"

  while IFS= read -r -d '' locale_dir; do
    asc screenshots validate \
      --path "$locale_dir" \
      --device-type "$device" \
      --output json >/dev/null
  done < <(find "$staging_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
}

for screenshot_set in "${screenshot_sets[@]}"; do
  source_dir="${screenshot_set%%:*}"
  device="${screenshot_set#*:}"

  if ! staging_path="$(prepare_device_screenshot_tree "$path" "$source_dir" "$device")"; then
    log "no $device screenshots under $path/$source_dir; skipping"
    continue
  fi

  validate_device_screenshot_tree "$staging_path" "$device"

  log "uploading $device screenshots for $platform $version"
  asc screenshots upload \
    --app "$APP_ID" \
    --version "$version" \
    --platform "$platform" \
    --path "$staging_path" \
    --device-type "$device" \
    --replace \
    --output json
done
