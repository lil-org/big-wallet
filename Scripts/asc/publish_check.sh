#!/usr/bin/env bash
set +x
set +a
set -euo pipefail

unset _asc_entrypoint_source _asc_entrypoint_directory
_asc_entrypoint_source="${BASH_SOURCE[0]}"
case "$_asc_entrypoint_source" in
  */*) _asc_entrypoint_directory="${_asc_entrypoint_source%/*}" ;;
  *) _asc_entrypoint_directory="." ;;
esac
source "$_asc_entrypoint_directory/common.sh"
unset _asc_entrypoint_source _asc_entrypoint_directory

platform="${1:-${PLATFORM:-IOS}}"
validate_macos_app_sandbox_information_confirmation "$platform"

. "$REPO_ROOT/Scripts/inpage_provider_toolchain.sh"

require_cmd xcodebuild
require_cmd plutil
require_cmd jq
inpage_provider_prepare_tool_path "$REPO_ROOT"
require_inpage_provider_toolchain

validate_export_options "$ASC_EXPORT_OPTIONS"
version="$(current_local_version)"
build_number="$(current_local_build_number)"
validate_local_version_sources "$version" "$build_number"
validate_alchemy_release_inputs

log "publish preflight ok"
