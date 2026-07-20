#!/bin/sh

set -eu

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

if [ "${SCRIPT_OUTPUT_FILE_COUNT:-0}" != "1" ]; then
    fail "exactly one cleanup output path is required"
fi

if [ -z "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
    fail "the cleanup output path is missing"
fi

if [ -z "${TARGET_BUILD_DIR:-}" ] ||
    [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]
then
    fail "TARGET_BUILD_DIR and UNLOCALIZED_RESOURCES_FOLDER_PATH are required"
fi

case "$TARGET_BUILD_DIR" in
    /*)
        ;;
    *)
        fail "TARGET_BUILD_DIR must be absolute"
        ;;
esac

case "$UNLOCALIZED_RESOURCES_FOLDER_PATH" in
    /*|*/|..|../*|*/..|*/../*)
        fail "UNLOCALIZED_RESOURCES_FOLDER_PATH must stay within the target"
        ;;
esac

expected_path="${TARGET_BUILD_DIR%/}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AlchemyAPIKey"
if [ "$SCRIPT_OUTPUT_FILE_0" != "$expected_path" ]; then
    fail "the cleanup output path does not match the target resource"
fi

resource_parent="${TARGET_BUILD_DIR%/}"
remaining_path=$UNLOCALIZED_RESOURCES_FOLDER_PATH
while [ -n "$remaining_path" ]; do
    case "$remaining_path" in
        */*)
            component=${remaining_path%%/*}
            remaining_path=${remaining_path#*/}
            ;;
        *)
            component=$remaining_path
            remaining_path=
            ;;
    esac

    if [ -z "$component" ] || [ "$component" = "." ] ||
        [ "$component" = ".." ]
    then
        fail "the target resource path is invalid"
    fi

    resource_parent="$resource_parent/$component"
    if [ -L "$resource_parent" ]; then
        fail "the target resource path must not traverse symbolic links"
    fi
done

if [ -d "$expected_path" ] && [ ! -L "$expected_path" ]; then
    fail "the legacy Alchemy key resource path is unexpectedly a directory"
fi

# Never inspect or print the legacy file. Removing this exact declared output is
# sufficient to clean products retained in reused DerivedData.
/bin/rm -f "$expected_path"

if [ -e "$expected_path" ] || [ -L "$expected_path" ]; then
    fail "the legacy Alchemy key resource could not be removed"
fi
