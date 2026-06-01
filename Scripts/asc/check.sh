#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd asc
require_cmd git
require_cmd jq
require_cmd plutil

version_ge() {
  local actual="$1"
  local required="$2"
  local IFS=.
  local actual_parts=()
  local required_parts=()
  read -r -a actual_parts <<<"$actual"
  read -r -a required_parts <<<"$required"

  local length="${#actual_parts[@]}"
  if (( ${#required_parts[@]} > length )); then
    length="${#required_parts[@]}"
  fi

  local i actual_part required_part
  for (( i = 0; i < length; i++ )); do
    actual_part="${actual_parts[$i]:-0}"
    required_part="${required_parts[$i]:-0}"

    [[ "$actual_part" =~ ^[0-9]+$ && "$required_part" =~ ^[0-9]+$ ]] \
      || return 1

    if (( actual_part > required_part )); then
      return 0
    fi

    if (( actual_part < required_part )); then
      return 1
    fi
  done

  return 0
}

actual_version="$(asc --version | awk '{print $1}' | sed 's/^v//')"
version_ge "$actual_version" "1.2.7" \
  || die "asc 1.2.7 or newer is required; found $actual_version"

if [[ "${SKIP_ASC_AUTH_CHECK:-0}" != "1" ]]; then
  auth_json="$(asc auth status --output json)"
  jq -e '
    (.environmentCredentialsComplete == true) or
    ((.credentials // []) | length > 0)
  ' <<<"$auth_json" >/dev/null \
    || die "asc auth is not configured; run asc auth login or provide ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_B64/ASC_PRIVATE_KEY/ASC_PRIVATE_KEY_PATH"
fi

log "preflight ok: asc $actual_version, app $APP_ID, project $PROJECT"
