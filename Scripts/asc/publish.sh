#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$REPO_ROOT/Scripts/inpage_provider_toolchain.sh"

require_cmd asc
require_cmd jq
require_cmd xcodebuild
require_cmd plutil
inpage_provider_prepare_tool_path
require_inpage_provider_toolchain

validate_export_options "$ASC_EXPORT_OPTIONS"

platform="${1:-${PLATFORM:-IOS}}"
local_version="$(current_local_version)"
local_build_number="$(current_local_build_number)"
version="${VERSION:-$local_version}"
build_number="$local_build_number"
artifact_path=""
artifact_dir=""
archive_path=""
upload_attempted=false

validate_local_version_sources "$version" "$build_number"

case "$platform" in
  IOS)
    platform_name="iOS"
    scheme="$IOS_SCHEME"
    artifact_root="$ASC_ARTIFACTS_DIR/ios"
    archive_name="Big-Wallet-iOS.xcarchive"
    ipa_name="Big-Wallet-iOS.ipa"
    destination="generic/platform=iOS"
    ;;
  MAC_OS)
    platform_name="macOS"
    scheme="$MACOS_SCHEME"
    artifact_root="$ASC_ARTIFACTS_DIR/macos"
    archive_name="Big-Wallet-macOS.xcarchive"
    destination="generic/platform=macOS"
    ;;
  VISION_OS)
    platform_name="visionOS"
    scheme="$VISIONOS_SCHEME"
    artifact_root="$ASC_ARTIFACTS_DIR/visionos"
    archive_name="Big-Wallet-visionOS.xcarchive"
    ipa_name="Big-Wallet-visionOS.ipa"
    destination="generic/platform=visionOS"
    ;;
  *)
    die "release publishing is only configured for IOS, MAC_OS, and VISION_OS, got $platform"
    ;;
esac

