#!/bin/sh

# Shared request-proof key loading for release scripts. This file is sourced by
# callers that provide a fail() function. It intentionally writes neither the
# key nor its fingerprint to stdout or stderr.

load_alchemy_jwt_request_proof_key() {
    set +x

    # Keep tracing disabled after this function returns: callers still use the
    # loaded key to write or compare bundle resources.
    if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
        fail "the request-proof key and fingerprint paths are required"
    fi

    # Imported environment variables retain their export attribute after an
    # assignment. Clear every variable that will hold key bytes before use so a
    # hostile or stale environment can never cause the loaded key to be passed
    # to child processes.
    unset ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        alchemy_snapshot_with_sentinel \
        alchemy_key_snapshot \
        alchemy_key_prefix \
        alchemy_final_character

    alchemy_key_file=$1
    alchemy_fingerprint_file=$2

    case "$alchemy_key_file" in
        /*)
            ;;
        *)
            fail "the request-proof key file path must be absolute"
            ;;
    esac

    alchemy_key_name=${alchemy_key_file##*/}
    alchemy_key_parent=${alchemy_key_file%/*}
    [ -n "$alchemy_key_name" ] ||
        fail "the request-proof key file path is invalid"
    if [ -z "$alchemy_key_parent" ]; then
        alchemy_key_parent=/
    fi

    alchemy_canonical_parent=$(
        CDPATH= cd -- "$alchemy_key_parent" 2>/dev/null && /bin/pwd -P
    ) || fail "the request-proof key directory could not be inspected"
    alchemy_canonical_key_file="${alchemy_canonical_parent%/}/$alchemy_key_name"
    [ "$alchemy_key_file" = "$alchemy_canonical_key_file" ] ||
        fail "the request-proof key file path must be canonical and must not traverse symbolic links"

    if [ -L "$alchemy_key_file" ]; then
        fail "the request-proof key file must not be a symbolic link"
    fi
    if [ ! -f "$alchemy_key_file" ]; then
        fail "the request-proof key file must be a regular file"
    fi

    alchemy_current_user=$(/usr/bin/id -u) ||
        fail "the current user could not be identified"
    alchemy_parent_owner=$(
        /usr/bin/stat -f '%u' -- "$alchemy_canonical_parent"
    ) || fail "the request-proof key directory owner could not be inspected"
    [ "$alchemy_parent_owner" = "$alchemy_current_user" ] ||
        fail "the request-proof key directory must be owned by the current user"

    alchemy_parent_mode=$(
        /usr/bin/stat -f '%Lp' -- "$alchemy_canonical_parent"
    ) || fail "the request-proof key directory mode could not be inspected"
    case "$alchemy_parent_mode" in
        *[!0-7]*|'')
            fail "the request-proof key directory mode is invalid"
            ;;
    esac
    alchemy_parent_mode_value=$((0$alchemy_parent_mode))
    if [ $((alchemy_parent_mode_value & 077)) -ne 0 ] ||
        [ $((alchemy_parent_mode_value & 0100)) -eq 0 ]
    then
        fail "the request-proof key directory must be owner-only and searchable by its owner"
    fi

    alchemy_metadata_before=$(
        /usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$alchemy_key_file"
    ) || fail "the request-proof key file could not be inspected"

    alchemy_metadata_remainder=$alchemy_metadata_before
    alchemy_file_device=${alchemy_metadata_remainder%%:*}
    alchemy_metadata_remainder=${alchemy_metadata_remainder#*:}
    alchemy_file_inode=${alchemy_metadata_remainder%%:*}
    alchemy_metadata_remainder=${alchemy_metadata_remainder#*:}
    alchemy_file_owner=${alchemy_metadata_remainder%%:*}
    alchemy_metadata_remainder=${alchemy_metadata_remainder#*:}
    alchemy_file_mode=${alchemy_metadata_remainder%%:*}
    alchemy_file_size=${alchemy_metadata_remainder#*:}

    [ -n "$alchemy_file_device" ] && [ -n "$alchemy_file_inode" ] ||
        fail "the request-proof key file identity could not be inspected"
    [ "$alchemy_file_owner" = "$alchemy_current_user" ] ||
        fail "the request-proof key file must be owned by the current user"
    [ "$alchemy_file_mode" = "600" ] ||
        fail "the request-proof key file mode must be 0600"
    case "$alchemy_file_size" in
        43|44)
            ;;
        *)
            fail "the request-proof key file must contain one 43-character base64url line"
            ;;
    esac

    # The sentinel prevents command substitution from stripping a permitted
    # final LF. The key file itself is opened and read exactly once.
    alchemy_snapshot_with_sentinel=$(
        /bin/cat -- "$alchemy_key_file" || exit 1
        printf '.'
    ) || fail "the request-proof key file could not be read"
    alchemy_key_snapshot=${alchemy_snapshot_with_sentinel%?}

    alchemy_metadata_after=$(
        /usr/bin/stat -f '%d:%i:%u:%Lp:%z' -- "$alchemy_key_file"
    ) || fail "the request-proof key file could not be re-inspected"
    [ "$alchemy_metadata_before" = "$alchemy_metadata_after" ] ||
        fail "the request-proof key file changed while it was being read"

    LC_ALL=C
    export LC_ALL
    [ "${#alchemy_key_snapshot}" -eq "$alchemy_file_size" ] ||
        fail "the request-proof key file contains unsupported bytes"

    alchemy_lf='
'
    case "$alchemy_file_size" in
        43)
            ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=$alchemy_key_snapshot
            ;;
        44)
            case "$alchemy_key_snapshot" in
                *"$alchemy_lf")
                    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=${alchemy_key_snapshot%"$alchemy_lf"}
                    ;;
                *)
                    fail "the request-proof key file may end only with a single LF"
                    ;;
            esac
            ;;
    esac

    [ "${#ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE}" -eq 43 ] ||
        fail "the request-proof key must contain exactly 43 characters"
    case "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" in
        *[!A-Za-z0-9_-]*)
            fail "the request-proof key must use unpadded base64url"
            ;;
    esac

    # A 32-byte value leaves four data bits in the final base64url character.
    # Requiring the low two padding bits to be zero proves this is the canonical
    # unpadded encoding of exactly 32 bytes.
    alchemy_key_prefix=${ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE%?}
    alchemy_final_character=${ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE#"$alchemy_key_prefix"}
    case "$alchemy_final_character" in
        A|E|I|M|Q|U|Y|c|g|k|o|s|w|0|4|8)
            ;;
        *)
            fail "the request-proof key must use canonical unpadded base64url"
            ;;
    esac

    if [ -L "$alchemy_fingerprint_file" ] ||
        [ ! -f "$alchemy_fingerprint_file" ]
    then
        fail "the tracked request-proof key fingerprint is missing or invalid"
    fi

    alchemy_fingerprint_with_sentinel=$(
        /bin/cat -- "$alchemy_fingerprint_file" || exit 1
        printf '.'
    ) || fail "the tracked request-proof key fingerprint could not be read"
    alchemy_fingerprint_snapshot=${alchemy_fingerprint_with_sentinel%?}
    case "${#alchemy_fingerprint_snapshot}" in
        64)
            ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT=$alchemy_fingerprint_snapshot
            ;;
        65)
            case "$alchemy_fingerprint_snapshot" in
                *"$alchemy_lf")
                    ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT=${alchemy_fingerprint_snapshot%"$alchemy_lf"}
                    ;;
                *)
                    fail "the tracked request-proof key fingerprint may end only with a single LF"
                    ;;
            esac
            ;;
        *)
            fail "the tracked request-proof key fingerprint must contain one SHA-256 digest"
            ;;
    esac
    case "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT" in
        *[!0-9a-f]*|'')
            fail "the tracked request-proof key fingerprint must be lowercase hexadecimal"
            ;;
    esac
    [ "${#ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT}" -eq 64 ] ||
        fail "the tracked request-proof key fingerprint must contain one SHA-256 digest"

    alchemy_digest_output=$(
        printf '%s' "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" |
            /usr/bin/shasum -a 256
    ) || fail "the request-proof key fingerprint could not be computed"
    alchemy_actual_fingerprint=${alchemy_digest_output%% *}
    [ "$alchemy_actual_fingerprint" = "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT" ] ||
        fail "the request-proof key does not match the tracked fingerprint"

    unset alchemy_snapshot_with_sentinel \
        alchemy_key_snapshot \
        alchemy_key_prefix \
        alchemy_final_character
}
