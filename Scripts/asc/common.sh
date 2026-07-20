#!/usr/bin/env bash
set -euo pipefail

ASC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ASC_SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"

APP_ID="${APP_ID:-6478607925}"
PROJECT="${PROJECT:-Wallet.xcodeproj}"
VERSION_TARGET="${VERSION_TARGET:-Big Wallet}"
IOS_SCHEME="${IOS_SCHEME:-Wallet iOS}"
MACOS_SCHEME="${MACOS_SCHEME:-Wallet}"
VISIONOS_SCHEME="${VISIONOS_SCHEME:-Wallet visionOS}"
ASC_METADATA_ROOT="${ASC_METADATA_ROOT:-app-store-connect}"
ASC_RUNTIME_ROOT="${ASC_RUNTIME_ROOT:-.asc}"
ASC_APP_INFO_DIR="${ASC_APP_INFO_DIR:-$ASC_METADATA_ROOT/localizations/app-info}"
ASC_VERSION_DIR="${ASC_VERSION_DIR:-$ASC_METADATA_ROOT/localizations/version}"
ASC_IOS_SCREENSHOTS="${ASC_IOS_SCREENSHOTS:-$ASC_METADATA_ROOT/screenshots/ios}"
ASC_MACOS_SCREENSHOTS="${ASC_MACOS_SCREENSHOTS:-$ASC_METADATA_ROOT/screenshots/macos}"
ASC_VISIONOS_SCREENSHOTS="${ASC_VISIONOS_SCREENSHOTS:-$ASC_METADATA_ROOT/screenshots/visionos}"
ASC_APP_INFO_ID="${ASC_APP_INFO_ID:-}"
ASC_APP_METADATA="${ASC_APP_METADATA:-$ASC_METADATA_ROOT/app-metadata.json}"
ASC_REVIEW_DETAILS_LOCAL="${ASC_REVIEW_DETAILS_LOCAL:-$ASC_RUNTIME_ROOT/review-details.local.json}"
ASC_EXPORT_OPTIONS="${ASC_EXPORT_OPTIONS:-$ASC_METADATA_ROOT/export-options-app-store.plist}"
ASC_ARTIFACTS_DIR="${ASC_ARTIFACTS_DIR:-$ASC_RUNTIME_ROOT/artifacts}"
ASC_TMP_DIR="${ASC_TMP_DIR:-$ASC_RUNTIME_ROOT/tmp}"
ASC_REPORTS_DIR="${ASC_REPORTS_DIR:-$ASC_RUNTIME_ROOT/reports}"
ASC_TEAM_ID="${ASC_TEAM_ID:-8DXC3N7E7P}"
ASC_WORKFLOW_FILE="$REPO_ROOT/.asc/workflow.json"
ALCHEMY_JWT_WORKER_DIR="$REPO_ROOT/Workers/alchemy-jwt"
ALCHEMY_JWT_RECEIPTS_DIR="$ASC_REPORTS_DIR/validated-builds"
ALCHEMY_JWT_PRELAUNCH_ANCHOR_VERSION="c5c74433-eb49-4998-979b-e78d17da74f8"
ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="${ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE:-/Users/ivan/Developer/secrets/tools/ALCHEMY_JWT_REQUEST_PROOF_KEY}"
export ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE
VERSIONED_INFO_PLISTS=(
  "App iOS/Info.plist"
  "App macOS/Info.plist"
  "Big Wallet Ambient/Info.plist"
)
WEB_EXTENSION_MANIFESTS=(
  "Safari iOS/Resources/manifest.json"
  "Safari macOS/Resources/manifest.json"
)

log() {
  printf '[asc] %s\n' "$*" >&2
}

die() {
  printf '[asc] error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_alchemy_uuid() {
  local description="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || die "$description must be a canonical lowercase UUID"
}

tracked_asc_environment_value() {
  local key="$1"
  local value

  [[ -f "$ASC_WORKFLOW_FILE" && ! -L "$ASC_WORKFLOW_FILE" ]] \
    || die "missing tracked ASC workflow: $ASC_WORKFLOW_FILE"

  value="$(jq -er --arg key "$key" '
    .env[$key]
    | select(type == "string" and length > 0)
  ' "$ASC_WORKFLOW_FILE" 2>/dev/null)" \
    || die "$ASC_WORKFLOW_FILE must define a non-empty env.$key string"

  printf '%s\n' "$value"
}

