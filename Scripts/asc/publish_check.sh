#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
. "$REPO_ROOT/Scripts/inpage_provider_toolchain.sh"

require_cmd xcodebuild
require_cmd plutil
inpage_provider_prepare_tool_path
require_inpage_provider_toolchain

validate_export_options "$ASC_EXPORT_OPTIONS"

log "publish preflight ok"
