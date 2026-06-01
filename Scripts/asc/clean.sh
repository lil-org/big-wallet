#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

rm -rf build .asc/artifacts .asc/tmp .asc/reports

log "removed local build artifacts"
