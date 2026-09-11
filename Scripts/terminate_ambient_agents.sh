#!/bin/sh

set -eu

if [ "${CONFIGURATION:-}" != "Debug" ]; then
    exit 0
fi

is_ambient_command() {
    command=$1

    for products_dir in \
        "${BUILT_PRODUCTS_DIR:-}" \
        "${CONFIGURATION_BUILD_DIR:-}"
    do
        [ -n "$products_dir" ] || continue

        for executable in \
            "$products_dir/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/MacOS/Big Wallet" \
            "$products_dir/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/MacOS/Big Wallet" \
            "$products_dir/Big Wallet.app/Contents/Helpers/Big Wallet.app/Contents/MacOS/Big Wallet" \
            "$products_dir/Big Wallet Helper.app/Contents/MacOS/Big Wallet" \
            "$products_dir/Big Wallet.app/Contents/Helpers/Big Wallet Helper.app/Contents/MacOS/Big Wallet" \
            "$products_dir/Big Wallet Helper.app/Contents/MacOS/Big Wallet Helper" \
            "$products_dir/Big Wallet.app/Contents/Helpers/Big Wallet Helper.app/Contents/MacOS/Big Wallet Helper" \
            "$products_dir/Big Wallet Ambient.app/Contents/MacOS/Big Wallet Ambient" \
            "$products_dir/Big Wallet.app/Contents/Helpers/Big Wallet Ambient.app/Contents/MacOS/Big Wallet Ambient"
        do
            case "$command" in
                "$executable"|"$executable "*) return 0 ;;
            esac
        done
    done

    return 1
}

command_for_pid() {
    raw_command=$(/bin/ps -p "$1" -o command= 2>/dev/null) || return 1
    printf '%s\n' "$raw_command" |
        /usr/bin/sed -e 's/^[[:space:]]*//'
}

processes=$(/bin/ps -axww -o pid= -o command=) || {
    echo "Unable to enumerate running processes before embedding the Ambient helper." >&2
    exit 1
}
pids=$(printf '%s\n' "$processes" | while read -r pid command; do
    if is_ambient_command "$command"; then
        echo "$pid"
    fi
done)

term_pids=""
failed=0
for pid in $pids; do
    command=$(command_for_pid "$pid") || continue
    if is_ambient_command "$command"; then
        if /bin/kill -TERM "$pid" 2>/dev/null; then
            term_pids="$term_pids $pid"
        else
            echo "Unable to terminate Big Wallet Helper process $pid." >&2
            failed=1
        fi
    fi
done

if [ -z "$term_pids" ]; then
    exit "$failed"
fi

echo "Terminating Big Wallet Helper processes:${term_pids}."
sleep 0.5
for pid in $term_pids; do
    command=$(command_for_pid "$pid") || continue
    if is_ambient_command "$command"; then
        echo "Big Wallet Helper process $pid did not exit after TERM." >&2
        failed=1
    fi
done
exit "$failed"
