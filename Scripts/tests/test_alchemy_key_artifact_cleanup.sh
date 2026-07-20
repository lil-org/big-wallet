#!/bin/sh

set -eu

tests_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_directory=$(CDPATH= cd -- "$tests_directory/../.." && pwd)
cleanup_script="$repository_directory/Scripts/remove_legacy_alchemy_api_key.sh"
scanner_script="$repository_directory/Scripts/assert_no_bundled_alchemy_key.sh"
project_file="$repository_directory/Wallet.xcodeproj/project.pbxproj"
publish_script="$repository_directory/Scripts/asc/publish.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/alchemy-key-artifact-tests.XXXXXX")
test_root=$(CDPATH= cd -- "$test_root" && /bin/pwd -P)
logs_directory="$test_root/logs"
mkdir -p "$logs_directory"
trap 'rm -rf "$test_root"' 0 HUP INT TERM

sentinel="SYNTHETIC_ALCHEMY_KEY_CONTENT_MUST_NOT_LEAK"
request_proof_key_value=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
request_proof_key_file="$test_root/request proof key with spaces"
printf '%s' "$request_proof_key_value" > "$request_proof_key_file"
chmod 0600 "$request_proof_key_file"
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
    cmp -s "$expected_file" "$path" || fail "$description"
}