load_alchemy_release_pins() {
  local configured_kid="${ALCHEMY_JWT_EXPECTED_KID:-}"
  local configured_version="${ALCHEMY_JWT_EXPECTED_WORKER_VERSION:-}"
  local tracked_kid
  local tracked_version

  tracked_kid="$(tracked_asc_environment_value ALCHEMY_JWT_EXPECTED_KID)"
  tracked_version="$(tracked_asc_environment_value ALCHEMY_JWT_EXPECTED_WORKER_VERSION)"

  if [[ -n "$configured_kid" && "$configured_kid" != "$tracked_kid" ]]; then
    die "ALCHEMY_JWT_EXPECTED_KID must match the tracked ASC workflow pin"
  fi
  if [[ -n "$configured_version" && "$configured_version" != "$tracked_version" ]]; then
    die "ALCHEMY_JWT_EXPECTED_WORKER_VERSION must match the tracked ASC workflow pin"
  fi

  require_alchemy_uuid "the expected Alchemy JWT kid" "$tracked_kid"
  require_alchemy_uuid "the expected Alchemy Worker version" "$tracked_version"

  if [[ "$tracked_version" == "$ALCHEMY_JWT_PRELAUNCH_ANCHOR_VERSION" ]]; then
    die "the tracked Alchemy Worker version is still the prelaunch anchor; replace it with the promoted HMAC Worker UUID"
  fi

  ALCHEMY_JWT_EXPECTED_KID="$tracked_kid"
  ALCHEMY_JWT_EXPECTED_WORKER_VERSION="$tracked_version"
}

require_alchemy_release_toolchain() {
  local expected_node_version
  local expected_npm_version
  local actual_node_version
  local actual_npm_version

  require_cmd jq
  require_cmd node
  require_cmd npm

  [[ -f "$ALCHEMY_JWT_WORKER_DIR/.nvmrc" ]] \
    || die "missing Alchemy Worker Node version pin"
  [[ -f "$ALCHEMY_JWT_WORKER_DIR/package.json" ]] \
    || die "missing Alchemy Worker package manifest"

  expected_node_version="$(tr -d '[:space:]' <"$ALCHEMY_JWT_WORKER_DIR/.nvmrc")"
  actual_node_version="$(node --version)"
  actual_node_version="${actual_node_version#v}"
  [[ -n "$expected_node_version" && "$actual_node_version" == "$expected_node_version" ]] \
    || die "Alchemy release verification requires Node $expected_node_version; found $actual_node_version"

  expected_npm_version="$(jq -er '
    .packageManager
    | select(type == "string" and startswith("npm@"))
    | sub("^npm@"; "")
  ' "$ALCHEMY_JWT_WORKER_DIR/package.json" 2>/dev/null)" \
    || die "the Alchemy Worker package manifest must pin npm"
  actual_npm_version="$(npm --version)"
  [[ "$actual_npm_version" == "$expected_npm_version" ]] \
    || die "Alchemy release verification requires npm $expected_npm_version; found $actual_npm_version"

  jq -e '
    .scripts["verify:release"]
    | type == "string" and length > 0
  ' "$ALCHEMY_JWT_WORKER_DIR/package.json" >/dev/null \
    || die "the Alchemy Worker package manifest is missing verify:release"
}

load_cloudflare_api_token_file() {
  local token_file="${CLOUDFLARE_API_TOKEN_FILE:-}"
  local token_name
  local token_parent
  local canonical_parent
  local canonical_file
  local current_user
  local parent_owner
  local parent_mode
  local parent_mode_value
  local metadata_before
  local metadata_after
  local token_owner
  local token_mode
  local token_size
  local snapshot_with_sentinel
  local snapshot
  local final_lf=$'\n'

  set +x
  unset CLOUDFLARE_API_TOKEN_VALUE

  [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] \
    || die "set CLOUDFLARE_API_TOKEN_FILE instead of exporting CLOUDFLARE_API_TOKEN"
  [[ -n "$token_file" ]] \
    || die "CLOUDFLARE_API_TOKEN_FILE is required for Alchemy release verification"
  [[ "$token_file" == /* ]] \
    || die "CLOUDFLARE_API_TOKEN_FILE must be an absolute path"

  token_name="${token_file##*/}"
  token_parent="${token_file%/*}"
  [[ -n "$token_name" ]] || die "the Cloudflare API token file path is invalid"
  [[ -n "$token_parent" ]] || token_parent="/"

  canonical_parent="$(cd "$token_parent" 2>/dev/null && pwd -P)" \
    || die "the Cloudflare API token directory could not be inspected"
  canonical_file="${canonical_parent%/}/$token_name"
  [[ "$token_file" == "$canonical_file" ]] \
    || die "the Cloudflare API token file path must be canonical and must not traverse symbolic links"
  [[ ! -L "$token_file" && -f "$token_file" ]] \
    || die "the Cloudflare API token file must be a regular file, not a symbolic link"

  current_user="$(/usr/bin/id -u)" \
    || die "the current user could not be identified"
  parent_owner="$(/usr/bin/stat -f '%u' -- "$canonical_parent")" \
    || die "the Cloudflare API token directory owner could not be inspected"
  [[ "$parent_owner" == "$current_user" ]] \
    || die "the Cloudflare API token directory must be owned by the current user"
  parent_mode="$(/usr/bin/stat -f '%Lp' -- "$canonical_parent")" \
    || die "the Cloudflare API token directory mode could not be inspected"
  [[ "$parent_mode" =~ ^[0-7]+$ ]] \
    || die "the Cloudflare API token directory mode is invalid"
  parent_mode_value=$((8#$parent_mode))
  (( (parent_mode_value & 077) == 0 && (parent_mode_value & 0100) != 0 )) \
    || die "the Cloudflare API token directory must be owner-only and searchable by its owner"

  metadata_before="$(/usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$token_file")" \
    || die "the Cloudflare API token file could not be inspected"
  IFS=: read -r _ _ token_owner token_mode token_size <<<"$metadata_before"
  [[ "$token_owner" == "$current_user" ]] \
    || die "the Cloudflare API token file must be owned by the current user"
  [[ "$token_mode" == "600" ]] \
    || die "the Cloudflare API token file mode must be 0600"
  [[ "$token_size" =~ ^[0-9]+$ ]] \
    || die "the Cloudflare API token file size is invalid"
  (( token_size >= 20 && token_size <= 513 )) \
    || die "the Cloudflare API token file must contain one token line"

  snapshot_with_sentinel="$(
    /bin/cat -- "$token_file" || exit 1
    printf '.'
  )" || die "the Cloudflare API token file could not be read"
  snapshot="${snapshot_with_sentinel%?}"

  metadata_after="$(/usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$token_file")" \
    || die "the Cloudflare API token file could not be re-inspected"
  [[ "$metadata_before" == "$metadata_after" ]] \
    || die "the Cloudflare API token file changed while it was being read"
  [[ "${#snapshot}" -eq "$token_size" ]] \
    || die "the Cloudflare API token file contains unsupported bytes"

  if [[ "$snapshot" == *"$final_lf" ]]; then
    snapshot="${snapshot%$final_lf}"
  fi
  [[ "${#snapshot}" -ge 20 && "${#snapshot}" -le 512 ]] \
    || die "the Cloudflare API token must contain 20 to 512 characters"
  [[ "$snapshot" != *[$' \t\r\n']* && "$snapshot" != *[![:graph:]]* ]] \
    || die "the Cloudflare API token file must contain one printable token line"

  CLOUDFLARE_API_TOKEN_VALUE="$snapshot"
  unset snapshot snapshot_with_sentinel
}

