#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

. "$script_dir/inpage_provider_toolchain.sh"
inpage_provider_prepare_tool_path "$repo_dir"
require_inpage_provider_toolchain

if [ "${1:-}" = --help ]; then
    inpage_provider_run_node "$script_dir/approval_lifecycle/run.mjs" --help
    exit 0
fi

configuration=${APPROVAL_CONFIGURATION:-Debug}
case "$configuration" in
    Debug|Release) ;;
    *) echo 'APPROVAL_CONFIGURATION must be Debug or Release' >&2; exit 2 ;;
esac

"$script_dir/check_wire_protocol.sh"
inpage_provider_run_node "$script_dir/validate_approval_worker_target.mjs"
inpage_provider_run_node --test "$script_dir/tests/approval_worker_target.test.mjs"
inpage_provider_run_node --test "$repo_dir"/"Safari Shared"/Tests/approval_lifecycle_*.test.mjs
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/big-wallet-approval-build.XXXXXX")
trap 'rm -rf "$build_directory"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Building isolated approval worker ($configuration)"
if ! xcodebuild -jobs 2 build -project Wallet.xcodeproj \
    -scheme ApprovalCrashWorker -configuration "$configuration" \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    > "$build_directory/build.log" 2>&1; then
    cat "$build_directory/build.log" >&2
    exit 1
fi

xcodebuild -showBuildSettings -json -project Wallet.xcodeproj \
    -scheme ApprovalCrashWorker -configuration "$configuration" \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    > "$build_directory/settings.json"
worker=$(inpage_provider_run_node --input-type=module - "$build_directory/settings.json" <<'JS'
import {readFileSync} from "node:fs";
import {join} from "node:path";
const targets = JSON.parse(readFileSync(process.argv[2], "utf8"));
const settings = targets.find(target => target.target === "ApprovalCrashWorker")?.buildSettings;
if (!settings?.TARGET_BUILD_DIR || !settings?.EXECUTABLE_PATH) {
    throw new Error("ApprovalCrashWorker build settings are missing");
}
process.stdout.write(join(settings.TARGET_BUILD_DIR, settings.EXECUTABLE_PATH));
JS
)
test -x "$worker"
inpage_provider_run_node "$script_dir/approval_lifecycle/run.mjs" --worker "$worker" "$@"
