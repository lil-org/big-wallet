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
    if [ -n "${case_root:-}" ]; then
        for log_file in "$case_root/seed.log" "$case_root/bump.log"; do
            [ ! -f "$log_file" ] || /usr/bin/tail -n 40 "$log_file" >&2
        done
    fi
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
    /usr/bin/ditto \
        "$repository_directory/Safari Shared/Inpage Provider/node_modules" \
        "$test_root/dependencies/node_modules"
    /bin/ln -s "$test_root/dependencies/node_modules" \
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

fixture_bin="$test_root/bin"
/bin/mkdir -p "$fixture_bin" "$test_root/outside"
cat > "$fixture_bin/asc" <<'ASC'
#!/bin/sh
set -eu
case "$1 $2" in
    "builds next-build-number")
        printf '%s\n' "next-build-number" >> "$ASC_TEST_LOG"
        printf '%s\n' '{"nextBuildNumber":46}'
        ;;
    "xcode version")
        [ "$3" = edit ] || exit 1
        shift 3
        project= version= build=
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --project) project=$2 ;;
                --version) version=$2 ;;
                --build-number) build=$2 ;;
                --output) [ "$2" = json ] || exit 1 ;;
                *) exit 1 ;;
            esac
            shift 2
        done
        [ "$project" = Wallet.xcodeproj ] && [ -n "$version" ] && [ -n "$build" ] || exit 1
        printf 'edit %s %s\n' "$version" "$build" >> "$ASC_TEST_LOG"
        printf '%s\n' '{}'
        ;;
    *) printf 'Unexpected ASC command: %s\n' "$*" >&2; exit 1 ;;
esac
ASC
/bin/chmod +x "$fixture_bin/asc"

fixture_env() {
    /usr/bin/env -i \
        PATH="$fixture_bin:$PATH" \
        HOME="$HOME" \
        TMPDIR="$test_root/" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        npm_config_offline=true \
        ASC_TEST_LOG="$case_root/asc.log" \
        "$@"
}

fixture_git() {
    fixture_env /usr/bin/git -C "$fixture" "$@"
}

prepare_bump_fixture() {
    case_root="$test_root/$1"
    fixture="$case_root/repository"
    origin="$case_root/origin.git"
    decoy="$case_root/decoy"
    /bin/mkdir -p "$fixture" "$decoy"
    printf '%s\n' unchanged > "$decoy/sentinel"
    : > "$case_root/asc.log"
    for relative_file in \
        Scripts/asc/common.sh \
        Scripts/asc/bump.sh \
        Scripts/alchemy_jwt_request_proof_key_common.sh \
        Scripts/build_inpage_provider.sh \
        Scripts/inpage_provider_toolchain.sh \
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
        /bin/mkdir -p "$fixture/${relative_file%/*}"
        /bin/cp -p "$repository_directory/$relative_file" "$fixture/$relative_file"
    done
    /bin/mkdir -p "$fixture/Safari Shared/Inpage Provider"
    for provider_file in "$repository_directory/Safari Shared/Inpage Provider"/*; do
        [ -f "$provider_file" ] || continue
        /bin/cp -p "$provider_file" "$fixture/Safari Shared/Inpage Provider/${provider_file##*/}"
    done
    if [ -d "$test_root/dependencies/node_modules" ]; then
        /bin/ln -s "$test_root/dependencies/node_modules" "$fixture/Safari Shared/Inpage Provider/node_modules"
    fi
    fixture_env /bin/bash -c '
        source "$1/Scripts/asc/common.sh"
        sync_local_version_sources 1.2.3 45 version
        PROJECT_DIR="$REPO_ROOT" /bin/sh "$REPO_ROOT/Scripts/build_inpage_provider.sh"
    ' seed "$fixture" > "$case_root/seed.log" 2>&1 || fail "could not seed $1"
    fixture_git init -q -b main
    fixture_git config user.name 'Build Marker Tests'
    fixture_git config user.email 'build-marker-tests@example.invalid'
    fixture_git config commit.gpgSign false
    fixture_git config core.hooksPath /dev/null
    printf '%s\n' 'node_modules' > "$fixture/.git/info/exclude"
    printf '%s\n' baseline > "$fixture/unrelated-staged.txt"
    printf '%s\n' baseline > "$fixture/unrelated-unstaged.txt"
    fixture_git add .
    fixture_git commit -qm seed
    fixture_env /usr/bin/git init -q --bare -b main "$origin"
    fixture_git remote add origin "$origin"
    fixture_git push -q -u origin main
    seed_head=$(fixture_git rev-parse HEAD)
}

run_bump() {
    (
        cd "$test_root/outside"
        fixture_env /usr/bin/env PROJECT_DIR="$decoy" \
            /bin/bash "$fixture/Scripts/asc/bump.sh" "$1"
    ) > "$case_root/bump.log" 2>&1
}

assert_no_bump_commit() {
    [ "$(fixture_git rev-parse HEAD)" = "$seed_head" ] || fail "failed bump committed changes"
    [ "$(fixture_env /usr/bin/git --git-dir="$origin" rev-parse refs/heads/main)" = "$seed_head" ] || \
        fail "failed bump published changes"
}

