#!/bin/sh

if [ "$CONFIGURATION" != "Debug" ]; then
    exit 0
fi

is_ambient_command() {
    command=$1

    for products_dir in "$BUILT_PRODUCTS_DIR" "$CONFIGURATION_BUILD_DIR"; do
        [ -n "$products_dir" ] || continue

        for executable in \
            "$products_dir/Big Wallet.app/Contents/MacOS/Big Wallet" \
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

pids=$(/bin/ps -axww -o pid= -o command= | while read -r pid command; do
    if is_ambient_command "$command"; then
        echo "$pid"
    fi
done)

if [ -z "$pids" ]; then
    exit 0
fi

echo "Terminating Big Wallet Helper processes: $pids."
/bin/kill -TERM $pids 2>/dev/null || true
sleep 0.5
/bin/kill -KILL $pids 2>/dev/null || true
