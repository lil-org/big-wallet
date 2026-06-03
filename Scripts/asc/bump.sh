#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd git
require_cmd jq

mode="${1:-version}"
xcode_version_files=(
  "$(project_pbxproj_file)"
  "${VERSIONED_INFO_PLISTS[@]}"
)

old_version="$(current_local_version)"
old_build="$(current_local_build_number)"
validate_local_version_sources "$old_version" "$old_build"

case "$mode" in
  version)
    new_version="${VERSION:-$(patch_bump_version "$old_version")}"
    commit_message_prefix="bump version to $new_version"
    version_files=("${xcode_version_files[@]}" "${WEB_EXTENSION_MANIFESTS[@]}")
    ;;
  build)
    new_version="$old_version"
    commit_message_prefix="bump build number"
    version_files=("${xcode_version_files[@]}")
    ;;
  *)
    die "usage: $0 <version|build>"
    ;;
esac

if ! git diff --quiet -- "${version_files[@]}" || ! git diff --cached --quiet -- "${version_files[@]}"; then
  die "version files have existing changes; commit or stash them before bumping"
fi

[[ "$old_build" =~ ^[0-9]+$ ]] || die "current build number is not numeric: $old_build"
local_next=$((old_build + 1))
next_build="$local_next"

read_next_build_number() {
  local platform="$1"
  local args=(
    builds next-build-number
    --app "$APP_ID"
    --version "$new_version"
    --initial-build-number "$local_next"
    --output json
  )

  if [[ -n "$platform" ]]; then
    args+=(--platform "$platform")
  fi

  asc "${args[@]}" | extract_next_build_number
}

remote_values=()
for platform in "" IOS MAC_OS VISION_OS; do
  if value="$(read_next_build_number "$platform" 2>/dev/null)" && [[ "$value" =~ ^[0-9]+$ ]]; then
    remote_values+=("$value")
  fi
done

[[ "${#remote_values[@]}" -gt 0 ]] || die "could not resolve next build number from App Store Connect"

for value in "${remote_values[@]}"; do
  if (( value > next_build )); then
    next_build="$value"
  fi
done

log "updating version $old_version -> $new_version, build $old_build -> $next_build"

asc xcode version edit \
  --project "$PROJECT" \
  --version "$new_version" \
  --build-number "$next_build" \
  --output json >/dev/null

sync_local_version_sources "$new_version" "$next_build" "$mode"
validate_local_version_sources "$new_version" "$next_build"

git add "${version_files[@]}"

if git diff --cached --quiet -- "${version_files[@]}"; then
  log "no version files changed; skipping commit and push"
  exit 0
fi

if [[ "$mode" == "version" ]]; then
  git commit -m "$commit_message_prefix ($next_build)" --only -- "${version_files[@]}"
else
  git commit -m "$commit_message_prefix $next_build" --only -- "${version_files[@]}"
fi

git push
