#!/bin/sh

set -eu

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

temporary_output=""
resource_path=""
resource_path_is_safe=0
bundle_complete=0

cleanup() {
    if [ -n "$temporary_output" ]; then
        /bin/rm -f "$temporary_output"
    fi
    temporary_output=""

    if [ "$resource_path_is_safe" -eq 1 ] &&
        [ "$bundle_complete" -ne 1 ]
    then
        /bin/rm -f "$resource_path"
    fi
}

trap cleanup 0
trap 'exit 1' 1 2 15

if [ "${SCRIPT_OUTPUT_FILE_COUNT:-0}" != "1" ]; then
    fail "exactly one request-proof resource output path is required"
fi

if [ -z "${SCRIPT_OUTPUT_FILE_0:-}" ]; then
    fail "the request-proof resource output path is missing"
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

resource_path="${TARGET_BUILD_DIR%/}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AlchemyJWTRequestProofKey"
if [ "$SCRIPT_OUTPUT_FILE_0" != "$resource_path" ]; then
    fail "the request-proof output path does not match the target resource"
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

[ -d "$resource_parent" ] ||
    fail "the target resource directory does not exist"

resource_path_is_safe=1
if [ -e "$resource_path" ] &&
    [ ! -f "$resource_path" ] &&
    [ ! -L "$resource_path" ]
then
    fail "the request-proof resource path is not a regular file"
fi
/bin/rm -f "$resource_path" ||
    fail "a stale request-proof resource could not be removed"
if [ -e "$resource_path" ] || [ -L "$resource_path" ]; then
    fail "a stale request-proof resource could not be removed"
fi

key_file=${ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE:-}
[ -n "$key_file" ] ||
    fail "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE is required"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
. "$script_directory/alchemy_jwt_request_proof_key_common.sh"
load_alchemy_jwt_request_proof_key \
    "$key_file" \
    "$script_directory/alchemy_jwt_request_proof_key.sha256"

umask 077
temporary_output=$(
    /usr/bin/mktemp \
        "${TARGET_BUILD_DIR%/}/.AlchemyJWTRequestProofKey.XXXXXX"
) || fail "a temporary request-proof resource could not be created"

# Normalize the optional source newline so every shipped resource has the
# exact canonical 43-byte representation expected by the client.
printf '%s' "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" > "$temporary_output"
/bin/chmod 0644 "$temporary_output"
/bin/mv -f "$temporary_output" "$resource_path"
temporary_output=""

if [ -L "$resource_path" ] || [ ! -f "$resource_path" ]; then
    fail "the request-proof resource was not written as a regular file"
fi

resource_metadata=$(/usr/bin/stat -f '%Lp:%z' -- "$resource_path") ||
    fail "the request-proof resource metadata could not be inspected"
resource_size=${resource_metadata##*:}
resource_mode=${resource_metadata%:*}
[ "$resource_mode" = "644" ] ||
    fail "the request-proof resource has unexpected permissions"
[ "$resource_size" -eq 43 ] ||
    fail "the request-proof resource has an unexpected size"

bundle_complete=1
