#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
repository_directory=$(CDPATH= cd -- "$tests_directory/../.." && /bin/pwd -P)
build_script="$repository_directory/Scripts/build_inpage_provider.sh"
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/asc-build-marker-tests.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && /bin/pwd -P)
trap '/bin/rm -rf "$test_root"' 0 1 2 15

fail() {
    printf '%s\n' "FAIL: $1" >&2
    exit 1
}

fixture="$test_root/repository"
/bin/mkdir -p \
    "$fixture/Scripts/asc" \
    "$fixture/Wallet.xcodeproj" \
    "$fixture/App iOS" \
    "$fixture/App macOS" \
    "$fixture/Big Wallet Ambient" \
    "$fixture/Safari Shared/Inpage Provider" \
    "$fixture/Safari Shared/Resources" \
    "$fixture/Safari macOS/Resources" \
    "$fixture/Workers/alchemy-jwt"

for relative_file in \
    Scripts/asc/common.sh \
    Scripts/asc/bump.sh \
    Scripts/alchemy_jwt_request_proof_key_common.sh \
    Wallet.xcodeproj/project.pbxproj \
    "App iOS/Info.plist" \
    "App macOS/Info.plist" \
    "Big Wallet Ambient/Info.plist" \
    "Safari Shared/Resources/manifest.json" \
    "Safari macOS/Resources/manifest.json" \
    "Safari Shared/Resources/bridge_wire.js" \
    "Safari Shared/Resources/inpage.js" \
    "Workers/alchemy-jwt/.nvmrc"
do
    /bin/cp -p \
        "$repository_directory/$relative_file" \
        "$fixture/$relative_file"
done

for provider_file in "$repository_directory/Safari Shared/Inpage Provider"/*; do
    [ -f "$provider_file" ] || continue
    /bin/cp -p \
        "$provider_file" \
        "$fixture/Safari Shared/Inpage Provider/${provider_file##*/}"
done
if [ -d "$repository_directory/Safari Shared/Inpage Provider/node_modules" ]; then
    /bin/ln -s \
        "$repository_directory/Safari Shared/Inpage Provider/node_modules" \
        "$fixture/Safari Shared/Inpage Provider/node_modules"
fi

result="$test_root/result"
/bin/bash -c '
    set -euo pipefail
    . "$1/Scripts/asc/common.sh"

    version="$(current_local_version)"
    build="$(current_local_build_number)"
    validate_local_version_sources "$version" "$build"
    validate_generated_web_extension_build_version "$version" "$build"

    next_build=$((build + 1))
    sync_local_version_sources "$version" "$next_build" build
    PROJECT_DIR="$1" /bin/sh "$3" >/dev/null
    validate_local_version_sources "$version" "$next_build"
    validate_generated_web_extension_build_version "$version" "$next_build"
    for manifest in "${WEB_EXTENSION_MANIFESTS[@]}"; do
        [[ "$(jq -r ".version" "$manifest")" == "$version" ]]
    done

    next_version="$(patch_bump_version "$version")"
    next_version_build=$((next_build + 1))
    sync_local_version_sources "$next_version" "$next_version_build" version
    PROJECT_DIR="$1" /bin/sh "$3" >/dev/null
    validate_local_version_sources "$next_version" "$next_version_build"
    validate_generated_web_extension_build_version \
        "$next_version" "$next_version_build"
    for manifest in "${WEB_EXTENSION_MANIFESTS[@]}"; do
        [[ "$(jq -r ".version" "$manifest")" == "$next_version" ]]
    done
    first_generated_hash="$(/usr/bin/shasum -a 256 \
        "$WEB_EXTENSION_GENERATED_FILE")"
    PROJECT_DIR="$1" /bin/sh "$3" >/dev/null
    second_generated_hash="$(/usr/bin/shasum -a 256 \
        "$WEB_EXTENSION_GENERATED_FILE")"
    [[ "$first_generated_hash" == "$second_generated_hash" ]]
    printf "%s %s\n" "$next_version" "$next_version_build" > "$2"
' marker-test "$fixture" "$result" "$build_script"
read -r expected_version expected_build < "$result"
expected_marker="$expected_version+$expected_build"

marker_file="$fixture/Safari Shared/Resources/bridge_wire.js"
count=$(/usr/bin/grep -F -c \
    "const BUILD_VERSION = \"$expected_marker\";" \
    "$marker_file")
