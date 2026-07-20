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

if [ "$#" -ne 2 ]; then
    fail "a platform and one archive or exported package are required"
fi

platform=$1
artifact=$2
case "$platform" in
    IOS|MAC_OS|VISION_OS)
        ;;
    *)
        fail "the release platform must be IOS, MAC_OS, or VISION_OS"
        ;;
esac

key_file=${ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE:-}
[ -n "$key_file" ] ||
    fail "ALCHEMY_JWT_REQUEST_PROOF_KEY_FILE is required"

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
. "$script_directory/alchemy_jwt_request_proof_key_common.sh"
load_alchemy_jwt_request_proof_key \
    "$key_file" \
    "$script_directory/alchemy_jwt_request_proof_key.sha256"

if [ -L "$artifact" ]; then
    fail "the release artifact must not be a symbolic link"
fi

umask 077
temporary_root=$(
    /usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/alchemy-jwt-release-scan.XXXXXX"
) || fail "a temporary artifact directory could not be created"
/bin/chmod 0700 "$temporary_root"

scan_root=""
artifact_kind=""
if [ -d "$artifact" ]; then
    scan_root=$(CDPATH= cd -- "$artifact" 2>/dev/null && /bin/pwd -P) ||
        fail "the release artifact directory could not be inspected"
    artifact_without_trailing_slash=${artifact%/}
    [ "$artifact_without_trailing_slash" = "$scan_root" ] ||
        fail "the release artifact directory path must be canonical and must not traverse symbolic links"
    artifact_kind=archive
elif [ -f "$artifact" ]; then
    case "$artifact" in
        /*)
            ;;
        *)
            fail "the release artifact path must be absolute"
            ;;
    esac

    artifact_name=${artifact##*/}
    artifact_parent=${artifact%/*}
    if [ -z "$artifact_parent" ]; then
        artifact_parent=/
    fi
    canonical_artifact_parent=$(
        CDPATH= cd -- "$artifact_parent" 2>/dev/null && /bin/pwd -P
    ) || fail "the release artifact parent directory could not be inspected"
    [ "$artifact" = "${canonical_artifact_parent%/}/$artifact_name" ] ||
        fail "the release artifact path must be canonical and must not traverse symbolic links"

    expanded_root="$temporary_root/expanded"
    case "$artifact" in
        *.ipa)
            case "$platform" in
                IOS|VISION_OS)
                    ;;
                *)
                    fail "IPA artifacts are valid only for iOS or visionOS"
                    ;;
            esac
            /bin/mkdir "$expanded_root"
            if ! /usr/bin/ditto -x -k "$artifact" "$expanded_root"; then
                fail "the IPA could not be expanded for validation"
            fi
            artifact_kind=ipa
            ;;
        *.pkg)
            [ "$platform" = "MAC_OS" ] ||
                fail "pkg artifacts are valid only for macOS"
            if ! /usr/sbin/pkgutil \
                --expand-full "$artifact" "$expanded_root" >/dev/null
            then
                fail "the package could not be expanded for validation"
            fi
            artifact_kind=package
            ;;
        *)
            fail "exported packages must have an .ipa or .pkg extension"
            ;;
    esac
    scan_root=$expanded_root
else
    fail "the release artifact must be an existing directory, IPA, or pkg"
fi

actual_path_list="$temporary_root/actual-proof-paths"
expected_path_list="$temporary_root/expected-proof-paths"
sorted_actual_path_list="$temporary_root/actual-proof-paths.sorted"
sorted_expected_path_list="$temporary_root/expected-proof-paths.sorted"

real_directory_tree_exists() {
    tree_root=$1
    relative_path=$2
    current_path=$tree_root

    while [ -n "$relative_path" ]; do
        case "$relative_path" in
            */*)
                component=${relative_path%%/*}
                relative_path=${relative_path#*/}
                ;;
            *)
                component=$relative_path
                relative_path=
                ;;
        esac

        if [ -z "$component" ] || [ "$component" = "." ] ||
            [ "$component" = ".." ]
        then
            return 1
        fi

        current_path="$current_path/$component"
        if [ -L "$current_path" ] || [ ! -d "$current_path" ]; then
            return 1
        fi
    done

    return 0
}

case "$artifact_kind" in
    archive)
        main_bundle_relative='Products/Applications/Big Wallet.app'
        ;;
    ipa)
        main_bundle_relative='Payload/Big Wallet.app'
        ;;
    package)
        distribution_path="$scan_root/Distribution"
        if [ -L "$distribution_path" ] || [ ! -f "$distribution_path" ]; then
            fail "the macOS product archive is missing its Distribution file"
        fi

        package_component_list="$temporary_root/package-components"
        if ! LC_ALL=C /usr/bin/find -P "$scan_root" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -name '*.pkg' \
            -print > "$package_component_list"
        then
            fail "the macOS product archive components could not be scanned"
        fi
        package_component_count=$(
            /usr/bin/wc -l < "$package_component_list" |
                /usr/bin/tr -d '[:space:]'
        ) || fail "the macOS product archive components could not be counted"
        [ "$package_component_count" = "1" ] ||
            fail "the macOS product archive must contain exactly one component package"
        IFS= read -r package_component_path < "$package_component_list" ||
            fail "the macOS product archive component could not be read"
        [ "${package_component_path%/*}" = "$scan_root" ] ||
            fail "the macOS product archive component path is invalid"
        package_component_name=${package_component_path##*/}
        case "$package_component_name" in
            ''|*[!A-Za-z0-9._-]*|.*|*.pkg.pkg)
                fail "the macOS product archive component name is invalid"
                ;;
            *.pkg)
                ;;
            *)
                fail "the macOS product archive component name is invalid"
                ;;
        esac
        main_bundle_relative="$package_component_name/Payload/Big Wallet.app"
        ;;
    *)
        fail "the release artifact kind could not be established"
        ;;
