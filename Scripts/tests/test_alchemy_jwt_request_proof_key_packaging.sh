#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH= cd -- "$tests_directory/../.." && pwd)
project_file="$repository_directory/Wallet.xcodeproj/project.pbxproj"
publish_script="$repository_directory/Scripts/asc/publish.sh"

test_root=$(
    /usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/alchemy-jwt-proof-packaging-tests.XXXXXX"
)
test_root=$(CDPATH= cd -- "$test_root" && /bin/pwd -P)
logs_directory="$test_root/logs"
/bin/mkdir -p "$logs_directory"
trap '/bin/rm -rf "$test_root"' 0 1 2 15

valid_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
other_key=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA
valid_fingerprint=$(
    printf '%s' "$valid_key" | /usr/bin/shasum -a 256
)
valid_fingerprint=${valid_fingerprint%% *}
other_fingerprint=$(
    printf '%s' "$other_key" | /usr/bin/shasum -a 256
)
other_fingerprint=${other_fingerprint%% *}

fixture_scripts_directory="$test_root/fixture/Scripts"
/bin/mkdir -p "$fixture_scripts_directory"
for fixture_script in \
    validate_alchemy_jwt_request_proof_key.sh \
    bundle_alchemy_jwt_request_proof_key.sh \
    assert_bundled_alchemy_jwt_request_proof_key.sh \
    alchemy_jwt_request_proof_key_common.sh \
    alchemy_login_keychain_supervisor.pl
do
    /bin/cp \
        "$repository_directory/Scripts/$fixture_script" \
        "$fixture_scripts_directory/$fixture_script"
done
printf '%s\n' \
    '' \
    'alchemy_jwt_request_proof_key_run_keychain_supervisor() {' \
    '    return 1' \
    '}' \
    >> "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
/bin/chmod 0755 \
    "$fixture_scripts_directory/validate_alchemy_jwt_request_proof_key.sh" \
    "$fixture_scripts_directory/bundle_alchemy_jwt_request_proof_key.sh" \
    "$fixture_scripts_directory/assert_bundled_alchemy_jwt_request_proof_key.sh"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

validator="$fixture_scripts_directory/validate_alchemy_jwt_request_proof_key.sh"
bundler="$fixture_scripts_directory/bundle_alchemy_jwt_request_proof_key.sh"
artifact_validator="$fixture_scripts_directory/assert_bundled_alchemy_jwt_request_proof_key.sh"
last_stdout=""
last_stderr=""

fail() {
    printf '%s\n' "FAIL: $1" >&2
    exit 1
}

assert_empty_file() {
    [ ! -s "$1" ] || fail "$2"
}

assert_file_contents() {
    expected=$1
    path=$2
    description=$3
    expected_file="$test_root/expected"
    printf '%s' "$expected" > "$expected_file"
    /usr/bin/cmp -s "$expected_file" "$path" || fail "$description"
}

keychain_supervisor="$fixture_scripts_directory/alchemy_login_keychain_supervisor.pl"
supervisor_fake="$test_root/keychain-supervisor-fake.pl"
printf '%s\n' \
    '#!/usr/bin/perl' \
    'use strict;' \
    'use warnings;' \
    'my $mode = shift @ARGV // exit 64;' \
    'if ($mode eq "success") {' \
    '    my $log = shift @ARGV // exit 64;' \
    '    keys(%ENV) == 0 or exit 65;' \
    '    open(my $handle, ">", $log) or exit 66;' \
    '    print {$handle} join("\n", @ARGV), "\n" or exit 67;' \
    '    close($handle) or exit 68;' \
    '    print STDOUT "keychain-secret\n" or exit 69;' \
    '    exit 0;' \
    '}' \
    'if ($mode eq "fd-check") {' \
    '    open(my $inherited_handle, ">&=9") and exit 76;' \
    '    print STDOUT "fd-closed\n" or exit 77;' \
    '    exit 0;' \
    '}' \
    'if ($mode eq "nonzero") {' \
    '    print STDOUT "must-not-escape\n";' \
    '    exit 44;' \
    '}' \
    'if ($mode eq "missing-lf") {' \
    '    print STDOUT "keychain-secret";' \
    '    exit 0;' \
    '}' \
    'if ($mode eq "nul") {' \
    '    print STDOUT "keychain\0secret\n";' \
    '    exit 0;' \
    '}' \
    'if ($mode eq "oversized") {' \
    '    print STDOUT(("A" x 65) . "\n");' \
    '    exit 0;' \
    '}' \
    'if ($mode eq "empty") {' \
    '    exit 0;' \
    '}' \
    'my $pid_file = shift @ARGV // exit 64;' \
    'open(my $pid_handle, ">", $pid_file) or exit 70;' \
    'print {$pid_handle} "$$\n" or exit 71;' \
    'close($pid_handle) or exit 72;' \
    'if ($mode eq "hang-term") {' \
    '    my $marker = shift @ARGV // exit 64;' \
    '    $SIG{TERM} = sub {' \
    '        open(my $marker_handle, ">", $marker) or exit 73;' \
    '        print {$marker_handle} "term\n" or exit 74;' \
    '        close($marker_handle) or exit 75;' \
    '        exit 0;' \
    '    };' \
    '} elsif ($mode eq "hang-ignore") {' \
    '    $SIG{TERM} = "IGNORE";' \
    '} elsif ($mode eq "close-output") {' \
    '    close(STDOUT);' \
    '} else {' \
    '    exit 64;' \
    '}' \
    'while (1) {' \
    '    select(undef, undef, undef, 1);' \
    '}' \
    > "$supervisor_fake"

