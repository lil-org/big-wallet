#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
scripts_directory=$(CDPATH= cd "$tests_directory/.." && pwd)
subject="$scripts_directory/bundle_alchemy_api_key.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/bundle-alchemy-api-key.XXXXXX")
logs_directory="$test_root/logs"
fixtures_directory="$test_root/fixture files"
mkdir -p "$logs_directory" "$fixtures_directory"
trap 'rm -rf "$test_root"' 0 HUP INT TERM

sentinel_marker="DO_NOT_LEAK_ALCHEMY_SENTINEL"
assertion_index=0

fail() {
    printf '%s\n' "FAIL: $1" >&2
    exit 1
}

assert_file_contents() {
    assertion_index=$((assertion_index + 1))
    expected_contents=$1
    actual_path=$2
    assertion_name=$3
    expected_path="$test_root/expected-$assertion_index"

    printf '%s' "$expected_contents" > "$expected_path"
    cmp -s "$expected_path" "$actual_path" ||
        fail "$assertion_name produced unexpected contents"
}

file_mode() {
    path=$1
    if mode=$(stat -f '%Lp' "$path" 2>/dev/null); then
        printf '%s' "$mode"
    elif mode=$(stat -c '%a' "$path" 2>/dev/null); then
        printf '%s' "$mode"
    else
        fail "could not determine output permissions"
    fi
}

invoke_subject() {
    invocation_name=$1
    expected_result=$2
    invocation_api_key=$3
    invocation_key_file=$4
    invocation_target_directory=$5
    invocation_resources_path=$6
    invocation_stdout="$logs_directory/$invocation_name.stdout"
    invocation_stderr="$logs_directory/$invocation_name.stderr"

    set +e
    ALCHEMY_API_KEY="$invocation_api_key" \
        ALCHEMY_API_KEY_FILE="$invocation_key_file" \
        TARGET_BUILD_DIR="$invocation_target_directory" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH="$invocation_resources_path" \
        "$subject" > "$invocation_stdout" 2> "$invocation_stderr"
    invocation_status=$?
    set -e

    case "$expected_result" in
        success)
            [ "$invocation_status" -eq 0 ] ||
                fail "$invocation_name unexpectedly failed"
            [ ! -s "$invocation_stdout" ] ||
                fail "$invocation_name wrote to stdout"
            [ ! -s "$invocation_stderr" ] ||
                fail "$invocation_name wrote to stderr"
            ;;
        failure)
            [ "$invocation_status" -ne 0 ] ||
                fail "$invocation_name unexpectedly succeeded"
            [ ! -s "$invocation_stdout" ] ||
                fail "$invocation_name wrote to stdout"
            [ -s "$invocation_stderr" ] ||
                fail "$invocation_name did not report an error"
            ;;
        *)
            fail "invalid expected result in test harness"
            ;;
    esac

    last_output_path="$invocation_target_directory/$invocation_resources_path/AlchemyAPIKey"
}

[ -x "$subject" ] || fail "subject script is not executable"
grep -F 'chmod 600 "$temporary_path"' "$subject" >/dev/null ||
    fail "temporary output is not restricted to mode 0600"
grep -F 'mktemp "${TARGET_BUILD_DIR}/.AlchemyAPIKey.XXXXXX"' "$subject" >/dev/null ||
    fail "temporary output is not staged beside the built products"
grep -F 'rm -f "${output_path}.tmp."*' "$subject" >/dev/null ||
    fail "legacy bundle-local temporary output is not cleaned up"
grep -F 'mv -f "$temporary_path" "$output_path"' "$subject" >/dev/null ||
    fail "output replacement is not atomic"
grep -F 'chmod 644 "$output_path"' "$subject" >/dev/null ||
    fail "final output is not normalized to mode 0644"

precedence_file="$fixtures_directory/configured key"
precedence_file_key="${sentinel_marker}_FILE_VALUE"
precedence_environment_key="${sentinel_marker}_ENVIRONMENT_VALUE"
printf '%s\n' "$precedence_file_key" > "$precedence_file"
invoke_subject \
    "environment-precedence" \
    "success" \
    "$precedence_environment_key" \
    "$precedence_file" \
    "$test_root/build products" \
    "Product With Spaces.app/Contents/Resources Folder"
