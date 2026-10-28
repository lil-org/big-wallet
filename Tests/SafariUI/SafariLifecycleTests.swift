import Foundation
import XCTest
#if os(macOS)
import AppKit
import Darwin
#else
import UIKit
#endif

final class SafariLifecycleTests: XCTestCase {
    @MainActor private var localSigning = true
    @MainActor private var activationMode = "automatic"
    @MainActor private var extensionActivated = false
    @MainActor private var retainedSafari = false
    @MainActor private var profilesConfigured = false
    @MainActor private var activeDappURL: String?
    @MainActor private lazy var safari: XCUIApplication = {
#if os(macOS)
        XCUIApplication(bundleIdentifier: "com.apple.Safari")
#else
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
#endif
    }()

#if os(macOS)
    @MainActor private var walletApplication: XCUIApplication?
    @MainActor private var helperApplication: XCUIApplication?
    @MainActor private var helperApplicationURL: URL?
    @MainActor private var wallet: XCUIApplication {
        guard let walletApplication else { preconditionFailure("The run-owned wallet application was not configured") }
        return walletApplication
    }
    @MainActor private var helper: XCUIApplication {
        guard let helperApplication else { preconditionFailure("The run-owned approval helper was not configured") }
        return helperApplication
    }
#else
    @MainActor private lazy var wallet = XCUIApplication()
#endif
#if os(iOS)
    @MainActor private var popup: XCUIElement {
        safari.webViews.matching(NSPredicate(format: "label == %@", "Wallet")).firstMatch
    }
    @MainActor private var popupDone: XCUIElement { safari.navigationBars["Wallet"].buttons["Done"] }
#endif
#if os(macOS)
    @MainActor private var helperIsRunning: Bool {
        guard let helperApplicationURL else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: "org.lil.wallet.ambient").contains {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == helperApplicationURL
        }
    }
#endif

    private var nativeRole: String {
#if os(macOS)
        "helper"
#else
        "extension"
#endif
    }

    @MainActor
    func testInstallAndNativeRoundtrip() async throws {
        try await scenario("install-native-roundtrip") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.verifyCrossProcessLock(control: control)
            try await self.connect("ethereum", control: control)
            let result = try await control.result("ethereum-connect")
            let accounts = (result["result"] as? [String])?.map { $0.lowercased() }
            try self.require(accounts?.contains(config.addresses.ethereum.lowercased()) == true,
                             "The installed extension did not return the fixture Ethereum account")
        }
    }

    @MainActor
    func testEthereumConnectionAndMessage() async throws {
        try await scenario("ethereum-signing") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.verifyCrossProcessLock(control: control)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            let result = try await control.result("ethereum-sign")
            try self.require((result["result"] as? String)?.hasPrefix("0x") == true,
                             "Ethereum signing did not produce a signature")
            try await control.assertSingleSettlement("ethereum-sign")
        }
    }

    @MainActor
    func testSolanaConnectionAndMessage() async throws {
        try await scenario("solana-signing") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("solana", control: control)
            try await self.perform("solana-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("solana-sign")
            try await control.assertSingleSettlement("solana-sign")
        }
    }

    @MainActor
    func testSolanaTransactionSigning() async throws {
        try await scenario("solana-transaction-signing") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("solana", control: control)
            try await self.perform("solana-transaction-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("solana-transaction-sign")
            try await self.perform("solana-batch-sign", control: control)
            try await self.reject(control: control)
            _ = try await control.result("solana-batch-sign", success: false)
            try self.require(try await control.eventCount("signingStarted") == 1,
                             "The rejected Solana batch progressed to signing")
            try await control.assertBroadcasts(chain: "solana", count: 0)
            try await self.perform("solana-batch-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("solana-batch-sign", occurrence: 2)
            try await control.assertSingleSettlement("solana-transaction-sign")
            try await control.assertSingleSettlement("solana-batch-sign", expected: 2)
            try await control.assertBroadcasts(chain: "solana", count: 0)
        }
    }

    @MainActor
    func testRejectionAndDuplicateApproval() async throws {
        try await scenario("rejection-duplicate-approval") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.reject(control: control)
            _ = try await control.result("ethereum-sign", success: false)
            try await control.assertNoSigningOrBroadcast()
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control, doubleClick: true)
            _ = try await control.result("ethereum-sign", occurrence: 2)
            try await control.assertSingleSettlement("ethereum-sign", expected: 2)
        }
    }

    @MainActor
    func testEthereumTransactionBroadcast() async throws {
        try await scenario("ethereum-broadcast") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-send", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-send")
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
        }
    }

    @MainActor
    func testSolanaTransactionBroadcast() async throws {
        try await scenario("solana-broadcast") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("solana", control: control)
            try await self.perform("solana-send", control: control)
            try await self.approve(control: control)
            _ = try await control.result("solana-send")
            try await control.assertBroadcasts(chain: "solana", count: 1)
        }
    }

    @MainActor
    func testNavigationAndTabClosure() async throws {
        try await scenario("navigation-tab-closure") { control, config in
            try await self.prepare(control: control, config: config)
#if os(iOS)
            try self.openTabOverview()
            try self.open(config.secondOriginURL)
            try self.open(config.dappURL)
#endif
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
#if os(iOS)
            try self.closeApproval()
#endif
            try self.open(config.secondOriginURL)
            try await self.perform("provider-state", control: control)
            let unrelated = try await control.result("provider-state")
            try self.require(unrelated["origin"] as? String == config.secondOriginURL,
                             "Navigation did not load the requested fixture origin")
            let state = unrelated["result"] as? [String: Any]
            try self.require((state?["accounts"] as? [String])?.isEmpty == true,
                             "Navigation exposed the previous document's wallet connection to another origin")
            try await control.assertNoSigningOrBroadcast()
            try self.closeOwnedApprovalIfPresent()
            try self.open(config.dappURL)
#if os(iOS)
            try await self.retirePopupRequests()
#endif
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
#if os(iOS)
            try self.closeApproval()
#endif
            try self.closeTab()
            try await control.assertNoSigningOrBroadcast()
            try self.closeOwnedApprovalIfPresent()
            try self.newTab()
            try self.open(config.dappURL)
#if os(iOS)
            try await self.retirePopupRequests()
#endif
            try await control.assertNoSigningOrBroadcast()
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
        }
    }

#if os(macOS)
    @MainActor
    func testApprovalWindowAuthenticationIsolation() async throws {
        try await scenario("macos-auth-isolation") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try self.newTab()
            try self.open(config.secondOriginURL)
            try await self.connect("ethereum", control: control)
            try await control.gate("authentication", "hold")
            try self.newTab()
            try self.open(config.dappURL)
            let firstState = try await self.providerState(control: control)
            guard let firstDocument = firstState["documentId"] as? String else {
                throw SafariUIFailure("The first approval page omitted its document identity")
            }
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
            let first = try await self.approvalWindowIdentifier(excluding: [])
            try self.focusApprovalWindow(self.helper.windows[first])
            try self.click(self.helper.windows[first].buttons["safari.approval.approve"], "hold authentication for the first request")
            try await control.waitForPoint("beforeAuthentication")
            try self.newTab()
            try self.open(config.secondOriginURL)
            let secondState = try await self.providerState(control: control)
            guard let secondDocument = secondState["documentId"] as? String, secondDocument != firstDocument else {
                throw SafariUIFailure("The concurrent approval pages did not have distinct document identities")
            }
            try await self.perform("ethereum-sign", control: control)
            let second = try await self.approvalWindowIdentifier(excluding: [first])
            try self.focusApprovalWindow(self.helper.windows[second])
            try self.click(self.helper.windows[second].buttons["safari.approval.approve"], "hold authentication for the second request")
            try await control.waitForPoint("beforeAuthentication", additional: 2)
            try self.require(first != second, "Concurrent requests reused one approval window")
            try await control.assertNoSigningOrBroadcast()
            try await control.gate("authentication", "release")
            let secondWindow = self.helper.windows[second]
            try self.authenticate(window: secondWindow)
            let secondResult = try await control.result("ethereum-sign", occurrence: 1)
            try self.require(secondResult["documentId"] as? String == secondDocument,
                             "Authenticating the second window completed another document's request")
            try self.require(self.helper.windows[first].secureTextFields["safari.authentication.password"].exists,
                             "Authenticating the second request also unlocked the first approval window")
            let firstWindow = self.helper.windows[first]
            try self.focusApprovalWindow(firstWindow)
            let cancelAuthentication = firstWindow.buttons["safari.authentication.cancel"]
            try self.require(cancelAuthentication.isEnabled, "The first request's authentication cannot be cancelled")
            try self.click(cancelAuthentication, "cancel only the still-locked first request")
            try self.require(firstWindow.waitForNonExistence(timeout: 10),
                             "Cancelling the first request's authentication did not close its approval window")
            let firstResult = try await control.result("ethereum-sign", success: false, occurrence: 2)
            try self.require(firstResult["documentId"] as? String == firstDocument,
                             "Cancelling the first window rejected another document's request")
            try self.require(try await control.eventCount("signingStarted") == 1,
                             "Authenticating one approval window signed more than its owned request")
            try await control.assertSingleSettlement("ethereum-sign", expected: 2)
        }
    }
#endif

#if os(iOS)
    @MainActor
    func testPopupDismissalAndRecovery() async throws {
        try await scenario("ios-popup-recovery") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await control.gate("authentication", "hold")
            try await self.startHeldAuthentication(action: "ethereum-sign", control: control)
            try self.closeApproval()
            try await control.gate("authentication", "release")
            if let completed = try await control.optionalResult("ethereum-sign", timeout: 8) {
                if completed["ok"] as? Bool == true {
                    try await control.assertSingleSettlement("ethereum-sign")
                } else {
                    try await self.perform("ethereum-sign", control: control)
                    try await self.approve(control: control)
                    _ = try await control.result("ethereum-sign")
                    try await control.assertSingleSettlement("ethereum-sign", expected: 2)
                }
            } else {
                try await self.showApproval(control: control)
                try await self.approve(control: control)
                _ = try await control.result("ethereum-sign")
                try await control.assertSingleSettlement("ethereum-sign")
            }
        }
    }
#endif

    @MainActor
    func testBrowserRestartAndRecovery() async throws {
        try await scenario("browser-restart") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
            self.safari.terminate()
            try self.require(self.safari.wait(for: .notRunning, timeout: 10), "Safari did not terminate")
            try await control.assertNoSigningOrBroadcast()
            self.safari.launch()
            try await self.enableExtension(control: control)
            try self.closeOwnedApprovalIfPresent()
            try self.open(config.dappURL)
#if os(iOS)
            try await self.retirePopupRequests()
#endif
            try await control.assertNoSigningOrBroadcast()
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
        }
    }

    @MainActor
    func testBackgroundAndForeground() async throws {
        try await scenario("background-foreground") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
            self.safari.activate()
            try self.require(self.safari.wait(for: .runningForeground, timeout: 10),
                             "Safari was not foreground before the background transition")
            self.wallet.activate()
            try self.require(self.wallet.wait(for: .runningForeground, timeout: 10),
                             "The wallet did not enter the foreground")
#if os(iOS)
            try self.require(self.wallet.buttons["wallet-unlock"].waitForExistence(timeout: 10),
                             "The containing wallet did not remain locked after returning from Safari")
            try self.require(!self.passwordField.exists,
                             "Returning to the locked wallet unexpectedly started authentication")
#endif
            let deadline = Date().addingTimeInterval(10)
            while self.safari.state == .runningForeground && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let safariState = self.safari.state
#if os(macOS)
            try self.require(safariState == .runningBackground,
                             "Safari did not enter an observed background state")
#else
            try self.require(safariState == .runningBackground || safariState == .runningBackgroundSuspended,
                             "Safari did not enter an observed background state")
#endif
            self.attachEvidence("background-foreground-wallet-visible-\(control.iteration)")
            try await control.assertNoSigningOrBroadcast()
            self.safari.activate()
            try self.require(self.safari.wait(for: .runningForeground, timeout: 10),
                             "Safari did not return to the foreground")
            let walletDeadline = Date().addingTimeInterval(10)
            while self.wallet.state == .runningForeground && Date() < walletDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let walletState = self.wallet.state
#if os(macOS)
            try self.require(walletState == .runningBackground,
                             "The wallet did not enter an observed background state")
#else
            try self.require(walletState == .runningBackground || walletState == .runningBackgroundSuspended,
                             "The wallet did not enter an observed background state")
#endif
            self.attachEvidence("background-foreground-safari-visible-\(control.iteration)")
            try await control.assertNoSigningOrBroadcast()
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
            try await control.assertSingleSettlement("ethereum-sign")
#if os(iOS)
            self.wallet.activate()
            try self.require(self.wallet.buttons["wallet-unlock"].waitForExistence(timeout: 10),
                             "Safari signing unexpectedly unlocked the containing wallet")
            self.safari.activate()
#endif
        }
    }

    @MainActor
    func testProfilesAndPrivateBrowsing() async throws {
        try await scenario("profiles-private") { control, config in
            try await self.prepare(control: control, config: config, privateBrowsing: true)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-chain", control: control)
            try await self.approveIfNeeded(action: "ethereum-chain", control: control)
            let originalState = try await self.providerState(control: control)
            try self.assertProviderState(originalState, address: config.addresses.ethereum, chainID: "0xaa36a7")
            let originalProfiles = try await control.nativeProfileIdentifiers()
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
#if os(iOS)
            try self.closeApproval()
#else
            try self.setPrivateExtensionEnabled()
#endif
            try self.newPrivateTab()
            try self.open(config.dappURL)
            try await self.perform("ethereum-connect", control: control)
            let rejected = try await control.result("ethereum-connect", success: false, occurrence: 2)
            try self.require((rejected["error"] as? [String: Any])?["code"] as? Int == 4200,
                             "Private Browsing did not reach the wallet's explicit unsupported-context rejection")
            try await control.assertNoSigningOrBroadcast()
            try self.closeTab()
            let profileName = "\(config.profilePrefix)-\(control.iteration)"
            try self.createAndOpenProfile(profileName)
            try await self.enableExtension(control: control, profile: profileName)
            try self.open(config.dappURL)
            try await self.allowFixtureWebsite(control: control, url: config.dappURL)
            let isolatedState = try await self.providerState(control: control)
            try self.assertProviderState(isolatedState, address: nil, chainID: "0x1")
            try await control.assertNoSigningOrBroadcast()
            try self.closeOwnedApprovalIfPresent()
            try await self.perform("ethereum-connect", control: control)
            try await self.showApproval(control: control)
            try await self.reject(control: control)
            _ = try await control.result("ethereum-connect", success: false, occurrence: 3)
            let profiles = try await control.nativeProfileIdentifiers()
            try self.require(!profiles.subtracting(originalProfiles).isEmpty,
                             "Safari did not deliver a distinct native profile identity for the new profile")
        }
    }

    @MainActor
    func testAuthorityRevocationDuringApproval() async throws {
        try await scenario("authority-revocation") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            let originalState = try await self.providerState(control: control)
            guard let originalDocument = originalState["documentId"] as? String else {
                throw SafariUIFailure("The held signing page omitted its document identity")
            }
            let authentications = try await control.eventCount("authenticationCompleted")
            try await control.gate("authentication", "hold")
            try await self.startHeldAuthentication(action: "ethereum-sign", control: control)
#if os(iOS)
            try self.closeApproval()
            let settledAfterDismissal = try await control.hasResult("ethereum-sign")
            let authenticationsAfterDismissal = try await control.eventCount("authenticationCompleted")
            try self.require(!settledAfterDismissal && authenticationsAfterDismissal == authentications,
                             "Dismissing the popup ended authentication before authority revocation")
#endif
            self.safari.activate()
            try self.newTab()
            try self.open(config.dappURL)
            let settledBeforeRevocation = try await control.hasResult("ethereum-sign")
            let authenticationsBeforeRevocation = try await control.eventCount("authenticationCompleted")
            try self.require(!settledBeforeRevocation && authenticationsBeforeRevocation == authentications,
                             "The original authentication did not remain pending until authority revocation")
            try await self.perform("ethereum-revoke", control: control)
            _ = try await control.result("ethereum-revoke")
            try await control.gate("authentication", "release")
            let rejected = try await control.result("ethereum-sign", success: false)
            try self.require(rejected["documentId"] as? String == originalDocument,
                             "Authority revocation did not reject the original document's held request")
            try await control.assertNoSigningOrBroadcast()
        }
    }

    @MainActor
    func testFeeReviewAndAuthenticationCancellation() async throws {
        try await scenario("fee-auth-cancel") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-send", control: control)
            try await self.showApproval(control: control)
#if os(macOS)
            let slider = self.helper.sliders["transactionSpeedSlider"]
#else
            let slider = self.popup.sliders["Fee"]
#endif
            try self.require(slider.waitForExistence(timeout: 15), "Transaction fee control is absent")
#if os(macOS)
            let previous = slider.normalizedSliderPosition
            slider.adjust(toNormalizedSliderPosition: previous < 0.5 ? 0.8 : 0.2)
            try self.require(abs(slider.normalizedSliderPosition - previous) > 0.1,
                             "The fee control did not change the reviewed transaction")
#else
            let fee = self.popup.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Fee:")).firstMatch
            try self.require(fee.waitForExistence(timeout: 10) && slider.isHittable,
                             "The transaction fee review is not available for a slider gesture")
            let previous = fee.label
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            let deadline = Date().addingTimeInterval(15)
            while fee.label == previous && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let adjusted = fee.label
            try self.require(adjusted != previous, "The fee gesture did not change the reviewed transaction fee")
#endif
            try await control.gate("authentication", "cancel")
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeAuthentication")
            try await control.assertNoSigningOrBroadcast()
            try await control.gate("authentication", "release")
            try await self.showApproval(control: control)
#if os(macOS)
            try self.require(abs(slider.normalizedSliderPosition - previous) > 0.1,
                             "Authentication cancellation discarded the reviewed fee adjustment")
#else
            try self.require(fee.label == adjusted,
                             "Authentication cancellation discarded the reviewed transaction fee adjustment")
#endif
            try await self.approve(control: control)
            _ = try await control.result("ethereum-send")
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
        }
    }

    @MainActor
    func testAmbiguousBroadcastRecovery() async throws {
        try await scenario("ambiguous-broadcast") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await control.fault("broadcast", parameters: ["mode": "ambiguous"])
            try await self.perform("ethereum-send", control: control)
            try await self.approve(control: control)
            try await control.waitForBroadcast(chain: "ethereum")
            let incarnations = try await control.nativeIncarnations(role: self.nativeRole)
            let signingCount = try await control.eventCount("signingStarted")
            try await control.fault("native-process", parameters: ["action": "terminate"])
            try await control.fault("broadcast", parameters: ["mode": "normal"])
            self.safari.activate()
            _ = try await control.result("ethereum-send", success: false)
            try await self.perform("ethereum-sign", control: control)
            try await self.reject(control: control)
            _ = try await control.result("ethereum-sign", success: false)
            try await control.waitForNewNativeIncarnation(role: self.nativeRole, excluding: incarnations)
            try self.require(try await control.eventCount("signingStarted") == signingCount,
                             "Recovering an ambiguous transaction signed again without a new approval")
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
            try await control.assertSingleSettlement("ethereum-send")
        }
    }

    @MainActor
    func testRPCFailureAndCapacity() async throws {
        try await scenario("rpc-failure-capacity") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await control.fault("rpc", parameters: ["mode": "unavailable"])
            try await self.perform("rpc-error", control: control)
            _ = try await control.result("rpc-error", success: false)
            try await control.fault("rpc", parameters: ["mode": "hold"])
            try await self.perform("rpc-burst", control: control)
            try await control.waitForRPCCapacity()
            try await control.fault("rpc", parameters: ["mode": "normal"])
            let burst = try await control.result("rpc-burst")
            try control.assertRPCOutcomes(burst)
            try await control.assertNoSigningOrBroadcast()
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
        }
    }

    @MainActor
    func testNativeProcessRecovery() async throws {
        try await scenario("native-process-recovery") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
            let incarnations = try await control.nativeIncarnations(role: self.nativeRole)
            try await control.fault("native-process", parameters: ["action": "terminate"])
            try await control.assertNoSigningOrBroadcast()
#if os(iOS)
            if self.popupDone.exists { try self.closeApproval() }
            try self.require(self.popup.waitForNonExistence(timeout: 10),
                             "The pre-termination popup did not close before loading a fresh native review")
#endif
            try await self.showApproval(control: control)
            try await control.waitForNewNativeIncarnation(role: self.nativeRole, excluding: incarnations)
#if os(iOS)
            try await self.restoreInterruptedReview()
#endif
            try await control.assertNoSigningOrBroadcast()
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
            try await control.assertSigningInNewNativeIncarnation(excluding: incarnations)
            try await control.assertSingleSettlement("ethereum-sign")
        }
    }

    @MainActor
    func testSameOriginReloadAndDocumentIsolation() async throws {
        try await scenario("document-reload") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            let before = try await self.providerState(control: control)
            guard let originalDocument = before["documentId"] as? String else {
                throw SafariUIFailure("The original page omitted its document identity")
            }
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
#if os(iOS)
            try self.closeApproval()
#endif
            try self.reload(config.dappURL)
            let after = try await self.providerState(control: control)
            guard let reloadedDocument = after["documentId"] as? String else {
                throw SafariUIFailure("The reloaded page omitted its document identity")
            }
            try self.require(originalDocument != reloadedDocument, "Same-origin navigation reused the previous document")
            try self.assertProviderState(after, address: config.addresses.ethereum, chainID: "0x1")
            try await control.assertNoSigningOrBroadcast()
            try self.closeOwnedApprovalIfPresent()
#if os(iOS)
            try await self.retirePopupRequests()
#endif
            try await control.assertNoSigningOrBroadcast()
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            let signed = try await control.result("ethereum-sign")
            try self.require(signed["documentId"] as? String == reloadedDocument,
                             "The signing response reached a retired document")
            try await control.assertNoSuccessfulResult(action: "ethereum-sign", documentID: originalDocument)
        }
    }

    @MainActor
    func testAccountAndChainSwitching() async throws {
        try await scenario("account-chain-switch") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.selectEthereumAccount(config.alternateAddresses.ethereum, control: control)
            try self.assertProviderState(try await self.providerState(control: control),
                                         address: config.alternateAddresses.ethereum, chainID: "0x1")
            try await self.perform("ethereum-chain", control: control)
            try await self.approveIfNeeded(action: "ethereum-chain", control: control,
                                           accountAddress: config.alternateAddresses.ethereum)
            try self.assertProviderState(try await self.providerState(control: control),
                                         address: config.alternateAddresses.ethereum, chainID: "0xaa36a7")
            try await self.perform("ethereum-mainnet", control: control)
            try await self.approveIfNeeded(action: "ethereum-mainnet", control: control,
                                           accountAddress: config.alternateAddresses.ethereum)
            try await self.selectEthereumAccount(config.addresses.ethereum, control: control)
            try self.assertProviderState(try await self.providerState(control: control),
                                         address: config.addresses.ethereum, chainID: "0x1")
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
        }
    }

    @MainActor
    func testMalformedRequests() async throws {
        try await scenario("malformed-requests") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("malformed-requests", control: control)
            let response = try await control.result("malformed-requests")
            guard let outcomes = response["result"] as? [[String: Any]], outcomes.count == 4 else {
                throw SafariUIFailure("Malformed request batch did not report all four cases")
            }
            for outcome in outcomes {
                let expectedCode = outcome["method"] as? String == "wallet_fixtureUnsupportedMethod" ? -32601 : -32602
                try self.require(outcome["ok"] as? Bool == false && outcome["code"] as? Int == expectedCode,
                                 "Malformed request unexpectedly succeeded or returned the wrong error: \(outcome)")
            }
            try await control.assertNoSigningOrBroadcast()
#if os(iOS)
            try self.showPopup()
            let idle = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true"),
                object: self.popup.buttons["Switch Account"]
            )
            let idleResult = await XCTWaiter.fulfillment(of: [idle], timeout: 10)
            try self.require(idleResult == .completed,
                             "Malformed input did not leave a freshly loaded empty approval queue")
            try self.require(!self.popup.buttons["Cancel"].exists, "Malformed input queued an approval request")