[ "$count" = 1 ] || fail "$marker_file did not receive the exact build marker"

generated_file="$fixture/Safari Shared/Resources/inpage.js"
generated_count=$(/usr/bin/grep -F -o "$expected_marker" \
    "$generated_file" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[ "$generated_count" = 1 ] || \
    fail "$generated_file did not receive the exact build marker"

generated_backup="$test_root/inpage.js"
/bin/cp -p "$generated_file" "$generated_backup"
EXPECTED_MARKER="$expected_marker" /usr/bin/perl -0pi -e '
    s/\Q$ENV{EXPECTED_MARKER}\E/stale-build-marker/g;
' "$generated_file"
if (
    cd "$fixture"
    /bin/bash -c \
        '. Scripts/asc/common.sh; validate_generated_web_extension_build_version "$1" "$2"' \
        marker-test "$expected_version" "$expected_build"
) >/dev/null 2>&1
then
    fail "a stale generated build marker passed validation"
fi
/bin/cp -p "$generated_backup" "$generated_file"

printf '%s\n' "const BUILD_VERSION = \"$expected_marker\";" \
    >> "$marker_file"
if (
    cd "$fixture"
    /bin/bash -c \
        '. Scripts/asc/common.sh; validate_local_version_sources "$1" "$2"' \
        marker-test "$expected_version" "$expected_build"
) >/dev/null 2>&1
then
    fail "duplicate build markers passed validation"
fi
if (
    cd "$fixture"
    /bin/bash -c \
        '. Scripts/asc/common.sh; set_web_extension_build_version "$1" "$2"' \
        marker-test "$expected_version" "$expected_build"
) >/dev/null 2>&1
then
    fail "duplicate build markers passed synchronization"
fi

/usr/bin/perl -0pi -e \
    's/const BUILD_VERSION = "[^"\n]*";//g' \
    "$marker_file"
if (
    cd "$fixture"
    /bin/bash -c \
        '. Scripts/asc/common.sh; validate_local_version_sources "$1" "$2"' \
        marker-test "$expected_version" "$expected_build"
) >/dev/null 2>&1
then
    fail "missing build marker passed validation"
fi
if (
    cd "$fixture"
    /bin/bash -c \
        '. Scripts/asc/common.sh; set_web_extension_build_version "$1" "$2"' \
        marker-test "$expected_version" "$expected_build"
) >/dev/null 2>&1
then
    fail "missing build marker passed synchronization"
fi

marker_expansion='$WEB_EXTENSION_BUILD_VERSION_FILE'
expansion_count=$(/usr/bin/grep -F -c "$marker_expansion" \
    "$fixture/Scripts/asc/bump.sh")
[ "$expansion_count" = 2 ] || \
    fail "bump.sh does not include marker files in both bump modes"

/usr/bin/awk '
    /^  version\)/ { mode = "version" }
    /^  build\)/ { mode = "build" }
    mode != "" && index($0, "$WEB_EXTENSION_GENERATED_FILE") {
        count[mode] += 1
    }
    mode != "" && /^    ;;$/ { mode = "" }
    END {
        if (count["version"] != 1 || count["build"] != 1) {
            exit 1
        }
    }
' "$fixture/Scripts/asc/bump.sh" || \
    fail "bump.sh does not include the generated bundle in both bump modes"

/usr/bin/awk '
    index($0, "Scripts/build_inpage_provider.sh") {
        build_count += 1
        if (previous !~ /PROJECT_DIR="\$REPO_ROOT"/) {
            exit 1
        }
    }
    { previous = $0 }
    END {
        if (build_count != 2) {
            exit 1
        }
    }
' "$fixture/Scripts/asc/bump.sh" || \
    fail "bump.sh does not pin both generated builds to REPO_ROOT"

/usr/bin/awk '
    index($0, "sync_local_version_sources") { sync_line = NR }
    index($0, "Scripts/build_inpage_provider.sh") { build_line = NR }
    index($0, "validate_generated_web_extension_build_version") &&
        NR > build_line { validation_line = NR }
    index($0, "git add") { stage_line = NR }
    END {
        if (sync_line == 0 || build_line <= sync_line ||
            validation_line <= build_line || stage_line <= validation_line) {
            exit 1
        }
    }
' "$fixture/Scripts/asc/bump.sh" || \
    fail "bump.sh does not rebuild, validate, and stage the generated bundle in order"

printf '%s\n' "ASC build marker regression tests: PASS"
