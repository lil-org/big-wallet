#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmd jq

load_review_details
require_complete_review_details

log "App Review details preflight ok"