validate_alchemy_release_inputs() {
  local proof_key_file="${ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE:-}"

  [[ -n "$proof_key_file" ]] \
    || die "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE is required for an ASC release"
  "$REPO_ROOT/Scripts/validate_alchemy_jwt_request_proof_key_file.sh" \
    "$proof_key_file"

  load_alchemy_release_pins
  require_alchemy_release_toolchain
  load_cloudflare_api_token_file
  unset CLOUDFLARE_API_TOKEN_VALUE
}

run_alchemy_worker_release_verification() {
  local proof_key_file="$1"
  local verification_status

  "$REPO_ROOT/Scripts/validate_alchemy_jwt_request_proof_key_file.sh" \
    "$proof_key_file"
  load_alchemy_release_pins
  require_alchemy_release_toolchain
  load_cloudflare_api_token_file

  log "verifying deployed Alchemy HMAC Worker $ALCHEMY_JWT_EXPECTED_WORKER_VERSION"
  set +e
  (
    cd "$ALCHEMY_JWT_WORKER_DIR"
    unset CLOUDFLARE_API_KEY \
      CLOUDFLARE_EMAIL \
      CLOUDFLARE_API_USER_SERVICE_KEY
    CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_TOKEN_VALUE" \
      npm run verify:release -- \
        --expected-kid "$ALCHEMY_JWT_EXPECTED_KID" \
        --expected-version "$ALCHEMY_JWT_EXPECTED_WORKER_VERSION" \
        --app-proof-key-file "$proof_key_file"
  ) >&2
  verification_status=$?
  set -e

  unset CLOUDFLARE_API_TOKEN_VALUE
  (( verification_status == 0 )) \
    || die "the deployed Alchemy HMAC Worker failed release verification"
}

alchemy_request_proof_fingerprint() {
  local fingerprint_file="$REPO_ROOT/Scripts/alchemy_jwt_request_proof_key.sha256"
  local fingerprint

  [[ -f "$fingerprint_file" && ! -L "$fingerprint_file" ]] \
    || die "the tracked request-proof key fingerprint is missing or invalid"
  fingerprint="$(tr -d '\n' <"$fingerprint_file")"
  [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] \
    || die "the tracked request-proof key fingerprint must contain one SHA-256 digest"
  [[ "$(/usr/bin/wc -c <"$fingerprint_file" | tr -d '[:space:]')" == "65" ]] \
    || die "the tracked request-proof key fingerprint must contain one newline-terminated SHA-256 digest"

  printf '%s\n' "$fingerprint"
}

validate_alchemy_release_platform() {
  case "$1" in
    IOS|MAC_OS|VISION_OS) ;;
    *) die "Alchemy release receipts support only IOS, MAC_OS, and VISION_OS" ;;
  esac
}

alchemy_release_receipt_path() {
  local platform="$1"

  validate_alchemy_release_platform "$platform"
  printf '%s/%s.json\n' "$ALCHEMY_JWT_RECEIPTS_DIR" "$platform"
}