supervisor_success_stdout="$logs_directory/supervisor-success.stdout"
supervisor_success_stderr="$logs_directory/supervisor-success.stderr"
supervisor_success_arguments="$logs_directory/supervisor-success.arguments"
/usr/bin/env -i /usr/bin/perl "$keychain_supervisor" \
    --timeout-seconds 2 \
    --term-grace-seconds 0.2 \
    --max-output-bytes 64 \
    -- \
    /usr/bin/perl "$supervisor_fake" \
    success "$supervisor_success_arguments" alpha "two words" \
    > "$supervisor_success_stdout" \
    2> "$supervisor_success_stderr" ||
    fail "the Keychain supervisor rejected valid output"
printf '%s\n' "keychain-secret" > "$test_root/expected"
/usr/bin/cmp -s "$test_root/expected" "$supervisor_success_stdout" ||
    fail "the Keychain supervisor changed valid output bytes"
printf '%s\n' alpha "two words" > "$test_root/expected"
/usr/bin/cmp -s "$test_root/expected" "$supervisor_success_arguments" ||
    fail "the Keychain supervisor changed child arguments"
assert_empty_file \
    "$supervisor_success_stderr" \
    "the Keychain supervisor wrote a success diagnostic"

supervisor_fd_stdout="$logs_directory/supervisor-fd.stdout"
supervisor_fd_stderr="$logs_directory/supervisor-fd.stderr"
/usr/bin/env -i /usr/bin/perl "$keychain_supervisor" \
    --timeout-seconds 2 \
    --term-grace-seconds 0.2 \
    --max-output-bytes 64 \
    -- \
    /usr/bin/perl "$supervisor_fake" fd-check \
    9> "$test_root/supervisor-inherited-fd" \
    > "$supervisor_fd_stdout" \
    2> "$supervisor_fd_stderr" ||
    fail "the Keychain supervisor did not close an inherited descriptor"
printf '%s\n' "fd-closed" > "$test_root/expected"
/usr/bin/cmp -s "$test_root/expected" "$supervisor_fd_stdout" ||
    fail "the Keychain supervisor descriptor test changed valid output"
assert_empty_file \
    "$supervisor_fd_stderr" \
    "the Keychain supervisor descriptor test wrote a diagnostic"

expect_supervisor_failure() {
    supervisor_case_name=$1
    supervisor_case_timeout=$2
    supervisor_case_grace=$3
    supervisor_case_maximum=$4
    shift 4
    supervisor_case_stdout="$logs_directory/$supervisor_case_name.stdout"
    supervisor_case_stderr="$logs_directory/$supervisor_case_name.stderr"

    set +e
    /usr/bin/env -i /usr/bin/perl "$keychain_supervisor" \
        --timeout-seconds "$supervisor_case_timeout" \
        --term-grace-seconds "$supervisor_case_grace" \
        --max-output-bytes "$supervisor_case_maximum" \
        -- \
        /usr/bin/perl "$supervisor_fake" "$@" \
        > "$supervisor_case_stdout" \
        2> "$supervisor_case_stderr"
    supervisor_case_status=$?
    set -e

    [ "$supervisor_case_status" -ne 0 ] ||
        fail "$supervisor_case_name unexpectedly succeeded"
    assert_empty_file \
        "$supervisor_case_stdout" \
        "$supervisor_case_name exposed rejected child output"
    assert_empty_file \
        "$supervisor_case_stderr" \
        "$supervisor_case_name wrote a failure diagnostic"
}

expect_supervisor_failure supervisor-child-failure 2 0.2 64 nonzero
expect_supervisor_failure supervisor-missing-lf 2 0.2 64 missing-lf
expect_supervisor_failure supervisor-nul 2 0.2 64 nul
expect_supervisor_failure supervisor-oversized 2 0.2 64 oversized
expect_supervisor_failure supervisor-empty 2 0.2 64 empty

supervisor_term_pid="$logs_directory/supervisor-term.pid"
supervisor_term_marker="$logs_directory/supervisor-term.marker"
expect_supervisor_failure \
    supervisor-term-timeout \
    1 \
    0.2 \
    64 \
    hang-term \
    "$supervisor_term_pid" \
    "$supervisor_term_marker"
[ -s "$supervisor_term_marker" ] ||
    fail "the Keychain supervisor did not send SIGTERM at its deadline"
supervisor_child_pid=$(/bin/cat "$supervisor_term_pid")
if /bin/kill -0 "$supervisor_child_pid" 2>/dev/null; then
    fail "the Keychain supervisor did not reap its SIGTERM child"
fi

supervisor_kill_pid="$logs_directory/supervisor-kill.pid"
expect_supervisor_failure \
    supervisor-kill-timeout \
    1 \
    0.2 \
    64 \
    hang-ignore \
    "$supervisor_kill_pid"
supervisor_child_pid=$(/bin/cat "$supervisor_kill_pid")
if /bin/kill -0 "$supervisor_child_pid" 2>/dev/null; then
    fail "the Keychain supervisor did not reap its SIGKILL child"
fi

supervisor_closed_output_pid="$logs_directory/supervisor-closed-output.pid"
expect_supervisor_failure \
    supervisor-closed-output-timeout \
    1 \
    0.2 \
    64 \
    close-output \
    "$supervisor_closed_output_pid"
supervisor_child_pid=$(/bin/cat "$supervisor_closed_output_pid")
if /bin/kill -0 "$supervisor_child_pid" 2>/dev/null; then
    fail "a child that closed stdout escaped the Keychain deadline"
fi

supervisor_interrupt_pid="$logs_directory/supervisor-interrupt-child.pid"
supervisor_interrupt_stdout="$logs_directory/supervisor-interrupt.stdout"
supervisor_interrupt_stderr="$logs_directory/supervisor-interrupt.stderr"
/usr/bin/env -i /usr/bin/perl "$keychain_supervisor" \
    --timeout-seconds 5 \
    --term-grace-seconds 0.2 \
    --max-output-bytes 64 \
    -- \
    /usr/bin/perl "$supervisor_fake" \
    hang-ignore "$supervisor_interrupt_pid" \
    > "$supervisor_interrupt_stdout" \
    2> "$supervisor_interrupt_stderr" &
