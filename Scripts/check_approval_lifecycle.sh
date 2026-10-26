#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

. "$script_dir/inpage_provider_toolchain.sh"
inpage_provider_prepare_tool_path "$repo_dir"

if [ "${1:-}" = --help ]; then
    inpage_provider_run_node "$script_dir/approval_lifecycle/run.mjs" --help
    exit 0
fi

. "$script_dir/vm/guest_session.sh"
if test_vm_is_virtual_mac; then
    test_vm_require_guest_session || exit 2
else
    inpage_provider_run_node --input-type=module - "$script_dir/test_vm.sh" "${APPROVAL_CONFIGURATION:-Debug}" "$@" <<'JS'
import {spawnSync} from 'node:child_process';
const [, , runner, configuration, ...extra] = process.argv;
const result = spawnSync(runner, ['run', 'all', '--stage', 'approval', '--configuration', configuration,
    ...extra.map(value => `--approval-arg=${value}`)], {stdio: 'inherit'});
process.exit(result.status ?? 2);
JS
    exit $?
fi

require_inpage_provider_toolchain
configuration=${APPROVAL_CONFIGURATION:-Debug}
case "$configuration" in
    Debug) swift_configuration=debug ;;
    Release) swift_configuration=release ;;
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
if ! swift build --package-path Packages/WalletRuntimeHarness \
    --configuration "$swift_configuration" --product ApprovalCrashWorker \
    --jobs 2 -Xswiftc -enable-testing \
    > "$build_directory/build.log" 2>&1; then
    cat "$build_directory/build.log" >&2
    exit 1
fi

worker_directory=$(swift build --package-path Packages/WalletRuntimeHarness \
    --configuration "$swift_configuration" --show-bin-path -Xswiftc -enable-testing)
worker="$worker_directory/ApprovalCrashWorker"
test -x "$worker"
inpage_provider_run_node "$script_dir/approval_lifecycle/run.mjs" --worker "$worker" "$@"
