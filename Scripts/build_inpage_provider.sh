#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=${PROJECT_DIR:-$(CDPATH= cd -- "$script_dir/.." && pwd)}
provider_dir="$repo_dir/Safari Shared/Inpage Provider"

if [ ! -d "$provider_dir" ]; then
    echo "error: missing inpage provider directory at $provider_dir"
    exit 1
fi

. "$script_dir/inpage_provider_toolchain.sh"
inpage_provider_prepare_tool_path
require_inpage_provider_toolchain

cd "$provider_dir"

needs_npm_ci=0

if [ ! -f package.json ] || [ ! -f package-lock.json ] || [ ! -d node_modules ] || [ ! -f node_modules/.package-lock.json ] || [ package.json -nt node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
    needs_npm_ci=1
elif ! ./node_modules/.bin/esbuild --version >/dev/null 2>&1; then
    needs_npm_ci=1
fi

if [ "$needs_npm_ci" -eq 1 ]; then
    npm ci --include=dev --include=optional --no-audit --prefer-offline
fi

npm run build
