#!/bin/sh

set +x
set +a
set -eu

unset alchemy_jwt_entrypoint_source \
    alchemy_jwt_entrypoint_directory
alchemy_jwt_entrypoint_source=$0
case "$alchemy_jwt_entrypoint_source" in
    */*) alchemy_jwt_entrypoint_directory=${alchemy_jwt_entrypoint_source%/*} ;;
    *) alchemy_jwt_entrypoint_directory=. ;;
esac
. "$alchemy_jwt_entrypoint_directory/alchemy_jwt_request_proof_key_common.sh"
unset alchemy_jwt_entrypoint_source \
    alchemy_jwt_entrypoint_directory

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

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && /bin/pwd -P)
load_alchemy_jwt_request_proof_key \
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

plist_value() {
    plist=$1
    key=$2
    description=$3
    value=$(/usr/bin/plutil -extract "$key" raw "$plist" 2>/dev/null) ||
        fail "$description is missing $key"
    [ -n "$value" ] || fail "$description has an empty $key"
    printf '%s\n' "$value"
}

signing_team_identifier() {
    bundle=$1
    description=$2
    details=$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1) ||
        fail "$description signing information could not be read"
    team=$(printf '%s\n' "$details" | /usr/bin/awk '
        /^TeamIdentifier=/ {
            count += 1
            value = substr($0, length("TeamIdentifier=") + 1)
        }
        END {
            if (count != 1 || value == "" || value == "not set") {
                exit 1
            }
            print value
        }
    ') || fail "$description has no unambiguous signing team"
    printf '%s\n' "$team"
}

require_entitlement_value() {
    rev_plist=$1
    rev_key=$2
    rev_expected=$3
    rev_description=$4
    rev_actual=$(
        /usr/libexec/PlistBuddy -c "Print :$rev_key" "$rev_plist" 2>/dev/null
    ) || fail "$rev_description is missing the $rev_key entitlement"
    [ "$rev_actual" = "$rev_expected" ] ||
        fail "$rev_description has an unexpected $rev_key entitlement"
}

require_entitlement_array() {
    rea_plist=$1
    rea_key=$2
    rea_description=$3
    shift 3
    rea_index=0
    for rea_expected in "$@"; do
        rea_actual=$(
            /usr/libexec/PlistBuddy \
                -c "Print :$rea_key:$rea_index" \
                "$rea_plist" 2>/dev/null
        ) || fail "$rea_description is missing a required $rea_key entitlement value"
        [ "$rea_actual" = "$rea_expected" ] ||
            fail "$rea_description has an unexpected $rea_key entitlement value"
        rea_index=$((rea_index + 1))
    done
    if /usr/libexec/PlistBuddy \
        -c "Print :$rea_key:$rea_index" \
        "$rea_plist" >/dev/null 2>&1
    then
        fail "$rea_description has extra $rea_key entitlement values"
    fi
}

require_no_entitlement() {
    rne_plist=$1
    rne_key=$2
    rne_description=$3
    if /usr/libexec/PlistBuddy \
        -c "Print :$rne_key" \
        "$rne_plist" >/dev/null 2>&1
    then
        fail "$rne_description must not have the $rne_key entitlement"
    fi
}

validate_macos_bundle_entitlements() {
    vmbe_bundle=$1
    vmbe_description=$2
    vmbe_identifier=$3
    vmbe_team=$4
    vmbe_output=$5

    if ! /usr/bin/codesign \
        -d --entitlements :- "$vmbe_bundle" \
        > "$vmbe_output" 2>/dev/null
    then
        fail "$vmbe_description signed entitlements could not be read"
    fi
    [ -s "$vmbe_output" ] &&
        /usr/bin/plutil -lint "$vmbe_output" >/dev/null 2>&1 ||
        fail "$vmbe_description has invalid signed entitlements"

    require_entitlement_value \
        "$vmbe_output" \
        com.apple.application-identifier \
        "$vmbe_team.$vmbe_identifier" \
        "$vmbe_description"
    require_entitlement_value \
        "$vmbe_output" \
        com.apple.developer.team-identifier \
        "$vmbe_team" \
        "$vmbe_description"
    require_entitlement_value \
        "$vmbe_output" \
        com.apple.security.app-sandbox \
        true \
        "$vmbe_description"
    require_entitlement_value \
        "$vmbe_output" \
        com.apple.security.network.client \
        true \
        "$vmbe_description"
    require_entitlement_array \
        "$vmbe_output" \
        com.apple.security.application-groups \
        "$vmbe_description" \
        "$vmbe_team.group.org.lil.wallet"
}

validate_macos_cloudkit_entitlements() {
    vmce_plist=$1
    vmce_description=$2
    require_entitlement_array \
        "$vmce_plist" \
        com.apple.developer.icloud-container-identifiers \
        "$vmce_description" \
        iCloud.org.lil.wallet
    require_entitlement_array \
        "$vmce_plist" \
        com.apple.developer.icloud-services \
        "$vmce_description" \
        CloudKit
}

validate_macos_helper() {
    app=$1
    extension_relative='Contents/PlugIns/Safari macOS.appex'
    helpers_relative="$extension_relative/Contents/Helpers"
    helpers="$app/$helpers_relative"
    helper_relative="$helpers_relative/Big Wallet.app"
    helper="$app/$helper_relative"
    extension="$app/$extension_relative"
    app_info="$app/Contents/Info.plist"
    helper_info="$helper/Contents/Info.plist"
    extension_info="$extension/Contents/Info.plist"

    outer_helpers="$app/Contents/Helpers"
    [ ! -L "$outer_helpers" ] ||
        fail "the macOS app legacy Helpers directory must not be a symlink"
    if [ -e "$outer_helpers" ]; then
        [ -d "$outer_helpers" ] ||
            fail "the macOS app legacy Helpers path must be a directory"
        legacy_helper_list="$temporary_root/macos-legacy-helper-apps"
        if ! LC_ALL=C /usr/bin/find -P "$outer_helpers" \
            -mindepth 1 \
            \( -type l -o -name '*.app' \) \
            -print > "$legacy_helper_list"
        then
            fail "the macOS app legacy helper bundles could not be scanned"
        fi
        [ ! -s "$legacy_helper_list" ] ||
            fail "the macOS app must not contain legacy outer helper bundles"
    fi

    real_directory_tree_exists "$app" "$helpers_relative" ||
        fail "the macOS Safari extension is missing its Helpers directory"
    helper_symlink_list="$temporary_root/macos-helper-symlinks"
    if ! LC_ALL=C /usr/bin/find -P "$helpers" \
        -mindepth 1 \
        -type l \
        -print > "$helper_symlink_list"
    then
        fail "the macOS app helper symlinks could not be scanned"
    fi
    [ ! -s "$helper_symlink_list" ] ||
        fail "the macOS app Helpers directory must not contain symlinks"
    helper_app_list="$temporary_root/macos-helper-apps"
    if ! LC_ALL=C /usr/bin/find -P "$helpers" \
        -mindepth 1 \
        \( -type d -o -type l \) \
        -name '*.app' \
        -print > "$helper_app_list"
    then
        fail "the macOS app helper bundles could not be scanned"
    fi
    helper_app_count=$(
        /usr/bin/wc -l < "$helper_app_list" |
            /usr/bin/tr -d '[:space:]'
    ) || fail "the macOS app helper bundles could not be counted"
    [ "$helper_app_count" = "1" ] ||
        fail "the macOS app must contain exactly one helper app"
    IFS= read -r packaged_helper < "$helper_app_list" ||
        fail "the macOS app helper bundle path could not be read"
    [ "$packaged_helper" = "$helper" ] && [ ! -L "$packaged_helper" ] &&
        [ -d "$packaged_helper" ] ||
        fail "the macOS Safari extension must contain only Contents/Helpers/Big Wallet.app"

    real_directory_tree_exists "$app" "$helper_relative/Contents/MacOS" ||
        fail "the macOS app is missing the embedded Ambient helper"
    real_directory_tree_exists "$app" "$extension_relative/Contents" ||
        fail "the macOS app is missing the Safari extension"
    [ ! -L "$app_info" ] && [ -f "$app_info" ] ||
        fail "the macOS app is missing its Info.plist"
    [ ! -L "$helper_info" ] && [ -f "$helper_info" ] ||
        fail "the Ambient helper is missing its Info.plist"
    [ ! -L "$extension_info" ] && [ -f "$extension_info" ] ||
        fail "the macOS Safari extension is missing its Info.plist"

    helper_identifier=$(plist_value \
        "$helper_info" CFBundleIdentifier "the Ambient helper Info.plist")
    [ "$helper_identifier" = 'org.lil.wallet.ambient' ] ||
        fail "the Ambient helper has an unexpected bundle identifier"
    helper_ui_element=$(plist_value \
        "$helper_info" LSUIElement "the Ambient helper Info.plist")
    [ "$helper_ui_element" = 'true' ] ||
        fail "the Ambient helper must set LSUIElement"
    extension_identifier=$(plist_value \
        "$extension_info" CFBundleIdentifier "the macOS Safari extension Info.plist")
    [ "$extension_identifier" = 'org.lil.wallet.Safari' ] ||
        fail "the macOS Safari extension has an unexpected bundle identifier"
    plist_value \
        "$extension_info" \
        NSAppleEventsUsageDescription \
        "the macOS Safari extension Info.plist" >/dev/null

    app_version=$(plist_value \
        "$app_info" CFBundleShortVersionString "the macOS app Info.plist")
    app_build=$(plist_value \
        "$app_info" CFBundleVersion "the macOS app Info.plist")
    helper_version=$(plist_value \
        "$helper_info" CFBundleShortVersionString "the Ambient helper Info.plist")
    helper_build=$(plist_value \
        "$helper_info" CFBundleVersion "the Ambient helper Info.plist")
    [ "$helper_version" = "$app_version" ] ||
        fail "the Ambient helper version does not match the macOS app"
    [ "$helper_build" = "$app_build" ] ||
        fail "the Ambient helper build does not match the macOS app"

    helper_executable_name=$(plist_value \
        "$helper_info" CFBundleExecutable "the Ambient helper Info.plist")
    case "$helper_executable_name" in
        ''|.|..|*/*) fail "the Ambient helper executable name is invalid" ;;
    esac
    helper_executable="$helper/Contents/MacOS/$helper_executable_name"
    [ ! -L "$helper_executable" ] && [ -f "$helper_executable" ] &&
        [ -x "$helper_executable" ] ||
        fail "the Ambient helper executable is missing or invalid"

    /usr/bin/codesign --verify --strict --deep "$helper" >/dev/null 2>&1 ||
        fail "the Ambient helper signature is invalid"
    /usr/bin/codesign --verify --strict --deep "$extension" >/dev/null 2>&1 ||
        fail "the macOS Safari extension signature is invalid"
    /usr/bin/codesign --verify --strict --deep "$app" >/dev/null 2>&1 ||
        fail "the macOS app nested-code signature is invalid"
    app_team=$(signing_team_identifier "$app" "the macOS app")
    helper_team=$(signing_team_identifier "$helper" "the Ambient helper")
    extension_team=$(signing_team_identifier \
        "$extension" "the macOS Safari extension")
    [ "$helper_team" = "$app_team" ] ||
        fail "the Ambient helper signing team does not match the macOS app"
    [ "$extension_team" = "$app_team" ] ||
        fail "the macOS Safari extension signing team does not match the macOS app"

    app_entitlements="$temporary_root/macos-app-entitlements.plist"
    extension_entitlements="$temporary_root/macos-extension-entitlements.plist"
    helper_entitlements="$temporary_root/macos-helper-entitlements.plist"
    validate_macos_bundle_entitlements \
        "$app" \
        "the macOS app" \
        org.lil.wallet \
        "$app_team" \
        "$app_entitlements"
    validate_macos_bundle_entitlements \
        "$extension" \
        "the macOS Safari extension" \
        org.lil.wallet.Safari \
        "$app_team" \
        "$extension_entitlements"
    validate_macos_bundle_entitlements \
        "$helper" \
        "the Ambient helper" \
        org.lil.wallet.ambient \
        "$app_team" \
        "$helper_entitlements"
    require_entitlement_array \
        "$app_entitlements" \
        keychain-access-groups \
        "the macOS app" \
        "$app_team.org.lil.keychain" \
        "$app_team.org.lil.wallet.rpc-auth"
    require_entitlement_array \
        "$extension_entitlements" \
        keychain-access-groups \
        "the macOS Safari extension" \
        "$app_team.org.lil.wallet.rpc-auth"
    require_entitlement_array \
        "$helper_entitlements" \
        keychain-access-groups \
        "the Ambient helper" \
        "$app_team.org.lil.keychain" \
        "$app_team.org.lil.wallet.rpc-auth"
    validate_macos_cloudkit_entitlements \
        "$app_entitlements" "the macOS app"
    validate_macos_cloudkit_entitlements \
        "$helper_entitlements" "the Ambient helper"
    require_entitlement_array \
        "$extension_entitlements" \
        com.apple.security.temporary-exception.apple-events \
        "the macOS Safari extension" \
        org.lil.wallet.ambient
    require_no_entitlement \
        "$app_entitlements" \
        com.apple.security.temporary-exception.apple-events \
        "the macOS app"
    require_no_entitlement \
        "$helper_entitlements" \
        com.apple.security.temporary-exception.apple-events \
        "the Ambient helper"
}