canonical_release_artifact_path() {
  local artifact="$1"
  local artifact_name
  local artifact_parent
  local canonical_parent

  [[ "$artifact" == /* ]] \
    || die "the release artifact path must be absolute"
  [[ ! -L "$artifact" && -f "$artifact" ]] \
    || die "the release artifact must be a regular file, not a symbolic link"

  artifact_name="${artifact##*/}"
  artifact_parent="${artifact%/*}"
  [[ -n "$artifact_parent" ]] || artifact_parent="/"
  canonical_parent="$(cd "$artifact_parent" 2>/dev/null && pwd -P)" \
    || die "the release artifact parent directory could not be inspected"
  [[ "$artifact" == "${canonical_parent%/}/$artifact_name" ]] \
    || die "the release artifact path must be canonical and must not traverse symbolic links"

  printf '%s\n' "$artifact"
}

release_artifact_sha256() {
  local artifact="$1"
  local metadata_before
  local metadata_after
  local digest_output
  local digest

  canonical_release_artifact_path "$artifact" >/dev/null
  metadata_before="$(/usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$artifact")" \
    || die "the release artifact could not be inspected"
  digest_output="$(/usr/bin/shasum -a 256 -- "$artifact")" \
    || die "the release artifact SHA-256 could not be computed"
  digest="${digest_output%% *}"
  metadata_after="$(/usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$artifact")" \
    || die "the release artifact could not be re-inspected"

  [[ "$metadata_before" == "$metadata_after" ]] \
    || die "the release artifact changed while its SHA-256 was being computed"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] \
    || die "the release artifact SHA-256 is malformed"

  printf '%s\n' "$digest"
}

write_alchemy_release_receipt() {
  local platform="$1"
  local version="$2"
  local build_number="$3"
  local build_id="$4"
  local artifact="$5"
  local proof_fingerprint="$6"
  local validated_artifact_sha256="$7"
  local canonical_artifact
  local artifact_sha256
  local receipt
  local temporary_receipt

  validate_alchemy_release_platform "$platform"
  [[ -n "$version" && "$version" != *[$'\r\n']* ]] \
    || die "the receipt version is invalid"
  [[ "$build_number" =~ ^[0-9]+$ ]] \
    || die "the receipt build number is invalid"
  [[ -n "$build_id" && "$build_id" != *[$'\r\n']* ]] \
    || die "the receipt build id is invalid"
  [[ "$proof_fingerprint" =~ ^[0-9a-f]{64}$ ]] \
    || die "the receipt proof-key fingerprint is invalid"
  [[ "$validated_artifact_sha256" =~ ^[0-9a-f]{64}$ ]] \
    || die "the validated release artifact SHA-256 is invalid"

  canonical_artifact="$(canonical_release_artifact_path "$artifact")"
  artifact_sha256="$(release_artifact_sha256 "$canonical_artifact")"
  [[ "$artifact_sha256" == "$validated_artifact_sha256" ]] \
    || die "the release artifact changed during its validated upload"
  receipt="$(alchemy_release_receipt_path "$platform")"

  mkdir -p "$ALCHEMY_JWT_RECEIPTS_DIR"
  chmod 700 "$ALCHEMY_JWT_RECEIPTS_DIR"
  temporary_receipt="$(mktemp "$ALCHEMY_JWT_RECEIPTS_DIR/.${platform}.XXXXXX")"
  chmod 600 "$temporary_receipt"

  if ! jq -n \
    --arg platform "$platform" \
    --arg version "$version" \
    --arg buildNumber "$build_number" \
    --arg buildId "$build_id" \
    --arg artifactPath "$canonical_artifact" \
    --arg artifactSHA256 "$artifact_sha256" \
    --arg proofKeyFingerprint "$proof_fingerprint" \
    '{
      schemaVersion: 1,
      platform: $platform,
      version: $version,
      buildNumber: $buildNumber,
      buildId: $buildId,
      artifactPath: $artifactPath,
      artifactSHA256: $artifactSHA256,
      proofKeyFingerprint: $proofKeyFingerprint
    }' >"$temporary_receipt"; then
    rm -f -- "$temporary_receipt"
    die "the Alchemy release receipt could not be written"
  fi

  mv -f -- "$temporary_receipt" "$receipt"
}

