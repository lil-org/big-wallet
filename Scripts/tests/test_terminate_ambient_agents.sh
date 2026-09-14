#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
repository_directory=$(CDPATH= cd -- "$tests_directory/../.." && /bin/pwd -P)
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ambient-cleanup-tests.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && /bin/pwd -P)
trap '/bin/rm -rf "$test_root"' 0 1 2 15

mock_directory="$test_root/bin"
products_directory="$test_root/products"
cleanup_script="$test_root/terminate_ambient_agents.sh"
kill_log="$test_root/kill.log"
ps_state="$test_root/ps-state"
/bin/mkdir -p "$mock_directory" "$products_directory" "$ps_state"
/bin/cp "$repository_directory/Scripts/terminate_ambient_agents.sh" \
    "$cleanup_script"

ambient_command="$products_directory/Big Wallet Helper.app/Contents/MacOS/Big Wallet --approval"
extension_helper_command="$products_directory/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/MacOS/Big Wallet --approval"
packaged_helper_command="$products_directory/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/MacOS/Big Wallet --approval"
dock_command="$products_directory/Big Wallet.app/Contents/MacOS/Big Wallet"
unrelated_command="/usr/bin/unrelated-process --same-pid"

printf '%s\n' \
    '#!/bin/sh' \
    "ambient_command='$ambient_command'" \
    "extension_helper_command='$extension_helper_command'" \
    "packaged_helper_command='$packaged_helper_command'" \
    "dock_command='$dock_command'" \
    "unrelated_command='$unrelated_command'" \
    'ps_state=${MOCK_PS_STATE:?}' \
    'if [ "${1:-}" = "-axww" ]; then' \
    '    [ "${MOCK_ENUMERATION_FAILURE:-0}" != "1" ] || exit 1' \
    '    printf "101 %s\n202 %s\n203 %s\n204 %s\n303 %s\n505 %s\n506 %s\n" "$ambient_command" "$ambient_command" "$ambient_command" "$ambient_command" "$dock_command" "$extension_helper_command" "$packaged_helper_command"' \
    '    exit 0' \
    'fi' \
    'if [ "${1:-}" = "-p" ]; then' \
    '    if [ "${4:-}" = "command=" ]; then' \
    '        case "${2:-}" in' \
    '            101)' \
    '                [ ! -e "$ps_state/term-101" ] || exit 1' \
    '                printf " %s\n" "$ambient_command"' \
    '                ;;' \
    '            202) printf " %s\n" "$unrelated_command" ;;' \
    '            203)' \
    '                if [ -e "$ps_state/term-203" ]; then' \
    '                    printf " %s\n" "$unrelated_command"' \
    '                else' \
    '                    printf " %s\n" "$ambient_command"' \
    '                fi' \
    '                ;;' \
    '            204)' \
    '                if [ ! -e "$ps_state/term-204" ]; then' \
    '                    printf " %s\n" "$ambient_command"' \
    '                elif [ "${MOCK_SAME_COMMAND_REUSE:-0}" = "1" ]; then' \
    '                    printf " %s\n" "$ambient_command"' \
    '                else' \
    '                    exit 1' \
    '                fi' \
    '                ;;' \
    '            303) printf " %s\n" "$dock_command" ;;' \
    '            505)' \
    '                [ ! -e "$ps_state/term-505" ] || exit 1' \
    '                printf " %s\n" "$extension_helper_command"' \
    '                ;;' \
    '            506)' \
    '                [ ! -e "$ps_state/term-506" ] || exit 1' \
    '                printf " %s\n" "$packaged_helper_command"' \
    '                ;;' \
    '            *) exit 1 ;;' \
    '        esac' \
    '    else' \
    '        exit 64' \
    '    fi' \
    '    exit 0' \
    'fi' \
    'exit 64' \
    > "$mock_directory/ps"
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" >> "$MOCK_KILL_LOG"' \
    'if [ "${1:-}" = "-TERM" ]; then' \
    '    [ "${2:-}" != "${MOCK_KILL_FAILURE_PID:-}" ] || exit 1' \
    '    : > "$MOCK_PS_STATE/term-${2:-}"' \
    'fi' \
    > "$mock_directory/kill"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$mock_directory/sleep"
/bin/chmod 0755 \
    "$cleanup_script" \
    "$mock_directory/ps" \
    "$mock_directory/kill" \
    "$mock_directory/sleep"

MOCK_PS="$mock_directory/ps" \
MOCK_KILL="$mock_directory/kill" \
/usr/bin/perl -pi -e '
    s{\Q/bin/ps\E}{$ENV{MOCK_PS}}g;
    s{\Q/bin/kill\E}{$ENV{MOCK_KILL}}g;
' "$cleanup_script"