is_managed_release_directory() {
  local candidate="$1"
  local relative

  [[ -n "$candidate" && -n "$artifact_root" ]] || return 1
  relative="${candidate#"$artifact_root"/}"

  [[ "$candidate" != "$relative" &&
     "$relative" == release.* &&
     "$relative" != */* ]]
}

cleanup_release_artifacts() {
  local status=$?

  trap - EXIT
  trap '' HUP INT TERM

  if [[ -n "$artifact_dir" ]]; then
    if ! is_managed_release_directory "$artifact_dir"; then
      log "refusing to clean unexpected release directory: $artifact_dir"
    # A failed upload command cannot prove that App Store Connect rejected the
    # binary. Once upload starts, retain its artifact and dSYMs for recovery.
    elif [[ "$upload_attempted" != true ]] &&
         ! rm -rf -- "$artifact_dir"; then
      log "could not remove incomplete release directory: $artifact_dir"
    fi
  fi

  exit "$status"
}

trap cleanup_release_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

emit_publish_result() {
  local build_id="$1"
  local result_artifact_path="$2"

  jq -n \
    --arg buildId "$build_id" \
    --arg version "$version" \
    --arg buildNumber "$build_number" \
    --arg platform "$platform" \
    --arg artifactPath "$result_artifact_path" \
    '{
      buildId: $buildId,
      version: $version,
      buildNumber: $buildNumber,
      platform: $platform,
      artifactPath: $artifactPath
    }'
}

lookup_build_json() {
  asc builds info \
    --app "$APP_ID" \
    --version "$version" \
    --build-number "$build_number" \
    --platform "$platform" \
    --output json
}

wait_for_build_json() {
  local build_id="$1"

  asc builds wait \
    --build-id "$build_id" \
    --fail-on-invalid \
    --output json
}

resolve_uploaded_build_id() {
  local attempts="${ASC_BUILD_LOOKUP_ATTEMPTS:-20}"
  local delay="${ASC_BUILD_LOOKUP_DELAY:-15}"
  local attempt
  local build_json
  local build_id

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if build_json="$(lookup_build_json 2>/dev/null)"; then
      build_id="$(extract_first_id <<<"$build_json")"
      if [[ -n "$build_id" && "$build_id" != "null" ]]; then
        wait_for_build_json "$build_id" >/dev/null
        printf '%s\n' "$build_id"
        return 0
      fi
    fi

    if (( attempt < attempts )); then
      log "uploaded build $version ($build_number) is not queryable yet; retrying in ${delay}s"
      sleep "$delay"
    fi
  done

  return 1
}

# App Store Connect cannot prove that an existing binary passed the local
# artifact scan, so retries deliberately require a fresh build number.
if existing_build_json="$(lookup_build_json 2>/dev/null)"; then
  existing_build_id="$(extract_first_id <<<"$existing_build_json")"

  if [[ -n "$existing_build_id" && "$existing_build_id" != "null" ]]; then
    die "refusing to reuse existing $platform build $version ($build_number): its archived contents cannot be verified; increment the build number and rerun"
  fi
fi

mkdir -p "$artifact_root"
artifact_root="$(cd "$artifact_root" && pwd -P)"
artifact_dir="$(mktemp -d "$artifact_root/release.XXXXXX")"
chmod 700 "$artifact_dir"
archive_path="$artifact_dir/$archive_name"

case "$platform" in
  IOS|VISION_OS)
    ipa_path="$artifact_dir/$ipa_name"
    ;;
  MAC_OS)
    export_dir="$artifact_dir/export"
    ;;
esac

log "archiving $platform $version ($build_number) from scheme $scheme"
archive_json="$(asc xcode archive \
  --project "$PROJECT" \
  --scheme "$scheme" \
  --configuration Release \
  --archive-path "$archive_path" \
  --xcodebuild-flag=-destination \
  --xcodebuild-flag="$destination" \
  --xcodebuild-flag=-allowProvisioningUpdates \
  --xcodebuild-flag="MARKETING_VERSION=$version" \
  --xcodebuild-flag="CURRENT_PROJECT_VERSION=$build_number" \
  --clean \
  --overwrite \
  --output json)"

archive_path="$(jq -r '.archive_path // .archivePath // empty' <<<"$archive_json")"
[[ -n "$archive_path" ]] || die "archive did not return an archive path"
"$REPO_ROOT/Scripts/assert_no_bundled_alchemy_key.sh" "$archive_path"

case "$platform" in
  IOS|VISION_OS)
    log "exporting $platform_name archive to $ipa_path"
    export_json="$(asc xcode export \
      --archive-path "$archive_path" \
      --export-options "$ASC_EXPORT_OPTIONS" \
      --ipa-path "$ipa_path" \
      --overwrite \
      --xcodebuild-flag=-allowProvisioningUpdates \
      --output json)"

    artifact_path="$(jq -r '.ipa_path // .ipaPath // empty' <<<"$export_json")"
    [[ -n "$artifact_path" ]] || die "$platform_name export did not return an IPA path"
    upload_flag=(--ipa "$artifact_path" --platform "$platform")
    ;;
  MAC_OS)
    log "exporting macOS archive to $export_dir"
    rm -rf "$export_dir"
    mkdir -p "$export_dir"

    xcodebuild \
      -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_dir" \
      -exportOptionsPlist "$ASC_EXPORT_OPTIONS" \
      -allowProvisioningUpdates >&2

    pkg_count="$(find "$export_dir" -maxdepth 1 -name '*.pkg' -type f | wc -l | tr -d ' ')"
    [[ "$pkg_count" == "1" ]] \
      || die "expected one exported macOS pkg in $export_dir, found $pkg_count"

    artifact_path="$(find "$export_dir" -maxdepth 1 -name '*.pkg' -type f | head -n 1)"
    upload_flag=(--pkg "$artifact_path")
    ;;
esac

"$REPO_ROOT/Scripts/assert_no_bundled_alchemy_key.sh" "$artifact_path"

log "uploading $platform build $version ($build_number)"
upload_attempted=true
upload_json="$(asc builds upload \
  --app "$APP_ID" \
  "${upload_flag[@]}" \
  --version "$version" \
  --build-number "$build_number" \
  --wait \
  --output json)"

build_id="$(extract_first_id <<<"$upload_json")"
if [[ -z "$build_id" || "$build_id" == "null" ]]; then
  log "upload completed without a build id in the response; resolving $platform build $version ($build_number)"
  build_id="$(resolve_uploaded_build_id)" \
    || die "could not resolve uploaded build id for $platform $version ($build_number)"
fi

[[ -n "$build_id" && "$build_id" != "null" ]] \
  || die "could not resolve uploaded build id for $platform $version ($build_number)"

emit_publish_result "$build_id" "$artifact_path"
