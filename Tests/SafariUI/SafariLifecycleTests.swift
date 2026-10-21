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
            try await self.connect("ethereum", control: control)
            try await self.perform("ethereum-sign", control: control)
            try await self.showApproval(control: control)
#if os(iOS)
            try self.closeApproval()
#endif
            try self.open(config.secondOriginURL)
            try await self.perform("provider-state", control: control)
            let unrelated = try await control.result("provider-state")
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
            self.helper.activate()
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
            try self.click(self.helper.windows[first].buttons[XCUIIdentifierCloseWindow], "close the still-locked first request")
            let firstResult = try await control.result("ethereum-sign", success: false, occurrence: 2)
            try self.require(firstResult["documentId"] as? String == firstDocument,
                             "Closing the first window rejected another document's request")
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
    func testExtensionDisableAndReenable() async throws {
        try await scenario("extension-toggle") { control, config in
            try await self.prepare(control: control, config: config)
            try await self.connect("ethereum", control: control)
            try await self.setExtensionEnabled(false, control: control)
            try self.open(config.dappURL)
            try self.require(self.safari.staticTexts["provider-unavailable"].waitForExistence(timeout: 15),
                             "A fresh page still exposes the wallet after extension disablement")
            try await self.setExtensionEnabled(true, control: control)
            try self.open(config.dappURL)
            try await self.connect("ethereum", control: control)
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
            try self.open(config.dappURL)
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
            try self.require(self.passwordField.waitForExistence(timeout: 12), "Held transaction authentication did not resume")
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
            try self.open(config.dappURL)
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
                if self.passwordField.waitForExistence(timeout: 8) { try await self.authenticateIfPresent(control: control) }
#endif
                self.safari.activate()
                try await control.assertNoSigningOrBroadcast()
                if let result = try await control.optionalResult("ethereum-send-custom", timeout: 8) {
                    try self.require(result["ok"] as? Bool == false, "The changed RPC destination reused the prior approval")
                } else {
                    try await self.reject(control: control)
                    _ = try await control.result("ethereum-send-custom", success: false)
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

    @MainActor
    private func openTransactionEditor() throws -> XCUIElement {
#if os(macOS)
        helper.activate()
        let editor = helper.buttons["editTransactionFeesButton"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: editor)
        try require(XCTWaiter.wait(for: [ready], timeout: 15) == .completed, "Transaction preparation never enabled its editor")
        try click(editor, "transaction editor")
        let field = helper.textFields["transactionNonceField"]
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
        try click(field, "transaction nonce")
#if os(macOS)
        field.typeKey("a", modifierFlags: .command)
#else
        field.doubleTap()
#endif
        field.typeText(nonce)
        let enteredNonce = field.value as? String
        try require(enteredNonce == nonce,
                    "Nonce entry expected \(nonce), received \(enteredNonce ?? "<unreadable>")")
#if os(macOS)
        try click(helper.buttons["Apply"], "apply reviewed transaction edits")
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
        try click(helper.buttons["Cancel"], "close unchanged transaction editor")
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
                if !retainedSafari, safari.state != .notRunning { safari.terminate() }
                try await control.post("start", ["scenario": identifier, "iteration": iteration])
#if os(iOS)
                if iteration == 1 { try await configureReducedMotion() }
#endif
                let iterationConfig = try await control.configuration()
                try await body(control, iterationConfig)
                attachEvidence("\(identifier)-\(iteration)")
                try await cleanup(retainingSafari: canRetainSafari && iteration < config.iterations,
                                  resettingProfileSession: identifier == "profiles-private")
                finishAttempted = true
                try await control.post("finish", ["scenario": identifier, "iteration": iteration,
                                                  "status": "passed", "evidence": ["xcresult": name]])
            } catch {
                attachEvidence("\(identifier)-\(iteration)-failure")
                var evidence = ["error": String(describing: error)]
                do { try await cleanup(resettingProfileSession: identifier == "profiles-private") }
                catch { evidence["cleanupError"] = String(describing: error) }
                if !finishAttempted {
                    try? await control.post("finish", ["scenario": identifier, "iteration": iteration,
                                                       "status": "failed", "evidence": evidence])
                }
                throw error
            }
        }
    }

    @MainActor
    private func cleanup(retainingSafari: Bool = false, resettingProfileSession: Bool = false) async throws {
        var keepSafari = false
        defer {
#if os(macOS)
            if helperIsRunning { helper.terminate() }
            if let walletApplication, walletApplication.state != .notRunning { walletApplication.terminate() }
#else
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            if settings.state != .notRunning { settings.terminate() }
            if wallet.state != .notRunning { wallet.terminate() }
#endif
            if !keepSafari, safari.state != .notRunning { safari.terminate() }
            retainedSafari = keepSafari
        }
        try closeOwnedApprovalIfPresent()
        guard safari.state != .notRunning, extensionActivated else { return }
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
        if popupDone.exists { popupDone.tap() }
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
                guard let fixtureURL = URL(string: activeDappURL) else {
                    throw SafariUIFailure("The cleanup fixture page URL is invalid")
                }
                safari.open(fixtureURL)
                try require(safari.buttons["ethereum-connect"].waitForExistence(timeout: 20),
                            "The cleanup fixture dapp did not load in ordinary Safari")
                try require(ordinaryDocument.exists, "Safari did not open the cleanup fixture page in ordinary browsing")
            } else if safari.textViews["TabOverview"].exists || !ordinaryDocument.exists || !safari.buttons["ethereum-connect"].exists {
                try open(activeDappURL)
            }
            try await retirePopupRequests()
        }
        dismissKeyboardIntroduction(in: safari)
        let tabs = safari.buttons["TabOverviewButton"]
        try require(tabs.waitForExistence(timeout: 8), "Cannot identify Safari's tabs control during scenario cleanup")
        if tabs.exists {
            tabs.press(forDuration: 1)
            let closeAll = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close All")).firstMatch
            if closeAll.exists {
                closeAll.tap()
                let confirmation = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Close All")).firstMatch
                if confirmation.exists { confirmation.tap() }
            } else if safari.buttons["Close This Tab"].exists {
                safari.buttons["Close This Tab"].tap()
            } else {
                throw SafariUIFailure("Cannot close the fixture tabs during Safari scenario cleanup")
            }
        }