#endif
            try self.require(!self.approvalButton.exists, "Malformed input opened an approval request")
#if os(iOS)
            self.attachEvidence("malformed-requests-empty-queue")
            try self.closeApproval()
#endif
        }
    }

    @MainActor
    func testFeeChangeRequiresFreshApproval() async throws {
        try await scenario("fee-change-reapproval") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-send-estimated", control: control)
            try await self.showApproval(control: control)
            let priorConsents = try await control.consentIdentifiers()
            try await control.gate("authentication", "hold")
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeAuthentication")
            let heldRequest = try await control.requestIDAtPoint("beforeAuthentication")
            try self.require(try await control.consentIdentifiers() == priorConsents,
                             "The first fee approval attempt created executable consent before authentication")
            try await control.fault("rpc-fees", parameters: ["multiplier": 10])
            try await control.gate("authentication", "release")
#if os(macOS)
            try self.require(try await self.waitForPasswordField(timeout: 12), "Held transaction authentication did not resume")
            try await self.authenticateIfPresent(control: control)
#endif
            try await self.showApproval(control: control)
            try self.waitForReviewNotice("Network fees updated")
            try await control.assertNoSigningOrBroadcast()
            try self.require(try await control.consentIdentifiers() == priorConsents,
                             "Changed fees created executable consent before the renewed approval")
            try self.require(!(try await control.hasResult("ethereum-send-estimated")),
                             "Changed fees completed the transaction without renewed approval")
            try await self.approve(control: control)
            _ = try await control.result("ethereum-send-estimated")
            let freshConsent = try await control.singleNewConsentIdentifier(excluding: priorConsents)
            try await control.assertSigningConsent(freshConsent, requestID: heldRequest)
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
            try await control.assertCurrentActionSingleSettlement("ethereum-send-estimated")
        }
    }

    @MainActor
    func testNonceEditSurvivesInterruption() async throws {
        try await scenario("nonce-editor") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-send-estimated", control: control)
            try await self.showApproval(control: control)
            try self.require(try self.transactionNonce() == "0", "The initial estimated transaction nonce is unexpected")
            try await control.fault("rpc-preparation", parameters: ["mode": "hold"])
            try self.editTransaction(nonce: "7")
            try await control.waitForPreparationHold()
            try self.closeApproval()
#if os(iOS)
            try await control.fault("extension-process", parameters: ["action": "terminate"])
#endif
            try await control.fault("rpc-preparation", parameters: ["mode": "normal"])
            try await control.assertNoSigningOrBroadcast()
#if os(macOS)
            _ = try await control.result("ethereum-send-estimated", success: false)
            try await self.perform("ethereum-send-estimated", control: control)
            try await self.showApproval(control: control)
            try self.require(try self.transactionNonce() == "0", "A replacement request inherited the closed request's nonce")
#else
            try await self.showApproval(control: control)
            if ["Try again", "Refresh"].contains(self.approvalButton.label) {
                try self.click(self.approvalButton, "retry interrupted transaction preparation")
            }
            try self.require(try self.transactionNonce() == "0", "The restarted extension restored a stale nonce edit from interrupted preparation")
#endif
            try self.editTransaction(nonce: "9")
            try await control.gate("authentication", "cancel")
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeAuthentication")
            try await control.assertNoSigningOrBroadcast()
            try await control.gate("authentication", "release")
            try await self.showApproval(control: control)
            try self.require(try self.transactionNonce() == "9", "Authentication cancellation discarded the current nonce edit")
            try await self.approve(control: control)
            _ = try await control.result("ethereum-send-estimated")
            try await control.assertAuthorizedTransaction(nonce: "0x9")
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
        }
    }

#if os(iOS)
    @MainActor
    func testPopupExecutionCheckpointRecovery() async throws {
        try await scenario("popup-execution-recovery") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            for point in ["beforeSigning", "afterSigning", "afterBroadcastCheckpoint", "beforeCompletion"] {
                let action = point == "afterBroadcastCheckpoint" ? "ethereum-send" : "ethereum-sign"
                let signingBefore = try await control.eventCount("signingStarted")
                try await control.gate(point, "hold")
                try await self.perform(action, control: control)
                try await self.pressApprove(control: control)
                try await control.waitForPoint(point)
                try self.closeApproval()
                try await control.gate(point, "release")
                try self.showPopup()
                guard let outcome = try await control.optionalResult(action, timeout: 30) else {
                    throw SafariUIFailure("Popup closure at \(point) left the original consent without a terminal outcome")
                }
                try self.require(outcome["ok"] as? Bool == true || (outcome["error"] as? [String: Any])?["code"] is Int,
                                 "Popup recovery returned neither a verified completion nor an explicit failure")
                let signingAfter = try await control.eventCount("signingStarted")
                try self.require(signingAfter - signingBefore <= 1, "Popup reopening consumed the same consent more than once")
                try await control.assertCurrentActionSingleSettlement(action)
                if self.popupDone.exists { try self.closeApproval() }
            }
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
        }
    }
#endif

    @MainActor
    func testAccountRemovalDuringApproval() async throws {
        try await scenario("account-removal") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await control.gate("signing", "hold")
            try await self.perform("ethereum-sign", control: control)
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeSigning")
            _ = try await self.applyMutation("removeEthereumAccount", control: control)
            do {
                try await control.gate("signing", "release")
                self.safari.activate()
                _ = try await control.result("ethereum-sign", success: false)
                try await control.assertNoSigningOrBroadcast()
            } catch {
                _ = try? await self.applyMutation("restoreEthereumAccount", control: control)
                throw error
            }
            _ = try await self.applyMutation("restoreEthereumAccount", control: control)
            try self.reload(config.dappURL)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
            try await control.assertCurrentActionSingleSettlement("ethereum-sign")
        }
    }

#if os(iOS)
    @MainActor
    func testVaultReplacementDuringApproval() async throws {
        try await scenario("vault-replacement") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await control.gate("signing", "hold")
            try await self.perform("ethereum-sign", control: control)
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeSigning")
            let replacement = try await self.applyMutation("replaceVaultGeneration", control: control)
            guard let previous = replacement["previousGeneration"] as? String,
                  let current = replacement["generation"] as? String else {
                throw SafariUIFailure("Vault publication did not report its actual generation change")
            }
            try self.require(previous != current, "Vault replacement did not publish a new generation")
            try await control.gate("signing", "release")
            self.safari.activate()
            try await self.showApproval(control: control)
            try self.waitForReviewNotice("Approval interrupted. Please try again from the website.")
            try self.require(self.popup.buttons["Refresh"].isEnabled && self.popup.buttons["Cancel"].isEnabled,
                             "Vault replacement did not restore an interrupted request with retry and rejection controls")
            try self.require(!(try await control.hasResult("ethereum-sign")),
                             "Vault replacement settled the original request before its restored review was rejected")
            try await control.assertNoSigningOrBroadcast()
            try await self.reject(control: control)
            _ = try await control.result("ethereum-sign", success: false)
            try await control.assertNoSigningOrBroadcast()
            try self.open(config.dappURL)
            try await self.perform("ethereum-sign", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-sign")
            try await control.assertSingleSettlement("ethereum-sign", expected: 2)
        }
    }
#endif

    @MainActor
    func testCustomNetworkReplacementDuringApproval() async throws {
        try await scenario("custom-network-replacement") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-add-custom", control: control)
            try await self.approveIfNeeded(action: "ethereum-add-custom", control: control)
            try await self.perform("ethereum-switch-custom", control: control)
            try await self.approveIfNeeded(action: "ethereum-switch-custom", control: control)
            try await self.perform("ethereum-send-custom", control: control)
            try await self.showApproval(control: control)
            try await control.gate("authentication", "hold")
            try await self.pressApprove(control: control)
            try await control.waitForPoint("beforeAuthentication")
            let original: [String: Any] = ["chainId": config.customNetwork.chainId, "rpcURL": config.customNetwork.rpcURL]
            let replacement: [String: Any] = ["chainId": config.customNetwork.chainId, "rpcURL": config.customNetwork.replacementRPCURL]
            _ = try await self.applyMutation("replaceCustomNetwork", parameters: replacement, control: control)
            do {
                try await control.gate("authentication", "release")
#if os(macOS)
                if self.helperIsRunning { self.helper.activate() }
                if try await self.waitForPasswordField(timeout: 8) { try await self.authenticateIfPresent(control: control) }
#endif
                self.safari.activate()
                try await control.assertNoSigningOrBroadcast()
                if let result = try await control.optionalResult("ethereum-send-custom", timeout: 8) {
                    try self.require(result["ok"] as? Bool == false, "The changed RPC destination reused the prior approval")
                } else {
                    try await self.rejectIfNeeded(action: "ethereum-send-custom", control: control)
                }
                try await control.assertNoSigningOrBroadcast()
            } catch {
                _ = try? await self.applyMutation("replaceCustomNetwork", parameters: original, control: control)
                throw error
            }
            _ = try await self.applyMutation("replaceCustomNetwork", parameters: original, control: control)
            try self.open(config.dappURL)
            try await self.perform("ethereum-send-custom", control: control)
            try await self.approve(control: control)
            _ = try await control.result("ethereum-send-custom")
            try await control.assertBroadcasts(chain: "ethereum", count: 1)
        }
    }

    @MainActor
    private func selectEthereumAccount(_ address: String, control: SafariUIControl) async throws {
#if os(iOS)
        let previous = try await control.consentIdentifiers()
        try showPopup()
        try click(popup.buttons["Switch Account"], "switch the connected website's account")
        try await approve(control: control, accountAddress: address)
        try await control.waitForSelectionCompletion(excluding: previous)
#else
        try await perform("ethereum-revoke", control: control)
        _ = try await control.result("ethereum-revoke")
        try await perform("ethereum-connect", control: control)
        try await approve(control: control, accountAddress: address)
        let connected = try await control.result("ethereum-connect")
        try require((connected["result"] as? [String])?.map { $0.lowercased() } == [address.lowercased()],
                    "Reconnecting did not return the newly approved Ethereum account")
#endif
        try await control.assertNoSigningOrBroadcast()
    }

    @MainActor
    private func verifyCrossProcessLock(control: SafariUIControl) async throws {
        let identifier = try await control.startLockProbe()
        try await perform("rpc-error", control: control)
        try await control.waitForLockProbe("fixtureLockHeld", identifier: identifier)
        wallet.activate()
        try await control.waitForLockProbe("fixtureLockAcquired", identifier: identifier)
        safari.activate()
        _ = try await control.result("rpc-error")
    }

    @MainActor
    private func applyMutation(_ operation: String, parameters: [String: Any] = [:], control: SafariUIControl) async throws -> [String: Any] {
        safari.activate()
        let identifier = try await control.mutation(operation, parameters: parameters)
        wallet.activate()
        let acknowledgement = try await control.waitForMutation(identifier)
        safari.activate()
        return acknowledgement
    }

    @MainActor
    private func providerState(control: SafariUIControl) async throws -> [String: Any] {
        try await perform("provider-state", control: control)
        return try await control.result("provider-state")
    }

    private func assertProviderState(_ response: [String: Any], address: String?, chainID: String? = nil) throws {
        guard let state = response["result"] as? [String: Any], let accounts = state["accounts"] as? [String] else {
            throw SafariUIFailure("Provider state omitted accounts")
        }
        if let address {
            try require(accounts.map { $0.lowercased() } == [address.lowercased()], "Provider selected a different Ethereum account")
        } else { try require(accounts.isEmpty, "Provider inherited another origin or profile's account") }
        if let chainID { try require(state["chainId"] as? String == chainID, "Provider chain differs from the approved chain") }
    }

    @MainActor
    private func approveIfNeeded(action: String, control: SafariUIControl, accountAddress: String? = nil) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if try await control.hasResult(action) { _ = try await control.result(action); return }
            if approvalButton.exists || passwordIsVisible {
                try await approve(control: control, accountAddress: accountAddress)
                _ = try await control.result(action)
                return
            }
