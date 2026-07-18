#!/bin/sh

set -eu

default_key_file="/Users/ivan/Developer/secrets/tools/ALCHEMY_API_KEY"

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

normalize_key() {
    LC_ALL=C awk '
        BEGIN {
            value = ""
            seen_value = 0
            seen_trailing_line_ending = 0
            invalid = 0
        }
        {
            sub(/\r$/, "")

            if ($0 == "") {
                if (seen_value) {
                    seen_trailing_line_ending = 1
                }
                next
            }

            if (seen_value || seen_trailing_line_ending) {
                invalid = 1
            }

            value = $0
            seen_value = 1
        }
        END {
            if (invalid) {
                exit 2
            }
            printf "%s", value
        }
    '
}

if [ -n "${ALCHEMY_API_KEY:-}" ]; then
    if ! alchemy_api_key=$(printf '%s' "$ALCHEMY_API_KEY" | normalize_key); then
        fail "ALCHEMY_API_KEY must contain exactly one value"
    fi
else
    if [ -n "${ALCHEMY_API_KEY_FILE:-}" ]; then
        key_file=$ALCHEMY_API_KEY_FILE
    else
        key_file=$default_key_file
    fi

    if [ ! -f "$key_file" ] || [ ! -r "$key_file" ]; then
        fail "Alchemy API key file is missing or unreadable: $key_file"
    fi

    if ! alchemy_api_key=$(normalize_key < "$key_file"); then
        fail "Alchemy API key file must contain exactly one value"
    fi
fi

if [ -z "$alchemy_api_key" ]; then
    fail "Alchemy API key is empty"
fi

case "$alchemy_api_key" in
    *[[:space:]]*)
        fail "Alchemy API key must not contain whitespace"
        ;;
esac

if [ -z "${TARGET_BUILD_DIR:-}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    fail "TARGET_BUILD_DIR and UNLOCALIZED_RESOURCES_FOLDER_PATH are required"
fi

resource_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
output_path="${resource_directory}/AlchemyAPIKey"

umask 077
mkdir -p "$resource_directory"
# TARGET_BUILD_DIR contains the product, so staging here stays outside the signed bundle
# while remaining on the same filesystem as the destination.
if ! temporary_path=$(mktemp "${TARGET_BUILD_DIR}/.AlchemyAPIKey.XXXXXX"); then
    fail "Could not create temporary Alchemy API key file"
fi
trap 'rm -f "$temporary_path"' EXIT HUP INT TERM
printf '%s' "$alchemy_api_key" > "$temporary_path"
chmod 600 "$temporary_path"
# Earlier versions staged beside the resource; remove those orphanable files before signing.
rm -f "${output_path}.tmp."*
mv -f "$temporary_path" "$output_path"
chmod 644 "$output_path"
trap - EXIT HUP INT TERM
