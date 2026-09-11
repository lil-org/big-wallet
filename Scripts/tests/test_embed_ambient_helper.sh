#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
repository_directory=$(CDPATH= cd -- "$tests_directory/../.." && /bin/pwd -P)
embed_script="$repository_directory/Scripts/embed_ambient_helper.sh"
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ambient-embed-tests.XXXXXX")
trap '/bin/rm -rf "$test_root"' 0 1 2 15

project_directory="$test_root/project"
products_directory="$test_root/products"
target_build_directory="$test_root/target"
contents_path="Safari macOS.appex/Contents"
helpers_directory="$target_build_directory/$contents_path/Helpers"
source_app="$products_directory/Big Wallet Helper.app"
cleanup_log="$test_root/cleanup.log"
/bin/mkdir -p "$project_directory/Scripts" "$source_app" \
    "$helpers_directory/Big Wallet.app" \
    "$helpers_directory/Big Wallet Helper.app" \
    "$helpers_directory/Big Wallet Ambient.app" \
    "$helpers_directory/Keep.app"

printf '%s\n' new > "$source_app/payload"
printf '%s\n' stale > "$helpers_directory/Big Wallet.app/stale"
printf '%s\n' legacy > "$helpers_directory/Big Wallet Helper.app/legacy"
printf '%s\n' ambient > "$helpers_directory/Big Wallet Ambient.app/ambient"
printf '%s\n' keep > "$helpers_directory/Keep.app/keep"

printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    ': "${CLEANUP_LOG:?}" "${HELPERS_DIRECTORY:?}"' \
    'for bundle in "Big Wallet.app" "Big Wallet Helper.app" "Big Wallet Ambient.app"; do' \
    '    [ -d "$HELPERS_DIRECTORY/$bundle" ] || exit 70' \
    'done' \
    'printf "%s\n" cleanup >> "$CLEANUP_LOG"' \
    'printf "%s\n" marker > "$HELPERS_DIRECTORY/Big Wallet.app/cleanup-marker"' \
    > "$project_directory/Scripts/terminate_ambient_agents.sh"
/bin/chmod 0755 "$project_directory/Scripts/terminate_ambient_agents.sh"

PROJECT_DIR="$project_directory" \
TARGET_BUILD_DIR="$target_build_directory" \
CONTENTS_FOLDER_PATH="$contents_path" \
BUILT_PRODUCTS_DIR="$products_directory" \
CLEANUP_LOG="$cleanup_log" \
HELPERS_DIRECTORY="$helpers_directory" \
    /bin/sh "$embed_script"

[ "$(/usr/bin/wc -l < "$cleanup_log" | /usr/bin/tr -d ' ')" = 1 ] || {
    echo "FAIL: cleanup did not run exactly once" >&2
    exit 1
}
[ -f "$helpers_directory/Big Wallet.app/payload" ] || {
    echo "FAIL: helper was not copied to the packaged path" >&2
    exit 1
}
[ ! -e "$helpers_directory/Big Wallet.app/stale" ] &&
[ ! -e "$helpers_directory/Big Wallet.app/cleanup-marker" ] || {
    echo "FAIL: cleanup did not run immediately before replacement" >&2
    exit 1
}
[ ! -e "$helpers_directory/Big Wallet Helper.app" ] &&
[ ! -e "$helpers_directory/Big Wallet Ambient.app" ] || {
    echo "FAIL: a known legacy helper survived" >&2
    exit 1
}
[ -f "$helpers_directory/Keep.app/keep" ] || {
    echo "FAIL: unrelated helper content was removed" >&2
    exit 1
}

/bin/rm -rf "$source_app"
: > "$cleanup_log"
set +e
PROJECT_DIR="$project_directory" \
TARGET_BUILD_DIR="$target_build_directory" \
CONTENTS_FOLDER_PATH="$contents_path" \
BUILT_PRODUCTS_DIR="$products_directory" \
CLEANUP_LOG="$cleanup_log" \
HELPERS_DIRECTORY="$helpers_directory" \
    /bin/sh "$embed_script" >/dev/null 2>&1
missing_status=$?
set -e
[ "$missing_status" -ne 0 ] && [ ! -s "$cleanup_log" ] || {
    echo "FAIL: missing source did not fail before cleanup" >&2
    exit 1
}

legacy_helpers_directory="$target_build_directory/Big Wallet.app/Contents/Helpers"
packaged_helper="$target_build_directory/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app"
/bin/mkdir -p \
    "$legacy_helpers_directory/Big Wallet.app" \
    "$legacy_helpers_directory/Big Wallet Helper.app" \
    "$legacy_helpers_directory/Big Wallet Ambient.app" \
    "$legacy_helpers_directory/Keep.app" \
    "$packaged_helper"
printf '%s\n' keep > "$legacy_helpers_directory/Keep.app/payload"
printf '%s\n' embedded > "$packaged_helper/payload"
PROJECT_DIR="$project_directory" \
TARGET_BUILD_DIR="$target_build_directory" \
CONTENTS_FOLDER_PATH="Big Wallet.app/Contents" \
CLEANUP_LOG="$cleanup_log" \
HELPERS_DIRECTORY="$legacy_helpers_directory" \
    /bin/sh "$embed_script" cleanup-legacy

for name in "Big Wallet.app" "Big Wallet Helper.app" "Big Wallet Ambient.app"; do
    [ ! -e "$legacy_helpers_directory/$name" ] || {
        echo "FAIL: a known outer helper survived cleanup" >&2
        exit 1
    }
done
[ -f "$legacy_helpers_directory/Keep.app/payload" ] &&
[ -f "$packaged_helper/payload" ] || {
    echo "FAIL: legacy cleanup removed unrelated or newly embedded helper content" >&2
    exit 1
}
[ "$(/usr/bin/wc -l < "$cleanup_log" | /usr/bin/tr -d ' ')" = 1 ] || {
    echo "FAIL: legacy cleanup did not terminate before removal" >&2
    exit 1
}
PROJECT_DIR="$project_directory" \
TARGET_BUILD_DIR="$target_build_directory" \
CONTENTS_FOLDER_PATH="Big Wallet.app/Contents" \
    /bin/sh "$embed_script" cleanup-legacy

if PROJECT_DIR="$project_directory" \
    TARGET_BUILD_DIR="$target_build_directory" \
    CONTENTS_FOLDER_PATH="$contents_path" \
        /bin/sh "$embed_script" cleanup-legacy >/dev/null 2>&1; then
    echo "FAIL: legacy cleanup accepted the Safari extension target" >&2
    exit 1
fi

echo "Ambient helper embed regression tests: PASS"
