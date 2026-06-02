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
current_json="$(current_xcode_version_json)"
version="${VERSION:-$(jq -r '.version' <<<"$current_json")}"
build_number="$(jq -r '.buildNumber' <<<"$current_json")"

case "$platform" in
  IOS)
    scheme="$IOS_SCHEME"
    artifact_dir=".asc/artifacts/ios"
    archive_path="$artifact_dir/Big-Wallet-iOS.xcarchive"
    ipa_path="$artifact_dir/Big-Wallet-iOS.ipa"
    destination="generic/platform=iOS"
    upload_flag=(--ipa "$ipa_path" --platform "$platform")
    ;;
  MAC_OS)
    scheme="$MACOS_SCHEME"
    artifact_dir=".asc/artifacts/macos"
    archive_path="$artifact_dir/Big-Wallet-macOS.xcarchive"
    export_dir="$artifact_dir/export"
    destination="generic/platform=macOS"
    ;;
  *)
    die "release publishing is only configured for IOS and MAC_OS, got $platform"
    ;;
esac

mkdir -p "$artifact_dir"

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

case "$platform" in
  IOS)
    log "exporting iOS archive to $ipa_path"
    export_json="$(asc xcode export \
      --archive-path "$archive_path" \
      --export-options "$ASC_EXPORT_OPTIONS" \
      --ipa-path "$ipa_path" \
      --overwrite \
      --xcodebuild-flag=-allowProvisioningUpdates \
      --output json)"

    artifact_path="$(jq -r '.ipa_path // .ipaPath // empty' <<<"$export_json")"
    [[ -n "$artifact_path" ]] || die "iOS export did not return an IPA path"
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

log "uploading $platform build $version ($build_number)"
upload_json="$(asc builds upload \
  --app "$APP_ID" \
  "${upload_flag[@]}" \
  --version "$version" \
  --build-number "$build_number" \
  --wait \
  --output json)"

build_id="$(extract_first_id <<<"$upload_json")"
[[ -n "$build_id" && "$build_id" != "null" ]] \
  || die "could not resolve uploaded build id for $platform $version ($build_number)"

jq -n \
  --arg buildId "$build_id" \
  --arg version "$version" \
  --arg buildNumber "$build_number" \
  --arg platform "$platform" \
  --arg artifactPath "$artifact_path" \
  '{
    buildId: $buildId,
    version: $version,
    buildNumber: $buildNumber,
    platform: $platform,
    artifactPath: $artifactPath
  }'