invoke_cleanup() {
    name=$1
    expected_result=$2
    target_build_dir=$3
    resources_path=$4
    output_count=$5
    output_path=$6
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    TARGET_BUILD_DIR="$target_build_dir" \
        UNLOCALIZED_RESOURCES_FOLDER_PATH="$resources_path" \
        SCRIPT_OUTPUT_FILE_COUNT="$output_count" \
        SCRIPT_OUTPUT_FILE_0="$output_path" \
        "$cleanup_script" > "$last_stdout" 2> "$last_stderr"
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

invoke_scanner() {
    name=$1
    expected_result=$2
    shift 2
    last_stdout="$logs_directory/$name.stdout"
    last_stderr="$logs_directory/$name.stderr"

    set +e
    "$scanner_script" "$@" > "$last_stdout" 2> "$last_stderr"
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

[ -x "$cleanup_script" ] || fail "cleanup script is not executable"
[ -x "$scanner_script" ] || fail "artifact scanner is not executable"

target_build_dir="$test_root/build products"
resources_path="Product With Spaces.app/Resources"
resource_directory="$target_build_dir/$resources_path"
legacy_path="$resource_directory/AlchemyAPIKey"
mkdir -p "$resource_directory"
printf '%s' "$sentinel" > "$legacy_path"
printf '%s' "preserve-backup" > "$resource_directory/AlchemyAPIKey.backup"
printf '%s' "preserve-resource" > "$resource_directory/NetworkCatalog.json"

invoke_cleanup \
    exact-file-removal \
    success \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$legacy_path"

[ ! -e "$legacy_path" ] || fail "cleanup left the exact legacy resource"
assert_file_contents \
    "preserve-backup" \
    "$resource_directory/AlchemyAPIKey.backup" \
    "cleanup changed a similarly named file"
assert_file_contents \
    "preserve-resource" \
    "$resource_directory/NetworkCatalog.json" \
    "cleanup changed an unrelated resource"

invoke_cleanup \
    idempotent-removal \
    success \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$legacy_path"

stale_variant_directory="$target_build_dir/Product With Spaces.app/Nested"
stale_variant="$stale_variant_directory/AlchemyAPIKey.tmp.stale"
mkdir -p "$stale_variant_directory"
printf '%s' "$sentinel" > "$stale_variant"
invoke_cleanup \
    stale-variant-exact-cleanup \
    success \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$legacy_path"
invoke_scanner \
    stale-variant-product-scan \
    failure \
    "$target_build_dir/Product With Spaces.app"
[ -f "$stale_variant" ] ||
    fail "the read-only scanner changed a stale variant"
rm -f "$stale_variant"

external_target="$test_root/external target"
printf '%s' "$sentinel" > "$external_target"
ln -s "$external_target" "$legacy_path"
invoke_cleanup \
    symlink-removal \
    success \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$legacy_path"
[ ! -L "$legacy_path" ] || fail "cleanup left the legacy symlink"
assert_file_contents \
    "$sentinel" \
    "$external_target" \
    "cleanup followed the legacy symlink"

parent_symlink_build="$test_root/parent symlink build"
parent_symlink_target="$test_root/parent symlink target"
mkdir -p "$parent_symlink_build/Product.app" "$parent_symlink_target"
parent_symlink_legacy="$parent_symlink_target/AlchemyAPIKey"
printf '%s' "$sentinel" > "$parent_symlink_legacy"
ln -s "$parent_symlink_target" \
    "$parent_symlink_build/Product.app/Resources"
invoke_cleanup \
    parent-symlink-fails-closed \
    failure \
    "$parent_symlink_build" \
    "Product.app/Resources" \
    1 \
    "$parent_symlink_build/Product.app/Resources/AlchemyAPIKey"
assert_file_contents \
    "$sentinel" \
    "$parent_symlink_legacy" \
    "cleanup followed a parent symlink outside the product"

mkdir "$legacy_path"
printf '%s' "$sentinel" > "$legacy_path/contents"
invoke_cleanup \
    directory-fails-closed \
    failure \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$legacy_path"
[ -d "$legacy_path" ] || fail "cleanup removed an unexpected directory"
assert_file_contents \
    "$sentinel" \
    "$legacy_path/contents" \
    "cleanup changed an unexpected directory"
rm -rf "$legacy_path"

printf '%s' "$sentinel" > "$legacy_path"
invoke_cleanup \
    output-path-mismatch \
    failure \
    "$target_build_dir" \
    "$resources_path" \
    1 \
    "$resource_directory/not-the-key"
[ -f "$legacy_path" ] || fail "mismatched output removed the legacy resource"

invoke_cleanup \
    output-count-mismatch \
    failure \
    "$target_build_dir" \
    "$resources_path" \
    2 \
    "$legacy_path"
[ -f "$legacy_path" ] || fail "invalid output count removed the legacy resource"

invoke_cleanup \
    relative-target-directory \
    failure \
    "relative/build" \
    "$resources_path" \
    1 \
    "relative/build/$resources_path/AlchemyAPIKey"

invoke_cleanup \
    traversing-resources-path \
    failure \
    "$target_build_dir" \
    "../outside" \
    1 \
    "$target_build_dir/../outside/AlchemyAPIKey"

rm -f "$legacy_path"

clean_artifact="$test_root/clean artifact"
mkdir -p "$clean_artifact/Nested"
printf '%s' "preserve" > "$clean_artifact/AlchemyAPIKey.backup"
printf '%s' "preserve" > "$clean_artifact/Nested/.AlchemyAPIKey"
invoke_scanner clean-artifact success "$clean_artifact"

outside_dirty_tree="$test_root/outside dirty tree"
mkdir -p "$outside_dirty_tree"
printf '%s' "$sentinel" > "$outside_dirty_tree/AlchemyAPIKey"
ln -s "$outside_dirty_tree" "$clean_artifact/Nested/unfollowed-link"
invoke_scanner does-not-follow-directory-symlinks success "$clean_artifact"

for banned_name in \
    AlchemyAPIKey \
    AlchemyAPIKey.tmp.12345 \
    .AlchemyAPIKey.ABCDEF
do
    dirty_artifact="$test_root/dirty-$banned_name"
    mkdir -p "$dirty_artifact/Nested"
    printf '%s' "$sentinel" > "$dirty_artifact/Nested/$banned_name"
    invoke_scanner "rejects-$banned_name" failure "$dirty_artifact"
done

symlink_artifact="$test_root/symlink artifact"
mkdir -p "$symlink_artifact"
ln -s "$external_target" "$symlink_artifact/AlchemyAPIKey"
invoke_scanner rejects-banned-symlink failure "$symlink_artifact"

invoke_scanner rejects-missing-root failure "$test_root/missing"
invoke_scanner rejects-symlink-root failure "$clean_artifact/Nested/unfollowed-link"
invoke_scanner rejects-dirty-second-root failure "$clean_artifact" "$dirty_artifact"

clean_ipa_source="$test_root/clean ipa source"
clean_ipa="$test_root/clean export.ipa"
mkdir -p "$clean_ipa_source/Payload/Wallet.app"
printf '%s' "preserve" \
    > "$clean_ipa_source/Payload/Wallet.app/AlchemyAPIKey.backup"
/usr/bin/ditto -c -k "$clean_ipa_source" "$clean_ipa"
invoke_scanner clean-exported-ipa success "$clean_ipa"

dirty_ipa_source="$test_root/dirty ipa source"
dirty_ipa="$test_root/dirty export.ipa"
mkdir -p "$dirty_ipa_source/Payload/Wallet.app"
printf '%s' "$sentinel" \
    > "$dirty_ipa_source/Payload/Wallet.app/AlchemyAPIKey"
/usr/bin/ditto -c -k "$dirty_ipa_source" "$dirty_ipa"
invoke_scanner dirty-exported-ipa failure "$dirty_ipa"

clean_pkg_source="$test_root/clean pkg source"
clean_pkg="$test_root/clean export.pkg"
mkdir -p "$clean_pkg_source/Applications/Wallet.app"
printf '%s' "preserve" \
    > "$clean_pkg_source/Applications/Wallet.app/AlchemyAPIKey.backup"
/usr/bin/pkgbuild \
    --root "$clean_pkg_source" \
    --identifier org.lil.big-wallet.test.clean \
    --version 1 \
    --install-location / \
    "$clean_pkg" >/dev/null
invoke_scanner clean-exported-pkg success "$clean_pkg"

dirty_pkg_source="$test_root/dirty pkg source"
dirty_pkg="$test_root/dirty export.pkg"
mkdir -p "$dirty_pkg_source/Applications/Wallet.app"
printf '%s' "$sentinel" \
    > "$dirty_pkg_source/Applications/Wallet.app/AlchemyAPIKey"
/usr/bin/pkgbuild \
    --root "$dirty_pkg_source" \
    --identifier org.lil.big-wallet.test.dirty \
    --version 1 \
    --install-location / \
    "$dirty_pkg" >/dev/null
invoke_scanner dirty-exported-pkg failure "$dirty_pkg"

ln -s "$clean_ipa" "$test_root/symlink export.ipa"
invoke_scanner \
    rejects-symlink-package \
    failure \
    "$test_root/symlink export.ipa"

if grep -F "$sentinel" "$logs_directory"/*.stdout "$logs_directory"/*.stderr \
    >/dev/null 2>&1
then
    fail "a synthetic key sentinel leaked into command output"
fi

assert_count() {
    expected_count=$1
    needle=$2
    file=$3
    actual_count=$(grep -F -c "$needle" "$file" || true)
    [ "$actual_count" -eq "$expected_count" ] ||
        fail "unexpected project occurrence count for $needle"
}

assert_target_phase_order() {
    target_id=$1
    resources_id=$2
    cleanup_id=$3
    description=$4

    awk \
        -v target_id="$target_id" \
        -v resources_id="$resources_id" \
        -v cleanup_id="$cleanup_id" '
        !active &&
            index($0, target_id " /*") &&
            index($0, " = {") {
            active = 1
        }
        active && index($0, resources_id " /*") {
            resources_line = NR
        }
        active && index($0, cleanup_id " /*") {
            cleanup_line = NR
        }
        active && /productType =/ {
            finished = 1
            exit
        }
        END {
            if (!finished ||
                resources_line == 0 ||
                cleanup_line != resources_line + 1) {
                exit 1
            }
        }
    ' "$project_file" || fail "$description cleanup phase is misplaced"
}

assert_count 7 "/* Remove Legacy Alchemy API Key */ = {" "$project_file"
assert_count 7 'name = "Remove Legacy Alchemy API Key";' "$project_file"
assert_count 7 '"$(SRCROOT)/Scripts/assert_no_bundled_alchemy_key.sh",' "$project_file"
assert_count 7 '"$(SRCROOT)/Scripts/remove_legacy_alchemy_api_key.sh",' "$project_file"
assert_count 7 '"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/AlchemyAPIKey",' "$project_file"
assert_count 7 'shellScript = "set -e\n/bin/sh \"$SRCROOT/Scripts/remove_legacy_alchemy_api_key.sh\"\n/bin/sh \"$SRCROOT/Scripts/assert_no_bundled_alchemy_key.sh\" \"$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME\"\n";' "$project_file"

if grep -F "Bundle Alchemy API Key" "$project_file" >/dev/null ||
    grep -F "bundle_alchemy_api_key.sh" "$project_file" >/dev/null
then
    fail "the project still references the key-bundling phase"
fi

assert_target_phase_order \
    2C09CB9E273979C1009AD39B \
    2C09CB9D273979C1009AD39B \
    516B2583C21E4F89B3F786DA \
    "Safari macOS"
assert_target_phase_order \
    2C17BDC92D3D007E0015C58B \
    2C17BDC82D3D007E0015C58B \
    AB014F43D7D74AA2A57639E3 \
    "Big Wallet visionOS"
assert_target_phase_order \
    2C19953B2674C4B900A8E370 \
    2C19953A2674C4B900A8E370 \
    E912C196422D43E2A14A6C26 \
    "Big Wallet macOS"
assert_target_phase_order \
    2C5FF96E26C84F7B00B32ACC \
    2C5FF96D26C84F7B00B32ACC \
    4EC946B2766C4F89AE45F6A5 \
    "Big Wallet iOS"
assert_target_phase_order \
    2C60546E2D529A9A00779570 \
    2C60546D2D529A9A00779570 \
    A0FB2A7A814343849A35549C \
    "Safari visionOS"
assert_target_phase_order \
    2CB9B54E2FA23F0600F094FB \
    2CB9B54D2FA23F0600F094FB \
    D8E7DDB615794095B0AE5890 \
    "Big Wallet Ambient"
assert_target_phase_order \
    2CCEB82C27594E2A00768473 \
    2CCEB82B27594E2A00768473 \
    0F74DBBAAD154CE0816A24C8 \
    "Safari iOS"

awk '
    index($0, "returned_archive_path=\"$(jq -r") {
        archive_line = NR
    }
    index($0, "returned_archive_path\" == \"\$archive_path") {
        archive_binding_line = NR
    }
    archive_line > 0 &&
        scanner_line == 0 &&
        index($0, "Scripts/assert_no_bundled_alchemy_key.sh") {
        scanner_line = NR
    }
    $0 ~ /^case "\$platform" in/ {
        export_line = NR
    }
    END {
        if (archive_line == 0 ||
            archive_binding_line <= archive_line ||
            scanner_line <= archive_line ||
            scanner_line <= archive_binding_line ||
            export_line <= scanner_line) {
            exit 1
        }
    }
' "$publish_script" ||
    fail "archive scanning is not wired before export"

awk '
    index($0, "artifact_dir=\"$(mktemp -d") {
        unique_directory_line = NR
    }
    index($0, "upload_flag=(--ipa \"$artifact_path\"") {
        ipa_upload_line = NR
    }
    index($0, "upload_flag=(--pkg \"$artifact_path\"") {
        pkg_upload_line = NR
    }
    index($0, "Scripts/assert_no_bundled_alchemy_key.sh") {
        final_scanner_line = NR
    }
    index($0, "upload_json=\"$(asc builds upload") {
        upload_line = NR
    }
    END {
        if (unique_directory_line == 0 ||
            ipa_upload_line == 0 ||
            pkg_upload_line == 0 ||
            final_scanner_line <= ipa_upload_line ||
            final_scanner_line <= pkg_upload_line ||
            upload_line <= final_scanner_line) {
            exit 1
        }
    }
' "$publish_script" ||
    fail "the exact exported artifact is not isolated and scanned before upload"

# Run the mocked publishing scenarios from a minimal temporary repository.
# Its synthetic key and adjacent fingerprint exercise the same fixed lookup
# without exposing the production key to tests or modifying the tracked
# production fingerprint.
publish_fixture_root="$test_root/publish fixture repository"
mkdir -p \
    "$publish_fixture_root/.asc" \
    "$publish_fixture_root/Scripts/asc" \
    "$publish_fixture_root/Workers/alchemy-jwt" \
    "$publish_fixture_root/Wallet.xcodeproj" \
    "$publish_fixture_root/App iOS" \
    "$publish_fixture_root/App macOS" \
    "$publish_fixture_root/Big Wallet Ambient" \
    "$publish_fixture_root/Safari iOS/Resources" \
    "$publish_fixture_root/Safari macOS/Resources" \
    "$publish_fixture_root/app-store-connect"
for fixture_script in \
    Scripts/asc/publish.sh \
    Scripts/asc/common.sh \
    Scripts/inpage_provider_toolchain.sh \
    Scripts/validate_alchemy_jwt_request_proof_key_file.sh \
    Scripts/alchemy_jwt_request_proof_key_common.sh \
    Scripts/assert_no_bundled_alchemy_key.sh \
    Scripts/assert_bundled_alchemy_jwt_request_proof_key.sh
do
    cp -p \
        "$repository_directory/$fixture_script" \
        "$publish_fixture_root/$fixture_script"
done
cp \
    "$repository_directory/Wallet.xcodeproj/project.pbxproj" \
    "$publish_fixture_root/Wallet.xcodeproj/project.pbxproj"
cp \
    "$repository_directory/App iOS/Info.plist" \
    "$publish_fixture_root/App iOS/Info.plist"
cp \
    "$repository_directory/App macOS/Info.plist" \
    "$publish_fixture_root/App macOS/Info.plist"
cp \
    "$repository_directory/Big Wallet Ambient/Info.plist" \
    "$publish_fixture_root/Big Wallet Ambient/Info.plist"
cp \
    "$repository_directory/Safari iOS/Resources/manifest.json" \
    "$publish_fixture_root/Safari iOS/Resources/manifest.json"
cp \
    "$repository_directory/Safari macOS/Resources/manifest.json" \
    "$publish_fixture_root/Safari macOS/Resources/manifest.json"
cp \
    "$repository_directory/app-store-connect/export-options-app-store.plist" \
    "$publish_fixture_root/app-store-connect/export-options-app-store.plist"
jq \
    --arg version "db7cd8d3-4425-4fe7-8c81-01bf963b6067" \
    '.env.ALCHEMY_JWT_EXPECTED_WORKER_VERSION = $version' \
    "$repository_directory/.asc/workflow.json" \
    > "$publish_fixture_root/.asc/workflow.json"
printf '%s\n' "24.18.0" \
    > "$publish_fixture_root/Workers/alchemy-jwt/.nvmrc"
printf '%s\n' \
    '{"private":true,"packageManager":"npm@11.16.0","scripts":{"verify:release":"node scripts/verify-release.mjs"}}' \
    > "$publish_fixture_root/Workers/alchemy-jwt/package.json"
request_proof_fingerprint=$(
    printf '%s' "$request_proof_key_value" | /usr/bin/shasum -a 256
)
request_proof_fingerprint=${request_proof_fingerprint%% *}
printf '%s\n' "$request_proof_fingerprint" \
    > "$publish_fixture_root/Scripts/alchemy_jwt_request_proof_key.sha256"
publish_script="$publish_fixture_root/Scripts/asc/publish.sh"

mock_home="$test_root/mock-home"
mock_bin="$mock_home/.local/bin"
mock_asc="$mock_bin/asc"
mock_asc_log="$logs_directory/publish-existing-build.asc"
actual_node=$(command -v node)
mkdir -p "$mock_bin"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = "--version" ]; then' \
    '    printf "%s\n" v24.18.0' \
    '    exit 0' \
    'fi' \
    "exec \"$actual_node\" \"\$@\"" \
    > "$mock_bin/node"
printf '%s\n' \
    '#!/bin/sh' \
    'if [ "${1:-}" = "--version" ]; then' \
    '    printf "%s\n" 11.16.0' \
    '    exit 0' \
    'fi' \
    'if [ "${1:-}" = run ] && [ "${2:-}" = verify:release ]; then' \
    '    printf "%s\n" "worker verify $*" >> "$MOCK_ASC_LOG"' \
    '    if [ -n "${MOCK_WORKER_VERIFY_MUTATION_ROOT:-}" ]; then' \
    '        mutated_ipa=$(/usr/bin/find "$MOCK_WORKER_VERIFY_MUTATION_ROOT" -type f -name '"'"'*.ipa'"'"' -print -quit)' \
    '        [ -n "$mutated_ipa" ] || exit 74' \
    '        /bin/dd if=/dev/zero of="$mutated_ipa" bs=1 count=1 conv=notrunc >/dev/null 2>&1' \
    '    fi' \
    '    if [ "${MOCK_WORKER_VERIFY_OUTCOME:-success}" = failure ]; then' \
    '        exit 73' \
    '    fi' \
    '    printf "%s\n" "release-verification: pass"' \
    '    exit 0' \
    'fi' \
    'exit 64' \
    > "$mock_bin/npm"
chmod 700 "$mock_bin/node" "$mock_bin/npm"

cloudflare_token_directory="$test_root/cloudflare token directory"
cloudflare_token_file="$cloudflare_token_directory/token"
mkdir "$cloudflare_token_directory"
chmod 700 "$cloudflare_token_directory"
printf '%040d' 0 > "$cloudflare_token_file"
chmod 600 "$cloudflare_token_file"
unset CLOUDFLARE_API_TOKEN
export CLOUDFLARE_API_TOKEN_FILE="$cloudflare_token_file"

printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s" "${1:-}" >> "$MOCK_ASC_LOG"' \
    'shift || true' \
    'for argument do printf " %s" "$argument" >> "$MOCK_ASC_LOG"; done' \
    'printf "\n" >> "$MOCK_ASC_LOG"' \
    'if [ "${1:-}" = "info" ]; then' \
    '    printf "%s\n" '"'"'{"id":"existing-build-id","processingState":"VALID"}'"'" \
    '    exit 0' \
    'fi' \
    'exit 64' \
    > "$mock_asc"
chmod 700 "$mock_asc"

publish_stdout="$logs_directory/publish-existing-build.stdout"
publish_stderr="$logs_directory/publish-existing-build.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$mock_asc_log" \
    ASC_ARTIFACTS_DIR="$test_root/publish artifacts" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS > "$publish_stdout" 2> "$publish_stderr"
publish_status=$?
set -e

[ "$publish_status" -ne 0 ] ||
    fail "publish reused an existing unverified build"
assert_empty_file \
    "$publish_stdout" \
    "existing-build rejection wrote a publish result"
grep -F \
    "refusing to reuse existing IOS build" \
    "$publish_stderr" >/dev/null ||
    fail "existing-build rejection was not actionable"
grep -F "builds info " "$mock_asc_log" >/dev/null ||
    fail "existing-build regression did not exercise the build lookup"
if grep -F "xcode archive" "$mock_asc_log" >/dev/null ||
    grep -F "builds upload" "$mock_asc_log" >/dev/null
then
    fail "existing-build rejection performed release work"
fi

if [ -e "$test_root/publish artifacts" ]; then
    if find "$test_root/publish artifacts" \
        -type d \
        -name 'release.*' \
        -print -quit | grep . >/dev/null
    then
        fail "existing-build rejection allocated a release directory"
    fi
fi

printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    'argument_value() {' \
    '    wanted=$1' \
    '    shift' \
    '    while [ "$#" -gt 0 ]; do' \
    '        if [ "$1" = "$wanted" ]; then' \
    '            shift' \
    '            printf "%s\n" "$1"' \
    '            return 0' \
    '        fi' \
    '        shift' \
    '    done' \
    '    return 1' \
    '}' \
    'separator=""' \
    'for argument do' \
    '    printf "%s%s" "$separator" "$argument" >> "$MOCK_ASC_LOG"' \
    '    separator=" "' \
    'done' \
    'printf "\n" >> "$MOCK_ASC_LOG"' \
    'command_name=${1:-}' \
    'subcommand=${2:-}' \
    'case "$command_name:$subcommand" in' \
    '    builds:info)' \
    '        exit 1' \
    '        ;;' \
    '    xcode:archive)' \
    '        archive_path=$(argument_value --archive-path "$@")' \
    '        app="$archive_path/Products/Applications/Big Wallet.app"' \
    '        extension="$app/PlugIns/Safari iOS.appex"' \
    '        mkdir -p "$extension"' \
    '        printf "%s" archive > "$app/Info.plist"' \
    '        cp "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE" "$app/AlchemyJWTRequestProofKey"' \
    '        cp "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE" "$extension/AlchemyJWTRequestProofKey"' \
    '        chmod 0644 "$app/AlchemyJWTRequestProofKey" "$extension/AlchemyJWTRequestProofKey"' \
    '        returned_archive_path=${MOCK_ARCHIVE_RETURN_PATH:-$archive_path}' \
    '        printf "{\"archive_path\":\"%s\"}\n" "$returned_archive_path"' \
    '        ;;' \
    '    xcode:export)' \
    '        if [ "${MOCK_PUBLISH_OUTCOME:-failure}" = pre-upload-failure ]; then' \
    '            exit 71' \
    '        fi' \
    '        ipa_path=$(argument_value --ipa-path "$@")' \
    '        ipa_source="$ipa_path.source"' \
    '        app="$ipa_source/Payload/Big Wallet.app"' \
    '        extension="$app/PlugIns/Safari iOS.appex"' \
    '        mkdir -p "$extension"' \
    '        printf "%s" export > "$app/Info.plist"' \
    '        cp "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE" "$app/AlchemyJWTRequestProofKey"' \
    '        cp "$ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE" "$extension/AlchemyJWTRequestProofKey"' \
    '        chmod 0644 "$app/AlchemyJWTRequestProofKey" "$extension/AlchemyJWTRequestProofKey"' \
    '        /usr/bin/ditto -c -k "$ipa_source" "$ipa_path"' \
    '        rm -rf "$ipa_source"' \
    '        returned_ipa_path=${MOCK_IPA_RETURN_PATH:-$ipa_path}' \
    '        printf "{\"ipa_path\":\"%s\"}\n" "$returned_ipa_path"' \
    '        ;;' \
    '    builds:upload)' \
    '        case "${MOCK_PUBLISH_OUTCOME:-failure}" in' \
    '            success)' \
    '                printf "%s\n" '"'"'{"id":"mock-build-id"}'"'" \
    '                ;;' \
    '            accepted-without-id)' \
    '                printf "%s\n" '"'"'{}'"'" \
    '                ;;' \
    '            ambiguous-upload)' \
    '                printf "%s\n" REMOTE_ACCEPTED >> "$MOCK_ASC_LOG"' \
    '                exit 72' \
    '                ;;' \
    '            *)' \
    '                exit 72' \
    '                ;;' \
    '        esac' \
    '        ;;' \
    '    *)' \
    '        exit 64' \
    '        ;;' \
    'esac' \
    > "$mock_asc"
chmod 700 "$mock_asc"

unrequested_archive="$test_root/unrequested archive.xcarchive"
unrequested_archive_app="$unrequested_archive/Products/Applications/Big Wallet.app"
unrequested_archive_extension="$unrequested_archive_app/PlugIns/Safari iOS.appex"
mkdir -p "$unrequested_archive_extension"
cp "$request_proof_key_file" \
    "$unrequested_archive_app/AlchemyJWTRequestProofKey"
cp "$request_proof_key_file" \
    "$unrequested_archive_extension/AlchemyJWTRequestProofKey"
chmod 0644 \
    "$unrequested_archive_app/AlchemyJWTRequestProofKey" \
    "$unrequested_archive_extension/AlchemyJWTRequestProofKey"

archive_mismatch_root="$test_root/archive path mismatch artifacts"
archive_mismatch_log="$logs_directory/publish-archive-path-mismatch.asc"
archive_mismatch_stdout="$logs_directory/publish-archive-path-mismatch.stdout"
archive_mismatch_stderr="$logs_directory/publish-archive-path-mismatch.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$archive_mismatch_log" \
    MOCK_ARCHIVE_RETURN_PATH="$unrequested_archive" \
    MOCK_PUBLISH_OUTCOME=success \
    ASC_ARTIFACTS_DIR="$archive_mismatch_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$archive_mismatch_stdout" \
    2> "$archive_mismatch_stderr"
archive_mismatch_status=$?
set -e

[ "$archive_mismatch_status" -ne 0 ] ||
    fail "publish trusted an archive path other than the requested path"
assert_empty_file \
    "$archive_mismatch_stdout" \
    "archive path mismatch wrote a publish result"
grep -F \
    "archive returned a path other than the requested isolated archive" \
    "$archive_mismatch_stderr" >/dev/null ||
    fail "archive path mismatch was not rejected explicitly"
if grep -F "xcode export " "$archive_mismatch_log" >/dev/null ||
    grep -F "builds upload " "$archive_mismatch_log" >/dev/null
then
    fail "archive path mismatch continued release work"
fi
if find "$archive_mismatch_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit | grep . >/dev/null
then
    fail "archive path mismatch retained its per-run release directory"
fi

unrequested_ipa_source="$test_root/unrequested IPA source"
unrequested_ipa="$test_root/unrequested release.ipa"
unrequested_ipa_app="$unrequested_ipa_source/Payload/Big Wallet.app"
unrequested_ipa_extension="$unrequested_ipa_app/PlugIns/Safari iOS.appex"
mkdir -p "$unrequested_ipa_extension"
cp "$request_proof_key_file" \
    "$unrequested_ipa_app/AlchemyJWTRequestProofKey"
cp "$request_proof_key_file" \
    "$unrequested_ipa_extension/AlchemyJWTRequestProofKey"
chmod 0644 \
    "$unrequested_ipa_app/AlchemyJWTRequestProofKey" \
    "$unrequested_ipa_extension/AlchemyJWTRequestProofKey"
/usr/bin/ditto -c -k "$unrequested_ipa_source" "$unrequested_ipa"

ipa_mismatch_root="$test_root/IPA path mismatch artifacts"
ipa_mismatch_log="$logs_directory/publish-IPA-path-mismatch.asc"
ipa_mismatch_stdout="$logs_directory/publish-IPA-path-mismatch.stdout"
ipa_mismatch_stderr="$logs_directory/publish-IPA-path-mismatch.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$ipa_mismatch_log" \
    MOCK_IPA_RETURN_PATH="$unrequested_ipa" \
    MOCK_PUBLISH_OUTCOME=success \
    ASC_ARTIFACTS_DIR="$ipa_mismatch_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$ipa_mismatch_stdout" \
    2> "$ipa_mismatch_stderr"
ipa_mismatch_status=$?
set -e

[ "$ipa_mismatch_status" -ne 0 ] ||
    fail "publish trusted an IPA path other than the requested path"
assert_empty_file \
    "$ipa_mismatch_stdout" \
    "IPA path mismatch wrote a publish result"
grep -F \
    "export returned a path other than the requested isolated IPA" \
    "$ipa_mismatch_stderr" >/dev/null ||
    fail "IPA path mismatch was not rejected explicitly"
if grep -F "builds upload " "$ipa_mismatch_log" >/dev/null; then
    fail "IPA path mismatch attempted an upload"
fi
if find "$ipa_mismatch_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit | grep . >/dev/null
then
    fail "IPA path mismatch retained its per-run release directory"
fi

worker_guard_root="$test_root/worker guard failure artifacts"
worker_guard_log="$logs_directory/publish-worker-guard-failure.asc"
worker_guard_stdout="$logs_directory/publish-worker-guard-failure.stdout"
worker_guard_stderr="$logs_directory/publish-worker-guard-failure.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$worker_guard_log" \
    MOCK_PUBLISH_OUTCOME=success \
    MOCK_WORKER_VERIFY_OUTCOME=failure \
    ASC_ARTIFACTS_DIR="$worker_guard_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$worker_guard_stdout" \
    2> "$worker_guard_stderr"
worker_guard_status=$?
set -e

[ "$worker_guard_status" -ne 0 ] ||
    fail "publish ignored a failed Worker release verification"
assert_empty_file \
    "$worker_guard_stdout" \
    "Worker release verification failure wrote a publish result"
grep -F "worker verify run verify:release" "$worker_guard_log" >/dev/null ||
    fail "Worker release verification failure did not exercise the narrow verifier"
if grep -F "builds upload " "$worker_guard_log" >/dev/null; then
    fail "publish uploaded after Worker release verification failed"
fi
if find "$worker_guard_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit | grep . >/dev/null
then
    fail "Worker verification failure retained its pre-upload release directory"
fi

artifact_mutation_root="$test_root/artifact mutation artifacts"
artifact_mutation_log="$logs_directory/publish-artifact-mutation.asc"
artifact_mutation_stdout="$logs_directory/publish-artifact-mutation.stdout"
artifact_mutation_stderr="$logs_directory/publish-artifact-mutation.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$artifact_mutation_log" \
    MOCK_PUBLISH_OUTCOME=success \
    MOCK_WORKER_VERIFY_MUTATION_ROOT="$artifact_mutation_root" \
    ASC_ARTIFACTS_DIR="$artifact_mutation_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$artifact_mutation_stdout" \
    2> "$artifact_mutation_stderr"
artifact_mutation_status=$?
set -e

[ "$artifact_mutation_status" -ne 0 ] ||
    fail "publish accepted an artifact changed during Worker verification"
assert_empty_file \
    "$artifact_mutation_stdout" \
    "artifact mutation failure wrote a publish result"
grep -F "worker verify run verify:release" "$artifact_mutation_log" >/dev/null ||
    fail "artifact mutation regression did not exercise Worker verification"
if grep -F "builds upload " "$artifact_mutation_log" >/dev/null; then
    fail "publish uploaded an artifact changed during Worker verification"
fi
if find "$artifact_mutation_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit | grep . >/dev/null
then
    fail "artifact mutation failure retained its pre-upload release directory"
fi

failed_publish_root="$test_root/pre-upload failure artifacts"
failed_publish_log="$logs_directory/publish-pre-upload-failure.asc"
failed_publish_stdout="$logs_directory/publish-pre-upload-failure.stdout"
failed_publish_stderr="$logs_directory/publish-pre-upload-failure.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$failed_publish_log" \
    MOCK_PUBLISH_OUTCOME=pre-upload-failure \
    ASC_ARTIFACTS_DIR="$failed_publish_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$failed_publish_stdout" \
    2> "$failed_publish_stderr"
failed_publish_status=$?
set -e

[ "$failed_publish_status" -ne 0 ] ||
    fail "mock pre-upload failure unexpectedly succeeded"
assert_empty_file \
    "$failed_publish_stdout" \
    "pre-upload failure wrote a publish result"
grep -F "xcode export " "$failed_publish_log" >/dev/null ||
    fail "mock pre-upload failure did not reach export"
if grep -F "builds upload " "$failed_publish_log" >/dev/null; then
    fail "mock pre-upload failure attempted an upload"
fi
if find "$failed_publish_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit | grep . >/dev/null
then
    fail "pre-upload failure retained its per-run release directory"
fi

ambiguous_publish_root="$test_root/ambiguous publish artifacts"
ambiguous_publish_log="$logs_directory/publish-ambiguous.asc"
ambiguous_publish_stdout="$logs_directory/publish-ambiguous.stdout"
ambiguous_publish_stderr="$logs_directory/publish-ambiguous.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$ambiguous_publish_log" \
    MOCK_PUBLISH_OUTCOME=ambiguous-upload \
    ASC_ARTIFACTS_DIR="$ambiguous_publish_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$ambiguous_publish_stdout" \
    2> "$ambiguous_publish_stderr"
ambiguous_publish_status=$?
set -e

[ "$ambiguous_publish_status" -ne 0 ] ||
    fail "ambiguous upload failure unexpectedly succeeded"
assert_empty_file \
    "$ambiguous_publish_stdout" \
    "ambiguous upload failure wrote a publish result"
grep -F "REMOTE_ACCEPTED" "$ambiguous_publish_log" >/dev/null ||
    fail "ambiguous upload mock did not record remote acceptance"
ambiguous_release_directory=$(find "$ambiguous_publish_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit)
[ -n "$ambiguous_release_directory" ] ||
    fail "ambiguous upload lost its release directory"
[ -f "$ambiguous_release_directory/Big-Wallet-iOS.ipa" ] ||
    fail "ambiguous upload lost its exported artifact"
[ -d "$ambiguous_release_directory/Big-Wallet-iOS.xcarchive" ] ||
    fail "ambiguous upload lost its symbolication archive"

accepted_publish_root="$test_root/accepted publish artifacts"
accepted_publish_log="$logs_directory/publish-accepted.asc"
accepted_publish_stdout="$logs_directory/publish-accepted.stdout"
accepted_publish_stderr="$logs_directory/publish-accepted.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$accepted_publish_log" \
    MOCK_PUBLISH_OUTCOME=accepted-without-id \
    ASC_BUILD_LOOKUP_ATTEMPTS=1 \
    ASC_ARTIFACTS_DIR="$accepted_publish_root" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$accepted_publish_stdout" \
    2> "$accepted_publish_stderr"
accepted_publish_status=$?
set -e

[ "$accepted_publish_status" -ne 0 ] ||
    fail "unresolved accepted upload unexpectedly succeeded"
assert_empty_file \
    "$accepted_publish_stdout" \
    "unresolved accepted upload wrote a publish result"
accepted_release_directory=$(find "$accepted_publish_root/ios" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'release.*' \
    -print -quit)
[ -n "$accepted_release_directory" ] ||
    fail "accepted upload lost its release directory after build lookup failure"
[ -f "$accepted_release_directory/Big-Wallet-iOS.ipa" ] ||
    fail "accepted upload lost its exported artifact"
[ -d "$accepted_release_directory/Big-Wallet-iOS.xcarchive" ] ||
    fail "accepted upload lost its symbolication archive"

successful_publish_root="$test_root/successful publish artifacts"
successful_publish_reports="$test_root/successful publish reports"
successful_publish_log="$logs_directory/publish-success.asc"
successful_publish_stdout="$logs_directory/publish-success.stdout"
successful_publish_stderr="$logs_directory/publish-success.stderr"
set +e
HOME="$mock_home" \
    PATH="$mock_bin:$PATH" \
    MOCK_ASC_LOG="$successful_publish_log" \
    MOCK_PUBLISH_OUTCOME=success \
    ASC_ARTIFACTS_DIR="$successful_publish_root" \
    ASC_REPORTS_DIR="$successful_publish_reports" \
    ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE="$request_proof_key_file" \
    "$publish_script" IOS \
    > "$successful_publish_stdout" \
    2> "$successful_publish_stderr"
successful_publish_status=$?
set -e

[ "$successful_publish_status" -eq 0 ] ||
    fail "mock publication unexpectedly failed"
artifact_path=$(jq -r '.artifactPath // empty' "$successful_publish_stdout")
[ -f "$artifact_path" ] ||
    fail "successful publication did not preserve its emitted artifact"
successful_publish_root=$(CDPATH= cd -- "$successful_publish_root" && pwd -P)
case "$artifact_path" in
    "$successful_publish_root"/ios/release.*/*.ipa)
        ;;
    *)
        fail "successful publication emitted an unexpected artifact path"
        ;;
esac
successful_release_directory=$(dirname "$artifact_path")
[ -d "$successful_release_directory/Big-Wallet-iOS.xcarchive" ] ||
    fail "successful publication did not retain its symbolication archive"
[ "$(find "$successful_release_directory" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 2 ] ||
    fail "successful publication retained unexpected files"
grep -F "builds upload " "$successful_publish_log" >/dev/null ||
    fail "mock successful publication did not reach upload"
grep -F \
    "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE=$request_proof_key_file" \
    "$successful_publish_log" >/dev/null ||
    fail "publish did not preserve the request-proof key path as one build setting"

successful_publish_receipt="$successful_publish_reports/validated-builds/IOS.json"
[ -f "$successful_publish_receipt" ] ||
    fail "successful publication did not write its validation receipt"
[ "$(/usr/bin/stat -f '%Lp' -- "$successful_publish_receipt")" = "600" ] ||
    fail "successful publication wrote an unsafe validation receipt"
artifact_sha256=$(/usr/bin/shasum -a 256 -- "$artifact_path")
artifact_sha256=${artifact_sha256%% *}
published_build_id=$(jq -r '.buildId // empty' "$successful_publish_stdout")
published_version=$(jq -r '.version // empty' "$successful_publish_stdout")
published_build_number=$(jq -r '.buildNumber // empty' "$successful_publish_stdout")
published_platform=$(jq -r '.platform // empty' "$successful_publish_stdout")
jq -e \
    --arg build_id "$published_build_id" \
    --arg version "$published_version" \
    --arg build_number "$published_build_number" \
    --arg platform "$published_platform" \
    --arg artifact_path "$artifact_path" \
    --arg artifact_sha256 "$artifact_sha256" \
    --arg proof_fingerprint "$request_proof_fingerprint" \
    '
    .schemaVersion == 1 and
    .buildId == $build_id and
    .version == $version and
    .buildNumber == $build_number and
    .platform == $platform and
    .artifactPath == $artifact_path and
    .artifactSHA256 == $artifact_sha256 and
    .proofKeyFingerprint == $proof_fingerprint
    ' "$successful_publish_receipt" >/dev/null ||
    fail "successful publication wrote a mismatched validation receipt"

if grep -F "$request_proof_key_value" \
    "$logs_directory"/*.stdout "$logs_directory"/*.stderr \
    >/dev/null 2>&1
then
    fail "the request-proof key leaked into publish output"
fi

printf '%s\n' "Alchemy key artifact cleanup regression tests: PASS"