#if os(iOS)
            try showPopup()
#endif
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The request neither completed nor presented its approval UI: \(action)")
    }

    @MainActor
    private func waitForReviewNotice(_ title: String) throws {
#if os(macOS)
        helper.activate()
        let notice = helper.textViews.matching(NSPredicate(format: "value CONTAINS %@", title)).firstMatch
#else
        let notice = popup.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
#endif
        try require(notice.waitForExistence(timeout: 15), "Updated transaction review did not show \(title)")
    }

#if os(macOS)
    @MainActor
    private var transactionEditor: XCUIElement {
        helper.sheets.containing(.textField, identifier: "transactionNonceField").firstMatch
    }
#endif

    @MainActor
    private func openTransactionEditor() throws -> XCUIElement {
#if os(macOS)
        helper.activate()
        let editor = helper.buttons["editTransactionFeesButton"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: editor)
        try require(XCTWaiter.wait(for: [ready], timeout: 15) == .completed, "Transaction preparation never enabled its editor")
        try click(editor, "transaction editor")
        let field = transactionEditor.textFields["transactionNonceField"]
#else
        let summary = popup.buttons["Advanced"]
        if !popup.textFields["Nonce"].exists {
            try revealPopupElement(summary, "transaction editor")
            try click(summary, "transaction editor")
        }
        let field = popup.textFields["Nonce"]
#endif
        try require(field.waitForExistence(timeout: 15), "Transaction nonce field is unavailable")
#if os(iOS)
        try revealPopupElement(field, "transaction nonce")
#endif
        return field
    }

    @MainActor
    private func editTransaction(nonce: String) throws {
        let field = try openTransactionEditor()
#if os(macOS)
        try click(field, "transaction nonce")
        field.typeKey("a", modifierFlags: .command)
#else
        let deadline = Date().addingTimeInterval(12)
        _ = try waitForStableTarget(field, "transaction nonce", until: deadline)
        field.tap()
        let keyboard = safari.keyboards.firstMatch
        var previousKeyboardFrame: CGRect?
        let editableFrame: @MainActor () -> CGRect? = {
            guard keyboard.exists && field.exists && field.isEnabled && field.isHittable else {
                previousKeyboardFrame = nil
                return nil
            }
            let keyboardFrame = keyboard.frame
            let frame = field.frame
            defer { previousKeyboardFrame = keyboardFrame }
            guard !keyboardFrame.isEmpty && !keyboardFrame.isNull && !keyboardFrame.isInfinite,
                  keyboardFrame == previousKeyboardFrame && frame.intersection(keyboardFrame).isEmpty else { return nil }
            return frame
        }
        _ = try waitForStableFrame("focused transaction nonce", until: deadline, frame: editableFrame)
        field.doubleTap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        _ = try waitForStableFrame("cleared transaction nonce", until: deadline) {
            guard field.value as? String == "" else { return nil }
            return editableFrame()
        }
#endif
        field.typeText(nonce)
        let enteredNonce = field.value as? String
        try require(enteredNonce == nonce,
                    "Nonce entry expected \(nonce), received \(enteredNonce ?? "<unreadable>")")
#if os(macOS)
        let sheet = transactionEditor
        try click(sheet.buttons["Apply"], "apply reviewed transaction edits")
        try require(sheet.waitForNonExistence(timeout: 10), "The transaction editor did not close after applying edits")
#else
        let network = popup.otherElements["Network, region"]
        try revealPopupElement(network, "transaction network")
        try click(network, "finish editing the transaction nonce")
        try require(safari.keyboards.firstMatch.waitForNonExistence(timeout: 10),
                    "The transaction keyboard did not dismiss before Apply")
        try require(popup.exists && popupDone.exists,
                    "Finishing nonce entry dismissed the Wallet approval")
        let retainedNonce = field.value as? String
        try require(retainedNonce == nonce,
                    "Finishing nonce entry changed \(nonce) to \(retainedNonce ?? "<unreadable>")")
        attachEvidence("ios-nonce-\(nonce)-keyboard-dismissed")
        try revealPopupElement(popup.buttons["Apply"], "apply reviewed transaction edits")
        try click(popup.buttons["Apply"], "apply reviewed transaction edits")
#endif
    }

    @MainActor
    private func transactionNonce() throws -> String {
        let field = try openTransactionEditor()
        guard let value = field.value as? String else { throw SafariUIFailure("Nonce field has no readable value") }
#if os(macOS)
        let sheet = transactionEditor
        try click(sheet.buttons["Cancel"], "close unchanged transaction editor")
        try require(sheet.waitForNonExistence(timeout: 10), "The unchanged transaction editor did not close")
#else
        let summary = popup.buttons["Advanced"]
        try revealPopupElement(summary, "transaction editor disclosure")
        try click(summary, "close unchanged transaction editor")
#endif
        return value
    }

    @MainActor
    private func scenario(_ identifier: String,
                          body: @MainActor (SafariUIControl, SafariUIConfiguration) async throws -> Void) async throws {
        continueAfterFailure = false
        let control = try SafariUIControl(bundle: Bundle(for: Self.self))
        let config = try await control.configuration()
#if os(iOS)
        var synchronizationError: NSError?
        try require(BWSafariSynchronizationInstall(&synchronizationError),
                    synchronizationError?.localizedDescription ?? "Safari synchronization could not be installed")
#endif
#if os(macOS)
        try configureApplications(config: config, runID: control.runID)
#endif
        localSigning = config.signingMode == "local"
        activationMode = config.activationMode
        retainedSafari = false
        let canRetainSafari = config.iterations > 1 && identifier != "profiles-private"
        for iteration in 1...config.iterations {
            control.iteration = iteration
            if !retainedSafari { extensionActivated = false }
            activeDappURL = nil
            var finishAttempted = false
            do {
                try await control.post("start", ["scenario": identifier, "iteration": iteration,
                                                  "synchronization": try synchronizationSnapshot()])
                if !retainedSafari, safari.state != .notRunning { safari.terminate() }
#if os(iOS)
                if iteration == 1 {
                    try await configureReducedMotion()
                    try configureSafariTabLayout()
                }
#endif
                let iterationConfig = try await control.configuration()
                try await body(control, iterationConfig)
                attachEvidence("\(identifier)-\(iteration)")
                try await cleanup(retainingSafari: canRetainSafari && iteration < config.iterations,
                                  resettingProfileSession: identifier == "profiles-private")
                let synchronization = try synchronizationSnapshot()
                finishAttempted = true
                try await control.post("finish", ["scenario": identifier, "iteration": iteration,
                                                  "synchronization": synchronization,
                                                  "status": "passed", "evidence": ["xcresult": name]])
            } catch {
                let diagnostic = "Safari scenario \(identifier):\(iteration) failed: \(error)"
                let boundedDiagnostic = String(decoding: diagnostic.utf8.prefix(8192), as: UTF8.self)
                FileHandle.standardError.write(Data((boundedDiagnostic + "\n").utf8))
                attachEvidence("\(identifier)-\(iteration)-failure")
                var evidence = ["error": String(describing: error)]
                do { try await cleanup(resettingProfileSession: identifier == "profiles-private") }
                catch { evidence["cleanupError"] = String(describing: error) }
                if !finishAttempted {
                    var failure: [String: Any] = ["scenario": identifier, "iteration": iteration,
                                                   "status": "failed", "evidence": evidence]
                    failure["synchronization"] = try? synchronizationSnapshot()
                    try? await control.post("finish", failure)
                }
                throw error
            }
        }
    }

    @MainActor
    private func synchronizationSnapshot() throws -> [String: Any] {
#if os(iOS)
        let value = BWSafariSynchronizationSnapshot()
        guard value["policy"] as? String == "safari-event-loop-only",
              value["hookInstalled"] as? Bool == true,
              value["hookActive"] as? Bool == true else {
            throw SafariUIFailure("Safari synchronization is no longer installed and active")
        }
        return value
#else
        ["schemaVersion": 1, "policy": "xctest-default", "hookInstalled": false]
#endif
    }

    @MainActor
    private func cleanup(retainingSafari: Bool = false, resettingProfileSession: Bool = false) async throws {
        var keepSafari = false
        var failure: Error?
        do {
            keepSafari = try await cleanupBrowserWindows(
                retainingSafari: retainingSafari, resettingProfileSession: resettingProfileSession
            )
        } catch {
            failure = error
        }
#if os(macOS)
        if helperIsRunning { helper.terminate() }
        if let walletApplication, walletApplication.state != .notRunning { walletApplication.terminate() }
        if !keepSafari {
            do {
                try await Task { @MainActor in try await self.terminateSafariForCleanup() }.value
            } catch {
                if let previous = failure {
                    failure = SafariUIFailure("\(previous); Safari shutdown failed: \(error)")
                } else {
                    failure = error
                }
            }
        }
#else
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        if settings.state != .notRunning { settings.terminate() }
        if wallet.state != .notRunning { wallet.terminate() }
        if !keepSafari, safari.state != .notRunning { safari.terminate() }
#endif
        retainedSafari = keepSafari
        if let failure { throw failure }
    }

    @MainActor
    private func cleanupBrowserWindows(retainingSafari: Bool, resettingProfileSession: Bool) async throws -> Bool {
        try closeOwnedApprovalIfPresent()
        guard safari.state != .notRunning, extensionActivated else { return false }
        safari.activate()
#if os(macOS)
        var closed = 0
        while safari.windows.count > 0 && closed < 30 {
            try click(safari.windows.firstMatch.buttons[XCUIIdentifierCloseWindow], "close run-owned Safari window")
            closed += 1
        }
        try require(safari.windows.count == 0, "Safari left fixture windows open after scenario cleanup")
#else
        dismissKeyboardIntroduction(in: safari)
        if popupDone.exists { try closeApproval() }
        let resetProfileSession = resettingProfileSession && profilesConfigured
        try restoreOrdinaryBrowsing(profile: resetProfileSession ? "Personal" : nil)
        if let activeDappURL {
            if resetProfileSession {
                safari.terminate()
                safari.launch()
                try newTab()
                attachEvidence("ios-cleanup-ordinary-tab-ready")
            }
            let ordinaryDocument = safari.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "TabDocument?", "&IsPrivate=false&")
            ).firstMatch
            if resetProfileSession {
                try require(ordinaryDocument.waitForExistence(timeout: 10),
                            "Safari did not restore an ordinary tab after the profile cleanup restart")
                try open(activeDappURL)
                try require(ordinaryDocument.exists, "Safari did not open the cleanup fixture page in ordinary browsing")
            } else if safari.textViews["TabOverview"].exists || !ordinaryDocument.exists || !safari.buttons["ethereum-connect"].exists {
                try open(activeDappURL)
            }
            try await retirePopupRequests()
        }
        dismissKeyboardIntroduction(in: safari)
        let tabs = safari.buttons["TabOverviewButton"]
        _ = try waitForStableTarget(tabs, "Safari tabs during cleanup", until: Date().addingTimeInterval(8))
        if tabs.exists {
            tabs.press(forDuration: 1)
            let closeAction = safari.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@ OR label == %@", "Close All", "Close This Tab"
            )).firstMatch
            _ = try waitForStableTarget(closeAction, "Safari tab-closing menu", until: Date().addingTimeInterval(12))
            let closesAll = closeAction.label.hasPrefix("Close All")
            closeAction.tap()
            if closesAll {
                let confirmation = safari.sheets["ConfirmCloseAllTabsAlert"].buttons["CloseAllTabsButton"].firstMatch
                try click(confirmation, "confirm closing fixture tabs")
            }
        }
#endif
        return retainingSafari && safari.state != .notRunning
    }

#if os(macOS)
    @MainActor
    private func terminateSafariForCleanup() async throws {
        let bundleIdentifier = "com.apple.Safari"
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        try require(applications.count <= 1, "Safari cleanup found multiple running browser processes")
        guard let application = applications.first else { return }
        let processIdentifier = application.processIdentifier
        guard processIdentifier > 0, let launchDate = application.launchDate,
              let bundleURL = application.bundleURL, bundleURL.isFileURL,
              application.bundleIdentifier == bundleIdentifier else {
            throw SafariUIFailure("Safari cleanup could not verify the running browser's identity")
        }
        let expectedBundlePath = bundleURL.resolvingSymlinksInPath().path
        var evidence = ["pid: \(processIdentifier)", "launchedAt: \(launchDate.timeIntervalSince1970)",
                        "bundleIdentifier: \(bundleIdentifier)", "bundlePath: \(expectedBundlePath)"]
        defer {
            let attachment = XCTAttachment(string: evidence.joined(separator: "\n"))
            attachment.name = "macos-safari-cleanup"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        evidence.append("gracefulTerminationAccepted: \(application.terminate())")
        let exitedGracefully = try await waitForSafariExit(application, timeout: .seconds(10))
        if !exitedGracefully, let current = NSRunningApplication(processIdentifier: processIdentifier), !current.isTerminated {
            guard current.processIdentifier == processIdentifier, current.launchDate == launchDate,
                  current.bundleIdentifier == bundleIdentifier,
                  current.bundleURL?.resolvingSymlinksInPath().path == expectedBundlePath else {
                evidence.append("forceTerminationRefused: process identity changed")
                throw SafariUIFailure("Safari process identity changed before cleanup escalation")
            }
            evidence.append("forceTerminationAccepted: \(current.forceTerminate())")
            let exited = try await waitForSafariExit(application, timeout: .seconds(10))
            evidence.append("exitedAfterForce: \(exited)")
            try require(exited, "Safari remained running after bounded cleanup termination")
        } else {
            evidence.append("exitedGracefully: \(application.isTerminated)")
        }
        try require(application.isTerminated, "Safari cleanup could not confirm the captured browser exited")
        let remaining = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        evidence.append("remainingSafariProcesses: \(remaining.map(\.processIdentifier))")
        try require(remaining.isEmpty, "Safari restarted or remained running after scenario cleanup")
    }

    @MainActor
    private func waitForSafariExit(_ application: NSRunningApplication, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !application.isTerminated && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        return application.isTerminated
    }
#endif

    @MainActor
    private func prepare(control: SafariUIControl, config: SafariUIConfiguration, privateBrowsing: Bool = false) async throws {
        activeDappURL = config.dappURL
        let reuseSafari = retainedSafari && extensionActivated && safari.state != .notRunning
        retainedSafari = false
        wallet.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        wallet.launch()
        if localSigning {
#if os(macOS)
            try require(try await waitForPasswordField(in: wallet, timeout: 12),
                        "The fixture wallet did not present its real password entry screen")
#else
            try require(passwordField.waitForExistence(timeout: 12),
                        "The fixture wallet did not present its real password entry screen")
#endif
        }
        try await authenticateIfPresent(control: control)
        safari.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        safari.activate()
#if os(iOS)
        try dismissStartPageExtensionDiscovery()
#endif
        if reuseSafari {
#if os(macOS)
            safari.typeKey("n", modifierFlags: .command)
            try require(safari.windows.firstMatch.waitForExistence(timeout: 12),
                        "The retained Safari session did not open a fresh ordinary window")
#else
            try newTab()
#endif
        } else {
            try await enableExtension(control: control)
        }
#if os(iOS)
        if privateBrowsing { try setPrivateExtensionEnabled() }
        try restoreOrdinaryBrowsing(profile: profilesConfigured ? "Personal" : nil)
        try dismissStartPageExtensionDiscovery()
        let previousDocument = try fixtureDocumentIdentity()
        guard let url = URL(string: config.dappURL), url.scheme == "http", url.host == "127.0.0.1" else {
            throw SafariUIFailure("The initial fixture page URL is invalid")
        }
        XCUIDevice.shared.system.open(url)
        try require(safari.wait(for: .runningForeground, timeout: 10),
                    "Safari did not open the initial fixture URL in the foreground")
        try waitForFixtureDocument(config.dappURL, replacing: previousDocument)
#else
        try open(config.dappURL)
#endif
        try require(safari.buttons["ethereum-connect"].waitForExistence(timeout: 20),
                    "The fixture dapp did not load in ordinary Safari")
#if os(iOS)
        let ordinaryDocument = safari.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "TabDocument?", "&IsPrivate=false&")
        ).firstMatch
        try require(ordinaryDocument.exists, "Safari did not open the initial fixture page in ordinary browsing")
        let address = safari.textFields.matching(NSPredicate(
            format: "identifier IN %@", ["URL", "TabBarItemTitle"]
        )).firstMatch
        try require(address.exists && address.frame.height > 0 && address.frame.midY < safari.frame.midY,
                    "Safari did not apply the expanded Top tab layout")
        attachEvidence("ios-initial-fixture-ready")