supervisor_process_pid=$!
supervisor_wait_attempt=0
while [ ! -s "$supervisor_interrupt_pid" ] &&
    [ "$supervisor_wait_attempt" -lt 100 ]
do
    /usr/bin/perl -e 'select(undef, undef, undef, 0.01)'
    supervisor_wait_attempt=$((supervisor_wait_attempt + 1))
done
[ -s "$supervisor_interrupt_pid" ] ||
    fail "the Keychain supervisor interruption child did not start"
/bin/kill -TERM "$supervisor_process_pid"
set +e
wait "$supervisor_process_pid"
supervisor_interrupt_status=$?
set -e
[ "$supervisor_interrupt_status" -ne 0 ] ||
    fail "an interrupted Keychain supervisor unexpectedly succeeded"
assert_empty_file \
    "$supervisor_interrupt_stdout" \
    "an interrupted Keychain supervisor exposed child output"
assert_empty_file \
    "$supervisor_interrupt_stderr" \
    "an interrupted Keychain supervisor wrote a diagnostic"
supervisor_child_pid=$(/bin/cat "$supervisor_interrupt_pid")
if /bin/kill -0 "$supervisor_child_pid" 2>/dev/null; then
    fail "an interrupted Keychain supervisor did not reap its child"
fi

set +e
/usr/bin/env -i /usr/bin/perl "$keychain_supervisor" \
    --timeout-seconds 0 \
    --term-grace-seconds 0.2 \
    --max-output-bytes 64 \
    -- \
    /bin/true \
    > "$logs_directory/supervisor-invalid.stdout" \
    2> "$logs_directory/supervisor-invalid.stderr"
supervisor_invalid_status=$?
set -e
[ "$supervisor_invalid_status" -ne 0 ] ||
    fail "the Keychain supervisor accepted an invalid deadline"
assert_empty_file \
    "$logs_directory/supervisor-invalid.stdout" \
    "an invalid Keychain supervisor invocation wrote to stdout"
assert_empty_file \
    "$logs_directory/supervisor-invalid.stderr" \
    "an invalid Keychain supervisor invocation wrote to stderr"

identity_arguments="$logs_directory/keychain-identity.arguments"
(
    fail() {
        printf '%s\n' "$1" >&2
        exit 1
    }

    USER=stale-user
    HOME=/Users/stale-home
    export USER HOME
    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    alchemy_jwt_request_proof_key_run_id() {
        [ "$1" = "$keychain_supervisor" ] || return 1
        case "$2:$3${4:+:$4}" in
            32:-u)
                printf '%s\n' 501
                ;;
            257:-un)
                printf '%s\n' effective-user
                ;;
            4097:-P:effective-user)
                printf '%s\n' \
                    "effective-user:********:501:20::0:0:Effective User:/Users/effective home:/bin/zsh"
                ;;
            *)
                return 1
                ;;
        esac
    }
    alchemy_jwt_request_proof_key_run_keychain_supervisor() {
        printf '%s\n' "$@" > "$identity_arguments"
        printf '%s\n' "$valid_key"
    }

    load_login_keychain_secret \
        ALCHEMY_JWT_REQUEST_PROOF_KEY \
        "$keychain_supervisor"
    [ "$LOGIN_KEYCHAIN_SECRET_VALUE" = "$valid_key" ] ||
        fail "the effective-user Keychain lookup changed the password"
    [ "$USER" = stale-user ] && [ "$HOME" = /Users/stale-home ] ||
        fail "the effective-user Keychain lookup changed the caller environment"
) || fail "the effective-user Keychain lookup failed"
printf '%s\n' \
    "$keychain_supervisor" \
    --timeout-seconds \
    30 \
    --term-grace-seconds \
    2 \
    --max-output-bytes \
    44 \
    -- \
    /usr/bin/security \
    find-generic-password \
    -a \
    effective-user \
    -s \
    ALCHEMY_JWT_REQUEST_PROOF_KEY \
    -w \
    "/Users/effective home/Library/Keychains/login.keychain-db" \
    > "$test_root/expected"
/usr/bin/cmp -s "$test_root/expected" "$identity_arguments" ||
    fail "ambient USER or HOME changed the effective-user Keychain lookup"

for identity_case in uid-mismatch extra-field relative-home
do
    case "$identity_case" in
        uid-mismatch)
            identity_record="effective-user:********:502:20::0:0:Effective User:/Users/effective:/bin/zsh"
            ;;
        extra-field)
            identity_record="effective-user:********:501:20::0:0:Effective User:/Users/attacker:actual-home:/bin/zsh"
            ;;
        relative-home)
            identity_record="effective-user:********:501:20::0:0:Effective User:Users/effective:/bin/zsh"
            ;;
    esac
    identity_supervisor_called="$logs_directory/$identity_case.supervisor-called"
    set +e
    (
        fail() {
            printf '%s\n' "$1" >&2
            exit 1
        }

        . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
        alchemy_jwt_request_proof_key_run_id() {
            [ "$1" = "$keychain_supervisor" ] || return 1
            case "$2:$3${4:+:$4}" in
                32:-u)
                    printf '%s\n' 501
                    ;;
                257:-un)
                    printf '%s\n' effective-user
                    ;;
                4097:-P:effective-user)
                    printf '%s\n' "$identity_record"
                    ;;
                *)
                    return 1
                    ;;
            esac
        }
        alchemy_jwt_request_proof_key_run_keychain_supervisor() {
            printf '%s\n' called > "$identity_supervisor_called"
            printf '%s\n' "$valid_key"
        }
        load_login_keychain_secret \
            ALCHEMY_JWT_REQUEST_PROOF_KEY \
            "$keychain_supervisor"
    ) > "$logs_directory/$identity_case.stdout" \
        2> "$logs_directory/$identity_case.stderr"
    identity_status=$?
    set -e
    [ "$identity_status" -ne 0 ] ||
        fail "$identity_case account record unexpectedly succeeded"
    [ ! -e "$identity_supervisor_called" ] ||
        fail "$identity_case account record reached the Keychain supervisor"
    assert_empty_file \
        "$logs_directory/$identity_case.stdout" \
        "$identity_case account record wrote to stdout"
    [ -s "$logs_directory/$identity_case.stderr" ] ||
        fail "$identity_case account record did not report an error"