assert_file_contents \
    "$precedence_environment_key" \
    "$last_output_path" \
    "environment precedence"
[ "$(file_mode "$last_output_path")" = "644" ] ||
    fail "environment precedence output does not have mode 0644"

crlf_file="$fixtures_directory/crlf key"
crlf_key="${sentinel_marker}_CRLF_VALUE"
printf '%s\r\n' "$crlf_key" > "$crlf_file"
invoke_subject \
    "file-crlf" \
    "success" \
    "" \
    "$crlf_file" \
    "$test_root/crlf build" \
    "Resources"
assert_file_contents "$crlf_key" "$last_output_path" "CRLF normalization"
[ "$(file_mode "$last_output_path")" = "644" ] ||
    fail "CRLF output does not have mode 0644"

invoke_subject \
    "missing-file" \
    "failure" \
    "" \
    "$fixtures_directory/does not exist" \
    "$test_root/missing build" \
    "Resources"

empty_file="$fixtures_directory/empty key"
: > "$empty_file"
invoke_subject \
    "empty-file" \
    "failure" \
    "" \
    "$empty_file" \
    "$test_root/empty build" \
    "Resources"

invoke_subject \
    "whitespace-key" \
    "failure" \
    "${sentinel_marker}_INVALID VALUE" \
    "$fixtures_directory/unused key" \
    "$test_root/whitespace build" \
    "Resources"

multiline_file="$fixtures_directory/multiline key"
printf '%s\n%s\n' \
    "${sentinel_marker}_LINE_ONE" \
    "${sentinel_marker}_LINE_TWO" > "$multiline_file"
invoke_subject \
    "multiline-file" \
    "failure" \
    "" \
    "$multiline_file" \
    "$test_root/multiline build" \
    "Resources"

atomic_target="$test_root/atomic build"
atomic_resources="Nested Product.app/Contents/Resources"
atomic_output="$atomic_target/$atomic_resources/AlchemyAPIKey"
mkdir -p "$(dirname "$atomic_output")"
printf '%s' "${sentinel_marker}_OLD_VALUE" > "$atomic_output"
chmod 777 "$atomic_output"
old_inode=$(ls -id "$atomic_output" | awk '{ print $1 }')
legacy_temporary_output="${atomic_output}.tmp.12345"
printf '%s' "${sentinel_marker}_STALE_TEMPORARY_VALUE" > "$legacy_temporary_output"
chmod 600 "$legacy_temporary_output"

atomic_key="${sentinel_marker}_ATOMIC_REPLACEMENT"
invoke_subject \
    "atomic-overwrite" \
    "success" \
    "$atomic_key" \
    "$fixtures_directory/unused atomic key" \
    "$atomic_target" \
    "$atomic_resources"
new_inode=$(ls -id "$last_output_path" | awk '{ print $1 }')

assert_file_contents "$atomic_key" "$last_output_path" "atomic overwrite"
[ "$old_inode" != "$new_inode" ] ||
    fail "atomic overwrite did not replace the destination file"
[ "$(file_mode "$last_output_path")" = "644" ] ||
    fail "atomic overwrite output does not have mode 0644"
[ ! -e "$legacy_temporary_output" ] ||
    fail "atomic overwrite did not remove legacy bundle-local temporary output"
if find "$(dirname "$last_output_path")" -type f -name 'AlchemyAPIKey.tmp.*' -print |
    grep -q .
then
    fail "atomic overwrite left a temporary file behind"
fi
if find "$atomic_target" -type f -name '.AlchemyAPIKey.*' -print |
    grep -q .
then
    fail "atomic overwrite left staging output behind"
fi

if grep -F "$sentinel_marker" \
    "$logs_directory"/*.stdout \
    "$logs_directory"/*.stderr >/dev/null 2>&1
then
    fail "a key sentinel leaked into command output"
fi

printf '%s\n' "bundle_alchemy_api_key.sh regression tests: PASS"