#endif
        try await allowFixtureWebsite(control: control, url: config.dappURL)
        try await control.waitForProviderReady()
#if os(iOS)
        if config.requiresApprovalDrain { try await retirePopupRequests() }
#endif
    }

    @MainActor
    private func connect(_ chain: String, control: SafariUIControl) async throws {
        try await perform("\(chain)-connect", control: control)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if try await control.hasResult("\(chain)-connect") { break }
            if approvalButton.exists || passwordIsVisible {
                try await approve(control: control)
                break
            }
#if os(iOS)
            try showPopup()
#endif
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await control.result("\(chain)-connect")
        safari.activate()
    }

    @MainActor
    private var approvalButton: XCUIElement {
#if os(macOS)
        helperIsRunning ? helper.buttons["safari.approval.approve"] : wallet.buttons["safari.approval.approve"]
#else
        popup.buttons.matching(NSPredicate(format: "label IN[c] %@", ["Connect", "OK", "Try Again", "Refresh", "Edit Fees"] as NSArray)).firstMatch
#endif
    }

    @MainActor
    private var passwordField: XCUIElement {
#if os(macOS)
        if helperIsRunning {
            let inHelper = helper.secureTextFields["safari.authentication.password"]
            if inHelper.exists { return inHelper }
        }
        return wallet.secureTextFields["safari.authentication.password"]
#else
        wallet.secureTextFields.firstMatch
#endif
    }

    @MainActor
    private var passwordIsVisible: Bool {
#if os(iOS)
        guard wallet.state == .runningForeground else { return false }
#endif
        return passwordField.exists
    }

#if os(macOS)
    @MainActor
    private func waitForPasswordField(in application: XCUIApplication? = nil, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let field = application?.secureTextFields["safari.authentication.password"] ?? passwordField
            if field.exists { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return (application?.secureTextFields["safari.authentication.password"] ?? passwordField).exists
    }
#endif

    @MainActor
    private func showApproval(control: SafariUIControl) async throws {
#if os(macOS)
        safari.activate()
        if helperIsRunning { helper.activate() }
#else
        try showPopup()
#endif
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try await authenticateIfPresent(control: control)
            if approvalButton.exists { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SafariUIFailure("Approval UI did not appear. Verify extension enablement, site permission, native messaging, and guest UI-automation consent.")
    }

    @MainActor
    private func pressApprove(control: SafariUIControl, doubleClick: Bool = false, accountAddress: String? = nil) async throws {
        try await showApproval(control: control)
#if os(macOS)
        let address = try accountAddress ?? control.selectedAccountAddress()
        try selectNativeApprovalAccount(address, required: accountAddress != nil)
#else
        let address = try accountAddress ?? control.selectedAccountAddress()
        let comparison = address.hasPrefix("0x") ? "label CONTAINS[c] %@" : "label CONTAINS %@"
        let account = popup.switches.matching(NSPredicate(format: comparison, address)).firstMatch
        if accountAddress != nil { try require(account.exists, "The requested wallet account is missing from the approval") }
        if account.exists {
            if try !switchState(account, description: "wallet account selection") {
                try revealPopupElement(account, "wallet account selection")
                try click(account, "wallet account selection")
            }
            try require(try switchState(account, description: "wallet account selection"),
                        "The requested wallet account did not become selected")
        }
        let cluster = popup.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Devnet")).firstMatch
        if !approvalButton.isEnabled, cluster.exists { try click(cluster, "finish the approval input") }
#endif
        let deadline = Date().addingTimeInterval(10)
        while !approvalButton.isEnabled && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(approvalButton.isEnabled,
                    "The approval button remains disabled after account or network selection")
#if os(macOS)
        if doubleClick { approvalButton.doubleClick() } else { approvalButton.click() }
#else
        let button = popup.buttons.matching(NSPredicate(format: "label IN[c] %@", ["Connect", "OK"] as NSArray)).firstMatch
        try revealPopupElement(button, "popup approval")
        _ = try waitForStableTarget(button, "Wallet approval decision", until: Date().addingTimeInterval(12))
        let title = button.label
        try require(["connect", "ok"].contains(title.lowercased()),
                    "The popup action \(title) restores or edits a review and cannot be treated as approval")
        if doubleClick { button.doubleTap() } else { button.tap() }
#endif
        try await authenticateIfPresent(control: control)
    }

    @MainActor
    private func approve(control: SafariUIControl, doubleClick: Bool = false, accountAddress: String? = nil) async throws {
        try await pressApprove(control: control, doubleClick: doubleClick, accountAddress: accountAddress)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try await authenticateIfPresent(control: control)
            try await Task.sleep(for: .milliseconds(100))
        }
        safari.activate()
#if os(iOS)
        if popupDone.exists { try closeApproval() }
#endif
    }

    @MainActor
    private func reject(control: SafariUIControl) async throws {
        try await showApproval(control: control)
#if os(macOS)
        try click(helper.buttons["safari.approval.reject"], "native rejection")
#else
        try revealPopupElement(popup.buttons["Cancel"], "popup rejection")
        try click(popup.buttons["Cancel"], "popup rejection")
#endif
        safari.activate()
    }

    @MainActor
    private func rejectIfNeeded(action: String, control: SafariUIControl) async throws {
#if os(macOS)
        if helperIsRunning { helper.activate() }
#else
        if !popup.exists { try showPopup() }
#endif
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if try await control.hasResult(action) {
                _ = try await control.result(action, success: false)
                return
            }
            if passwordIsVisible {
                try await authenticateIfPresent(control: control)
                continue
            }
#if os(macOS)
            let reject = helperIsRunning ? helper.buttons["safari.approval.reject"] : wallet.buttons["safari.approval.reject"]
#else
            let reject = popup.buttons["Cancel"]
#endif
            if reject.exists && reject.isEnabled {
                do {
#if os(iOS)
                    try revealPopupElement(reject, "rejection of the invalidated request")
#endif
                    if reject.isHittable {
                        try click(reject, "reject the invalidated request if it still needs a decision")
                        safari.activate()
                        _ = try await control.result(action, success: false)
                        return
                    }
                } catch {
                    guard try await control.hasResult(action) else { throw error }
                    _ = try await control.result(action, success: false)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The invalidated request neither completed nor exposed rejection controls")
    }

    @MainActor
    private func startHeldAuthentication(action: String, control: SafariUIControl) async throws {
        try await perform(action, control: control)
        try await pressApprove(control: control)
        try await control.waitForPoint("beforeAuthentication")
    }

    @MainActor
    private func authenticateIfPresent(control: SafariUIControl) async throws {
        guard passwordIsVisible else { return }
#if os(macOS)
        let app = helperIsRunning && helper.secureTextFields["safari.authentication.password"].exists ? helper : wallet
        let field = app.secureTextFields["safari.authentication.password"]
#else
        let app = wallet
        let field = passwordField
#endif
        app.activate()
        try click(field, "wallet password field")
        field.typeText("approval-fixture-password")
#if os(macOS)
        try click(app.buttons["safari.authentication.confirm"], "wallet password confirmation")
#else
        try click(app.buttons["OK"], "wallet password confirmation")
#endif
        let deadline = Date().addingTimeInterval(8)
#if os(macOS)
        while field.exists && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(!field.exists, "The wallet did not accept the fixture password")
#else
        while passwordIsVisible && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(!passwordIsVisible, "The wallet did not accept the fixture password")
#endif
    }

    @MainActor
    private func perform(_ action: String, control: SafariUIControl) async throws {
        try await control.markAction(action)
#if os(macOS)
        safari.activate()
#else
        if safari.state != .runningForeground { safari.activate() }
#endif
#if os(iOS)
        let switchAccount = popup.buttons["Switch Account"]
        if popupDone.exists && switchAccount.exists && switchAccount.isEnabled {
            try closeApproval()
        }
        if !popup.exists && !popupDone.exists { try dismissSafariMoreMenu() }
#endif
        try require(fixtureText(exactly: "Providers ready").waitForExistence(timeout: 15),
                    "The current fixture document did not initialize its providers")
#if os(macOS)
        let viewport = safari.windows.firstMatch.scrollViews.containing(.webView, identifier: nil).firstMatch
        try require(viewport.waitForExistence(timeout: 12), "Safari did not expose the fixture page viewport")
        let button = viewport.buttons[action]
#else
        guard let document = try fixtureDocumentIdentity() else {
            throw SafariUIFailure("Safari did not expose the current fixture document")
        }
        let page = fixtureWindow.webViews.containing(.staticText, identifier: document).firstMatch
        try require(page.waitForExistence(timeout: 12), "Safari did not expose the current fixture web view")
        let button = page.buttons[action]
#endif
        try require(button.waitForExistence(timeout: 15), "The fixture action \(action) is missing")
#if os(macOS)
        for _ in 0..<8 where !button.isHittable {
            let above = button.frame.midY < viewport.frame.midY
            viewport.scroll(byDeltaX: 0, deltaY: above ? 400 : -400)
        }
        try click(button, "fixture action \(action)")
#else
        try revealFixtureAction(button, in: page, documentIdentity: document, description: action)
        let frame = try waitForStableTarget(button, "fixture action \(action)", until: Date().addingTimeInterval(12))
        try require(page.exists && !popup.exists && !popupDone.exists && (try fixtureViewport(in: page)).contains(frame),
                    "The fixture action changed or became obscured before its tap")
        button.tap()
#endif
    }

#if os(iOS)
    @MainActor
    private func waitForStableFrame(_ description: String, until deadline: Date,
                                    frame: @MainActor () throws -> CGRect?) throws -> CGRect {
        var previous: CGRect?
        while Date() < deadline {
            if let current = try frame(), !current.isEmpty && !current.isNull && !current.isInfinite,
               current.minX.isFinite && current.minY.isFinite && current.width.isFinite && current.height.isFinite {
                if current == previous { return current }
                previous = current
            } else {
                previous = nil
            }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        throw SafariUIFailure("The \(description) did not expose stable, usable geometry")
    }

    @MainActor
    private func waitForStableTarget(_ element: XCUIElement, _ description: String, until deadline: Date) throws -> CGRect {
        try waitForStableFrame(description, until: deadline) {
            guard element.exists && element.isEnabled && element.isHittable else { return nil }
            return element.frame
        }
    }

    @MainActor
    private func fixtureViewport(in page: XCUIElement) throws -> CGRect {
        let bounds = page.frame.intersection(fixtureWindow.frame)
        try require(!bounds.isEmpty && !bounds.isNull && !bounds.isInfinite,
                    "The fixture web view has no visible frame")
        let chrome = fixtureWindow.otherElements["CapsuleViewController"]
        try require(chrome.exists, "Safari did not expose its browser chrome")
        var top = bounds.minY
        var bottom = bounds.maxY
        for region in chrome.children(matching: .other).allElementsBoundByIndex {
            let frame = region.frame.intersection(bounds)
            guard !frame.isEmpty && !frame.isNull && !frame.isInfinite,
                  frame.minX <= bounds.minX, frame.maxX >= bounds.maxX else { continue }
            if frame.minY <= bounds.minY { top = max(top, frame.maxY) }
            if frame.maxY >= bounds.maxY { bottom = min(bottom, frame.minY) }
        }
        try require(top > bounds.minY && bottom < bounds.maxY,
                    "Safari did not expose its top and bottom browser chrome boundaries")
        let viewport = CGRect(x: bounds.minX, y: top, width: bounds.width,
                              height: max(0, bottom - top)).insetBy(dx: 8, dy: 8)
        try require(!viewport.isEmpty && !viewport.isNull && !viewport.isInfinite,
                    "Safari's browser chrome leaves no unobscured fixture viewport")
        return viewport
    }

    @MainActor
    private func revealFixtureAction(_ button: XCUIElement, in page: XCUIElement, documentIdentity: String, description: String) throws {
        var actionButtonRightEdge: CGFloat?
        var scrollIndicatorOwner: XCUIElement?
        for attempt in 0...8 {
            try require(!popup.exists && !popupDone.exists, "The Wallet popup blocks the fixture action \(description)")
            try require(page.exists && button.exists, "The fixture document changed while revealing \(description)")
            let viewport = try fixtureViewport(in: page)
            let frame = button.frame
            try require(!frame.isEmpty && !frame.isNull && !frame.isInfinite,
                        "The fixture action \(description) has no usable frame")
            if viewport.contains(frame) && button.isHittable { return }
            guard attempt < 8 else { break }
            try require(frame.maxY > viewport.maxY || frame.minY < viewport.minY,
                        "The fixture action \(description) remains blocked inside its viewport")
            let rightmostButton: CGFloat
            if let cached = actionButtonRightEdge {
                rightmostButton = cached
            } else {
                let actions = page.buttons.allElementsBoundByIndex
                try require(!actions.isEmpty, "The fixture page has no action buttons to establish a safe scrolling corridor")
                var rightEdge = viewport.minX
                for action in actions {
                    let actionFrame = action.frame
                    try require(!actionFrame.isEmpty && !actionFrame.isNull && !actionFrame.isInfinite &&
                                actionFrame.minX.isFinite && actionFrame.maxX.isFinite &&
                                actionFrame.minY.isFinite && actionFrame.maxY.isFinite,
                                "A fixture action has no usable frame for safe scrolling")
                    rightEdge = max(rightEdge, actionFrame.maxX)
                }
                actionButtonRightEdge = rightEdge
                rightmostButton = rightEdge
            }
            let nativeOwner: XCUIElement
            if let cached = scrollIndicatorOwner {
                nativeOwner = cached
            } else {
                let owners = fixtureWindow.otherElements.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "TabDocument?"
                )).containing(.staticText, identifier: documentIdentity)
                try require(owners.count == 1, "Safari did not expose one native owner for the fixture document")
                let identifier = owners.firstMatch.identifier
                nativeOwner = fixtureWindow.otherElements.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
                scrollIndicatorOwner = nativeOwner
            }
            try require(nativeOwner.exists, "The fixture document's native scroll owner changed")
            let indicator = nativeOwner.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
            try require(indicator.exists, "Safari did not expose the fixture page's vertical scroll indicator")
            let indicatorFrame = indicator.frame
            try require(!indicatorFrame.isEmpty && !indicatorFrame.isNull && !indicatorFrame.isInfinite &&
                        indicatorFrame.minX.isFinite && indicatorFrame.maxX.isFinite &&
                        indicatorFrame.minY.isFinite && indicatorFrame.maxY.isFinite && viewport.intersects(indicatorFrame),
                        "Safari's vertical scroll indicator has no usable frame")
            let corridorLeft = max(viewport.minX + 12, rightmostButton + 12)
            let corridorRight = min(viewport.maxX - 12, indicatorFrame.minX - 12)
            try require(corridorRight - corridorLeft >= 16,
                        "The fixture page has no safe scrolling corridor between its actions and Safari's scroll indicator")
            let maximumDistance = viewport.height * 0.4
            let displacement = max(-maximumDistance, min(maximumDistance, frame.midY - viewport.midY))
            try require(displacement.isFinite && abs(displacement) >= 1,
                        "The fixture action has no usable scrolling displacement")
            let applicationFrame = safari.frame
            let origin = safari.coordinate(withNormalizedOffset: .zero)
            let x = (corridorLeft + corridorRight) / 2 - applicationFrame.minX
            let start = origin.withOffset(CGVector(dx: x,
                dy: viewport.midY + displacement / 2 - applicationFrame.minY))
            let end = origin.withOffset(CGVector(dx: x,
                dy: viewport.midY - displacement / 2 - applicationFrame.minY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        throw SafariUIFailure("The fixture action \(description) could not be fully revealed clear of Safari's browser chrome")
    }
#endif

    @MainActor
    private func enableExtension(control: SafariUIControl, profile: String? = nil) async throws {
#if os(macOS)
        if localSigning {
            openSafariSettings()
            let advanced = safari.buttons["Advanced"]
            try click(advanced, "Safari Advanced settings")
            let developer = safari.checkBoxes["ShowDevelopMenuCheckBox"]
            try setSwitch(developer, enabled: true, description: "Safari developer features")
            try click(safari.buttons["Developer"], "Safari Developer settings")
            let unsigned = safari.checkBoxes.matching(NSPredicate(format: "title ==[c] %@ OR label ==[c] %@", "Allow unsigned extensions", "Allow unsigned extensions")).firstMatch
            try require(unsigned.waitForExistence(timeout: 12), "Safari does not expose Allow unsigned extensions")
            if try !switchState(unsigned, description: "Allow unsigned extensions") {
                unsigned.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                    .withOffset(CGVector(dx: 9, dy: 0)).click()
                let sheet = safari.sheets.firstMatch
                let password = sheet.secureTextFields["Password"]
                if password.waitForExistence(timeout: 8) {
                    let prompt = sheet.staticTexts.allElementsBoundByIndex.map {
                        ($0.value as? String) ?? $0.label
                    }.joined(separator: " ").lowercased()
                    try require(prompt.contains("safari is trying to allow") && prompt.contains("unsigned extensions"),
                                "Safari presented an unexpected authentication request")
                    try click(password, "guest authorization for Safari unsigned extensions")
                    do {
                        try await control.post("stage-guest-credential", [:])
                        password.typeKey("v", modifierFlags: .command)
                        try click(sheet.buttons["OK"], "authorize unsigned extensions in the isolated guest")
                        try await control.post("clear-guest-credential", [:])
                    } catch {
                        try? await control.post("clear-guest-credential", [:])
                        throw error
                    }
                }
                let deadline = Date().addingTimeInterval(10)
                while try !switchState(unsigned, description: "Allow unsigned extensions"), Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try require(try switchState(unsigned, description: "Allow unsigned extensions"),
                            "Guest authorization did not enable Safari's unsigned extension support")
                if helperIsRunning { helper.terminate() }
                wallet.terminate()
                try await control.post("refresh-extension-registration", [:])
                wallet.launch()
                try require(try await waitForPasswordField(in: wallet, timeout: 12), "The containing wallet did not reopen after unsigned extensions were enabled")
                try await authenticateIfPresent(control: control)
                safari.activate()
            }
        }
#endif
        try await setExtensionEnabled(true, control: control, profile: profile, verifyingPreparation: true)
    }

    @MainActor
    private func setExtensionEnabled(_ enabled: Bool, control: SafariUIControl, profile: String? = nil,
                                     verifyingPreparation: Bool = false) async throws {
#if os(macOS)
        openSafariSettings()
        try click(safari.buttons["Extensions"], "Safari Extensions settings")
        let unsignedIdentifier = "org.lil.wallet.Safari (UNSIGNED)-checkbox"
        let predicate = localSigning ? NSPredicate(format: "identifier == %@", unsignedIdentifier)
            : NSPredicate(format: "value == %@", "Wallet")
        let rows = safari.tableRows.containing(predicate)
        let row = rows.firstMatch
        try require(row.waitForExistence(timeout: 12) && rows.count == 1,
                    "Safari did not expose exactly one installed Wallet extension row")
        let title = row.staticTexts.matching(NSPredicate(format: "value == %@", "Wallet")).firstMatch
        try click(title, "Wallet extension details")
        let checkbox = localSigning ? row.checkBoxes[unsignedIdentifier] : row.checkBoxes.firstMatch
        let currentlyEnabled = try switchState(checkbox, description: "Big Wallet extension")
        if enabled && activationMode == "prepared" && verifyingPreparation {
            try require(currentlyEnabled,
                        "The prepared VM's Wallet activation did not survive this run's installation or Safari restart")
        } else if enabled && activationMode == "interactive" && !currentlyEnabled {
            try await control.post("interactive-activation", ["phase": "waiting", "enabled": true])
            attachEvidence("macos-wallet-extension-awaiting-user")
            let deadline = Date().addingTimeInterval(120)
            let enabledPredicate = NSPredicate(format: "value == %@ OR value == %@", NSNumber(value: true), "1")
            let enabledCheckbox = row.checkBoxes.matching(localSigning
                ? NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "identifier == %@", unsignedIdentifier), enabledPredicate
                ])
                : enabledPredicate).firstMatch
            var observedEnabled = false
            while Date() < deadline {
                if enabledCheckbox.exists {
                    observedEnabled = true
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            try require(observedEnabled,
                        "Enable the checkbox beside Wallet in Safari's Extensions tab inside the VM and leave that tab open during the activation checkpoint")
            try await control.post("interactive-activation", ["phase": "observed", "enabled": true])
        } else {
            try setSwitch(checkbox, enabled: enabled, description: "Big Wallet extension", detectingSafariInterference: true)
        }
        attachEvidence("macos-wallet-extension-\(enabled ? "enabled" : "disabled")")
        closeSafariSettings()
#else
        let settings = try openIOSSafariSettings()
        try clickSettingsItem("Extensions", in: settings)
        try clickSettingsItem("Wallet", in: settings)
        attachEvidence("ios-wallet-extension-settings")
        let global = settings.switches["Allow Extension"]
        profilesConfigured = !global.exists
        if profilesConfigured {
            let name = profile ?? "Personal"
            let permission = settings.switches[name]
            try revealSettingsSwitch(permission, in: settings, description: "Big Wallet extension in \(name)")
            try setSwitch(permission, enabled: enabled, description: "Big Wallet extension in \(name)")
        } else {
            try setSwitch(global, enabled: enabled, description: "Big Wallet extension")
        }
        if enabled {
            let allSites = settings.cells["All Websites"]
            if allSites.exists {
                allSites.tap()
                try click(settings.cells["Allow"], "allow fixture website access")
                attachEvidence("ios-wallet-website-permission")
            }
        }
        if safari.state != .notRunning { safari.terminate() }
        safari.launch()
#endif
        extensionActivated = enabled
    }

    @MainActor
    private func allowFixtureWebsite(control: SafariUIControl, url: String) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if safari.staticTexts["Providers ready"].exists, try await control.providerIsReady() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if safari.staticTexts["Providers ready"].exists, try await control.providerIsReady() { return }
#if os(macOS)
        let identifier = "WebExtension-org.lil.wallet.Safari" + (localSigning ? " (UNSIGNED)" : "")
        try click(safari.windows.firstMatch.buttons[identifier], "Wallet website access")
        attachEvidence("macos-wallet-website-access-request")
        let permission = safari.buttons["Always Allow on This Website"]
        try require(permission.waitForExistence(timeout: 10),
                    "Safari did not expose the fixture website access confirmation")
        try click(permission, "allow Wallet on the fixture website")
        safari.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
#else
        try openWalletExtensionAction()
        let permission = safari.alerts.firstMatch
        try require(permission.waitForExistence(timeout: 10),
                    "The providers are unavailable and Safari did not request fixture website access")
        try grantFixtureWebsitePermission(permission)
        if popup.exists || popupDone.exists { try closeApproval() }
#endif
        try open(url)
        try require(safari.buttons["ethereum-connect"].waitForExistence(timeout: 20),
                    "The fixture dapp did not reload after website access was granted")
        try require(safari.staticTexts["Providers ready"].waitForExistence(timeout: 15),
                    "The fixture providers did not appear after website access was granted")
    }

    @MainActor
    private func setPrivateExtensionEnabled() throws {
#if os(macOS)
        openSafariSettings()
        try click(safari.buttons["Extensions"], "Safari Extensions settings")
        let extensionRow = safari.staticTexts.matching(NSPredicate(format: "label == %@", "Wallet")).firstMatch
        if extensionRow.exists { try click(extensionRow, "Wallet extension details") }
        let permission = safari.checkBoxes.matching(NSPredicate(format: "title CONTAINS[c] %@ OR label CONTAINS[c] %@", "Private Browsing", "Private Browsing")).firstMatch
        try setSwitch(permission, enabled: true, description: "Wallet extension access in Private Browsing")
        closeSafariSettings()
#else
        let settings = try openIOSSafariSettings()
        try clickSettingsItem("Extensions", in: settings)
        try clickSettingsItem("Wallet", in: settings)
        let permission = settings.switches.matching(NSPredicate(format: "label CONTAINS %@", "Private Browsing")).firstMatch
        try revealSettingsSwitch(permission, in: settings, description: "Wallet extension access in Private Browsing")
        try setSwitch(permission, enabled: true, description: "Wallet extension access in Private Browsing")
        if safari.state != .notRunning { safari.terminate() }
        safari.launch()
#endif
    }

    @MainActor
    private func open(_ value: String) throws {
        safari.activate()
        let previousDocument = try fixtureDocumentIdentity()
#if os(macOS)
        safari.typeKey("l", modifierFlags: .command)
        let address = safari.windows.firstMatch.textFields["WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"]
        try require(address.waitForExistence(timeout: 12) && address.isHittable,
                    "Safari did not expose its focused address field")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        try require(pasteboard.setString(value, forType: .string), "Could not stage the fixture URL on the guest clipboard")
        let pasteboardChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == pasteboardChange { pasteboard.clearContents() }
        }
        address.typeKey("v", modifierFlags: .command)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: address)
        try require(XCTWaiter.wait(for: [entered], timeout: 5) == .completed,
                    "Safari did not receive the exact fixture URL")
        address.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
#else
        if safari.textViews["TabOverview"].exists { try newTab() }
        let deadline = Date().addingTimeInterval(12)
        let address = fixtureWindow.textFields["URL"]
        let keyboard = safari.keyboards.firstMatch
        let addressControl = fixtureWindow.textFields["TabBarItemTitle"]
        let collapsedAddress = fixtureWindow.otherElements["TabBarItemTitle"]
        var didExpandAddress = false
        var didFocusAddress = false
        while Date() < deadline {
            dismissKeyboardIntroduction(in: safari)
            if address.exists && address.isHittable && keyboard.exists { break }
            guard Date() < deadline else { break }
            if !didFocusAddress && !address.exists && addressControl.exists && addressControl.isHittable {
                _ = try waitForStableTarget(addressControl, "Safari address control", until: deadline)
                addressControl.tap()
                didFocusAddress = true
            } else if !didExpandAddress && !didFocusAddress && !address.exists && collapsedAddress.exists && collapsedAddress.isHittable {
                _ = try waitForStableTarget(collapsedAddress, "collapsed Safari address control", until: deadline)
                collapsedAddress.tap()
                didExpandAddress = true
            } else {
                RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
            }
        }
        let focusedAddressFrame: @MainActor () -> CGRect? = {
            guard address.exists && address.isEnabled && address.isHittable && keyboard.exists else { return nil }
            return address.frame
        }
        _ = try waitForStableFrame("focused Safari address field", until: deadline, frame: focusedAddressFrame)
        let clear = safari.buttons["ClearTextButton"]
        if clear.exists && clear.isEnabled {
            let clearDeadline = Date().addingTimeInterval(12)
            _ = try waitForStableTarget(clear, "clear the Safari address field", until: clearDeadline)
            clear.tap()
            _ = try waitForStableFrame("cleared Safari address field", until: clearDeadline, frame: focusedAddressFrame)
        }
        address.typeText(value)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: address)
        try require(XCTWaiter.wait(for: [entered], timeout: 5) == .completed,
                    "Safari did not receive the exact fixture URL")
        let go = safari.keyboards.buttons["Go"]
        try click(go, "Safari keyboard Go button")
        try require(safari.keyboards.firstMatch.waitForNonExistence(timeout: 10),
                    "Safari did not dismiss its keyboard after navigation")
#endif
        try waitForFixtureDocument(value, replacing: previousDocument)
    }

    @MainActor
    private var fixtureWindow: XCUIElement { safari.windows.firstMatch }

    private var fixtureTextAttribute: String {
#if os(macOS)
        "value"
#else
        "label"
#endif
    }

    @MainActor
    private func fixtureText(_ element: XCUIElement) -> String? {
#if os(macOS)
        element.value as? String
#else
        element.label
#endif
    }

    @MainActor
    private func fixtureText(exactly value: String) -> XCUIElement {
        fixtureWindow.staticTexts.matching(NSPredicate(format: "%K == %@", fixtureTextAttribute, value)).firstMatch
    }

    @MainActor
    private var fixtureDocument: XCUIElement {
        fixtureWindow.staticTexts.matching(NSPredicate(format: "%K BEGINSWITH %@", fixtureTextAttribute, "Fixture document: ")).firstMatch
    }

    @MainActor
    private func fixtureDocumentIdentity() throws -> String? {
        let document = fixtureDocument
        guard document.exists else { return nil }
        guard let identity = fixtureText(document), identity.count > "Fixture document: ".count else {
            throw SafariUIFailure("Safari exposed an unreadable fixture document identity")
        }
        return identity
    }

    @MainActor
    private func reload(_ value: String) throws {
        safari.activate()
#if os(iOS)
        if popupDone.exists { try closeApproval() }
#endif
        guard let previousDocument = try fixtureDocumentIdentity() else {
            throw SafariUIFailure("Safari did not expose the fixture document before reload")
        }
#if os(macOS)
        safari.typeKey("r", modifierFlags: .command)
#else
        let reload = fixtureWindow.buttons["ReloadButton"]
        try click(reload, "reload the current Safari document")
#endif
        try waitForFixtureDocument(value, replacing: previousDocument)
    }

    @MainActor
    private func waitForFixtureDocument(_ value: String, replacing previousDocument: String?) throws {
        guard var origin = URLComponents(string: value), origin.scheme != nil, origin.host != nil else {
            throw SafariUIFailure("The fixture page URL is invalid")
        }
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        guard let expectedOrigin = origin.string else { throw SafariUIFailure("The fixture page origin is invalid") }
        try require(fixtureText(exactly: "Fixture origin: \(expectedOrigin)").waitForExistence(timeout: 20),
                    "Safari did not load the requested fixture origin \(expectedOrigin)")
        let freshDocument = fixtureWindow.staticTexts.matching(NSPredicate(
            format: "%K BEGINSWITH %@ AND %K != %@", fixtureTextAttribute, "Fixture document: ",
            fixtureTextAttribute, previousDocument ?? ""
        )).firstMatch
        try require(freshDocument.waitForExistence(timeout: 20),
                    "Safari did not load a fresh fixture document")
        guard let identity = fixtureText(freshDocument), identity.count > "Fixture document: ".count,
              identity != previousDocument else {
            throw SafariUIFailure("Safari did not expose a fresh fixture document identity")
        }
    }

    @MainActor
    private func newTab() throws {
        safari.activate()
#if os(macOS)
        safari.typeKey("t", modifierFlags: .command)
#else
        try openTabOverview()
        try click(safari.buttons["NewTabButton"], "new Safari tab")
        try require(safari.textViews["TabOverview"].waitForNonExistence(timeout: 10),
                    "Safari did not leave the tab overview after creating a tab")
#endif
    }

    @MainActor
    private func closeTab() throws {
        safari.activate()
#if os(macOS)
        safari.typeKey("w", modifierFlags: .command)
#else
        let tabs = safari.buttons["TabOverviewButton"]
        _ = try waitForStableTarget(tabs, "Safari tabs control", until: Date().addingTimeInterval(10))
        tabs.press(forDuration: 1)
        try click(safari.buttons["Close This Tab"], "close pending request tab")
#endif
    }

    @MainActor
    private func newPrivateTab() throws {
        safari.activate()
#if os(macOS)
        safari.typeKey("n", modifierFlags: [.command, .shift])
#else
        try dismissSafariMoreMenu()
        let tabs = safari.buttons["TabOverviewButton"]
        let collapsed = safari.otherElements["TabBarItemTitle"]
        if !tabs.exists, collapsed.exists { try click(collapsed, "expand Safari's tab controls") }
        _ = try waitForStableTarget(tabs, "Safari tabs control", until: Date().addingTimeInterval(10))
        tabs.press(forDuration: 1)
        attachEvidence("ios-private-tab-menu")
        try click(safari.buttons["New Private Tab"], "new private Safari tab")
        try dismissPrivateBrowsingIntroduction()
        try require(safari.textViews["TabOverview"].waitForNonExistence(timeout: 10),
                    "Safari did not leave the tab overview after creating a private tab")
        let privateDocument = safari.otherElements.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "TabDocument?", "&IsPrivate=true&")
        ).firstMatch
        try require(privateDocument.waitForExistence(timeout: 10), "Safari did not open a private tab")
        attachEvidence("ios-private-tab-ready")
