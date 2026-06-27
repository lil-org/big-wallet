#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

rm -rf build "$ASC_ARTIFACTS_DIR" "$ASC_TMP_DIR" "$ASC_REPORTS_DIR"

log "removed local build artifacts"
