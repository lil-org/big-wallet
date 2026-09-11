#!/bin/sh

set -eu

helpers_directory="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"

case "${1:-embed}" in
    cleanup-legacy)
        if [ "$CONTENTS_FOLDER_PATH" != "Big Wallet.app/Contents" ]; then
            echo "error: Legacy Ambient helper cleanup must run in the main app target" >&2
            exit 1
        fi
        if [ ! -e "$helpers_directory/Big Wallet.app" ] &&
            [ ! -L "$helpers_directory/Big Wallet.app" ] &&
            [ ! -e "$helpers_directory/Big Wallet Helper.app" ] &&
            [ ! -L "$helpers_directory/Big Wallet Helper.app" ] &&
            [ ! -e "$helpers_directory/Big Wallet Ambient.app" ] &&
            [ ! -L "$helpers_directory/Big Wallet Ambient.app" ]; then
            exit 0
        fi
        /bin/sh "$PROJECT_DIR/Scripts/terminate_ambient_agents.sh"
        /bin/rm -rf \
            "$helpers_directory/Big Wallet.app" \
            "$helpers_directory/Big Wallet Helper.app" \
            "$helpers_directory/Big Wallet Ambient.app"
        exit 0
        ;;
    embed)
        if [ "$CONTENTS_FOLDER_PATH" != "Safari macOS.appex/Contents" ]; then
            echo "error: The Ambient helper must be embedded in the Safari macOS extension" >&2
            exit 1
        fi
        ;;
    *)
        echo "error: Unknown Ambient helper embedding mode" >&2
        exit 1
        ;;
esac

source_app="$BUILT_PRODUCTS_DIR/Big Wallet Helper.app"
destination_app="$helpers_directory/Big Wallet.app"

if [ ! -d "$source_app" ]; then
    echo "error: Missing ambient helper product at $source_app" >&2
    exit 1
fi

/bin/mkdir -p "$helpers_directory"
/bin/sh "$PROJECT_DIR/Scripts/terminate_ambient_agents.sh"
/bin/rm -rf \
    "$helpers_directory/Big Wallet.app" \
    "$helpers_directory/Big Wallet Helper.app" \
    "$helpers_directory/Big Wallet Ambient.app"
/usr/bin/ditto "$source_app" "$destination_app"