#endif
    }

    @MainActor
    private func closeOwnedApprovalIfPresent() throws {
#if os(macOS)
        if !helperIsRunning { return }
        helper.activate()
        let windows = helper.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "safari.approval.window."))
        let identifiers = windows.allElementsBoundByIndex.map(\.identifier)
        for identifier in identifiers {
            let window = helper.windows[identifier]
            guard window.exists else { continue }
            try focusApprovalWindow(window)
            try click(window.buttons[XCUIIdentifierCloseWindow], "retire the interrupted request's approval window")
            try require(window.waitForNonExistence(timeout: 10), "The interrupted approval window did not close")
        }
#endif
    }

    @MainActor
    private func closeApproval() throws {
#if os(macOS)
        let close = helper.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        try click(close, "close approval window during authentication")
#else
        try click(popupDone, "dismiss the Wallet approval")
        try require(popup.waitForNonExistence(timeout: 10) && popupDone.waitForNonExistence(timeout: 10),
                    "Safari did not dismiss the extension popup")
#endif
    }

    @MainActor
    private func createAndOpenProfile(_ profile: String) throws {
#if os(macOS)
        openSafariSettings()
        try click(safari.buttons["Profiles"], "Safari Profiles settings")
        let create = safari.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "StartUsingProfilesButton", "Add Profile"
        )).firstMatch
        try click(create, "create isolated Safari profile")
        let form = safari.sheets.containing(.textField, identifier: "CreateProfileFormNameTextField").firstMatch
        let name = form.textFields["CreateProfileFormNameTextField"]
        try click(name, "Safari profile name")
        name.typeKey("a", modifierFlags: .command)
        name.typeText(profile)
        try require(name.value as? String == profile, "Safari did not receive the exact fixture profile name")
        try click(form.buttons["CreateProfileFormCreateProfileButton"], "save isolated Safari profile")
        try require(form.waitForNonExistence(timeout: 10), "Safari did not finish creating the isolated profile")
        closeSafariSettings()
        try click(safari.menuBars.menuBarItems["File"], "Safari File menu")
        let newWindowSubmenu = safari.menuItems["NewWindowSubmenuItem"]
        if newWindowSubmenu.exists { try click(newWindowSubmenu, "Safari profile window submenu") }
        try click(safari.menuItems["New \(profile) Window"], "open isolated Safari profile")
#else
        let settings = try openIOSSafariSettings()
        try clickSettingsItem("New Profile", in: settings)
        try click(settings.textFields["Name"], "Safari profile name")
        settings.textFields["Name"].typeText(profile)
        try click(settings.buttons["Done"], "save isolated Safari profile")
        profilesConfigured = true
        safari.activate()
        try selectSafariProfile(profile)
        attachEvidence("ios-created-profile-selected")
        try restoreOrdinaryBrowsing()
        try newTab()