#endif
        keepSafari = retainingSafari && safari.state != .notRunning
    }

    @MainActor
    private func prepare(control: SafariUIControl, config: SafariUIConfiguration, privateBrowsing: Bool = false) async throws {
        activeDappURL = config.dappURL
        let reuseSafari = retainedSafari && extensionActivated && safari.state != .notRunning
        retainedSafari = false
        wallet.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        wallet.launch()
        if localSigning {
            try require(passwordField.waitForExistence(timeout: 12),
                        "The fixture wallet did not present its real password entry screen")
        }
        try await authenticateIfPresent(control: control)
        safari.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        safari.activate()
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
        guard let fixtureURL = URL(string: config.dappURL) else { throw SafariUIFailure("The fixture page URL is invalid") }
        safari.open(fixtureURL)
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
        let comparison = address.hasPrefix("0x") ? "identifier == %@ AND label ==[c] %@" : "identifier == %@ AND label == %@"
        let account = helper.descendants(matching: .any).matching(
            NSPredicate(format: comparison, "safari.approval.account", address)
        ).firstMatch
        if account.exists, account.value as? String != "selected" {
            try click(account, "fixture account selection")
        }
#else
        let address = try accountAddress ?? control.selectedAccountAddress()
        let comparison = address.hasPrefix("0x") ? "label CONTAINS[c] %@" : "label CONTAINS %@"
        let account = popup.switches.matching(NSPredicate(format: comparison, address)).firstMatch
        if account.exists, try !switchState(account, description: "wallet account selection") { account.tap() }
        let cluster = popup.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Devnet")).firstMatch
        if !approvalButton.isEnabled, cluster.exists { cluster.tap() }
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
        try revealPopupElement(approvalButton, "popup approval")
        let title = approvalButton.label
        try require(["connect", "ok"].contains(title.lowercased()),
                    "The popup action \(title) restores or edits a review and cannot be treated as approval")
        if doubleClick { approvalButton.doubleTap() } else { approvalButton.tap() }
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
        if popupDone.exists { popupDone.tap() }
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
#else
        let app = wallet
#endif
        app.activate()
        try click(passwordField, "wallet password field")
        passwordField.typeText("approval-fixture-password")
#if os(macOS)
        try click(app.buttons["safari.authentication.confirm"], "wallet password confirmation")
#else
        try click(app.buttons["OK"], "wallet password confirmation")
#endif
        let deadline = Date().addingTimeInterval(8)
        while passwordIsVisible && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(!passwordIsVisible, "The wallet did not accept the fixture password")
    }

    @MainActor
    private func perform(_ action: String, control: SafariUIControl) async throws {
        try await control.markAction(action)
        if safari.state != .runningForeground { safari.activate() }
#if os(iOS)
        let switchAccount = popup.buttons["Switch Account"]
        if popupDone.exists && switchAccount.exists && switchAccount.isEnabled {
            try click(popupDone, "dismiss the completed Wallet popup")
            try require(popup.waitForNonExistence(timeout: 10), "The completed Wallet popup did not close")
        }
        if !popup.exists && !popupDone.exists { try dismissSafariMoreMenu() }
#endif
#if os(macOS)
        let viewport = safari.windows.firstMatch.scrollViews.containing(.webView, identifier: nil).firstMatch
        try require(viewport.waitForExistence(timeout: 12), "Safari did not expose the fixture page viewport")
        let button = viewport.buttons[action]
#else
        let button = safari.buttons[action]
#endif
        try require(button.waitForExistence(timeout: 15), "The fixture action \(action) is missing")
        for _ in 0..<8 where !button.isHittable {
#if os(macOS)
            let above = button.frame.midY < viewport.frame.midY
            viewport.scroll(byDeltaX: 0, deltaY: above ? 400 : -400)
#else
            let above = button.frame.midY < safari.frame.midY
            if above { safari.swipeDown() } else { safari.swipeUp() }
#endif
        }
        try click(button, "fixture action \(action)")
    }

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
                try require(passwordField.waitForExistence(timeout: 12), "The containing wallet did not reopen after unsigned extensions were enabled")
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
        while !safari.textFields["URL"].exists && Date() < deadline {
            dismissKeyboardIntroduction(in: safari)
            let expanded = safari.textFields["TabBarItemTitle"]
            let collapsed = safari.otherElements["TabBarItemTitle"]
            if expanded.exists && expanded.isHittable {
                try click(expanded, "Safari address field")
            } else if collapsed.exists && collapsed.isHittable {
                try click(collapsed, "collapsed Safari address field")
            } else {
                _ = safari.textFields["URL"].waitForExistence(timeout: min(0.2, max(0, deadline.timeIntervalSinceNow)))
            }
        }
        dismissKeyboardIntroduction(in: safari)
        let address = safari.textFields["URL"]
        try require(address.exists, "Safari did not expose its focused address field")
        try click(address, "focused Safari address field")
        let clear = safari.buttons["ClearTextButton"]
        if clear.exists && clear.isEnabled { clear.tap() }
        address.typeText(value)
        let go = safari.keyboards.buttons["Go"]
        try require(go.waitForExistence(timeout: 12) && go.isEnabled && go.isHittable,
                    "Safari did not expose an enabled keyboard Go button")
        go.tap()