load_and_validate_alchemy_release_receipt() {
  local platform="$1"
  local version="$2"
  local build_number="$3"
  local requested_build_id="$4"
  local proof_fingerprint="$5"
  local receipt
  local receipt_mode
  local receipt_platform
  local receipt_version
  local receipt_build_number
  local receipt_build_id
  local receipt_artifact
  local receipt_artifact_sha256
  local receipt_proof_fingerprint
  local actual_artifact_sha256

  receipt="$(alchemy_release_receipt_path "$platform")"
  [[ ! -L "$receipt" && -f "$receipt" ]] \
    || die "missing validated Alchemy release receipt for $platform; upload this build through Scripts/asc/publish.sh first"
  receipt_mode="$(/usr/bin/stat -f '%Lp' -- "$receipt")" \
    || die "the Alchemy release receipt could not be inspected"
  [[ "$receipt_mode" == "600" ]] \
    || die "the Alchemy release receipt must have mode 0600"

  jq -e '
    type == "object" and
    .schemaVersion == 1 and
    ([keys[]] | sort) == ([
      "artifactPath",
      "artifactSHA256",
      "buildId",
      "buildNumber",
      "platform",
      "proofKeyFingerprint",
      "schemaVersion",
      "version"
    ] | sort) and
    (.platform | type == "string" and length > 0) and
    (.version | type == "string" and length > 0) and
    (.buildNumber | type == "string" and length > 0) and
    (.buildId | type == "string" and length > 0) and
    (.artifactPath | type == "string" and startswith("/")) and
    (.artifactSHA256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.proofKeyFingerprint | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$receipt" >/dev/null \
    || die "the Alchemy release receipt is malformed"

  IFS=$'\t' read -r \
    receipt_platform \
    receipt_version \
    receipt_build_number \
    receipt_build_id \
    receipt_artifact \
    receipt_artifact_sha256 \
    receipt_proof_fingerprint < <(
      jq -r '[
        .platform,
        .version,
        .buildNumber,
        .buildId,
        .artifactPath,
        .artifactSHA256,
        .proofKeyFingerprint
      ] | @tsv' "$receipt"
    )

  [[ "$receipt_platform" == "$platform" ]] \
    || die "the Alchemy release receipt platform does not match $platform"
  [[ "$receipt_version" == "$version" ]] \
    || die "the Alchemy release receipt version does not match $version"
  [[ "$receipt_build_number" == "$build_number" ]] \
    || die "the Alchemy release receipt build number does not match $build_number"
  if [[ -n "$requested_build_id" && "$receipt_build_id" != "$requested_build_id" ]]; then
    die "the requested build id does not match the validated Alchemy release receipt"
  fi
  [[ "$receipt_proof_fingerprint" == "$proof_fingerprint" ]] \
    || die "the Alchemy release receipt proof-key fingerprint does not match"

  canonical_release_artifact_path "$receipt_artifact" >/dev/null
  actual_artifact_sha256="$(release_artifact_sha256 "$receipt_artifact")"
  [[ "$actual_artifact_sha256" == "$receipt_artifact_sha256" ]] \
    || die "the release artifact changed after its validated upload"

  ALCHEMY_RELEASE_RECEIPT_BUILD_ID="$receipt_build_id"
  ALCHEMY_RELEASE_RECEIPT_ARTIFACT_PATH="$receipt_artifact"
}

plist_value() {
  local file="$1"
  local key="$2"

  /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null
}

current_xcode_version_json() {
  asc xcode version view \
    --project "$PROJECT" \
    --target "$VERSION_TARGET" \
    --output json
}

current_version() {
  current_xcode_version_json | jq -r '.version'
}

current_build_number() {
  current_xcode_version_json | jq -r '.buildNumber'
}

project_pbxproj_file() {
  printf '%s/project.pbxproj\n' "$PROJECT"
}

project_build_setting_values() {
  local key="$1"
  local file
  file="$(project_pbxproj_file)"

  [[ -f "$file" ]] || die "missing Xcode project file: $file"

  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
      sub(";[[:space:]]*$", "", line)
      sub(/^"/, "", line)
      sub(/"$/, "", line)
      print line
    }
  ' "$file" | sort -u
}

current_project_build_setting() {
  local key="$1"
  local values=()
  local value

  while IFS= read -r value; do
    [[ -n "$value" ]] && values+=("$value")
  done < <(project_build_setting_values "$key")

  case "${#values[@]}" in
    0)
      die "project has no $key build setting"
      ;;
    1)
      printf '%s\n' "${values[0]}"
      ;;
    *)
      die "project has multiple $key build settings: ${values[*]}"
      ;;
  esac
}

current_local_version() {
  current_project_build_setting MARKETING_VERSION
}

current_local_build_number() {
  current_project_build_setting CURRENT_PROJECT_VERSION
}

set_project_build_setting() {
  local key="$1"
  local value="$2"
  local file
  file="$(project_pbxproj_file)"

  [[ -f "$file" ]] || die "missing Xcode project file: $file"

  KEY="$key" VALUE="$value" /usr/bin/perl -0pi -e '
    my $key = $ENV{KEY};
    my $value = $ENV{VALUE};
    s/(\b\Q$key\E\s*=\s*)[^;\n]+;/${1}$value;/g;
  ' "$file"
}

set_versioned_info_plist_placeholders() {
  local plist

  for plist in "${VERSIONED_INFO_PLISTS[@]}"; do
    plist_set_string "$plist" CFBundleShortVersionString '$(MARKETING_VERSION)'
    plist_set_string "$plist" CFBundleVersion '$(CURRENT_PROJECT_VERSION)'
  done
}

set_web_extension_manifest_versions() {
  local version="$1"
  local manifest
  local tmp

  for manifest in "${WEB_EXTENSION_MANIFESTS[@]}"; do
    tmp="$(mktemp "$manifest.XXXXXX")"
    jq --arg version "$version" '.version = $version' "$manifest" >"$tmp"
    mv "$tmp" "$manifest"
  done
}