#endif
    }

#if os(macOS)
    private func accountHomeDirectory() throws -> URL {
        let recommended = sysconf(_SC_GETPW_R_SIZE_MAX)
        let capacity = recommended > 0 ? min(max(Int(recommended), 16_384), 1_048_576) : 16_384
        var buffer = [CChar](repeating: 0, count: capacity)
        return try buffer.withUnsafeMutableBufferPointer { storage in
            guard let base = storage.baseAddress else { throw SafariUIFailure("Guest account lookup has no storage") }
            var account = passwd()
            var result: UnsafeMutablePointer<passwd>?
            let status = getpwuid_r(getuid(), &account, base, storage.count, &result)
            guard status == 0, result != nil, account.pw_uid == getuid(), let directory = account.pw_dir else {
                throw SafariUIFailure("Unable to resolve the guest account home directory (status \(status))")
            }
            let path = String(cString: directory)
            guard path.hasPrefix("/") else { throw SafariUIFailure("The guest account home directory is not absolute") }
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        }
    }

    @MainActor
    private func configureApplications(config: SafariUIConfiguration, runID: String) throws {
        guard let walletPath = config.walletApplicationPath, let helperPath = config.helperApplicationPath,
              walletPath.hasPrefix("/"), helperPath.hasPrefix("/") else {
            throw SafariUIFailure("macOS Safari tests require the run-owned installed application paths")
        }
        let walletURL = URL(fileURLWithPath: walletPath, isDirectory: true)
        let helperURL = URL(fileURLWithPath: helperPath, isDirectory: true)
        let accountHome = try accountHomeDirectory()
        let root = accountHome
            .appendingPathComponent("Applications/BigWalletSafariVM/\(runID)", isDirectory: true)
        let configuration = URL(fileURLWithPath: config.fixtureRoot).lastPathComponent
        let stages = configuration == "Debug" ? ["safari.macos.debug"] : ["safari.macos.release", "safari.soak-macos.release"]
        let candidates = config.activationMode == "prepared"
            ? [accountHome.appendingPathComponent("Applications/BigWalletSafariVM/Prepared/Big Wallet.app", isDirectory: true).path]
            : stages.map { root.appendingPathComponent($0, isDirectory: true).appendingPathComponent("Big Wallet.app", isDirectory: true).path }
        let expectedHelper = walletURL.appendingPathComponent("Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app", isDirectory: true)
        guard candidates.contains(walletPath) else {
            throw SafariUIFailure("Installed wallet path mismatch: actual=\(walletPath), expected=\(candidates), accountHome=\(accountHome.path), runnerHome=\(FileManager.default.homeDirectoryForCurrentUser.path)")
        }
        guard walletURL.standardizedFileURL.path == walletPath, walletURL.resolvingSymlinksInPath().path == walletPath,
              helperURL.standardizedFileURL.path == helperPath, helperURL.resolvingSymlinksInPath().path == helperPath else {
            throw SafariUIFailure("Installed application paths are not canonical: wallet=\(walletPath), resolvedWallet=\(walletURL.resolvingSymlinksInPath().path), helper=\(helperPath), resolvedHelper=\(helperURL.resolvingSymlinksInPath().path)")
        }
        guard helperURL == expectedHelper else {
            throw SafariUIFailure("Installed helper path mismatch: actual=\(helperPath), expected=\(expectedHelper.path)")
        }
        let walletIdentifier = Bundle(url: walletURL)?.bundleIdentifier
        let helperIdentifier = Bundle(url: helperURL)?.bundleIdentifier
        guard walletIdentifier == "org.lil.wallet", helperIdentifier == "org.lil.wallet.ambient" else {
            throw SafariUIFailure("Installed application identities are invalid: wallet=\(walletIdentifier ?? "missing") at \(walletPath), helper=\(helperIdentifier ?? "missing") at \(helperPath)")
        }
        walletApplication = XCUIApplication(url: walletURL)
        helperApplication = XCUIApplication(url: helperURL)
        helperApplicationURL = helperURL
    }

    @MainActor
    private func approvalWindowIdentifier(excluding previous: Set<String>) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            guard helperIsRunning else {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            let windows = helper.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "safari.approval.window."))
            if let window = windows.allElementsBoundByIndex.first(where: { !previous.contains($0.identifier) }) {
                return window.identifier
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The native request did not create an independently identifiable approval window")
    }

    @MainActor
    private func authenticate(window: XCUIElement) throws {
        try focusApprovalWindow(window)
        let password = window.secureTextFields["safari.authentication.password"]
        try click(password, "password sheet belonging to the selected request")
        password.typeText("approval-fixture-password")
        try click(window.buttons["safari.authentication.confirm"], "authenticate only the selected request")
    }

    @MainActor
    private func focusApprovalWindow(_ window: XCUIElement) throws {
        helper.activate()
        try require(window.waitForExistence(timeout: 12), "The selected approval window no longer exists")
        let frame = window.frame
        try require(!frame.isEmpty && frame.minX.isFinite && frame.minY.isFinite,
                    "The selected approval window has no visible frame")
        let identifier = window.identifier
        let otherFrames = helper.windows.allElementsBoundByIndex
            .filter { $0.identifier != identifier }
            .flatMap { other in [other.frame] + other.sheets.allElementsBoundByIndex.map(\.frame) }
        let titlebarPoints = [frame.midX, frame.minX + 12, frame.maxX - 12].map {
            CGPoint(x: $0, y: frame.minY + 4)
        }
        guard let point = titlebarPoints.first(where: { point in !otherFrames.contains { $0.contains(point) } }) else {
            throw SafariUIFailure("The selected approval window has no exposed title bar: target=\(frame), otherWindowsAndSheets=\(otherFrames)")
        }
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).click()
    }

    @MainActor
    private func selectNativeApprovalAccount(_ address: String, required: Bool) throws {
        let application = helperIsRunning && helper.buttons["safari.approval.approve"].exists ? helper : wallet
        let table = application.tables["safari.approval.accounts"]
        guard table.exists else {
            try require(!required, "The requested account selection screen is missing")
            return
        }
        let normalizedAddress = address.hasPrefix("0x") ? address.lowercased() : address
        let selectedIdentifier = "safari.approval.account.\(normalizedAddress).selected"
        let account = table.staticTexts.matching(NSPredicate(format: "identifier IN %@", [
            selectedIdentifier, "safari.approval.account.\(normalizedAddress).unselected",
        ])).firstMatch
        if !account.exists || !account.isHittable {
            table.scroll(byDeltaX: 0, deltaY: 10_000)
            for _ in 0..<8 {
                if account.exists && account.isHittable { break }
                table.scroll(byDeltaX: 0, deltaY: -250)
            }
        }
        try require(account.exists && account.isHittable,
                    "The requested wallet account could not be revealed in the approval")
        if account.identifier != selectedIdentifier {
            try click(account, "fixture account selection")
        }
        try require(table.staticTexts[selectedIdentifier].waitForExistence(timeout: 5),
                    "The requested wallet account did not become selected before approval")
    }

    @MainActor private func openSafariSettings() {
        safari.activate()
        safari.typeKey(",", modifierFlags: .command)
    }

    @MainActor private func closeSafariSettings() {
        safari.typeKey("w", modifierFlags: .command)
    }
