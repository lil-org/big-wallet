#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd curl
require_cmd jq
export ASC_TIMEOUT="${ASC_TIMEOUT:-120s}"

platform="${1:-${PLATFORM:-IOS}}"
build_id="${2:-${BUILD_ID:-}}"
version="$(target_version)"
version_id="$(Scripts/asc/ensure_version.sh "$platform" "$version")"
version_state="$(asc versions view --version-id "$version_id" --output json | extract_app_store_version_state)"

if app_store_version_is_submitted_state "$version_state"; then
  log "$platform $version is already in App Store state $version_state; skipping review submission"
  exit 0
fi

resolve_rejected_review_items() {
  local item_ids=()
  local item_id
  local schema_json
  local token
  local request_body
  local response
  local state

  while IFS= read -r item_id; do
    [[ -n "$item_id" ]] && item_ids+=("$item_id")
  done < <(
    asc review history \
      --app "$APP_ID" \
      --platform "$platform" \
      --output json \
      | extract_rejected_review_submission_item_ids_for_version "$version_id"
  )

  [[ "${#item_ids[@]}" -gt 0 ]] || return 0

  schema_json="$(asc schema --method PATCH reviewSubmissionItems)"
  jq -e '
    any(.[]; .path == "/v1/reviewSubmissionItems/{id}" and (.requestAttributes.resolved == "boolean"))
  ' <<<"$schema_json" >/dev/null \
    || die "asc schema does not expose an official reviewSubmissionItems resolved update field"

  log "marking ${#item_ids[@]} rejected App Review item(s) ready for review"
  token="$(asc auth token --confirm)"

  for item_id in "${item_ids[@]}"; do
    request_body="$(jq -n \
      --arg id "$item_id" \
      '{
        data: {
          type: "reviewSubmissionItems",
          id: $id,
          attributes: {
            resolved: true
          }
        }
      }')"

    response="$(curl -fsS \
      -X PATCH \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$request_body" \
      "https://api.appstoreconnect.apple.com/v1/reviewSubmissionItems/$item_id")"

    state="$(jq -r '.data.attributes.state // empty' <<<"$response")"
    [[ "$state" == "READY_FOR_REVIEW" ]] \
      || die "App Store Connect returned review item state=${state:-missing} after resolving $item_id"
  done
}

review_submit_error_is_retryable() {
  local output="$1"

  [[ "$output" == *"not ready to be submitted yet"* || "$output" == *"please try again later"* ]]
}

submit_review_with_retry() {
  local attempts="${ASC_REVIEW_SUBMIT_ATTEMPTS:-6}"
  local delay="${ASC_REVIEW_SUBMIT_RETRY_DELAY:-30}"
  local attempt=1
  local output
  local status

  while true; do
    set +e
    output="$(asc review submit \
      --app "$APP_ID" \
      --version-id "$version_id" \
      --build "$build_id" \
      --platform "$platform" \
      --confirm \
      --output json 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$output"

    if [[ "$status" -eq 0 ]]; then
      return 0
    fi

    if (( attempt >= attempts )) || ! review_submit_error_is_retryable "$output"; then
      return "$status"
    fi

    log "review submission is not ready yet; retrying in ${delay}s (${attempt}/${attempts})"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}

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
resolve_rejected_review_items
submit_review_with_retry
