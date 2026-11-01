#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

if [ "${1:-}" = --help ]; then
    echo 'Run curated security mutations only in the test VM.'
    echo 'Scripts/test_vm.sh run all --stage mutation runs six core mutants.'
    echo 'Scripts/test_vm.sh run extended --stage mutation runs nineteen mutants.'
    exit 0
fi

. "$script_dir/vm/guest_session.sh"
if ! test_vm_is_virtual_mac; then
    case "${1:-core}" in
        core) profile=all ;;
        extended) profile=extended ;;
        *) echo 'Use core or extended; mutation output directories belong to the VM runner.' >&2; exit 2 ;;
    esac
    [ "$#" -le 1 ] || { echo 'Mutation output directories belong to the VM runner.' >&2; exit 2; }
    exec "$script_dir/test_vm.sh" run "$profile" --stage mutation
fi
test_vm_require_guest_session || exit 2
exec node "$script_dir/security_mutations/run.mjs" "$@"
