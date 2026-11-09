export const RUNTIME_TEST_TARGETS = ["WalletDomainTests", "WalletAuthorityTests", "WalletFlowsTests", "WalletNetworkingTests"];
export const RUNTIME_MODULES = ["WalletDomain", "WalletNetworking", "WalletAuthority", "WalletFlows"];
export const isCompileOnlyTarget = selector => selector === "ApprovalCrashWorker" || RUNTIME_MODULES.includes(selector);
export const APP_TEST_TARGETS = {macos: "Tests macOS", ios: "Tests iOS", visionos: "Tests visionOS"};
const platforms = Object.keys(APP_TEST_TARGETS);
export const APP_TEST_CLASS_PLATFORMS = {
    AccountPreviewStateTests: ["macos"],
    AccountsListViewControllerTests: ["macos"],
    WalletAccessControllerTests: platforms,
    OnboardingCancellationTests: ["macos"],
    WindowAuthenticationSessionTests: ["macos"],
    MobileWalletAccessTests: ["ios", "visionos"],
    NativeApprovalCoordinatorTests: ["macos"],
    NativeAccountSelectionViewControllerTests: ["macos"],
    PopupRequestSessionsTests: platforms,
    TransactionApprovalCoordinatorTests: ["macos"],
    PasswordStorageTests: platforms,
    SecretHandlingTests: ["macos"],
    MacSecretLifetimeTests: ["macos"],
    NativeSecretAlertPresentationTests: ["macos"],
};

export const TSAN_FOCUS = {
    focused: {
        runtime: [
            "WalletAuthorityTests/ApprovalResolutionTests", "WalletAuthorityTests/NativeApprovalServiceTests",
            "WalletAuthorityTests/WalletCoreProxyParallelDerivationTests", "WalletAuthorityTests/WalletSigningScopeTests",
            "WalletAuthorityTests/WalletSigningSessionTests", "WalletAuthorityTests/WalletsManagerPreviewTests",
            "WalletDomainTests/AsyncTestSupportTests", "WalletNetworkingTests/AlchemyJWTProviderTests",
            "WalletNetworkingTests/SafariRPCRequestTests", "WalletNetworkingTests/SafariRPCServiceTests",
            "WalletNetworkingTests/SafariRPCStreamingTests", "WalletNetworkingTests/SolanaOptionsTests",
            "WalletNetworkingTests/TransactionInspectorTests",
        ],
        app: ["Tests macOS/AccountPreviewStateTests"],
    },
    extended: {
        runtime: [
            "WalletAuthorityTests/DurableProfilePersistenceTests", "WalletAuthorityTests/ExtensionBridgeStoredRequestTests",
            "WalletAuthorityTests/NativeApprovalCoordinatorTests", "WalletAuthorityTests/TransactionApprovalCoordinatorTests",
            "WalletAuthorityTests/WalletAuthorityRevocationLedgerTests", "WalletAuthorityTests/WalletsManagerPrivateKeyImportTests",
        ],
        app: [
            "Tests macOS/AccountsListViewControllerTests", "Tests macOS/NativeAccountSelectionViewControllerTests",
            "Tests macOS/NativeApprovalCoordinatorTests", "Tests macOS/PopupRequestSessionsTests",
            "Tests macOS/TransactionApprovalCoordinatorTests",
        ],
    },
};

export function matchesTestSelector(identifier, rawSelector) {
    const selector = rawSelector.replace(/\(\)$/, "");
    const name = identifier.split("/").slice(1).join("/");
    return identifier === selector || identifier.startsWith(`${selector}/`) || name === selector || name.startsWith(`${selector}/`);
}

export function focusMayMatch(selectors, focus) {
    if (!selectors.length) { return true; }
    return focus.some(scope => {
        const unqualified = scope.slice(scope.indexOf("/") + 1);
        return selectors.some(selector => matchesTestSelector(scope, selector) ||
            selector.startsWith(`${scope}/`) || selector.startsWith(`${unqualified}/`));
    });
}

export function candidateTargets(selectors, platform, runtime) {
    const targets = runtime ? RUNTIME_TEST_TARGETS : [APP_TEST_TARGETS[platform]];
    const allTargets = [...RUNTIME_TEST_TARGETS, ...Object.values(APP_TEST_TARGETS), "Safari UI Tests macOS", "Safari UI Tests iOS"];
    if (!selectors.length) { return [...targets]; }
    return targets.filter(target => selectors.some(raw => {
        if (isCompileOnlyTarget(raw)) { return false; }
        const selector = raw.replace(/\(\)$/, "");
        const qualified = allTargets.find(name => selector === name || selector.startsWith(`${name}/`));
        if (qualified) { return qualified === target; }
        return selector !== "SafariLifecycleTests" && !selector.startsWith("SafariLifecycleTests/");
    }));
}
