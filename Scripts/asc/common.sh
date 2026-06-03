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
ASC_APP_INFO_DIR="${ASC_APP_INFO_DIR:-.asc/localizations/app-info}"
ASC_VERSION_DIR="${ASC_VERSION_DIR:-.asc/localizations/version}"
ASC_IOS_SCREENSHOTS="${ASC_IOS_SCREENSHOTS:-.asc/screenshots/ios}"
ASC_MACOS_SCREENSHOTS="${ASC_MACOS_SCREENSHOTS:-.asc/screenshots/macos}"
ASC_VISIONOS_SCREENSHOTS="${ASC_VISIONOS_SCREENSHOTS:-.asc/screenshots/visionos}"
ASC_APP_INFO_ID="${ASC_APP_INFO_ID:-}"
ASC_APP_METADATA="${ASC_APP_METADATA:-.asc/app-metadata.json}"
ASC_REVIEW_DETAILS_LOCAL="${ASC_REVIEW_DETAILS_LOCAL:-.asc/review-details.local.json}"
ASC_EXPORT_OPTIONS="${ASC_EXPORT_OPTIONS:-.asc/export-options-app-store.plist}"
ASC_TEAM_ID="${ASC_TEAM_ID:-8DXC3N7E7P}"

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
  [[ -n "$review_first_name" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_FIRST_NAME or .asc app metadata reviewDetails.contactFirstName")
  [[ -n "$review_last_name" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_LAST_NAME or .asc app metadata reviewDetails.contactLastName")
  [[ -n "$review_email" ]] || review_missing_fields+=("ASC_REVIEW_CONTACT_EMAIL or .asc app metadata reviewDetails.contactEmail")

  if [[ -n "$review_demo_user" && -z "$review_demo_password" ]]; then
    die "demo account name is set but demo password is missing; set ASC_REVIEW_DEMO_ACCOUNT_PASSWORD or .asc/review-details.local.json reviewDetails.demoAccountPassword"
  fi

  if [[ -z "$review_demo_user" && -n "$review_demo_password" ]]; then
    die "demo account password is set but demo account name is missing; set ASC_REVIEW_DEMO_ACCOUNT_NAME or .asc/review-details.local.json reviewDetails.demoAccountName"
  fi
}

require_complete_review_details() {
  if [[ "${#review_missing_fields[@]}" -gt 0 ]]; then
    die "missing required App Review details: ${review_missing_fields[*]}"
  fi
}