assert_bump_contents() {
    expected_version=$1
    [ "$(fixture_git rev-list --count "$seed_head..HEAD")" = 1 ] || fail "expected one bump commit"
    [ "$(fixture_git rev-parse HEAD)" = \
        "$(fixture_env /usr/bin/git --git-dir="$origin" rev-parse refs/heads/main)" ] || fail "bump commit was not published"
    fixture_git diff-tree --no-commit-id --name-only -r HEAD | /usr/bin/sort > "$case_root/changed-paths"
    {
        printf '%s\n' Wallet.xcodeproj/project.pbxproj \
            'Safari Shared/Resources/bridge_wire.js' \
            'Safari Shared/Resources/inpage.js'
        if [ "$expected_version" = 1.2.4 ]; then
            printf '%s\n' 'Safari Shared/Resources/manifest.json' 'Safari macOS/Resources/manifest.json'
        fi
    } | /usr/bin/sort > "$case_root/expected-paths"
    /usr/bin/cmp "$case_root/changed-paths" "$case_root/expected-paths" || fail "unexpected bump commit paths"
    committed="$case_root/committed"
    /bin/mkdir -p "$committed"
    fixture_git archive HEAD | /usr/bin/tar -xf - -C "$committed"
    fixture_env /bin/bash -c '
        source "$1/Scripts/asc/common.sh"
        validate_local_version_sources "$2" 46
        validate_generated_web_extension_build_version "$2" 46
    ' committed-check "$committed" "$expected_version" || fail "committed version artifacts are inconsistent"
    /usr/bin/grep -Fx "edit $expected_version 46" "$case_root/asc.log" > /dev/null || fail "ASC received incorrect version arguments"
    [ "$(/bin/ls -A "$decoy")" = sentinel ] && \
        [ "$(cat "$decoy/sentinel")" = unchanged ] || fail "inherited PROJECT_DIR changed the decoy"
}

prepare_bump_fixture build
printf '%s\n' staged-change > "$fixture/unrelated-staged.txt"
printf '%s\n' unstaged-change > "$fixture/unrelated-unstaged.txt"
fixture_git add unrelated-staged.txt
fixture_git diff --cached > "$case_root/staged-before"
fixture_git diff > "$case_root/unstaged-before"
run_bump build || fail "build bump failed; see $case_root/bump.log"
assert_bump_contents 1.2.3
fixture_git diff --cached > "$case_root/staged-after"
fixture_git diff > "$case_root/unstaged-after"
/usr/bin/cmp "$case_root/staged-before" "$case_root/staged-after" || fail "bump changed unrelated staged work"
/usr/bin/cmp "$case_root/unstaged-before" "$case_root/unstaged-after" || fail "bump changed unrelated unstaged work"
fixture_git diff "$seed_head" HEAD -- 'Safari Shared/Resources/manifest.json' 'Safari macOS/Resources/manifest.json' > "$case_root/manifest-diff"
[ ! -s "$case_root/manifest-diff" ] || fail "build-only bump changed manifests"

prepare_bump_fixture version
run_bump version || fail "version bump failed; see $case_root/bump.log"
assert_bump_contents 1.2.4

prepare_bump_fixture stale-before
printf '\n// stale generated fixture\n' >> "$fixture/Safari Shared/Resources/inpage.js"
fixture_git add 'Safari Shared/Resources/inpage.js'
fixture_git commit -qm 'seed stale generated bundle'
fixture_git push -q
seed_head=$(fixture_git rev-parse HEAD)
if run_bump build; then fail "committed stale generated bundle allowed a bump"; fi
assert_no_bump_commit
[ ! -s "$case_root/asc.log" ] || fail "stale generated bundle reached ASC"
fixture_git diff --quiet -- 'Safari Shared/Resources/inpage.js' && fail "stale bundle was not regenerated"
fixture_git diff --cached --quiet || fail "failed preflight staged files"

prepare_bump_fixture stale-after
/bin/mv "$fixture/Scripts/build_inpage_provider.sh" "$fixture/Scripts/build_inpage_provider_real.sh"
cat > "$fixture/Scripts/build_inpage_provider.sh" <<'BUILD'
#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/sh "$script_dir/build_inpage_provider_real.sh"
if ! /usr/bin/grep -Fq 'const BUILD_VERSION = "1.2.3+45";' \
    "$PROJECT_DIR/Safari Shared/Resources/bridge_wire.js"; then
    /usr/bin/perl -0pi -e 's/1\.2\.3\+46/stale-after-bump/g' \
        "$PROJECT_DIR/Safari Shared/Resources/inpage.js"
fi
BUILD
fixture_git add Scripts
fixture_git commit -qm 'seed invalid generation fixture'
fixture_git push -q
seed_head=$(fixture_git rev-parse HEAD)
if run_bump build; then fail "invalid post-bump generated marker was committed"; fi
assert_no_bump_commit
fixture_git diff --cached --quiet || fail "failed post-bump validation staged files"
/usr/bin/grep -Fx 'edit 1.2.3 46' "$case_root/asc.log" > /dev/null || fail "post-bump fixture failed before editing"
/usr/bin/grep -Fq 'stale-after-bump' "$fixture/Safari Shared/Resources/inpage.js" || \
    fail "post-bump fixture did not inject the invalid marker"
/usr/bin/grep -Fq 'inpage.js must embed BUILD_VERSION=1.2.3+46 exactly once' "$case_root/bump.log" || \
    fail "post-bump failure did not come from generated-marker validation"

printf '%s\n' "ASC build marker regression tests: PASS"
