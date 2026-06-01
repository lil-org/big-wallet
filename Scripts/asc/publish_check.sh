#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd xcodebuild
require_cmd plutil

validate_export_options "$ASC_EXPORT_OPTIONS"

log "publish preflight ok"