sync_local_version_sources() {
  local version="$1"
  local build_number="$2"
  local mode="${3:-version}"

  set_project_build_setting MARKETING_VERSION "$version"
  set_project_build_setting CURRENT_PROJECT_VERSION "$build_number"
  set_versioned_info_plist_placeholders

  if [[ "$mode" == "version" ]]; then
    set_web_extension_manifest_versions "$version"
  fi
}

require_single_project_build_setting() {
  local key="$1"
  local expected="$2"
  local values=()
  local value

  while IFS= read -r value; do
    [[ -n "$value" ]] && values+=("$value")
  done < <(project_build_setting_values "$key")

  [[ "${#values[@]}" -gt 0 ]] || die "project has no $key build setting"

  if [[ "${#values[@]}" -ne 1 || "${values[0]}" != "$expected" ]]; then
    die "project must set $key=$expected for every target; found: ${values[*]}"
  fi
}

validate_local_version_sources() {
  local version="$1"
  local build_number="$2"
  local plist
  local manifest
  local manifest_version

  require_single_project_build_setting MARKETING_VERSION "$version"
  require_single_project_build_setting CURRENT_PROJECT_VERSION "$build_number"

  for plist in "${VERSIONED_INFO_PLISTS[@]}"; do
    require_plist_value "$plist" CFBundleShortVersionString '$(MARKETING_VERSION)'
    require_plist_value "$plist" CFBundleVersion '$(CURRENT_PROJECT_VERSION)'
  done

  for manifest in "${WEB_EXTENSION_MANIFESTS[@]}"; do
    manifest_version="$(jq -r '.version // empty' "$manifest")"
    [[ "$manifest_version" == "$version" ]] \
      || die "$manifest must set version=$version; found ${manifest_version:-missing}"
  done
}

target_version() {
  if [[ -n "${VERSION:-}" ]]; then
    printf '%s\n' "$VERSION"
  else
    current_version
  fi
}