validate_mobile_bundle_entitlements() {
    vmobile_bundle=$1
    vmobile_description=$2
    vmobile_output=$3

    if ! /usr/bin/codesign \
        -d --entitlements :- "$vmobile_bundle" \
        > "$vmobile_output" 2>/dev/null
    then
        fail "$vmobile_description signed entitlements could not be read"
    fi
    [ -s "$vmobile_output" ] &&
        /usr/bin/plutil -lint "$vmobile_output" >/dev/null 2>&1 ||
        fail "$vmobile_description has invalid signed entitlements"
}

validate_mobile_entitlements() {
    vme_app=$1
    vme_extension_name=$2
    vme_platform_description=$3
    vme_extension_relative="PlugIns/$vme_extension_name"
    vme_extension="$vme_app/$vme_extension_relative"

    real_directory_tree_exists "$vme_app" "$vme_extension_relative" ||
        fail "the $vme_platform_description app is missing its Safari extension"
    /usr/bin/codesign --verify --strict --deep "$vme_app" >/dev/null 2>&1 ||
        fail "the $vme_platform_description app nested-code signature is invalid"
    /usr/bin/codesign --verify --strict "$vme_extension" >/dev/null 2>&1 ||
        fail "the $vme_platform_description Safari extension signature is invalid"

    vme_app_team=$(signing_team_identifier \
        "$vme_app" "the $vme_platform_description app")
    vme_extension_team=$(signing_team_identifier \
        "$vme_extension" "the $vme_platform_description Safari extension")
    [ "$vme_extension_team" = "$vme_app_team" ] ||
        fail "the $vme_platform_description Safari extension signing team does not match the app"

    vme_app_entitlements="$temporary_root/$vme_platform_description-app-entitlements.plist"
    vme_extension_entitlements="$temporary_root/$vme_platform_description-extension-entitlements.plist"
    validate_mobile_bundle_entitlements \
        "$vme_app" \
        "the $vme_platform_description app" \
        "$vme_app_entitlements"
    validate_mobile_bundle_entitlements \
        "$vme_extension" \
        "the $vme_platform_description Safari extension" \
        "$vme_extension_entitlements"
    require_entitlement_array \
        "$vme_app_entitlements" \
        keychain-access-groups \
        "the $vme_platform_description app" \
        "$vme_app_team.org.lil.keychain" \
        "$vme_app_team.org.lil.wallet.safari-approval" \
        "$vme_app_team.org.lil.wallet.rpc-auth"
    require_entitlement_array \
        "$vme_extension_entitlements" \
        keychain-access-groups \
        "the $vme_platform_description Safari extension" \
        "$vme_app_team.org.lil.wallet.safari-approval" \
        "$vme_app_team.org.lil.wallet.rpc-auth"
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
        validate_mobile_entitlements \
            "$main_bundle" "Safari iOS.appex" iOS
        ;;
    VISION_OS)
        validate_mobile_entitlements \
            "$main_bundle" "Safari visionOS.appex" visionOS
        ;;
    MAC_OS)
        validate_macos_helper "$main_bundle"
        ;;
esac

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
            "$main_bundle/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/Resources/AlchemyJWTRequestProofKey" \
            > "$expected_path_list"
        ;;
esac

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
            "$main_bundle/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app/Contents/Resources/AlchemyJWTRequestProofKey" \
            "the Ambient helper"
        ;;
esac