#endif
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
        try require(tabs.waitForExistence(timeout: 10), "Safari tabs control is unavailable")
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
        try require(tabs.waitForExistence(timeout: 10) && tabs.isHittable, "Safari tabs control is unavailable")
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
        for window in windows.allElementsBoundByIndex {
            try click(window.buttons[XCUIIdentifierCloseWindow], "retire the interrupted request's approval window")
        }
#endif
    }

    @MainActor
    private func closeApproval() throws {
#if os(macOS)
        let close = helper.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        try click(close, "close approval window during authentication")
#else
        try click(popupDone, "dismiss extension popup during authentication")
#endif
    }

    @MainActor
    private func createAndOpenProfile(_ profile: String) throws {
#if os(macOS)
        openSafariSettings()
        try click(safari.buttons["Profiles"], "Safari Profiles settings")
        let create = safari.buttons["Start Using Profiles"].exists ? safari.buttons["Start Using Profiles"] : safari.buttons["New Profile"]
        try click(create, "create isolated Safari profile")
        try click(safari.textFields["Name"], "Safari profile name")
        safari.textFields["Name"].typeText(profile)
        try click(safari.buttons["Create Profile"], "save isolated Safari profile")
        closeSafariSettings()
        try click(safari.menuBars.menuBarItems["File"], "Safari File menu")
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
        helper.activate()
        let password = window.secureTextFields["safari.authentication.password"]
        try click(password, "password sheet belonging to the selected request")
        password.typeText("approval-fixture-password")
        try click(window.buttons["safari.authentication.confirm"], "authenticate only the selected request")
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
        let deadline = Date().addingTimeInterval(5)
        while !UIAccessibility.isReduceMotionEnabled, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(UIAccessibility.isReduceMotionEnabled, "The simulator did not apply Reduce Motion")
        attachEvidence("ios-reduce-motion-enabled")
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
    private func dismissPrivateBrowsingIntroduction() throws {
        let introduction = safari.otherElements["TurnOnLockedPrivateBrowsingView"]
        if introduction.waitForExistence(timeout: 2) {
            try click(introduction.buttons["NotNowButton"], "continue without enabling Locked Private Browsing")
            try require(introduction.waitForNonExistence(timeout: 10), "Safari did not dismiss its Locked Private Browsing introduction")
        }
    }

    @MainActor
    private func dismissSafariMoreMenu() throws {
        let menu = safari.otherElements.matching(
            NSPredicate(format: "identifier IN %@", ["MoreMenu", "TabBarMoreMenu"])
        ).firstMatch
        if menu.exists {
            safari.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
            try require(menu.waitForNonExistence(timeout: 10), "Safari did not dismiss its open More menu")
        }
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
        func isVisible() -> Bool {
            let frame = element.frame
            let viewport = popup.frame.intersection(safari.frame).insetBy(dx: 8, dy: 8)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return !frame.isEmpty && center.x.isFinite && center.y.isFinite &&
                !viewport.isNull && !viewport.isEmpty && viewport.contains(center) && element.isHittable
        }
        for _ in 0..<8 {
            if isVisible() { return }
            if element.frame.midY < popup.frame.intersection(safari.frame).midY { popup.swipeDown() }
            else { popup.swipeUp() }
        }
        try require(isVisible(), "The popup could not scroll \(description) into view")
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
        try require(popup.waitForExistence(timeout: 12), "Safari did not present the Wallet extension popup")
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
        let deadline = Date().addingTimeInterval(15)
        var openedMenu = false
        while Date() < deadline {
            if popup.waitForExistence(timeout: 1) { return }
            if popupDone.exists {
                try require(popup.waitForExistence(timeout: 12), "Safari presented Wallet popup controls without its extension content")
                return
            }
            if safari.otherElements["TabBarMoreMenu"].exists {
                openedMenu = true
                break
            }
            let collapsedAddress = safari.otherElements["TabBarItemTitle"]
            if !menu.exists, collapsedAddress.exists && collapsedAddress.isHittable {
                if popup.exists { return }
                if popupDone.exists { continue }
                collapsedAddress.tap()
            }
            if popup.exists { return }
            if popupDone.exists {
                try require(popup.waitForExistence(timeout: 12), "Safari presented Wallet popup controls without its extension content")
                return
            }
            if safari.otherElements["TabBarMoreMenu"].exists {
                openedMenu = true
                break
            }
            guard menu.exists && menu.isHittable else { continue }
            menu.tap()
            openedMenu = true
            break
        }
        try require(openedMenu, "Safari presented neither its Wallet popup nor an available Page Menu")
        if popup.exists { return }
        let extensionButton = safari.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wallet")).firstMatch
        if !extensionButton.exists, safari.buttons["Extensions"].exists {
            safari.buttons["Extensions"].tap()
        }
        do {
            try click(extensionButton, "Big Wallet extension popup")
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
        try require(element.waitForExistence(timeout: 12) && element.isHittable, "Missing or blocked \(description)")
#if os(macOS)
        element.click()
#else
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
#else
        let platform = "ios"
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
    }

    func configuration() async throws -> SafariUIConfiguration {
        let config = try JSONDecoder().decode(SafariUIConfiguration.self, from: await request("config"))
        guard (1...10).contains(config.iterations), config.signingMode == signingMode, config.fixtureRoot == fixtureRoot,
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