esac

real_directory_tree_exists "$scan_root" "$main_bundle_relative" ||
    fail "the release artifact is missing the expected Big Wallet app"
main_bundle="$scan_root/$main_bundle_relative"

case "$platform" in
    IOS)
        printf '%s\n' \
            "$main_bundle/AlchemyJWTRequestProofKey" \
            "$main_bundle/PlugIns/Safari iOS.appex/AlchemyJWTRequestProofKey" \
            > "$expected_path_list"
        ;;
    VISION_OS)
        printf '%s\n' \
            "$main_bundle/AlchemyJWTRequestProofKey" \
            "$main_bundle/PlugIns/Safari visionOS.appex/AlchemyJWTRequestProofKey" \
            > "$expected_path_list"
        ;;
    MAC_OS)
        printf '%s\n' \
            "$main_bundle/Contents/Resources/AlchemyJWTRequestProofKey" \
            "$main_bundle/Contents/PlugIns/Safari macOS.appex/Contents/Resources/AlchemyJWTRequestProofKey" \
            "$main_bundle/Contents/Helpers/Big Wallet.app/Contents/Resources/AlchemyJWTRequestProofKey" \
            > "$expected_path_list"
        ;;
esac

# The find status is checked before any counting or comparison, so an
# unreadable subtree cannot be hidden by a successful wc/tr pipeline. Matching
# temporary names in this same set makes the exact comparison reject them too.
if ! LC_ALL=C /usr/bin/find -P "$scan_root" \
    \( \
        -name 'AlchemyJWTRequestProofKey' -o \
        -name '.AlchemyJWTRequestProofKey.*' -o \
        -name 'AlchemyJWTRequestProofKey.tmp.*' \
    \) \
    -print > "$actual_path_list"
then
    fail "the release artifact request-proof resources could not be scanned"
fi

LC_ALL=C /usr/bin/sort "$actual_path_list" > "$sorted_actual_path_list" ||
    fail "the release artifact request-proof paths could not be sorted"
LC_ALL=C /usr/bin/sort "$expected_path_list" > "$sorted_expected_path_list" ||
    fail "the expected request-proof paths could not be sorted"
if ! /usr/bin/cmp -s "$sorted_expected_path_list" "$sorted_actual_path_list"; then
    fail "the release artifact request-proof resource paths do not exactly match the production bundles"
fi

verify_resource() {
    resource=$1
    description=$2
    unset resource_with_sentinel bundled_key
    relative_resource=${resource#"$main_bundle"/}
    resource_parent_relative=${relative_resource%/*}

    if [ "$resource_parent_relative" != "$relative_resource" ] &&
        ! real_directory_tree_exists "$main_bundle" "$resource_parent_relative"
    then
        fail "$description request-proof resource path traverses a symbolic link or invalid directory"
    fi
    if [ -L "$resource" ] || [ ! -f "$resource" ]; then
        fail "$description is missing its request-proof resource"
    fi

    resource_metadata_before=$(
        /usr/bin/stat -f '%d:%i:%Lp:%z' -- "$resource"
    ) || fail "$description request-proof resource could not be inspected"
    resource_size=${resource_metadata_before##*:}
    resource_metadata_without_size=${resource_metadata_before%:*}
    resource_mode=${resource_metadata_without_size##*:}
    [ "$resource_mode" = "644" ] ||
        fail "$description request-proof resource has unsafe permissions"
    [ "$resource_size" -eq 43 ] ||
        fail "$description has a mismatched request-proof resource"

    resource_with_sentinel=$(
        /bin/cat -- "$resource" || exit 1
        printf '.'
    ) || fail "$description request-proof resource could not be read"
    bundled_key=${resource_with_sentinel%?}
    resource_metadata_after=$(
        /usr/bin/stat -f '%d:%i:%Lp:%z' -- "$resource"
    ) || fail "$description request-proof resource could not be re-inspected"
    [ "$resource_metadata_before" = "$resource_metadata_after" ] ||
        fail "$description request-proof resource changed while it was being read"
    [ "${#bundled_key}" -eq 43 ] &&
        [ "$bundled_key" = "$ALCHEMY_JWT_REQUEST_PROOF_KEY_VALUE" ] ||
        fail "$description has a mismatched request-proof resource"
}

case "$platform" in
    IOS)
        verify_resource \
            "$main_bundle/AlchemyJWTRequestProofKey" \
            "the iOS app"
        verify_resource \
            "$main_bundle/PlugIns/Safari iOS.appex/AlchemyJWTRequestProofKey" \
            "the iOS Safari extension"
        ;;
    VISION_OS)
        verify_resource \
            "$main_bundle/AlchemyJWTRequestProofKey" \
            "the visionOS app"
        verify_resource \
            "$main_bundle/PlugIns/Safari visionOS.appex/AlchemyJWTRequestProofKey" \
            "the visionOS Safari extension"
        ;;
    MAC_OS)
        verify_resource \
            "$main_bundle/Contents/Resources/AlchemyJWTRequestProofKey" \
            "the macOS app"
        verify_resource \
            "$main_bundle/Contents/PlugIns/Safari macOS.appex/Contents/Resources/AlchemyJWTRequestProofKey" \
            "the macOS Safari extension"
        verify_resource \
            "$main_bundle/Contents/Helpers/Big Wallet.app/Contents/Resources/AlchemyJWTRequestProofKey" \
            "the Ambient helper"
        ;;
esac
