#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd jq
require_cmd plutil

validate_file() {
  local file="$1"
  shift

  plutil -lint "$file" >/dev/null

  local json
  json="$(plutil -convert json -o - -- "$file")"

  local field
  for field in "$@"; do
    jq -e --arg field "$field" '
      .[$field] | type == "string" and length > 0
    ' <<<"$json" >/dev/null || die "$file is missing required field $field"
  done
}

[[ -d "$ASC_APP_INFO_DIR" ]] || die "missing $ASC_APP_INFO_DIR"
[[ -d "$ASC_VERSION_DIR" ]] || die "missing $ASC_VERSION_DIR"

app_count=0
while IFS= read -r -d '' file; do
  validate_file "$file" name subtitle privacyPolicyUrl
  app_count=$((app_count + 1))
done < <(find "$ASC_APP_INFO_DIR" -name '*.strings' -type f -print0 | sort -z)

version_count=0
while IFS= read -r -d '' file; do
  validate_file "$file" description keywords supportUrl whatsNew
  version_count=$((version_count + 1))
done < <(find "$ASC_VERSION_DIR" -name '*.strings' -type f -print0 | sort -z)

[[ "$app_count" -gt 0 ]] || die "no app-info localization files found"
[[ "$version_count" -gt 0 ]] || die "no version localization files found"

for locale in ml sl te or ta bn mr kn pa ur gu; do
  file="$ASC_VERSION_DIR/$locale.strings"
  [[ -f "$file" ]] || die "problem locale is missing: $file"
  validate_file "$file" whatsNew
done

log "validated $app_count app-info and $version_count version localization files"
