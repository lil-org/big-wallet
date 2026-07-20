#!/bin/sh

set -eu

fail() {
    printf '%s\n' "error: $1" >&2
    exit 1
}

temporary_root=""

cleanup() {
    if [ -n "$temporary_root" ] && [ -d "$temporary_root" ]; then
        /bin/rm -rf "$temporary_root"
    fi
    temporary_root=""
}

trap cleanup 0
trap 'exit 1' 1 2 15

if [ "$#" -eq 0 ]; then
    fail "at least one artifact directory or exported package is required"
fi

scan_directory() {
    root=$1
    if ! matches=$(
        LC_ALL=C /usr/bin/find -P "$root" \
            \( \
                -name AlchemyAPIKey -o \
                -name 'AlchemyAPIKey.tmp.*' -o \
                -name '.AlchemyAPIKey.*' \
            \) \
            -print
    )
    then
        fail "the artifact directory could not be scanned"
    fi

    if [ -n "$matches" ]; then
        printf '%s\n' \
            "error: bundled legacy Alchemy key artifact found:" >&2
        printf '%s\n' "$matches" >&2
        exit 1
    fi
}

scan_package() {
    artifact=$1
    temporary_root=$(
        mktemp -d "${TMPDIR:-/tmp}/alchemy-key-package-scan.XXXXXX"
    )
    expanded_root="$temporary_root/expanded"

    case "$artifact" in
        *.ipa)
            mkdir "$expanded_root"
            if ! /usr/bin/ditto -x -k "$artifact" "$expanded_root"; then
                fail "the IPA could not be expanded for scanning"
            fi
            ;;
        *.pkg)
            if ! /usr/sbin/pkgutil \
                --expand-full "$artifact" "$expanded_root" >/dev/null
            then
                fail "the package could not be expanded for scanning"
            fi
            ;;
        *)
            fail "exported packages must have an .ipa or .pkg extension"
            ;;
    esac

    scan_directory "$expanded_root"
    cleanup
}

for artifact in "$@"; do
    if [ -L "$artifact" ]; then
        fail "artifacts must not be symlinks"
    elif [ -d "$artifact" ]; then
        scan_directory "$artifact"
    elif [ -f "$artifact" ]; then
        scan_package "$artifact"
    else
        fail "artifacts must be existing directories, IPA files, or pkg files"
    fi
done
