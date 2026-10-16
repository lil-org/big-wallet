#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

mode=${1:-all}
case "$mode" in
    --help|-h)
        echo 'Usage: Scripts/check_swift6.sh [all|build|test|performance|tsan|fuzz|approval]'
        echo 'Host invocations run inside the headless test VM. Use Scripts/test_vm.sh for setup and results.'
        exit 0
        ;;
    all|build|test|performance|tsan|fuzz|approval) ;;
    *) echo 'Usage: Scripts/check_swift6.sh [all|build|test|performance|tsan|fuzz|approval]' >&2; exit 2 ;;
esac
. "$script_dir/vm/guest_session.sh"
if test_vm_is_virtual_mac; then
    echo 'Submit selected stages from the host with Scripts/test_vm.sh.' >&2
    exit 2
fi
if [ "$mode" = all ]; then
    exec "$script_dir/test_vm.sh" run all
fi
exec "$script_dir/test_vm.sh" run all --stage "$mode"
