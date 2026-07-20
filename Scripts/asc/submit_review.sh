#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd curl
require_cmd jq
export ASC_TIMEOUT="${ASC_TIMEOUT:-120s}"

platform="${1:-${PLATFORM:-IOS}}"
build_id="${2:-${BUILD_ID:-}}"
local_version="$(current_local_version)"
build_number="$(current_local_build_number)"
version="${VERSION:-$local_version}"
validate_local_version_sources "$version" "$build_number"

proof_key_file="${ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE:-}"
[[ -n "$proof_key_file" ]] \
  || die "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE is required for review submission"
"$REPO_ROOT/Scripts/validate_alchemy_jwt_request_proof_key_file.sh" \
  "$proof_key_file"
proof_fingerprint="$(alchemy_request_proof_fingerprint)"

load_and_validate_alchemy_release_receipt \
  "$platform" \
  "$version" \
  "$build_number" \
  "$build_id" \
  "$proof_fingerprint"
build_id="$ALCHEMY_RELEASE_RECEIPT_BUILD_ID"
artifact_path="$ALCHEMY_RELEASE_RECEIPT_ARTIFACT_PATH"

"$REPO_ROOT/Scripts/assert_no_bundled_alchemy_key.sh" "$artifact_path"
"$REPO_ROOT/Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh" \
  "$platform" \
  "$artifact_path"
run_alchemy_worker_release_verification "$proof_key_file"

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

log "submitting $platform $version with build $build_id"
resolve_rejected_review_items
submit_review_with_retry
