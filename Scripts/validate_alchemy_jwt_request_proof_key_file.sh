#!/bin/sh

set -eu

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    fail "exactly one request-proof key file is required"
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
. "$script_directory/alchemy_jwt_request_proof_key_common.sh"

load_alchemy_jwt_request_proof_key \
    "$1" \
    "$script_directory/alchemy_jwt_request_proof_key.sha256"