done

invoke_validator() {
    name=$1
    expected_result=$2
    key_value=$3
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    HOME="$test_root/no-login-keychain" \
        ALCHEMY_JWT_REQUEST_PROOF_KEY="$key_value" \
        "$validator" > "$last_stdout" 2> "$last_stderr"
    status=$?
    set -e

    case "$expected_result" in
        success)
            [ "$status" -eq 0 ] || fail "$name unexpectedly failed"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            assert_empty_file "$last_stderr" "$name wrote to stderr"
            ;;
        failure)
            [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            [ -s "$last_stderr" ] || fail "$name did not report an error"
            ;;
        *)
            fail "invalid expected result for $name"
            ;;
    esac
}

invoke_traced_validator() {
    name=$1
    key_value=$2
    shift 2
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    HOME="$test_root/no-login-keychain" \
        ALCHEMY_JWT_REQUEST_PROOF_KEY="$key_value" \
        "$@" "$validator" > "$last_stdout" 2> "$last_stderr"
    traced_status=$?
    set -e

    [ "$traced_status" -eq 0 ] ||
        fail "$name unexpectedly failed"
    assert_empty_file "$last_stdout" "$name wrote to stdout"
    /usr/bin/grep -F "set +x" "$last_stderr" >/dev/null 2>&1 ||
        fail "$name did not enable tracing before the loader disabled it"
    if /usr/bin/grep -F "$valid_key" \
        "$last_stdout" "$last_stderr" >/dev/null 2>&1
    then
        fail "$name exposed the request-proof key"
    fi
}

invoke_bundler() {
    name=$1
    expected_result=$2
    configuration=$3
    target_build_dir=$4
    resources_path=$5
    output_path=$6
    key_value=$7
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    CONFIGURATION="$configuration" \
        TARGET_BUILD_DIR="$target_build_dir" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH="$resources_path" \
        SCRIPT_OUTPUT_FILE_COUNT=1 \
        SCRIPT_OUTPUT_FILE_0="$output_path" \
        HOME="$test_root/no-login-keychain" \
        ALCHEMY_JWT_REQUEST_PROOF_KEY="$key_value" \
        "$bundler" > "$last_stdout" 2> "$last_stderr"
    status=$?
    set -e

    case "$expected_result" in
        success)
            [ "$status" -eq 0 ] || fail "$name unexpectedly failed"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            assert_empty_file "$last_stderr" "$name wrote to stderr"
            ;;
        failure)
            [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            [ -s "$last_stderr" ] || fail "$name did not report an error"
            ;;
        *)
            fail "invalid expected result for $name"
            ;;
    esac
}

invoke_artifact_validator() {
    name=$1
    expected_result=$2
    platform=$3
    artifact=$4
    key_value=$5
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    HOME="$test_root/no-login-keychain" \
        ALCHEMY_JWT_REQUEST_PROOF_KEY="$key_value" \
        "$artifact_validator" "$platform" "$artifact" \
        > "$last_stdout" 2> "$last_stderr"
    status=$?
    set -e

    case "$expected_result" in
        success)
            [ "$status" -eq 0 ] || fail "$name unexpectedly failed"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            assert_empty_file "$last_stderr" "$name wrote to stderr"
            ;;
        failure)
            [ "$status" -ne 0 ] || fail "$name unexpectedly succeeded"
            assert_empty_file "$last_stdout" "$name wrote to stdout"
            [ -s "$last_stderr" ] || fail "$name did not report an error"
            ;;
        *)
            fail "invalid expected result for $name"
            ;;
    esac
}

for executable in "$validator" "$bundler" "$artifact_validator"; do
    [ -x "$executable" ] || fail "$executable is not executable"
done

invoke_validator valid-environment-key success "$valid_key"
invoke_traced_validator \
    explicit-xtrace-does-not-leak \
    "$valid_key" \
    /bin/sh -x
invoke_traced_validator \
    inherited-xtrace-does-not-leak \
    "$valid_key" \
    /usr/bin/env SHELLOPTS=xtrace /bin/sh

invoke_validator newline-key failure "${valid_key}
"
invoke_validator bom-key failure "﻿${valid_key}"
crlf_key_with_sentinel=$(printf '%s\r\n.' "$valid_key")
crlf_key=${crlf_key_with_sentinel%?}
invoke_validator crlf-key failure "$crlf_key"
unset crlf_key crlf_key_with_sentinel
invoke_validator invalid-character failure \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA*"
invoke_validator noncanonical-base64url failure \
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB"
invoke_validator missing-environment-and-keychain failure ""

printf '%s\n' "$other_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
invoke_validator wrong-fingerprint failure "$valid_key"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

printf '%s\r\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
invoke_validator malformed-fingerprint failure "$valid_key"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

/bin/mv \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256" \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256.saved"
invoke_validator missing-fingerprint failure "$valid_key"
/bin/mv \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256.saved" \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

invoke_validator valid-but-unpinned-replacement failure "$other_key"

(
    fail() {
        exit 1
    }

    ALCHEMY_JWT_REQUEST_PROOF_KEY=$other_key
    export ALCHEMY_JWT_REQUEST_PROOF_KEY
    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    ALCHEMY_JWT_REQUEST_PROOF_KEY=$valid_key
    load_alchemy_jwt_request_proof_key \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    [ "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" = "$valid_key" ] ||
        fail "a post-source request-proof assignment did not take precedence"
) || fail "post-source request-proof precedence failed"

