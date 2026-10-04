#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_dir"

mode=${1:-all}
mac_destination='platform=macOS,arch=arm64'
ios_destination=${SWIFT6_IOS_DESTINATION:-'platform=iOS Simulator,name=iPhone 18 Pro'}
vision_destination=${SWIFT6_VISIONOS_DESTINATION:-'platform=visionOS Simulator,name=Apple Vision Pro'}

build() {
    for configuration in Debug Release; do
        xcodebuild -jobs 2 build -project Wallet.xcodeproj -scheme Wallet -configuration "$configuration" -destination 'generic/platform=macOS'
        xcodebuild -jobs 2 build -project Wallet.xcodeproj -scheme 'Wallet iOS' -configuration "$configuration" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
        xcodebuild -jobs 2 build -project Wallet.xcodeproj -scheme 'Wallet visionOS' -configuration "$configuration" -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO
        xcodebuild -jobs 2 -enableCodeCoverage NO build-for-testing -project Wallet.xcodeproj -scheme 'Tests macOS' -configuration "$configuration" -destination "$mac_destination" ENABLE_TESTABILITY=YES
        xcodebuild -jobs 2 -enableCodeCoverage NO build-for-testing -project Wallet.xcodeproj -scheme 'Tests iOS' -configuration "$configuration" -destination "$ios_destination" ENABLE_TESTABILITY=YES
        xcodebuild -jobs 2 -enableCodeCoverage NO build-for-testing -project Wallet.xcodeproj -scheme 'Tests visionOS' -configuration "$configuration" -destination "$vision_destination" ENABLE_TESTABILITY=YES
    done
}

test() {
    xcodebuild -jobs 2 -enableCodeCoverage NO test -project Wallet.xcodeproj -scheme 'Tests macOS' -configuration Debug -destination "$mac_destination" -parallel-testing-enabled NO -collect-test-diagnostics never
    xcodebuild -jobs 2 -enableCodeCoverage NO test -project Wallet.xcodeproj -scheme 'Tests iOS' -configuration Debug -destination "$ios_destination" -parallel-testing-enabled NO -collect-test-diagnostics never
    xcodebuild -jobs 2 -enableCodeCoverage NO test -project Wallet.xcodeproj -scheme 'Tests visionOS' -configuration Debug -destination "$vision_destination" -parallel-testing-enabled NO -collect-test-diagnostics never
    "$script_dir/check_wire_protocol.sh"
    (cd 'Safari Shared/Inpage Provider' && npm test)
}

performance() {
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SCRYPT_DERIVE_MS=1000 \
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SCRYPT_WALLETCORE_JSON_IMPORT_MS=1000 \
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SECP256K1_PUBLIC_KEY_MS=25 \
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SECP256K1_SIGN_MS=15 \
    TEST_RUNNER_WALLETCORE_PROXY_PERF_ED25519_SIGN_MS=15 \
    xcodebuild -jobs 2 -enableCodeCoverage NO test -project Wallet.xcodeproj -scheme 'Tests macOS' -configuration Release -destination "$mac_destination" -parallel-testing-enabled NO -collect-test-diagnostics never ENABLE_TESTABILITY=YES -only-testing:'Tests macOS/WalletCoreProxyPerformanceGateTests'
}

tsan() {
    xcodebuild -jobs 2 -enableCodeCoverage NO test -project Wallet.xcodeproj -scheme 'Tests macOS' -configuration Debug -destination "$mac_destination" -parallel-testing-enabled NO -collect-test-diagnostics never -enableThreadSanitizer YES -only-testing:'Tests macOS/AlchemyJWTProviderTests' -only-testing:'Tests macOS/SolanaOptionsTests' -only-testing:'Tests macOS/ApprovalResolutionTests' -only-testing:'Tests macOS/WalletSigningSessionTests' -only-testing:'Tests macOS/WalletSigningScopeTests' -only-testing:'Tests macOS/NativeApprovalServiceTests' -only-testing:'Tests macOS/TransactionInspectorTests' -only-testing:'Tests macOS/WalletsManagerPreviewTests' -only-testing:'Tests macOS/WalletCoreProxyParallelDerivationTests'
}

case "$mode" in
    build) build ;;
    test) test ;;
    performance) performance ;;
    tsan) tsan ;;
    all) build; test; performance; tsan ;;
    *) echo 'Usage: Scripts/check_swift6.sh [all|build|test|performance|tsan]' >&2; exit 2 ;;
esac
