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

# Exercise the fixed, adjacent fingerprint lookup without depending on the
# repository's production fingerprint. The real file is populated separately
# from the existing production key and is never replaced by a test value.
fixture_scripts_directory="$test_root/fixture/Scripts"
/bin/mkdir -p "$fixture_scripts_directory"
for fixture_script in \
    validate_alchemy_jwt_request_proof_key_file.sh \
    bundle_alchemy_jwt_request_proof_key.sh \
    assert_bundled_alchemy_jwt_request_proof_key.sh \
    alchemy_jwt_request_proof_key_common.sh
do
    /bin/cp \
        "$repository_directory/Scripts/$fixture_script" \
        "$fixture_scripts_directory/$fixture_script"
done
/bin/chmod 0755 \
    "$fixture_scripts_directory/validate_alchemy_jwt_request_proof_key_file.sh" \
    "$fixture_scripts_directory/bundle_alchemy_jwt_request_proof_key.sh" \
    "$fixture_scripts_directory/assert_bundled_alchemy_jwt_request_proof_key.sh"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

validator="$fixture_scripts_directory/validate_alchemy_jwt_request_proof_key_file.sh"
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

invoke_validator() {
    name=$1
    expected_result=$2
    key_file=$3
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    "$validator" "$key_file" > "$last_stdout" 2> "$last_stderr"
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
    key_file=$2
    shift 2
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    "$@" "$validator" "$key_file" > "$last_stdout" 2> "$last_stderr"
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
    key_file=$7
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    CONFIGURATION="$configuration" \
        TARGET_BUILD_DIR="$target_build_dir" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH="$resources_path" \
        SCRIPT_OUTPUT_FILE_COUNT=1 \
        SCRIPT_OUTPUT_FILE_0="$output_path" \
        ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$key_file" \
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
    key_file=$5
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$key_file" \
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

key_directory="$test_root/external keys with spaces"
/bin/mkdir -p "$key_directory"
/bin/chmod 0700 "$key_directory"
valid_key_file="$key_directory/request proof key"
printf '%s' "$valid_key" > "$valid_key_file"
/bin/chmod 0600 "$valid_key_file"
invoke_validator valid-key success "$valid_key_file"
invoke_traced_validator \
    explicit-xtrace-does-not-leak \
    "$valid_key_file" \
    /bin/sh -x
invoke_traced_validator \
    inherited-xtrace-does-not-leak \
    "$valid_key_file" \
    /usr/bin/env SHELLOPTS=xtrace /bin/sh

newline_key_file="$key_directory/request proof key with newline"
printf '%s\n' "$valid_key" > "$newline_key_file"
/bin/chmod 0600 "$newline_key_file"
invoke_validator valid-key-with-newline success "$newline_key_file"

bom_key_file="$key_directory/BOM key"
printf '\357\273\277%s' "$valid_key" > "$bom_key_file"
/bin/chmod 0600 "$bom_key_file"
invoke_validator bom-key failure "$bom_key_file"

crlf_key_file="$key_directory/CRLF key"
printf '%s\r\n' "$valid_key" > "$crlf_key_file"
/bin/chmod 0600 "$crlf_key_file"
invoke_validator crlf-key failure "$crlf_key_file"

wrong_mode_key="$key_directory/wrong mode"
printf '%s' "$valid_key" > "$wrong_mode_key"
/bin/chmod 0644 "$wrong_mode_key"
invoke_validator wrong-mode failure "$wrong_mode_key"

invalid_character_key="$key_directory/invalid character"
printf '%s' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA*" \
    > "$invalid_character_key"
/bin/chmod 0600 "$invalid_character_key"
invoke_validator invalid-character failure "$invalid_character_key"

noncanonical_key="$key_directory/noncanonical"
printf '%s' "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB" \
    > "$noncanonical_key"
/bin/chmod 0600 "$noncanonical_key"
invoke_validator noncanonical-base64url failure "$noncanonical_key"

two_line_key="$key_directory/two lines"
printf '%s\n%s\n' "$valid_key" "$valid_key" > "$two_line_key"
/bin/chmod 0600 "$two_line_key"
invoke_validator multiple-lines failure "$two_line_key"

printf '%s\n' "$other_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
invoke_validator wrong-fingerprint failure "$valid_key_file"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

printf '%s\r\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
invoke_validator malformed-fingerprint failure "$valid_key_file"
printf '%s\n' "$valid_fingerprint" \
    > "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

/bin/mv \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256" \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256.saved"
invoke_validator missing-fingerprint failure "$valid_key_file"
/bin/mv \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256.saved" \
    "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"

replacement_key_file="$key_directory/replacement key"
printf '%s' "$other_key" > "$replacement_key_file"
/bin/chmod 0600 "$replacement_key_file"
invoke_validator valid-but-unpinned-replacement failure "$replacement_key_file"

export_probe="$logs_directory/hostile-export-environment.txt"
(
    fail() {
        exit 1
    }
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE=preexisting
    alchemy_snapshot_with_sentinel=preexisting
    alchemy_key_snapshot=preexisting
    alchemy_key_prefix=preexisting
    alchemy_final_character=preexisting
    resource_with_sentinel=preexisting
    bundled_key=preexisting
    export ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
        alchemy_snapshot_with_sentinel \
        alchemy_key_snapshot \
        alchemy_key_prefix \
        alchemy_final_character \
        resource_with_sentinel \
        bundled_key
    . "$fixture_scripts_directory/alchemy_jwt_request_proof_key_common.sh"
    load_alchemy_jwt_request_proof_key \
        "$valid_key_file" \
        "$fixture_scripts_directory/alchemy_jwt_request_proof_key.sha256"
    /usr/bin/env > "$export_probe"
)
if /usr/bin/grep -F "$valid_key" "$export_probe" >/dev/null 2>&1; then
    fail "the request-proof key was inherited by a child process"
fi
for key_variable in \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE \
    alchemy_snapshot_with_sentinel \
    alchemy_key_snapshot \
    alchemy_key_prefix \
    alchemy_final_character
do
    if /usr/bin/grep -E "^${key_variable}=" "$export_probe" >/dev/null 2>&1; then
        fail "$key_variable retained an inherited export attribute"
    fi
done

/bin/ln -s "$valid_key_file" "$key_directory/symlink key"
invoke_validator symlink-key failure "$key_directory/symlink key"

insecure_key_directory="$test_root/insecure key directory"
/bin/mkdir -p "$insecure_key_directory"
/bin/chmod 0755 "$insecure_key_directory"
insecure_parent_key="$insecure_key_directory/request proof key"
printf '%s' "$valid_key" > "$insecure_parent_key"
/bin/chmod 0600 "$insecure_parent_key"
invoke_validator insecure-parent-directory failure "$insecure_parent_key"

symlinked_key_parent_target="$test_root/symlinked key parent target"
symlinked_key_parent="$test_root/symlinked key parent"
/bin/mkdir -p "$symlinked_key_parent_target"
/bin/chmod 0700 "$symlinked_key_parent_target"
symlinked_parent_key="$symlinked_key_parent_target/request proof key"
printf '%s' "$valid_key" > "$symlinked_parent_key"
/bin/chmod 0600 "$symlinked_parent_key"
/bin/ln -s "$symlinked_key_parent_target" "$symlinked_key_parent"
invoke_validator \
    symlinked-parent-directory \
    failure \
    "$symlinked_key_parent/request proof key"

relative_key_name=request-proof-relative-test-key
printf '%s' "$valid_key" > "$test_root/$relative_key_name"
/bin/chmod 0600 "$test_root/$relative_key_name"
(
    cd "$test_root"
    invoke_validator relative-path failure "$relative_key_name"
)

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
ambient_app="$mac_app/Contents/Helpers/Big Wallet.app"
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

/bin/ln -s "$valid_key_file" \
    "$mac_app/Contents/Helpers/Big Wallet.app/Contents/Resources/UnexpectedProofLink"
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
    7 \
    '"$(ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE)",' \
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
    '"$(SRCROOT)/Scripts/bundle_alchemy_jwt_request_proof_key.sh",' \
    "$project_file"
assert_count \
    7 \
    '"$(SRCROOT)/Scripts/validate_alchemy_jwt_request_proof_key_file.sh",' \
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
            index($0, "\"$(ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE)\",") {
            key_input_count++
        }
        active && /showEnvVarsInLog = 0;/ {
            hidden_environment = 1
        }
        active && /^		};/ {
            exit
        }
        END {
            if (!hidden_environment || key_input_count != 1) {
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
    'Scripts/validate_alchemy_jwt_request_proof_key_file.sh' \
    "$publish_script"
assert_count \
    1 \
    'validate_alchemy_release_inputs' \
    "$publish_script"
assert_count \
    1 \
    '--xcodebuild-flag="ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE=$proof_key_file"' \
    "$publish_script"
assert_count \
    2 \
    'Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh' \
    "$publish_script"

printf '%s\n' "Alchemy JWT request-proof key packaging regression tests: PASS"