patch_bump_version() {
  local version="$1"
  local IFS=.
  local parts=()
  read -r -a parts <<<"$version"

  [[ "${#parts[@]}" -gt 0 ]] || die "cannot patch-bump empty version"

  local last_index=$(( ${#parts[@]} - 1 ))
  [[ "${parts[$last_index]}" =~ ^[0-9]+$ ]] \
    || die "cannot patch-bump non-numeric version component: $version"

  while (( ${#parts[@]} < 3 )); do
    parts+=("0")
  done
  last_index=$(( ${#parts[@]} - 1 ))

  parts[$last_index]=$(( parts[$last_index] + 1 ))

  printf '%s\n' "${parts[*]}"
}

extract_version_id() {
  local version="$1"
  local platform="$2"

  jq -r --arg version "$version" --arg platform "$platform" '
    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      else []
      end;

    rows[]
    | select((.attributes.versionString // .versionString // "") == $version)
    | select((.attributes.platform // .platform // "") == $platform)
    | .id
  ' | head -n 1
}

extract_version_state_for() {
  local version="$1"
  local platform="$2"

  jq -r --arg version "$version" --arg platform "$platform" '
    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      else []
      end;

    def version_state:
      [
        .state?,
        .appStoreState?,
        .appVersionState?,
        .attributes.state?,
        .attributes.appStoreState?,
        .attributes.appVersionState?
      ]
      | map(select(. != null and . != ""))
      | .[0] // empty;

    rows[]
    | select((.attributes.versionString // .versionString // "") == $version)
    | select((.attributes.platform // .platform // "") == $platform)
    | version_state
  ' | head -n 1
}

extract_app_store_version_state() {
  jq -r '
    def version_state:
      [
        .state?,
        .appStoreState?,
        .appVersionState?,
        .attributes.state?,
        .attributes.appStoreState?,
        .attributes.appVersionState?
      ]
      | map(select(. != null and . != ""))
      | .[0] // empty;

    if (.data? | type) == "object" then
      .data | version_state
    else
      version_state
    end
  '
}

app_store_version_is_submitted_state() {
  local state="$1"

  case "$state" in
    WAITING_FOR_REVIEW|IN_REVIEW|PENDING_APPLE_RELEASE|PENDING_DEVELOPER_RELEASE|READY_FOR_SALE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_recoverable_rejected_version_for() {
  local platform="$1"

  jq -r --arg platform "$platform" '
    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      else []
      end;

    def version_state:
      [
        .state?,
        .appStoreState?,
        .appVersionState?,
        .attributes.state?,
        .attributes.appStoreState?,
        .attributes.appVersionState?
      ]
      | map(select(. != null and . != ""))
      | .[0] // empty;

    [
      rows[]
      | select((.attributes.platform // .platform // "") == $platform)
      | {
          id: (.id // ""),
          version: (.attributes.versionString // .versionString // ""),
          state: version_state,
          createdDate: (.attributes.createdDate // .createdDate // "")
        }
      | select(.id != "")
      | select(.state as $state | [
          "REJECTED",
          "METADATA_REJECTED",
          "DEVELOPER_REJECTED",
          "INVALID_BINARY",
          "UNRESOLVED_ISSUES"
        ] | index($state))
    ]
    | sort_by(.createdDate)
    | reverse
    | .[0] // empty
    | [.id, .version, .state]
    | @tsv
  ' | head -n 1
}

extract_rejected_review_submission_item_ids_for_version() {
  local version_id="$1"

  jq -r --arg version_id "$version_id" '
    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      else []
      end;

    rows[]
    | select((.state // .attributes.state // "") == "UNRESOLVED_ISSUES")
    | (.items // [])[]?
    | select((.type // .itemType // "") as $type | $type == "appStoreVersion" or $type == "appStoreVersions")
    | select((.resourceId // .itemId // "") == $version_id)
    | select((.state // .attributes.state // "") == "REJECTED")
    | .id
  '
}

extract_first_id() {
  jq -r '
    if .buildId? then .buildId
    elif .id? then .id
    elif .data.id? then .data.id
    elif (.data? | type) == "array" then (.data[0].id // "")
    else ""
    end
  '
}

app_store_locale() {
  local locale="$1"

  case "$locale" in
    bn) printf 'bn-BD\n' ;;
    gu) printf 'gu-IN\n' ;;
    kn) printf 'kn-IN\n' ;;
    ml) printf 'ml-IN\n' ;;
    mr) printf 'mr-IN\n' ;;
    or) printf 'or-IN\n' ;;
    pa) printf 'pa-IN\n' ;;
    sl) printf 'sl-SI\n' ;;
    ta) printf 'ta-IN\n' ;;
    te) printf 'te-IN\n' ;;
    ur) printf 'ur-PK\n' ;;
    *) printf '%s\n' "$locale" ;;
  esac
}

extract_app_info_ids() {
  local platform="${1:-}"

  jq -r --arg platform "$platform" '
    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      elif (.appInfos? | type) == "array" then .appInfos
      elif (.items? | type) == "array" then .items
      else []
      end;

    rows[]
    | select(
        $platform == "" or
        ((.attributes.platform // .platform // "") == $platform)
      )
    | .id // .appInfoId // empty
  '
}

extract_preferred_app_info_ids() {
  local platform="${1:-}"

  jq -r --arg platform "$platform" '
    def state:
      .attributes.state // .state // .attributes.appStoreState // .appStoreState // "";

    def state_rank:
      if state == "PREPARE_FOR_SUBMISSION" then 0
      elif state == "WAITING_FOR_REVIEW" then 1
      elif state == "IN_REVIEW" then 1
      elif state == "REJECTED" then 2
      elif state == "UNRESOLVED_ISSUES" then 2
      elif state == "READY_FOR_DISTRIBUTION" then 3
      elif state == "READY_FOR_SALE" then 3
      else 9
      end;

    def rows:
      if type == "array" then .
      elif (.data? | type) == "array" then .data
      elif (.appInfos? | type) == "array" then .appInfos
      elif (.items? | type) == "array" then .items
      else []
      end;

    [
      rows[]
      | select(
          $platform == "" or
          ((.attributes.platform // .platform // "") == $platform)
        )
      | { id: (.id // .appInfoId // empty), rank: state_rank }
      | select(.id != "")
    ] as $candidates
    | if ($candidates | length) == 0 then
        empty
      else
        ($candidates | map(.rank) | min) as $best_rank
        | $candidates[]
        | select(.rank == $best_rank)
        | .id
      end
  '
}

resolve_app_info_id() {
  local platform="${1:-}"
  local platform_env_names=()
  local platform_env_name

  case "$platform" in
    IOS) platform_env_names=(ASC_IOS_APP_INFO_ID) ;;
    MAC_OS) platform_env_names=(ASC_MACOS_APP_INFO_ID ASC_MAC_OS_APP_INFO_ID) ;;
    VISION_OS) platform_env_names=(ASC_VISIONOS_APP_INFO_ID ASC_VISION_OS_APP_INFO_ID) ;;
  esac

  for platform_env_name in "${platform_env_names[@]}"; do
    if [[ -n "${!platform_env_name:-}" ]]; then
      printf '%s\n' "${!platform_env_name}"
      return 0
    fi
  done

  if [[ -n "$ASC_APP_INFO_ID" ]]; then
    printf '%s\n' "$ASC_APP_INFO_ID"
    return 0
  fi

  local app_info_json
  local ids=()
  local id
  app_info_json="$(asc apps info list --app "$APP_ID" --output json)"

  while IFS= read -r id; do
    [[ -n "$id" ]] && ids+=("$id")
  done < <(extract_app_info_ids "$platform" <<<"$app_info_json")

  if [[ "${#ids[@]}" -eq 0 && -n "$platform" ]]; then
    while IFS= read -r id; do
      [[ -n "$id" ]] && ids+=("$id")
    done < <(extract_app_info_ids <<<"$app_info_json")
  fi

  if [[ "${#ids[@]}" -gt 1 ]]; then
    local preferred_ids=()

    while IFS= read -r id; do
      [[ -n "$id" ]] && preferred_ids+=("$id")
    done < <(extract_preferred_app_info_ids "$platform" <<<"$app_info_json")

    if [[ "${#preferred_ids[@]}" -eq 0 && -n "$platform" ]]; then
      while IFS= read -r id; do
        [[ -n "$id" ]] && preferred_ids+=("$id")
      done < <(extract_preferred_app_info_ids <<<"$app_info_json")
    fi

    if [[ "${#preferred_ids[@]}" -gt 0 ]]; then
      ids=("${preferred_ids[@]}")
    fi
  fi

  case "${#ids[@]}" in
    0)
      die "could not resolve an app info record for app $APP_ID"
      ;;
    1)
      printf '%s\n' "${ids[0]}"
      ;;
    *)
      if [[ "${#platform_env_names[@]}" -gt 0 ]]; then
        die "multiple app info records found for app $APP_ID platform $platform; set one of ${platform_env_names[*]} or ASC_APP_INFO_ID to one of: ${ids[*]}"
      fi

      die "multiple app info records found for app $APP_ID; set ASC_APP_INFO_ID to one of: ${ids[*]}"
      ;;
  esac
}

extract_next_build_number() {
  jq -r '
    [
      .nextBuildNumber?,
      .buildNumber?,
      .next?,
      .data.nextBuildNumber?,
      .data.buildNumber?,
      .data.attributes.nextBuildNumber?,
      .data.attributes.buildNumber?
    ]
    | map(select(. != null))
    | .[0] // empty
  '
}

plist_set_string() {
  local file="$1"
  local key="$2"
  local value="$3"

  /usr/libexec/PlistBuddy -c "Set :$key $value" "$file" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$file" >/dev/null
}

require_plist_value() {
  local file="$1"
  local key="$2"
  local expected="$3"

  [[ "$(plist_value "$file" "$key")" == "$expected" ]] \
    || die "$file must set $key=$expected"
}

validate_export_options() {
  local file="$1"

  [[ -f "$file" ]] || die "missing export options plist: $file"
  plutil -lint "$file" >/dev/null

  require_plist_value "$file" destination export
  require_plist_value "$file" method app-store-connect
  require_plist_value "$file" signingStyle automatic
  require_plist_value "$file" teamID "$ASC_TEAM_ID"
  require_plist_value "$file" manageAppVersionAndBuildNumber false
  require_plist_value "$file" uploadSymbols true
}

json_string() {
  local file="$1"
  local filter="$2"

  [[ -f "$file" ]] || return 0
  jq -r "$filter // empty | strings" "$file"
}

app_metadata_string() {
  json_string "$ASC_APP_METADATA" "$1"
}

review_detail_string() {
  local key="$1"
  local env_name="$2"

  if [[ -n "${!env_name:-}" ]]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi

  local value
  value="$(json_string "$ASC_REVIEW_DETAILS_LOCAL" ".reviewDetails[\"$key\"]")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  json_string "$ASC_APP_METADATA" ".reviewDetails[\"$key\"]"
}

load_review_details() {
  review_first_name="$(review_detail_string contactFirstName ASC_REVIEW_CONTACT_FIRST_NAME)"
  review_last_name="$(review_detail_string contactLastName ASC_REVIEW_CONTACT_LAST_NAME)"
  review_email="$(review_detail_string contactEmail ASC_REVIEW_CONTACT_EMAIL)"
  review_notes="$(review_detail_string notes ASC_REVIEW_NOTES)"
  review_demo_user="$(review_detail_string demoAccountName ASC_REVIEW_DEMO_ACCOUNT_NAME)"
  review_demo_password="$(review_detail_string demoAccountPassword ASC_REVIEW_DEMO_ACCOUNT_PASSWORD)"

  review_missing_fields=()
  [[ -n "$review_first_name" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_FIRST_NAME or $ASC_APP_METADATA reviewDetails.contactFirstName")
  [[ -n "$review_last_name" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_LAST_NAME or $ASC_APP_METADATA reviewDetails.contactLastName")
  [[ -n "$review_email" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_EMAIL or $ASC_APP_METADATA reviewDetails.contactEmail")

  if [[ -n "$review_demo_user" && -z "$review_demo_password" ]]; then
    die "demo account name is set but demo password is missing; set ASC_REVIEW_DEMO_ACCOUNT_PASSWORD or $ASC_REVIEW_DETAILS_LOCAL reviewDetails.demoAccountPassword"
  fi

  if [[ -z "$review_demo_user" && -n "$review_demo_password" ]]; then
    die "demo account password is set but demo account name is missing; set ASC_REVIEW_DEMO_ACCOUNT_NAME or $ASC_REVIEW_DETAILS_LOCAL reviewDetails.demoAccountName"
  fi
}

require_complete_review_details() {
  if [[ "${#review_missing_fields[@]}" -gt 0 ]]; then
    die "missing required App Review details: ${review_missing_fields[*]}"
  fi
}