(
    fail() {
        exit 1
    }

    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=$other_key
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT=bad
    export ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT
    ALCHEMY_JWT_REQUEST_PROOF_KEY=$valid_key
    load_alchemy_jwt_request_proof_key \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    [ "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" = "$valid_key" ] ||
        fail "an unvalidated private cache overrode a post-source public assignment"
) || fail "unvalidated request-proof cache precedence failed"

for post_source_value in "" too-short
do
    case "$post_source_value" in
        "")
            post_source_expected_error="is unavailable in the environment and login Keychain"
            ;;
        *)
            post_source_expected_error="must contain exactly 43 characters"
            ;;
    esac
    set +e
    (
        fail() {
            printf '%s\n' "$1" >&2
            exit 1
        }

        HOME="$test_root/no-login-keychain"
        ALCHEMY_JWT_REQUEST_PROOF_KEY=$valid_key
        export HOME ALCHEMY_JWT_REQUEST_PROOF_KEY
        . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
        ALCHEMY_JWT_REQUEST_PROOF_KEY=$post_source_value
        load_alchemy_jwt_request_proof_key \
            "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    ) > "$logs_directory/post-source-selection.stdout" \
        2> "$logs_directory/post-source-selection.stderr"
    post_source_selection_status=$?
    set -e
    [ "$post_source_selection_status" -ne 0 ] ||
        fail "an empty or malformed post-source assignment fell back to the captured key"
    /usr/bin/grep -F "$post_source_expected_error" \
        "$logs_directory/post-source-selection.stderr" >/dev/null ||
        fail "post-source selection did not fail through the selected credential source"
done
unset post_source_value \
    post_source_expected_error \
    post_source_selection_status

set +e
(
    fail() {
        printf '%s\n' "$1" >&2
        exit 1
    }

    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=too-short
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT=bad
    _alchemy_jwt_request_proof_key_cache_valid=1
    export ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT \
        _alchemy_jwt_request_proof_key_cache_valid
    load_alchemy_jwt_request_proof_key \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
) >"$logs_directory/post-source-cache.stdout" \
    2>"$logs_directory/post-source-cache.stderr"
post_source_cache_status=$?
set -e
[ "$post_source_cache_status" -ne 0 ] ||
    fail "a hostile post-source request-proof cache bypassed validation"
/usr/bin/grep -F "must contain exactly 43 characters" \
    "$logs_directory/post-source-cache.stderr" >/dev/null ||
    fail "a hostile post-source request-proof cache did not fail validation"
unset post_source_cache_status

preload_export_probe="$logs_directory/hostile-preload-export-environment.txt"
export_probe="$logs_directory/hostile-export-environment.txt"
hostile_trace_probe="$logs_directory/hostile-export-xtrace.txt"
(
    fail() {
        exit 1
    }
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=preexisting
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT=preexisting
    _alchemy_jwt_request_proof_key_cache_valid=preexisting
    ALCHEMY_JWT_REQUEST_PROOF_KEY=$valid_key
    _alchemy_jwt_request_proof_key_captured_environment_value=preexisting
    LOGIN_KEYCHAIN_SECRET_VALUE=preexisting
    login_keychain_output_with_sentinel=preexisting
    login_keychain_output=preexisting
    alchemy_key_snapshot=preexisting
    alchemy_key_public_assignment_present=preexisting
    alchemy_key_prefix=preexisting
    alchemy_final_character=preexisting
    resource_with_sentinel=preexisting
    bundled_key=preexisting
    export ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT \
        _alchemy_jwt_request_proof_key_cache_valid \
        ALCHEMY_JWT_REQUEST_PROOF_KEY \
        _alchemy_jwt_request_proof_key_captured_environment_value \
        LOGIN_KEYCHAIN_SECRET_VALUE \
        login_keychain_output_with_sentinel \
        login_keychain_output \
        alchemy_key_snapshot \
        alchemy_key_public_assignment_present \
        alchemy_key_prefix \
        alchemy_final_character \
        resource_with_sentinel \
        bundled_key
    unset LC_ALL
    set -a
    set -x
    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    [ "${ALCHEMY_JWT_REQUEST_PROOF_KEY+x}" != x ] ||
        fail "the source request-proof key remained public"
    [ "${ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE+x}" != x ] ||
        fail "a hostile request-proof cache survived source bootstrap"
    [ "${LOGIN_KEYCHAIN_SECRET_VALUE+x}" != x ] ||
        fail "a hostile Keychain cache survived source bootstrap"
    /usr/bin/env > "$preload_export_probe"
    load_alchemy_jwt_request_proof_key \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    [ "${LC_ALL+x}" != x ] ||
        fail "the request-proof loader changed the caller locale"

    cached_request_proof_key=$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE
    export ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT
    ALCHEMY_JWT_REQUEST_PROOF_KEY=$other_key
    export ALCHEMY_JWT_REQUEST_PROOF_KEY
    load_alchemy_jwt_request_proof_key \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    [ "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" = "$cached_request_proof_key" ] ||
        fail "a cached request-proof key was unexpectedly replaced"
    [ "${ALCHEMY_JWT_REQUEST_PROOF_KEY+x}" != x ] ||
        fail "a cached request-proof reload did not scrub the public key"
    unset cached_request_proof_key
    /usr/bin/env > "$export_probe"
) 2> "$hostile_trace_probe"
if /usr/bin/grep -F "$valid_key" \
    "$preload_export_probe" "$export_probe" "$hostile_trace_probe" \
    >/dev/null 2>&1
then
    fail "the request-proof key was inherited by a child process"
fi
if /usr/bin/grep -F "$other_key" "$hostile_trace_probe" >/dev/null 2>&1; then
    fail "a cached request-proof reload exposed its public assignment through xtrace"
fi
for key_variable in \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FINGERPRINT \
    _alchemy_jwt_request_proof_key_cache_valid \
    ALCHEMY_JWT_REQUEST_PROOF_KEY \
    _alchemy_jwt_request_proof_key_captured_environment_value \
    LOGIN_KEYCHAIN_SECRET_VALUE \
    login_keychain_output_with_sentinel \
    login_keychain_output \
    alchemy_key_snapshot \
    alchemy_key_public_assignment_present \
    alchemy_key_prefix \
    alchemy_final_character \
    resource_with_sentinel \
    bundled_key
do
    if /usr/bin/grep -E "^${key_variable}=" \
        "$preload_export_probe" "$export_probe" >/dev/null 2>&1
    then
        fail "$key_variable retained an inherited export attribute"
    fi
done

valid_key_file=$valid_key
newline_key_file=$valid_key
wrong_mode_key=invalid
replacement_key_file=$other_key

target_build_dir="$test_root/build products with spaces"
resources_path="Big Wallet.app/Resources"
resource_directory="$target_build_dir/$resources_path"
resource_path="$resource_directory/AlchemyJWTRequestProofKey"
/bin/mkdir -p "$resource_directory"

invoke_bundler \
    release-bundle \
    success \
    Release \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    "$newline_key_file"
assert_file_contents \
    "$valid_key" \
    "$resource_path" \
    "the bundled key was not normalized to 43 bytes"
[ "$(/usr/bin/stat -f '%Lp' -- "$resource_path")" = "644" ] ||
    fail "the bundled request-proof resource is not mode 0644"

invoke_bundler \
    debug-bundle \
    success \
    Debug \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    "$valid_key_file"
assert_file_contents \
    "$valid_key" \
    "$resource_path" \
    "a Debug build did not bundle the required request-proof key"

printf '%s' "$valid_key" > "$resource_path"
invoke_bundler \
    debug-without-key-fails-and-removes-stale-resource \
    failure \
    Debug \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    ""
[ ! -e "$resource_path" ] ||
    fail "a Debug build retained a stale request-proof resource"

invoke_bundler \
    debug-without-key-fails-with-clean-output \
    failure \
    Debug \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    ""

printf '%s' "$valid_key" > "$resource_path"
invoke_bundler \
    release-without-key-fails-and-removes-stale-resource \
    failure \
    Release \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    ""
[ ! -e "$resource_path" ] ||
    fail "a missing-key Release build retained a stale resource"

printf '%s' "preserve-existing-resource" > "$resource_path"
invoke_bundler \
    invalid-release-key-removes-stale-output \
    failure \
    Release \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    "$wrong_mode_key"
[ ! -e "$resource_path" ] ||
    fail "an invalid Release key left a stale request-proof resource"

printf '%s' "preserve-existing-resource" > "$resource_path"
invoke_bundler \
    unpinned-debug-key-removes-stale-output \
    failure \
    Debug \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    "$replacement_key_file"
[ ! -e "$resource_path" ] ||
    fail "an unpinned Debug key left a stale request-proof resource"

invoke_bundler \
    mismatched-output-path \
    failure \
    Release \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_directory/not-the-resource" \
    "$valid_key_file"

leaf_symlink_target="$test_root/leaf symlink target"
/bin/mkdir -p "$leaf_symlink_target"
/bin/ln -s "$leaf_symlink_target" "$resource_path"
invoke_bundler \
    leaf-symlink-is-safely-replaced \
    success \
    Release \
    "$target_build_dir" \
    "$resources_path" \
    "$resource_path" \
    "$valid_key_file"
[ ! -L "$resource_path" ] && [ -f "$resource_path" ] ||
    fail "the bundler did not replace a stale leaf symlink with a regular file"
assert_file_contents \
    "$valid_key" \
    "$resource_path" \
    "the replacement for a stale leaf symlink did not contain the pinned key"
leaf_symlink_entries=$(
    /usr/bin/find -P "$leaf_symlink_target" -mindepth 1 -print
) || fail "the leaf symlink target could not be inspected"
[ -z "$leaf_symlink_entries" ] ||
    fail "the bundler wrote through a leaf symlink"
/bin/rm -f "$resource_path"

parent_symlink_build="$test_root/parent symlink build"
parent_symlink_target="$test_root/parent symlink target"
/bin/mkdir -p "$parent_symlink_build/Big Wallet.app" "$parent_symlink_target"
/bin/ln -s "$parent_symlink_target" \
    "$parent_symlink_build/Big Wallet.app/Resources"
invoke_bundler \
    parent-symlink-fails-closed \
    failure \
    Release \
    "$parent_symlink_build" \
    "Big Wallet.app/Resources" \
    "$parent_symlink_build/Big Wallet.app/Resources/AlchemyJWTRequestProofKey" \
    "$valid_key_file"

ios_artifact="$test_root/iOS release artifact"
ios_app="$ios_artifact/Products/Applications/Big Wallet.app"
ios_extension="$ios_app/PlugIns/Safari iOS.appex"
/bin/mkdir -p "$ios_extension"
printf '%s' "$valid_key" > "$ios_app/AlchemyJWTRequestProofKey"
printf '%s' "$valid_key" > "$ios_extension/AlchemyJWTRequestProofKey"
/bin/chmod 0644 \
    "$ios_app/AlchemyJWTRequestProofKey" \
    "$ios_extension/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    ios-directory \
    success \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"

/bin/chmod 0600 "$ios_extension/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    rejects-unsafe-resource-mode \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/chmod 0644 "$ios_extension/AlchemyJWTRequestProofKey"

ios_extension_decoy="$test_root/iOS extension decoy"
/bin/mv "$ios_extension" "$ios_extension_decoy"
/bin/ln -s "$ios_extension_decoy" "$ios_extension"
invoke_artifact_validator \
    rejects-symlinked-required-ancestor-with-decoy \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/rm -f "$ios_extension"
/bin/mv "$ios_extension_decoy" "$ios_extension"

unreadable_subtree="$ios_artifact/unreadable subtree"
/bin/mkdir -p "$unreadable_subtree"
printf '%s' "$valid_key" \
    > "$unreadable_subtree/AlchemyJWTRequestProofKey"
/bin/chmod 0000 "$unreadable_subtree"
invoke_artifact_validator \
    rejects-find-permission-failure \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/chmod 0700 "$unreadable_subtree"
/bin/rm -rf "$unreadable_subtree"

printf '%s' "$valid_key" \
    > "$ios_app/.AlchemyJWTRequestProofKey.interrupted"
invoke_artifact_validator \
    rejects-temporary-resource \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/rm -f "$ios_app/.AlchemyJWTRequestProofKey.interrupted"

decoy_bundle="$ios_app/Frameworks/Decoy.framework"
/bin/mkdir -p "$decoy_bundle"
printf '%s' "$valid_key" > "$decoy_bundle/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    rejects-decoy-resource \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/rm -rf "$ios_app/Frameworks"

test_bundle="$ios_app/PlugIns/Tests iOS.xctest"
/bin/mkdir -p "$test_bundle"
printf '%s' "$valid_key" > "$test_bundle/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    rejects-test-bundle-resource \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
/bin/rm -rf "$test_bundle"

printf '%s' "$other_key" > "$ios_extension/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    rejects-mismatched-extension \
    failure \
    IOS \
    "$ios_artifact" \
    "$valid_key_file"
printf '%s' "$valid_key" > "$ios_extension/AlchemyJWTRequestProofKey"

ios_ipa_source="$test_root/iOS IPA source"
ios_ipa="$test_root/iOS release.ipa"
/bin/mkdir -p "$ios_ipa_source/Payload"
/usr/bin/ditto "$ios_app" \
    "$ios_ipa_source/Payload/Big Wallet.app"
/usr/bin/ditto -c -k "$ios_ipa_source" "$ios_ipa"
invoke_artifact_validator ios-ipa success IOS "$ios_ipa" "$valid_key_file"

decoy_ipa_source="$test_root/iOS decoy IPA source"
decoy_ipa="$test_root/iOS decoy release.ipa"
/bin/mkdir -p \
    "$decoy_ipa_source/Payload/Big Wallet.app" \
    "$decoy_ipa_source/Decoy"
/usr/bin/ditto "$ios_app" \
    "$decoy_ipa_source/Decoy/Big Wallet.app"
/usr/bin/ditto -c -k "$decoy_ipa_source" "$decoy_ipa"
invoke_artifact_validator \
    rejects-complete-decoy-app-outside-fixed-ipa-root \
    failure \
    IOS \
    "$decoy_ipa" \
    "$valid_key_file"

vision_artifact="$test_root/visionOS release artifact"
vision_app="$vision_artifact/Products/Applications/Big Wallet.app"
vision_extension="$vision_app/PlugIns/Safari visionOS.appex"
/bin/mkdir -p "$vision_extension"
printf '%s' "$valid_key" > "$vision_app/AlchemyJWTRequestProofKey"
printf '%s' "$valid_key" > "$vision_extension/AlchemyJWTRequestProofKey"
/bin/chmod 0644 \
    "$vision_app/AlchemyJWTRequestProofKey" \
    "$vision_extension/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    visionos-directory \
    success \
    VISION_OS \
    "$vision_artifact" \
    "$valid_key_file"

mac_artifact="$test_root/macOS release artifact"
mac_app="$mac_artifact/Products/Applications/Big Wallet.app"
mac_extension="$mac_app/Contents/PlugIns/Safari macOS.appex"
ambient_app="$mac_app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app"
/bin/mkdir -p \
    "$mac_app/Contents/Resources" \
    "$mac_extension/Contents/Resources" \
    "$ambient_app/Contents/Resources"
printf '%s' "$valid_key" \
    > "$mac_app/Contents/Resources/AlchemyJWTRequestProofKey"
printf '%s' "$valid_key" \
    > "$mac_extension/Contents/Resources/AlchemyJWTRequestProofKey"
printf '%s' "$valid_key" \
    > "$ambient_app/Contents/Resources/AlchemyJWTRequestProofKey"
/bin/chmod 0644 \
    "$mac_app/Contents/Resources/AlchemyJWTRequestProofKey" \
    "$mac_extension/Contents/Resources/AlchemyJWTRequestProofKey" \
    "$ambient_app/Contents/Resources/AlchemyJWTRequestProofKey"
invoke_artifact_validator \
    macos-directory \
    success \
    MAC_OS \
    "$mac_artifact" \
    "$valid_key_file"

mac_pkg_source="$test_root/macOS pkg source"
mac_pkg="$test_root/macOS release.pkg"
/bin/mkdir -p "$mac_pkg_source"
/usr/bin/ditto "$mac_app" "$mac_pkg_source/Big Wallet.app"
/bin/cp \
    "$repository_directory/App macOS/Info.plist" \
    "$mac_pkg_source/Big Wallet.app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier \
    -string org.lil.big-wallet.proof-packaging-test \
    "$mac_pkg_source/Big Wallet.app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundlePackageType \
    -string APPL \
    "$mac_pkg_source/Big Wallet.app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString \
    -string 1.0 \
    "$mac_pkg_source/Big Wallet.app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion \
    -string 1 \
    "$mac_pkg_source/Big Wallet.app/Contents/Info.plist"
/usr/bin/productbuild \
    --component "$mac_pkg_source/Big Wallet.app" /Applications \
    "$mac_pkg" >/dev/null
invoke_artifact_validator \
    macos-pkg \
    success \
    MAC_OS \
    "$mac_pkg" \
    "$valid_key_file"

/bin/ln -s "$valid_key_file" "$mac_artifact/UnexpectedProofLink"
invoke_artifact_validator \
    ignores-unrelated-symlink \
    success \
    MAC_OS \
    "$mac_artifact" \
    "$valid_key_file"

if /usr/bin/grep -F "$valid_key" \
    "$logs_directory"/*.stdout "$logs_directory"/*.stderr \
    >/dev/null 2>&1
then
    fail "the request-proof key leaked into command output"
fi
if /usr/bin/grep -F "$other_key" \
    "$logs_directory"/*.stdout "$logs_directory"/*.stderr \
    >/dev/null 2>&1
then
    fail "a mismatched request-proof key leaked into command output"
fi

assert_count() {
    expected_count=$1
    needle=$2
    file=$3
    actual_count=$(
        /usr/bin/grep -F -c -- "$needle" "$file" || true
    )
    [ "$actual_count" -eq "$expected_count" ] ||
        fail "unexpected project occurrence count for $needle"
}

assert_bundle_phase_after_cleanup() {
    target_id=$1
    cleanup_id=$2
    bundle_id=$3
    description=$4

    /usr/bin/awk \
        -v target_id="$target_id" \
        -v cleanup_id="$cleanup_id" \
        -v bundle_id="$bundle_id" '
        !active &&
            index($0, target_id " /*") &&
            index($0, " = {") {
            active = 1
        }
        active && index($0, cleanup_id " /*") {
            cleanup_line = NR
        }
        active && index($0, bundle_id " /*") {
            bundle_line = NR
        }
        active && /productType =/ {
            finished = 1
            exit
        }
        END {
            if (!finished ||
                cleanup_line == 0 ||
                bundle_line != cleanup_line + 1) {
                exit 1
            }
        }
    ' "$project_file" ||
        fail "$description request-proof phase is misplaced"
}

assert_count \
    7 \
    "/* Bundle Alchemy JWT Request Proof Key */ = {" \
    "$project_file"
assert_count \
    7 \
    'name = "Bundle Alchemy JWT Request Proof Key";' \
    "$project_file"
assert_count \
    0 \
    'ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/alchemy_jwt_request_proof_key.sha256",' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/alchemy_jwt_request_proof_key_common.sh",' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/alchemy_login_keychain_supervisor.pl",' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/bundle_alchemy_jwt_request_proof_key.sh",' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/validate_alchemy_jwt_request_proof_key.sh",' \
    "$project_file"
assert_count \
    7 \
    '"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AlchemyJWTRequestProofKey",' \
    "$project_file"
assert_count \
    7 \
    'shellScript = "set -e\n/bin/sh \"$SRCROOT/Scripts/bundle_alchemy_jwt_request_proof_key.sh\"\n";' \
    "$project_file"

for phase_id in \
    2FA6A0010000000000000001 \
    2FA6A0010000000000000002 \
    2FA6A0010000000000000003 \
    2FA6A0010000000000000004 \
    2FA6A0010000000000000005 \
    2FA6A0010000000000000006 \
    2FA6A0010000000000000007
do
    /usr/bin/awk -v phase_id="$phase_id" '
        index($0, phase_id " /*") && index($0, " = {") {
            active = 1
        }
        active &&
            index($0, "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE") {
            legacy_key_input = 1
        }
        active && /alwaysOutOfDate = 1;/ {
            always_out_of_date += 1
        }
        active && /showEnvVarsInLog = 0;/ {
            hidden_environment = 1
        }
        active && /^		};/ {
            exit
        }
        END {
            if (!hidden_environment ||
                always_out_of_date != 1 ||
                legacy_key_input) {
                exit 1
            }
        }
    ' "$project_file" ||
        fail "$phase_id does not safely declare the dynamic key input"
done

assert_bundle_phase_after_cleanup \
    2C09CB9E273979C1009AD39B \
    516B2583C21E4F89B3F786DA \
    2FA6A0010000000000000001 \
    "Safari macOS"
assert_bundle_phase_after_cleanup \
    2C17BDC92D3D007E0015C58B \
    AB014F43D7D74AA2A57639E3 \
    2FA6A0010000000000000002 \
    "Big Wallet visionOS"
assert_bundle_phase_after_cleanup \
    2C19953B2674C4B900A8E370 \
    E912C196422D43E2A14A6C26 \
    2FA6A0010000000000000003 \
    "Big Wallet macOS"
assert_bundle_phase_after_cleanup \
    2C5FF96E26C84F7B00B32ACC \
    4EC946B2766C4F89AE45F6A5 \
    2FA6A0010000000000000004 \
    "Big Wallet iOS"
assert_bundle_phase_after_cleanup \
    2C60546E2D529A9A00779570 \
    A0FB2A7A814343849A35549C \
    2FA6A0010000000000000005 \
    "Safari visionOS"
assert_bundle_phase_after_cleanup \
    2CB9B54E2FA23F0600F094FB \
    D8E7DDB615794095B0AE5890 \
    2FA6A0010000000000000006 \
    "Big Wallet Ambient"
assert_bundle_phase_after_cleanup \
    2CCEB82C27594E2A00768473 \
    0F74DBBAAD154CE0816A24C8 \
    2FA6A0010000000000000007 \
    "Safari iOS"

assert_count \
    0 \
    'Scripts/validate_alchemy_jwt_request_proof_key.sh' \
    "$publish_script"
assert_count \
    1 \
    'validate_alchemy_release_inputs' \
    "$publish_script"
assert_count \
    0 \
    '--xcodebuild-flag="ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE=$proof_key_file"' \
    "$publish_script"
assert_count \
    2 \
    'Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh' \
    "$publish_script"

printf '%s\n' "Alchemy JWT request-proof key packaging regression tests: PASS"
