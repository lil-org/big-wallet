#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd jq

version_id="${1:-}"
require_review_details="${2:-false}"
platform="${3:-${PLATFORM:-}}"

[[ -n "$version_id" ]] || die "usage: $0 VERSION_ID"

case "$require_review_details" in
  true|false) ;;
  *) die "require_review_details must be true or false, got $require_review_details" ;;
esac

sync_review_details=false
review_args=()

load_review_details

if [[ "${#review_missing_fields[@]}" -gt 0 ]]; then
  if [[ "$require_review_details" == "true" ]]; then
    require_complete_review_details
  fi

  log "skipping App Review details sync; missing ${review_missing_fields[*]}"
else
  sync_review_details=true
  review_args=(
    --contact-first-name "$review_first_name"
    --contact-last-name "$review_last_name"
    --contact-email "$review_email"
    --notes "$review_notes"
  )

  if [[ -n "${ASC_REVIEW_CONTACT_PHONE:-}" ]]; then
    review_args+=(--contact-phone "$ASC_REVIEW_CONTACT_PHONE")
  fi

  if [[ -n "$review_demo_user" ]]; then
    review_args+=(--demo-account-required=true)
    review_args+=(--demo-account-name "$review_demo_user")
    review_args+=(--demo-account-password "$review_demo_password")
  else
    review_args+=(--demo-account-required=false)
  fi
fi

copyright="$(app_metadata_string '.copyright')"
if [[ -n "$copyright" ]]; then
  log "updating version copyright"
  asc versions update \
    --version-id "$version_id" \
    --copyright "$copyright" \
    --output json
fi

primary_category="$(app_metadata_string '.categories.primary')"
if [[ -n "$primary_category" ]]; then
  app_info_id="$(resolve_app_info_id "$platform")"
  primary_subcategory_one="$(app_metadata_string '.categories.primarySubcategoryOne')"
  primary_subcategory_two="$(app_metadata_string '.categories.primarySubcategoryTwo')"
  secondary_category="$(app_metadata_string '.categories.secondary')"
  secondary_subcategory_one="$(app_metadata_string '.categories.secondarySubcategoryOne')"
  secondary_subcategory_two="$(app_metadata_string '.categories.secondarySubcategoryTwo')"

  read_category_relationship_id() {
    local relationship="$1"

    asc apps info relationships "$relationship" \
      --info-id "$app_info_id" \
      --output json \
      | extract_first_id
  }

  category_relationships=(
    primary-category
    primary-subcategory-one
    primary-subcategory-two
    secondary-category
    secondary-subcategory-one
    secondary-subcategory-two
  )
  category_flags=(
    --primary
    --primary-subcategory-one
    --primary-subcategory-two
    --secondary
    --secondary-subcategory-one
    --secondary-subcategory-two
  )
  category_values=(
    "$primary_category"
    "$primary_subcategory_one"
    "$primary_subcategory_two"
    "$secondary_category"
    "$secondary_subcategory_one"
    "$secondary_subcategory_two"
  )
  category_args=(
    categories set
    --app "$APP_ID"
    --app-info "$app_info_id"
  )

  categories_match=true
  for category_index in "${!category_relationships[@]}"; do
    desired_category="${category_values[$category_index]}"

    if [[ -n "$desired_category" ]]; then
      category_args+=("${category_flags[$category_index]}" "$desired_category")
    fi

    current_category="$(read_category_relationship_id "${category_relationships[$category_index]}")"
    [[ "$current_category" == "$desired_category" ]] || categories_match=false
  done

  if [[ "$categories_match" == "true" ]]; then
    log "app categories already match metadata; skipping update"
  else
    log "updating app categories"
    category_args+=(--output json)
    asc "${category_args[@]}"
  fi
fi

if [[ "$sync_review_details" == "true" ]]; then
  detail_id=""
  set +e
  details_json="$(asc review details-for-version \
    --version-id "$version_id" \
    --output json 2>/dev/null)"
  details_status=$?
  set -e

  if [[ "$details_status" -eq 0 ]]; then
    detail_id="$(extract_first_id <<<"$details_json")"
  fi

  if [[ -n "$detail_id" && "$detail_id" != "null" ]]; then
    log "updating App Review details"
    asc review details-update \
      --id "$detail_id" \
      "${review_args[@]}" \
      --output json
  else
    log "creating App Review details"
    asc review details-create \
      --version-id "$version_id" \
      "${review_args[@]}" \
      --output json
  fi
fi