#else
    @MainActor
    private func openIOSSettings() throws -> XCUIApplication {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        dismissKeyboardIntroduction(in: settings)
        let search = settings.searchFields.firstMatch
        if search.exists, let query = search.value as? String,
           !query.isEmpty, query != "Search", settings.buttons["close"].exists {
            settings.buttons["close"].tap()
        }
        for _ in 0..<8 {
            let back = settings.navigationBars.buttons.firstMatch
            guard back.exists, ["Settings", "Apps", "Safari", "Extensions", "Wallet", "Accessibility", "Motion", "Back"].contains(back.label) else { break }
            back.tap()
        }
        return settings
    }

    @MainActor
    private func configureReducedMotion() async throws {
        let settings = try openIOSSettings()
        try clickSettingsItem("Accessibility", in: settings)
        try clickSettingsItem("Motion", in: settings)
        let reduceMotion = settings.switches.matching(NSPredicate(format: "label == %@", "Reduce Motion")).firstMatch
        try revealSettingsSwitch(reduceMotion, in: settings, description: "Reduce Motion")
        try setSwitch(reduceMotion, enabled: true, description: "Reduce Motion")
        let crossFade = settings.switches["REDUCE_MOTION_REDUCE_SLIDE_ANIMATIONS"]
        try revealSettingsSwitch(crossFade, in: settings, description: "Prefer Cross-Fade Transitions")
        try setSwitch(crossFade, enabled: true, description: "Prefer Cross-Fade Transitions")
        let deadline = Date().addingTimeInterval(5)
        while (!UIAccessibility.isReduceMotionEnabled || !UIAccessibility.prefersCrossFadeTransitions), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(UIAccessibility.isReduceMotionEnabled && UIAccessibility.prefersCrossFadeTransitions,
                    "The simulator did not apply Reduce Motion and Prefer Cross-Fade Transitions")
        attachEvidence("ios-reduce-motion-enabled")
        settings.terminate()
    }

    @MainActor
    private func configureSafariTabLayout() throws {
        let settings = try openIOSSafariSettings()
        let layout = settings.cells["SEARCH_POSITION"]
        let top = layout.staticTexts["Top"]
        var revealed = false
        for attempt in 0...12 {
            let applicationFrame = settings.frame
            let viewportTop = settings.navigationBars.firstMatch.frame.maxY + 12
            var viewportBottom = applicationFrame.maxY - 50
            let search = settings.searchFields.firstMatch
            if search.exists && search.frame.height > 0 && search.frame.minY > viewportTop {
                viewportBottom = min(viewportBottom, search.frame.minY - 12)
            }
            let viewport = CGRect(x: applicationFrame.minX + 8, y: viewportTop,
                                  width: applicationFrame.width - 16, height: viewportBottom - viewportTop)
            try require(!viewport.isEmpty && !viewport.isNull && !viewport.isInfinite,
                        "Safari Settings did not expose a usable layout viewport")
            let layoutFrame = layout.exists ? layout.frame : nil
            let topFrame = top.exists ? top.frame : nil
            let validTop = layoutFrame.map { cell in
                topFrame.map { label in
                    !cell.isEmpty && !cell.isNull && !cell.isInfinite &&
                    !label.isEmpty && !label.isNull && !label.isInfinite && cell.contains(label)
                } ?? false
            } ?? false
            if validTop, let topFrame, viewport.contains(topFrame), top.isHittable {
                revealed = true
                break
            }
            guard attempt < 12 else { break }
            let target = validTop ? topFrame : layoutFrame
            let maximumDistance = viewport.height * 0.4
            let displacement: CGFloat
            if let target, !target.isEmpty && !target.isNull && !target.isInfinite {
                displacement = max(-maximumDistance, min(maximumDistance, target.midY - viewport.midY))
                try require(abs(displacement) >= 1,
                            "Safari Settings exposed a blocked Top tab layout option")
            } else {
                displacement = maximumDistance
            }
            let origin = settings.coordinate(withNormalizedOffset: .zero)
            let x = viewport.maxX - 4 - applicationFrame.minX
            let start = origin.withOffset(CGVector(dx: x,
                dy: viewport.midY + displacement / 2 - applicationFrame.minY))
            let end = origin.withOffset(CGVector(dx: x,
                dy: viewport.midY - displacement / 2 - applicationFrame.minY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        try require(revealed, "Safari Settings did not reveal the Top tab layout option")
        top.tap()
        attachEvidence("ios-safari-top-tab-layout")
        settings.terminate()
    }

    @MainActor
    private func openIOSSafariSettings() throws -> XCUIApplication {
        let settings = try openIOSSettings()
        try clickSettingsItem("Apps", in: settings)
        attachEvidence("ios-settings-apps")
        try clickSettingsItem("Safari", in: settings)
        attachEvidence("ios-settings-safari")
        return settings
    }

    @MainActor
    private func revealSettingsSwitch(_ element: XCUIElement, in settings: XCUIApplication, description: String) throws {
        for _ in 0..<8 {
            if element.exists && element.isHittable { break }
            settings.tables.firstMatch.swipeUp()
        }
        try require(element.exists && element.isHittable, "Settings did not reveal \(description)")
    }

    @MainActor
    private func clickSettingsItem(_ label: String, in settings: XCUIApplication) throws {
        for _ in 0..<12 {
            let item: XCUIElement
            if label == "Safari" { item = settings.buttons["com.apple.mobilesafari"] }
            else if label == "Extensions" { item = settings.cells["WEB_EXTENSIONS"] }
            else if label == "Wallet" { item = settings.buttons["org.lil.wallet.Safari"] }
            else if label == "New Profile" { item = settings.cells["NEW_PROFILE"] }
            else {
                let button = settings.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
                item = button.exists ? button : settings.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
            }
            let top = settings.navigationBars.firstMatch.exists ? settings.navigationBars.firstMatch.frame.maxY + 12 : settings.frame.minY + 80
            var bottom = settings.frame.maxY - 50
            let search = settings.searchFields.firstMatch
            if search.exists && search.frame.height > 0 && search.frame.minY > top {
                bottom = min(bottom, search.frame.minY - 12)
            }
            if item.exists {
                let frame = item.frame
                guard frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite else { continue }
                if frame.width <= 0 || frame.height <= 0 { settings.swipeUp(); continue }
                if frame.midY >= top && frame.midY <= bottom && settings.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    item.tap()
                    if settings.navigationBars[label].waitForExistence(timeout: 5) { return }
                }
                if frame.midY < top { settings.swipeDown(); continue }
            }
            settings.swipeUp()
        }
        throw SafariUIFailure("Settings did not navigate to the documented \(label) page")
    }

    @MainActor
    private func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let keyboard = app.otherElements["UIContinuousPathIntroductionView"]
        let keyboardContinue = keyboard.buttons["Continue"]
        if keyboardContinue.exists && keyboardContinue.isHittable { keyboardContinue.tap() }
        let search = app.scrollViews["UniversalSearchFirstTimeExperienceView"]
        let searchContinue = search.buttons["Continue"]
        if searchContinue.exists && searchContinue.isHittable { searchContinue.tap() }
    }

    @MainActor
    private func dismissStartPageExtensionDiscovery() throws {
        let window = fixtureWindow
        let startPage = window.collectionViews["StartPageCollectionView"]
        let startPageExists = startPage.exists
        if startPageExists { attachEvidence("ios-start-page-inspection") }
        let card = startPage.cells["onboardingItemIdentifierContent-ExtensionsDiscovery"]
        let cardExists = card.exists
        let menu = window.otherElements.matching(NSPredicate(
            format: "identifier IN %@", ["MoreMenu", "TabBarMoreMenu"]
        )).firstMatch
        guard safari.state == .runningForeground, !window.textViews["TabOverview"].exists,
              !popup.exists, !popupDone.exists, !safari.keyboards.firstMatch.exists,
              !safari.alerts.firstMatch.exists, !window.sheets.firstMatch.exists, !menu.exists else {
            print("Safari Start Page Extensions discovery: another surface is active")
            return
        }
        guard startPageExists else {
            print("Safari Start Page Extensions discovery: Start Page is absent")
            return
        }
        guard cardExists else {
            print("Safari Start Page Extensions discovery: card is absent")
            return
        }
        let buttons = card.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "close", "close"))
        try require(buttons.count == 1, "Safari's Extensions discovery card has no unambiguous close button")
        let close = buttons.firstMatch
        let visible = startPage.frame.intersection(window.frame)
        let cardFrame = card.frame
        let closeFrame = close.frame
        guard !visible.isEmpty && !visible.isNull && !visible.isInfinite &&
              cardFrame.width > 0 && cardFrame.height > 0 && closeFrame.width > 0 && closeFrame.height > 0 &&
              visible.contains(closeFrame) && cardFrame.contains(closeFrame) else {
            print("Safari Start Page Extensions discovery: close button is outside its visible card bounds")
            return
        }
        guard close.isHittable else {
            print("Safari Start Page Extensions discovery: close button is not hittable")
            return
        }
        print("Safari Start Page Extensions discovery: visible close button found")
        close.tap()
        try require(card.waitForNonExistence(timeout: 10),
                    "Safari did not dismiss its Extensions discovery card")
        attachEvidence("ios-start-page-extension-discovery-dismissed")
    }

    @MainActor
    private func dismissPrivateBrowsingIntroduction() throws {
        let introduction = safari.otherElements["TurnOnLockedPrivateBrowsingView"]
        if introduction.waitForExistence(timeout: 2) {
            try click(introduction.buttons["NotNowButton"], "continue without enabling Locked Private Browsing")
            try require(introduction.waitForNonExistence(timeout: 10), "Safari did not dismiss its Locked Private Browsing introduction")
        }
    }

    @MainActor
    private func dismissSafariMoreMenu() throws {
        let window = fixtureWindow
        let menu = window.otherElements.matching(
            NSPredicate(format: "identifier IN %@", ["MoreMenu", "TabBarMoreMenu"])
        ).firstMatch
        guard menu.exists else { return }
        let windowFrame = window.frame
        let usableFrame: (CGRect) -> Bool = { frame in
            !frame.isEmpty && !frame.isNull && !frame.isInfinite &&
                frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
        }
        let contentFrame: @MainActor () throws -> CGRect = {
            let content = menu.collectionViews
            try self.require(content.count == 1, "Safari's open More menu has no unambiguous content region")
            var frame = content.firstMatch.frame.intersection(menu.frame).intersection(windowFrame)
            for ancestor in menu.otherElements.containing(.collectionView, identifier: nil).allElementsBoundByIndex {
                frame = frame.intersection(ancestor.frame)
            }
            try self.require(usableFrame(frame), "Safari's open More menu has no visible content bounds")
            return frame
        }
        let menuFrame = try waitForStableFrame("Safari More menu", until: Date().addingTimeInterval(10)) {
            try contentFrame()
        }
        let interior = windowFrame.insetBy(dx: 12, dy: 12)
        try require(usableFrame(interior) && usableFrame(menuFrame) && windowFrame.intersects(menuFrame),
                    "Safari's open More menu has no usable dismissal geometry")
        let excluded = menuFrame.insetBy(dx: -8, dy: -8)
        var horizontalGaps: [(lower: CGFloat, upper: CGFloat)] = [
            (lower: max(interior.minX, excluded.maxX), upper: interior.maxX),
            (lower: interior.minX, upper: min(interior.maxX, excluded.minX)),
        ]
        horizontalGaps.removeAll { gap in gap.upper - gap.lower < 16 }
        horizontalGaps.sort { first, second in
            let firstWidth = first.upper - first.lower
            let secondWidth = second.upper - second.lower
            return firstWidth > secondWidth
        }
        var verticalGaps: [(lower: CGFloat, upper: CGFloat)] = [
            (lower: max(interior.minY, excluded.maxY), upper: interior.maxY),
            (lower: interior.minY, upper: min(interior.maxY, excluded.minY)),
        ]
        verticalGaps.removeAll { gap in gap.upper - gap.lower < 16 }
        verticalGaps.sort { first, second in
            let firstHeight = first.upper - first.lower
            let secondHeight = second.upper - second.lower
            return firstHeight > secondHeight
        }
        let point: CGPoint
        if let gap = horizontalGaps.first {
            point = CGPoint(x: (gap.lower + gap.upper) / 2, y: interior.midY)
        } else if let gap = verticalGaps.first {
            point = CGPoint(x: interior.midX, y: (gap.lower + gap.upper) / 2)
        } else {
            throw SafariUIFailure("Safari's open More menu leaves no safe outside dismissal point")
        }
        guard menu.exists else { return }
        let currentMenuFrame = try contentFrame()
        try require(window.frame == windowFrame && usableFrame(currentMenuFrame) && interior.contains(point) &&
                    !currentMenuFrame.insetBy(dx: -8, dy: -8).contains(point),
                    "Safari's More menu changed before its outside dismissal tap")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - windowFrame.minX, dy: point.y - windowFrame.minY)).tap()
        try require(menu.waitForNonExistence(timeout: 10), "Safari did not dismiss its open More menu")
    }

    @MainActor
    private func openTabOverview() throws {
        try dismissSafariMoreMenu()
        let overview = safari.textViews["TabOverview"]
        if overview.exists { return }
        let tabs = safari.buttons["TabOverviewButton"]
        let collapsed = safari.otherElements["TabBarItemTitle"]
        if !tabs.exists, collapsed.exists { try click(collapsed, "expand Safari's tab controls") }
        try click(tabs, "Safari tabs")
        try require(overview.waitForExistence(timeout: 10), "Safari did not present its tab overview")
    }

    @MainActor
    private func selectSafariProfile(_ profile: String) throws {
        try openTabOverview()
        try click(safari.buttons["MoreEditOptionsButton"], "Safari profile menu")
        let switcher = safari.buttons["ProfileSwitcher"]
        try require(switcher.waitForExistence(timeout: 10), "Safari did not expose its profile switcher")
        if switcher.label != "Profile, \(profile)" {
            try click(switcher, "Safari profile selection")
            let menu = safari.otherElements["MoreMenu"]
            let profiles = menu.collectionViews
            try require(profiles.count == 1, "Safari did not expose one profile list")
            let option = menu.buttons["ProfileSwitcher-\(profile)"]
            for _ in 0..<8 {
                if option.exists && option.isHittable { break }
                let applicationFrame = safari.frame
                var visible = profiles.firstMatch.frame.intersection(applicationFrame)
                for ancestor in menu.otherElements.containing(.collectionView, identifier: nil).allElementsBoundByIndex {
                    visible = visible.intersection(ancestor.frame)
                }
                try require(!visible.isNull && !visible.isInfinite && visible.width > 0 && visible.height > 0,
                            "Safari's profile list has no visible scrolling area")
                let upward = option.exists ? option.frame.midY >= visible.midY : profile != "Personal"
                let origin = safari.coordinate(withNormalizedOffset: .zero)
                let start = origin.withOffset(CGVector(dx: visible.midX - applicationFrame.minX,
                    dy: visible.minY - applicationFrame.minY + visible.height * (upward ? 0.8 : 0.2)))
                let end = origin.withOffset(CGVector(dx: visible.midX - applicationFrame.minX,
                    dy: visible.minY - applicationFrame.minY + visible.height * (upward ? 0.2 : 0.8)))
                start.press(forDuration: 0.1, thenDragTo: end)
            }
            try click(option, "select Safari profile \(profile)")
        }
        try dismissSafariMoreMenu()
    }

    @MainActor
    private func restoreOrdinaryBrowsing(profile: String? = nil) throws {
        if safari.otherElements["TurnOnLockedPrivateBrowsingView"].exists { try dismissPrivateBrowsingIntroduction() }
        try dismissSafariMoreMenu()
        let overview = safari.textViews["TabOverview"]
        if let profile { try selectSafariProfile(profile) }
        if !overview.exists {
            let ordinaryDocument = safari.otherElements.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@", "TabDocument?", "&IsPrivate=false&")
            ).firstMatch
            if ordinaryDocument.exists { return }
            try openTabOverview()
        }
        try require(overview.waitForExistence(timeout: 10), "Safari did not expose its browsing mode selection")
        let ordinaryGroups = safari.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label != %@", "CapsuleTabGroup", "Private, Tab Group")
        )
        try require(ordinaryGroups.count == 1, "Safari did not expose one unambiguous ordinary tab group")
        let ordinary = ordinaryGroups.firstMatch
        if !ordinary.isSelected { try click(ordinary, "return to ordinary Safari browsing") }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: ordinary)
        try require(XCTWaiter.wait(for: [selected], timeout: 10) == .completed,
                    "Safari did not select its ordinary tab group")
    }

    @MainActor
    private func revealPopupElement(_ element: XCUIElement, _ description: String) throws {
        try require(element.waitForExistence(timeout: 10), "Missing \(description)")
        for _ in 0..<8 {
            try require(popup.exists && element.exists, "The popup closed or changed while revealing \(description)")
            if element.isHittable { return }
            let applicationFrame = safari.frame
            var viewport = popup.frame.intersection(applicationFrame)
            let navigation = safari.navigationBars["Wallet"]
            if navigation.exists {
                let top = max(viewport.minY, navigation.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            let scrollIndicator = popup.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar")).firstMatch
            if scrollIndicator.exists {
                viewport = viewport.intersection(CGRect(x: viewport.minX, y: scrollIndicator.frame.minY,
                    width: viewport.width, height: scrollIndicator.frame.height))
            }
            try require(!viewport.isEmpty && !viewport.isNull && !viewport.isInfinite,
                        "The popup has no visible scrolling area for \(description)")
            let previousFrame = element.frame
            let upward: Bool
            if previousFrame.minY < viewport.minY {
                upward = false
            } else if previousFrame.maxY > viewport.maxY {
                upward = true
            } else {
                let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
                try require(XCTWaiter.wait(for: [hittable], timeout: 3) == .completed,
                            "The visible \(description) remains blocked in the popup")
                return
            }
            let scrollThumb = scrollIndicator.children(matching: .other).firstMatch
            try require(scrollIndicator.exists && scrollThumb.exists,
                        "The popup has no outer scroll gutter for \(description)")
            let gutter = scrollThumb.frame.intersection(viewport)
            try require(!gutter.isEmpty && !gutter.isNull && !gutter.isInfinite,
                        "The popup has no visible outer scroll gutter for \(description)")
            let origin = safari.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: gutter.midX - applicationFrame.minX,
                dy: viewport.minY - applicationFrame.minY + viewport.height * (upward ? 0.8 : 0.2)))
            let end = origin.withOffset(CGVector(dx: gutter.midX - applicationFrame.minX,
                dy: viewport.minY - applicationFrame.minY + viewport.height * (upward ? 0.2 : 0.8)))
            start.press(forDuration: 0.1, thenDragTo: end)
            try require(popup.exists && element.exists, "The popup closed or changed while scrolling to \(description)")
            let currentFrame = element.frame
            let progressed = upward ? currentFrame.minY < previousFrame.minY : currentFrame.maxY > previousFrame.maxY
            try require(element.isHittable || progressed,
                        "The popup did not scroll toward \(description)")
        }
        try require(popup.exists && element.exists && element.isHittable,
                    "The popup could not scroll \(description) into view")
    }

    @MainActor
    private func restoreInterruptedReview() async throws {
        let title = approvalButton.label.lowercased()
        guard ["refresh", "try again"].contains(title) else { return }
        try click(approvalButton, "restore the interrupted request review")
        let decision = popup.buttons.matching(NSPredicate(format: "label IN[c] %@", ["Connect", "OK"] as NSArray)).firstMatch
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if decision.exists && decision.isEnabled { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The recovery action did not restore a review with an enabled approval decision")
    }

    @MainActor
    private func retirePopupRequests() async throws {
        try showPopup()
        let deadline = Date().addingTimeInterval(15)
        var refreshed = false
        while Date() < deadline {
            if !popup.exists { try showPopup() }
            let reject = popup.buttons["Cancel"]
            if reject.exists && reject.isEnabled {
                try revealPopupElement(reject, "rejection of the retired document's request")
                try click(reject, "reject the request from the retired document")
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            if popup.buttons["Switch Account"].exists {
                try closeApproval()
                return
            }
            let refresh = popup.buttons["Refresh"]
            if !refreshed && !reject.exists && popup.staticTexts["Failed to load"].exists && refresh.exists && refresh.isEnabled {
                try revealPopupElement(refresh, "refresh the failed popup queue")
                try click(refresh, "refresh the failed popup queue")
                refreshed = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        attachEvidence("retired-popup-not-idle")
        throw SafariUIFailure("The popup retained approvals from a retired document")
    }

    @MainActor
    private func showPopup() throws {
        try openWalletExtensionAction()
        let permission = safari.alerts.firstMatch
        if permission.exists { try grantFixtureWebsitePermission(permission) }
        _ = try waitForStableFrame("Wallet extension popup", until: Date().addingTimeInterval(12)) {
            self.popup.exists && self.popupDone.exists ? self.popup.frame : nil
        }
    }

    @MainActor
    private func grantFixtureWebsitePermission(_ permission: XCUIElement) throws {
        guard let activeDappURL, let host = URL(string: activeDappURL)?.host, host == "127.0.0.1" else {
            throw SafariUIFailure("The fixture website permission has no expected loopback host")
        }
        try require(permission.label == "“Wallet” would like to access \(host).",
                    "Safari presented an unexpected website permission request")
        attachEvidence("ios-fixture-website-access-request")
        try click(permission.buttons.matching(identifier: "AllowForOneDayButton").firstMatch,
                  "allow Wallet on the isolated fixture website")
        try require(permission.waitForNonExistence(timeout: 10), "Safari did not dismiss its website permission request")
        attachEvidence("ios-fixture-website-access-granted")
    }

    @MainActor
    private func openWalletExtensionAction() throws {
        let menu = safari.buttons["MoreMenuButton"]
        let pageMenu = safari.otherElements["TabBarMoreMenu"]
        let deadline = Date().addingTimeInterval(15)
        var openedMenu = false
        var expandedAddress = false
        while Date() < deadline {
            if popup.waitForExistence(timeout: 1) { return }
            if popupDone.exists {
                try require(popup.waitForExistence(timeout: 12), "Safari presented Wallet popup controls without its extension content")
                return
            }
            if pageMenu.exists {
                openedMenu = true
                break
            }
            let collapsedAddress = safari.otherElements["TabBarItemTitle"]
            if !expandedAddress, !menu.exists, collapsedAddress.exists && collapsedAddress.isHittable {
                if popup.exists { return }
                if popupDone.exists { continue }
                _ = try waitForStableTarget(collapsedAddress, "collapsed Safari address control", until: deadline)
                collapsedAddress.tap()
                expandedAddress = true
            }
            if popup.exists { return }
            if popupDone.exists {
                try require(popup.waitForExistence(timeout: 12), "Safari presented Wallet popup controls without its extension content")
                return
            }
            if pageMenu.exists {
                openedMenu = true
                break
            }
            guard menu.exists && menu.isHittable else { continue }
            _ = try waitForStableTarget(menu, "Safari Page Menu control", until: deadline)
            menu.tap()
            openedMenu = true
            break
        }
        try require(openedMenu, "Safari presented neither its Wallet popup nor an available Page Menu")
        if popup.exists { return }
        let selectionDeadline = Date().addingTimeInterval(12)
        do {
            while Date() < selectionDeadline {
                if popup.exists { return }
                let extensionButton = pageMenu.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wallet")).firstMatch
                let extensions = pageMenu.buttons["Extensions"]
                if pageMenu.exists && (extensionButton.exists || extensions.exists) {
                    let opensSubmenu = !extensionButton.exists
                    let action = opensSubmenu ? extensions : extensionButton
                    _ = try waitForStableTarget(action, "Safari Wallet extension menu action", until: selectionDeadline)
                    if popup.exists { return }
                    try require(pageMenu.exists, "Safari's Page Menu disappeared before selecting its extension action")
                    action.tap()
                    if opensSubmenu {
                        let submenuWallet = safari.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wallet")).firstMatch
                        try click(submenuWallet, "Big Wallet extension popup")
                    }
                    return
                }
                RunLoop.current.run(until: min(selectionDeadline, Date().addingTimeInterval(0.05)))
            }
            throw SafariUIFailure("Safari did not expose a Wallet or Extensions action in its Page Menu")
        } catch let error as SafariUIFailure {
            guard popup.waitForExistence(timeout: 12) else { throw error }
        }
    }
#endif

    @MainActor
    private func switchState(_ element: XCUIElement, description: String) throws -> Bool {
        if let number = element.value as? NSNumber {
            if number.intValue == 0 { return false }
            if number.intValue == 1 { return true }
        } else if let value = element.value as? String {
            if ["1", "true"].contains(value) { return true }
            if ["0", "false"].contains(value) { return false }
        }
        throw SafariUIFailure("Unsupported accessibility value for \(description): \(String(describing: element.value))")
    }

    @MainActor
    private func setSwitch(_ element: XCUIElement, enabled: Bool, description: String,
                           detectingSafariInterference: Bool = false) throws {
        try require(element.waitForExistence(timeout: 12), "Missing \(description)")
        let state = try switchState(element, description: description)
        if state != enabled {
#if os(macOS)
            element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
                .withOffset(CGVector(dx: min(9, element.frame.width / 2), dy: 0)).click()
            if enabled && detectingSafariInterference {
                let interference = safari.sheets.firstMatch.staticTexts.matching(
                    NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "interfered with clicking", "interfered with clicking")
                ).firstMatch
                if interference.waitForExistence(timeout: 2) {
                    throw SafariUIFailure("Safari blocked automated extension activation because an app or service interfered with clicking. Resolve the interference and enable the extension interactively inside the isolated guest before macOS browser coverage can proceed. See https://support.apple.com/en-us/108379")
                }
            }
#else
            let control = element.switches.firstMatch.exists ? element.switches.firstMatch : element
            control.tap()
#endif
        }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR value == %@", NSNumber(value: enabled), enabled ? "1" : "0"),
            object: element
        )
        try require(XCTWaiter.wait(for: [changed], timeout: 5) == .completed,
                    "The \(description) control did not reach the requested state after direct interaction (value: \(String(describing: element.value)))")
    }

    @MainActor
    private func click(_ element: XCUIElement, _ description: String) throws {
#if os(macOS)
        try require(element.waitForExistence(timeout: 12) && element.isHittable, "Missing or blocked \(description)")
        element.click()
#else
        _ = try waitForStableTarget(element, description, until: Date().addingTimeInterval(12))
        element.tap()
#endif
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SafariUIFailure(message) }
    }

    @MainActor
    private func attachEvidence(_ label: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = label
        image.lifetime = .keepAlways
        add(image)
        var applications = [("SAFARI", safari)]
#if os(macOS)
        if let walletApplication { applications.append(("WALLET", walletApplication)) }
        if helperIsRunning { applications.append(("HELPER", helper)) }
#else
        applications.append(("WALLET", wallet))
        applications.append(("SETTINGS", XCUIApplication(bundleIdentifier: "com.apple.Preferences")))
#endif
        let descriptions = applications.map { name, application in
            let state = application.state
            let summary = "\(name) state: \(state.rawValue)"
            return state == .runningForeground ? summary + "\n" + application.debugDescription : summary
        }
        let hierarchy = XCTAttachment(string: descriptions.joined(separator: "\n\n"))
        hierarchy.name = label + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

private struct SafariUIFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private struct SafariUIConfiguration: Decodable, Sendable {
    struct Addresses: Decodable, Sendable { let ethereum: String; let solana: String }
    let dappURL: String
    let secondOriginURL: String
    struct CustomNetwork: Decodable, Sendable {
        let chainId: Int
        let rpcURL: String
        let replacementRPCURL: String
        let name: String
    }
    let addresses: Addresses
    let alternateAddresses: Addresses
    let customNetwork: CustomNetwork
    let iterations: Int
    let signingMode: String
    let synchronizationPolicy: String
    let activationMode: String
    let profilePrefix: String
    let requiresApprovalDrain: Bool
    let fixtureRoot: String
    let walletApplicationPath: String?
    let helperApplicationPath: String?
}

@MainActor
private final class SafariUIControl {
    private struct Descriptor: Decodable {
        let version: Int
        let runID: String
        let root: String
        let platform: String
        let signingMode: String
        let configuration: String
    }
    private struct Endpoint: Decodable { let url: String; let token: String }
    private let endpoint: URL
    private let token: String
    let runID: String
    private let fixtureRoot: String
    let signingMode: String
    private let synchronizationPolicy: String
    var iteration = 1
    private var checkpointBaselines = [String: Int]()
    private var expectedOccurrences = [String: Int]()
    private var cachedConfiguration: SafariUIConfiguration?
    private var selectedChain = "ethereum"

    init(bundle: Bundle) throws {
        guard let descriptorURL = bundle.url(forResource: "SafariVMRun", withExtension: "json") else {
            throw SafariUIFailure("Safari UI tests require the VM-only bundled run descriptor. Use Scripts/test_vm.sh run all --stage safari.")
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: descriptorURL))
#if os(macOS)
        let platform = "macos"
        let expectedSynchronizationPolicy = "xctest-default"
#else
        let platform = "ios"
        let expectedSynchronizationPolicy = "safari-event-loop-only"
#endif
        guard descriptor.version == 1, !descriptor.runID.isEmpty,
              descriptor.platform == platform,
              ["local", "apple"].contains(descriptor.signingMode),
              ["Debug", "Release"].contains(descriptor.configuration),
              descriptor.root == "/Volumes/BigWalletBuild/Exchange/\(descriptor.runID)/safari/\(platform)/\(descriptor.configuration)",
              !descriptor.root.contains("..") else { throw SafariUIFailure("Invalid Safari VM run descriptor") }
        let value = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: URL(fileURLWithPath: descriptor.root).appendingPathComponent("control.json")))
        guard let url = URL(string: value.url), url.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              !value.token.isEmpty else { throw SafariUIFailure("Invalid guest loopback control endpoint") }
        endpoint = url
        token = value.token
        runID = descriptor.runID
        fixtureRoot = descriptor.root
        signingMode = descriptor.signingMode
        synchronizationPolicy = expectedSynchronizationPolicy
    }

    func configuration() async throws -> SafariUIConfiguration {
        let config = try JSONDecoder().decode(SafariUIConfiguration.self, from: await request("config"))
        guard (1...10).contains(config.iterations), config.signingMode == signingMode, config.fixtureRoot == fixtureRoot,
              config.synchronizationPolicy == synchronizationPolicy,
              ["automatic", "interactive", "prepared"].contains(config.activationMode),
              config.activationMode != "prepared" || config.signingMode == "local",
              !config.profilePrefix.isEmpty else { throw SafariUIFailure("Invalid Safari test configuration") }
#if os(iOS)
        guard config.activationMode == "automatic" else { throw SafariUIFailure("Invalid iOS Safari activation mode") }
#endif
        cachedConfiguration = config
        return config
    }

    func post(_ operation: String, _ body: [String: Any]) async throws {
        _ = try await request(operation, body: body)
    }

    func gate(_ point: String, _ value: String) async throws {
        let name = ["authentication": "beforeAuthentication", "signing": "beforeSigning", "broadcast": "beforeDispatch"][point] ?? point
        if value == "hold" || value == "cancel" {
            checkpointBaselines[name] = try await rows("events").filter { $0["point"] as? String == name }.count
        }
        try await post("gate", ["point": point, "value": value])
    }

    func fault(_ kind: String, parameters: [String: Any]) async throws {
        try await post("fault", parameters.merging(["kind": kind]) { _, new in new })
    }

    func selectedAccountAddress() throws -> String {
        guard let config = cachedConfiguration else { throw SafariUIFailure("Fixture account configuration was not loaded") }
        return selectedChain == "solana" ? config.addresses.solana : config.addresses.ethereum
    }

    func markAction(_ action: String) async throws {
        if action.hasPrefix("ethereum-") { selectedChain = "ethereum" }
        if action.hasPrefix("solana-") { selectedChain = "solana" }
        expectedOccurrences[action] = try await rows("results").filter { $0["action"] as? String == action }.count + 1
    }

    func hasResult(_ action: String) async throws -> Bool {
        let count = try await rows("results").filter { $0["action"] as? String == action }.count
        return count >= expectedOccurrences[action, default: 1]
    }

    func providerIsReady() async throws -> Bool {
        let handshake = try await state()["handshake"] as? [String: Any]
        return handshake?["provider"] as? Bool == true
    }

    func waitForProviderReady() async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try await providerIsReady() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The enabled extension did not inject its providers into the fresh Safari document")
    }

    func startLockProbe() async throws -> String {
        let data = try await request("lock-probe", body: [:])
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = response["probeID"] as? String, UUID(uuidString: identifier) != nil else {
            throw SafariUIFailure("The fixture lock probe omitted its unique identity")
        }
        return identifier
    }

    func waitForLockProbe(_ kind: String, identifier: String) async throws {
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            if try await rows("events").contains(where: { $0["kind"] as? String == kind && $0["probeID"] as? String == identifier }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The native lock probe did not reach \(kind)")
    }

    func result(_ action: String, success: Bool = true, occurrence: Int? = nil) async throws -> [String: Any] {
        let occurrence = occurrence ?? expectedOccurrences[action, default: 1]
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            let results = try await rows("results").filter { $0["action"] as? String == action }
            if results.count >= occurrence {
                let result = results[occurrence - 1]
                guard result["ok"] as? Bool == success else {
                    throw SafariUIFailure("\(action) returned unexpected outcome: \(result)")
                }
                return result
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SafariUIFailure("No terminal \(action) result reached the fixture server")
    }

    func assertSingleSettlement(_ action: String, expected: Int = 1) async throws {
        let results = try await rows("results").filter { $0["action"] as? String == action }
        guard results.count == expected, results.allSatisfy({ $0["settlements"] as? Int == 1 }) else {
            throw SafariUIFailure("\(action) settled an unexpected number of times: \(results)")
        }
    }

    func nativeProfileIdentifiers() async throws -> Set<String> {
        let events = try await rows("events").filter {
            $0["kind"] as? String == "nativeIngress" && $0["source"] as? String == "site" && $0["privateBrowsing"] as? Bool == false
        }
        guard !events.isEmpty else { throw SafariUIFailure("No actual Safari native profile evidence was recorded") }
        return Set(events.map { $0["profileIdentifier"] as? String ?? "default-profile" })
    }

    func optionalResult(_ action: String, timeout: TimeInterval) async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let results = try await rows("results").filter { $0["action"] as? String == action }
            let index = expectedOccurrences[action, default: 1] - 1
            if results.indices.contains(index) { return results[index] }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func waitForPoint(_ point: String, additional: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let reached = try await rows("events").filter { $0["point"] as? String == point }.count
            if reached >= checkpointBaselines[point, default: 0] + additional { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("Native execution never reached \(point)")
    }

    func requestIDAtPoint(_ point: String) async throws -> Int {
        let events = try await rows("events").filter { $0["point"] as? String == point }
        guard events.count > checkpointBaselines[point, default: 0], let requestID = events.last?["requestID"] as? Int else {
            throw SafariUIFailure("The held \(point) checkpoint omitted its original request identity")
        }
        return requestID
    }

    func mutation(_ operation: String, parameters: [String: Any]) async throws -> String {
        let data = try await request("mutation", body: parameters.merging(["operation": operation]) { _, new in new })
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = response["mutationID"] as? String, UUID(uuidString: identifier) != nil else {
            throw SafariUIFailure("Fixture mutation omitted its unique identity")
        }
        return identifier
    }

    func waitForMutation(_ identifier: String) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if let event = try await rows("events").first(where: { $0["kind"] as? String == "mutationCompleted" && $0["mutationID"] as? String == identifier }) {
                guard event["succeeded"] as? Bool == true else { throw SafariUIFailure("Native fixture mutation failed: \(event)") }
                return event
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("Foreground wallet did not acknowledge its production-store mutation")
    }

    func nativeIncarnations(role: String) async throws -> Set<String> {
        let events = try await rows("events").filter {
            $0["kind"] as? String == "processStarted" && $0["role"] as? String == role ||
                role == "extension" && $0["kind"] as? String == "nativeIngress" ||
                role == "helper" && $0["kind"] as? String == "consentAccepted"
        }
        let incarnations = Set(events.compactMap { $0["incarnation"] as? String })
        guard !incarnations.isEmpty else { throw SafariUIFailure("No actual \(role) process identity was recorded before termination") }
        return incarnations
    }

    func waitForNewNativeIncarnation(role: String, excluding previous: Set<String>) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let started = try await rows("events").filter { $0["kind"] as? String == "processStarted" && $0["role"] as? String == role }
            if started.contains(where: { event in
                guard let incarnation = event["incarnation"] as? String else { return false }
                return !previous.contains(incarnation)
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The terminated \(role) did not restart with a new native incarnation")
    }

    func assertSigningInNewNativeIncarnation(excluding previous: Set<String>) async throws {
        let signing = try await rows("events").filter { $0["kind"] as? String == "signingStarted" }
        guard signing.count == 1, let incarnation = signing.first?["incarnation"] as? String,
              !previous.contains(incarnation) else {
            throw SafariUIFailure("The recovered request did not sign exactly once in a new native process")
        }
    }

    func eventCount(_ kind: String) async throws -> Int {
        try await rows("events").filter { $0["kind"] as? String == kind }.count
    }

    func consentIdentifiers() async throws -> Set<String> {
        let consents = try await rows("events").filter { $0["kind"] as? String == "consentAccepted" }
        let identifiers = consents.compactMap { $0["consentID"] as? String }
        guard identifiers.count == consents.count else { throw SafariUIFailure("Native consent evidence omitted its identity") }
        return Set(identifiers)
    }

    func singleNewConsentIdentifier(excluding previous: Set<String>) async throws -> String {
        let current = try await consentIdentifiers().subtracting(previous)
        guard current.count == 1, let identifier = current.first else {
            throw SafariUIFailure("The renewed approval did not create exactly one distinct consent")
        }
        return identifier
    }

    func waitForSelectionCompletion(excluding previous: Set<String>) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let events = try await rows("events")
            let consents = events.filter {
                guard $0["kind"] as? String == "consentAccepted", let identifier = $0["consentID"] as? String else { return false }
                return !previous.contains(identifier)
            }
            guard consents.count <= 1 else { throw SafariUIFailure("One account selection produced multiple consents") }
            if let consent = consents.first, let consentID = consent["consentID"] as? String,
               let requestID = consent["requestID"] as? Int,
               let authorization = events.first(where: { $0["kind"] as? String == "authorization" && $0["consentID"] as? String == consentID }),
               let executionID = authorization["executionID"] as? String,
               events.contains(where: { $0["kind"] as? String == "completion" && $0["requestID"] as? Int == requestID && $0["executionID"] as? String == executionID }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("The explicit account selection did not complete its freshly consented request")
    }

    func assertSigningConsent(_ identifier: String, requestID: Int) async throws {
        let events = try await rows("events")
        let consents = events.filter { $0["kind"] as? String == "consentAccepted" && $0["consentID"] as? String == identifier }
        let signing = events.filter { $0["kind"] as? String == "signingStarted" }
        let authorizations = events.filter { $0["kind"] as? String == "authorization" }
        guard consents.count == 1, let consent = consents.first, consent["requestID"] as? Int == requestID,
              signing.count == 1, signing.first?["requestID"] as? Int == requestID,
              let execution = signing.first?["executionID"] as? String else {
            throw SafariUIFailure("The renewed fee approval did not sign its original held request exactly once")
        }
        let matching = authorizations.filter { $0["executionID"] as? String == execution }
        guard matching.count == 1, let authorization = matching.first,
              authorization["consentID"] as? String == identifier, authorization["requestID"] as? Int == requestID,
              authorization["requestToken"] as? String == consent["requestToken"] as? String,
              authorization["profileIdentifier"] as? String == consent["profileIdentifier"] as? String,
              authorization["configurationKey"] as? String == consent["configurationKey"] as? String else {
            throw SafariUIFailure("Updated transaction fees did not require fresh consent for the original request")
        }
    }

    func assertNoSuccessfulResult(action: String, documentID: String) async throws {
        let results = try await rows("results")
        guard !results.contains(where: { $0["action"] as? String == action && $0["documentId"] as? String == documentID && $0["ok"] as? Bool == true }) else {
            throw SafariUIFailure("A retired document received a successful signing result")
        }
    }

    func assertCurrentActionSingleSettlement(_ action: String) async throws {
        try await assertSingleSettlement(action, expected: expectedOccurrences[action, default: 1])
    }

    func waitForPreparationHold() async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let rpc = try await state()["rpc"] as? [String: Any], let held = rpc["preparationHeld"] as? Int, held > 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("Transaction estimation never reached the held RPC boundary")
    }

    func assertAuthorizedTransaction(nonce: String) async throws {
        let transactions = try await rows("events").filter { $0["kind"] as? String == "authorizedTransaction" }
        guard let transaction = transactions.last?["transaction"] as? [String: Any],
              transaction["nonce"] as? String == nonce else {
            throw SafariUIFailure("The actual signing authorization did not preserve the reviewed nonce")
        }
    }

    func waitForRPCCapacity() async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let state = try await state()
            guard let rpc = state["rpc"] as? [String: Any], let held = rpc["held"] as? Int,
                  let peak = rpc["peak"] as? Int, let outcomes = rpc["outcomes"] as? [[String: Any]] else {
                throw SafariUIFailure("The fixture server omitted RPC saturation evidence")
            }
            if peak > 4 { throw SafariUIFailure("More than four RPC calls passed one native process's per-origin admission limit") }
            if held > 0 && peak > 0 && outcomes.contains(where: Self.isQuotaRejection) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("RPC burst never demonstrated a held request plus a bounded-admission rejection")
    }

    func assertRPCOutcomes(_ response: [String: Any]) throws {
        guard let outcomes = response["result"] as? [[String: Any]], outcomes.count == 140,
              Set(outcomes.compactMap { $0["index"] as? Int }) == Set(0..<140),
              outcomes.contains(where: { $0["ok"] as? Bool == true && $0["result"] as? String == "0x100" }),
              outcomes.contains(where: Self.isQuotaRejection),
              outcomes.allSatisfy({ outcome in
                  outcome["ok"] as? Bool == true && outcome["result"] as? String == "0x100" || Self.isQuotaRejection(outcome)
              }) else {
            throw SafariUIFailure("RPC capacity recovery must settle all 140 calls with both success and explicit quota rejection")
        }
    }

    nonisolated private static func isQuotaRejection(_ outcome: [String: Any]) -> Bool {
        guard outcome["ok"] as? Bool == false, let error = outcome["error"] as? [String: Any],
              error["code"] as? Int == -32005, let data = error["data"] as? [String: Any],
              let reason = data["reason"] as? String else { return false }
        return !reason.isEmpty
    }

    func waitForBroadcast(chain: String) async throws {
        let deadline = Date().addingTimeInterval(35)
        while Date() < deadline {
            if try await rows("broadcasts").contains(where: { $0["chain"] as? String == chain }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SafariUIFailure("No \(chain) broadcast reached the fixture RPC server")
    }

    func assertBroadcasts(chain: String, count: Int) async throws {
        let rows = try await rows("broadcasts").filter { $0["chain"] as? String == chain }
        guard rows.reduce(0, { $0 + ($1["count"] as? Int ?? 1) }) == count else {
            throw SafariUIFailure("Expected \(count) \(chain) dispatches, observed \(rows)")
        }
    }

    func assertNoSigningOrBroadcast() async throws {
        try await Task.sleep(for: .milliseconds(1500))
        let events = try await rows("events")
        let forbidden = events.filter { $0["kind"] as? String == "signingStarted" || $0["kind"] as? String == "broadcastCheckpoint" }
        guard forbidden.isEmpty, try await rows("broadcasts").isEmpty else {
            throw SafariUIFailure("An interrupted request progressed to signing or dispatch: \(forbidden)")
        }
    }

    private func state() async throws -> [String: Any] {
        guard let state = try JSONSerialization.jsonObject(with: await request("state")) as? [String: Any] else {
            throw SafariUIFailure("Malformed VM control state")
        }
        return state
    }

    private func rows(_ key: String) async throws -> [[String: Any]] {
        guard let values = try await state()[key] as? [[String: Any]] else {
            throw SafariUIFailure("Missing \(key) in VM control state")
        }
        return values
    }

    private func request(_ operation: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent("control").appendingPathComponent(operation))
        switch operation {
        case "refresh-extension-registration": request.timeoutInterval = 180
        case "start": request.timeoutInterval = 75
        case "fault" where body?["action"] as? String == "terminate" &&
            ["native-process", "extension-process"].contains(body?["kind"] as? String ?? ""):
            request.timeoutInterval = 75
        default: request.timeoutInterval = 15
        }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw SafariUIFailure("VM control \(operation) rejected the request: \(String(data: data, encoding: .utf8) ?? "invalid response")")
        }
        return data
    }
}
