#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

if [ "${1:-}" = --help ]; then
    echo 'Run shipped-main upgrade and backup recovery verification in the test VM.'
    echo 'Use Scripts/test_vm.sh run all --stage upgrade for Debug and Release.'
    exit 0
fi

configuration=${UPGRADE_CONFIGURATION:-Debug}
case "$configuration" in
    Debug|Release) ;;
    *) echo 'UPGRADE_CONFIGURATION must be Debug or Release' >&2; exit 2 ;;
esac

. "$script_dir/vm/guest_session.sh"
if ! test_vm_is_virtual_mac; then
    if [ "$#" -ne 0 ]; then
        echo 'Upgrade output directories are owned by the VM runner' >&2
        exit 2
    fi
    exec "$script_dir/test_vm.sh" run all --stage upgrade --configuration "$configuration"
fi
test_vm_require_guest_session || exit 2
exec node "$script_dir/wallet_upgrade/run.mjs" --configuration "$configuration" "$@"