set +e
PATH="$mock_directory:/usr/bin:/bin" \
    CONFIGURATION=Debug \
    BUILT_PRODUCTS_DIR="$products_directory" \
    CONFIGURATION_BUILD_DIR="$products_directory" \
    MOCK_KILL_LOG="$kill_log" \
    MOCK_PS_STATE="$ps_state" \
    MOCK_SAME_COMMAND_REUSE=1 \
    "$cleanup_script" >/dev/null 2>"$test_root/reuse-error.log"
reuse_status=$?
set -e
[ "$reuse_status" -ne 0 ] || {
    printf '%s\n' "FAIL: same-command PID reuse did not fail closed" >&2
    exit 1
}
/usr/bin/grep -q 'process 204 did not exit after TERM' \
    "$test_root/reuse-error.log" || {
    printf '%s\n' "FAIL: same-command PID reuse failure was not reported" >&2
    exit 1
}

expected_log="$test_root/expected-kill.log"
printf '%s\n' \
    '-TERM 101' \
    '-TERM 203' \
    '-TERM 204' \
    '-TERM 505' \
    '-TERM 506' \
    > "$expected_log"
/usr/bin/cmp -s "$expected_log" "$kill_log" || {
    printf '%s\n' "FAIL: PID reuse cleanup targeted the wrong process" >&2
    exit 1
}

: > "$kill_log"
normal_ps_state="$test_root/normal-ps-state"
/bin/mkdir -p "$normal_ps_state"
PATH="$mock_directory:/usr/bin:/bin" \
CONFIGURATION=Debug \
BUILT_PRODUCTS_DIR="$products_directory" \
CONFIGURATION_BUILD_DIR="$products_directory" \
MOCK_KILL_LOG="$kill_log" \
MOCK_PS_STATE="$normal_ps_state" \
    "$cleanup_script" >/dev/null
/usr/bin/cmp -s "$expected_log" "$kill_log" || {
    printf '%s\n' "FAIL: normal Debug cleanup used unexpected signals" >&2
    exit 1
}

: > "$kill_log"
set +e
PATH="$mock_directory:/usr/bin:/bin" \
CONFIGURATION=Debug \
BUILT_PRODUCTS_DIR="$products_directory" \
CONFIGURATION_BUILD_DIR="$products_directory" \
MOCK_ENUMERATION_FAILURE=1 \
MOCK_KILL_LOG="$kill_log" \
MOCK_PS_STATE="$ps_state" \
    "$cleanup_script" >/dev/null 2>"$test_root/enumeration-error.log"
enumeration_status=$?
set -e
[ "$enumeration_status" -ne 0 ] || {
    printf '%s\n' "FAIL: process enumeration failure did not fail closed" >&2
    exit 1
}
/usr/bin/grep -q 'Unable to enumerate running processes' \
    "$test_root/enumeration-error.log" || {
    printf '%s\n' "FAIL: process enumeration failure was not reported" >&2
    exit 1
}
[ ! -s "$kill_log" ] || {
    printf '%s\n' "FAIL: enumeration failure invoked kill" >&2
    exit 1
}

: > "$kill_log"
kill_failure_state="$test_root/kill-failure-state"
/bin/mkdir -p "$kill_failure_state"
set +e
PATH="$mock_directory:/usr/bin:/bin" \
CONFIGURATION=Debug \
BUILT_PRODUCTS_DIR="$products_directory" \
CONFIGURATION_BUILD_DIR="$products_directory" \
MOCK_KILL_FAILURE_PID=204 \
MOCK_KILL_LOG="$kill_log" \
MOCK_PS_STATE="$kill_failure_state" \
    "$cleanup_script" >/dev/null 2>"$test_root/kill-error.log"
kill_status=$?
set -e
[ "$kill_status" -ne 0 ] || {
    printf '%s\n' "FAIL: TERM failure did not fail closed" >&2
    exit 1
}
/usr/bin/grep -q 'Unable to terminate Big Wallet Helper process 204' \
    "$test_root/kill-error.log" || {
    printf '%s\n' "FAIL: TERM failure was not reported" >&2
    exit 1
}

: > "$kill_log"
PATH="$mock_directory:/usr/bin:/bin" \
CONFIGURATION=Release \
BUILT_PRODUCTS_DIR="$products_directory" \
CONFIGURATION_BUILD_DIR="$products_directory" \
MOCK_KILL_LOG="$kill_log" \
MOCK_PS_STATE="$ps_state" \
    "$cleanup_script" >/dev/null
[ ! -s "$kill_log" ] || {
    printf '%s\n' "FAIL: non-Debug cleanup invoked kill" >&2
    exit 1
}

printf '%s\n' "Ambient helper cleanup regression tests: PASS"
