#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

. "$script_dir/inpage_provider_toolchain.sh"
inpage_provider_prepare_tool_path "$repo_dir"

if ! inpage_provider_run_node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'; then
    echo "error: Node.js 18 or newer is required to check the wire protocol" >&2
    exit 1
fi

inpage_provider_run_node "$script_dir/generate_wire_protocol.mjs" --check
