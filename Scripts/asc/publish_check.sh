#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$REPO_ROOT/Scripts/inpage_provider_toolchain.sh"

require_cmd xcodebuild
require_cmd plutil
require_cmd jq
inpage_provider_prepare_tool_path
require_inpage_provider_toolchain

validate_export_options "$ASC_EXPORT_OPTIONS"
version="$(current_local_version)"
build_number="$(current_local_build_number)"
validate_local_version_sources "$version" "$build_number"

log "publish preflight ok"
