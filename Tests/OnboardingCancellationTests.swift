import AppKit
import Security
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class OnboardingCancellationTests: XCTestCase {
    func testClosingEachOnboardingScreenDoesNotReopenOnActivation() async throws {
        for stage in [Stage.welcome, .create, .repeatPassword, .returnedWelcome] {
            let fixture = OnboardingKeychainFixture()
            let agent = Agent(approvalInbox: ApprovalInbox())
            agent.keychain = fixture.keychain
            let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let window = try await openOnboarding(agent)
            defer { window.close() }
            try await advance(window, to: stage)

            window.close()
            await waitUntil { !window.isVisible }
            let passwordReads = fixture.passwordReads
            for _ in 0..<3 { agent.applicationDidBecomeActive() }

            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(fixture.passwordReads, passwordReads)
            XCTAssertFalse(NSApp.windows.contains { candidate in
                !priorWindows.contains(ObjectIdentifier(candidate)) && candidate.isVisible &&
                    (candidate.contentViewController is WelcomeViewController ||
                    candidate.contentViewController is PasswordViewController)
            })
        }
    }

    func testPasswordCloseBeforeWindowNotificationCancelsOnlyThatOnboarding() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = Agent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        let firstWindow = try await openOnboarding(agent)
        try await advance(firstWindow, to: .repeatPassword)
        let password = try XCTUnwrap(firstWindow.contentViewController as? PasswordViewController)

        password.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        firstWindow.close()
        await settleUI()
        let cancelledReads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, cancelledReads)

        let nextWindow = try await openOnboarding(agent)
        defer { nextWindow.close() }
        password.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: firstWindow)
        let currentReads = fixture.passwordReads
        agent.applicationDidBecomeActive()

        XCTAssertGreaterThan(fixture.passwordReads, currentReads)
        XCTAssertTrue(nextWindow.isVisible)
        XCTAssertTrue(nextWindow.contentViewController is WelcomeViewController)
    }

    func testExistingCredentialCompletionIsNotUserCancellation() async throws {
        let fixture = OnboardingKeychainFixture()
        var completions = [Bool]()
        var cancellations = 0
        let password = PasswordViewController.with(
            mode: .create,
            onboardingCancelled: { cancellations += 1 },
            completion: { completions.append($0) }
        )
        password.keychain = fixture.keychain
        let window = show(password)
        defer { window.close() }
        await waitUntil { password.passwordTextField.isEnabled }
        fixture.password = "existing-password"

        password.actionButtonTapped(password.okButton as Any)
        window.close()

        XCTAssertEqual(completions, [false])
        XCTAssertEqual(cancellations, 0)
    }

    func testRetiredSetupCallbackDoesNotCancelExternalCredentialHandoff() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = OnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        agent.readCount = { fixture.passwordReads }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try await advance(window, to: .create)
        let oldForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        fixture.password = "externally-created-password"

        agent.applicationDidBecomeActive()
        oldForm.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        await waitUntil { agent.authenticationRequests == 1 }

        XCTAssertTrue(agent.observedPendingIntent)
    }

    func testReturningToWelcomeRetiresOldPasswordCallbacksAndKeepsCancellation() async throws {
        let fixture = OnboardingKeychainFixture()
        var completions = [Bool]()
        var cancellations = 0
        let password = PasswordViewController.with(
            mode: .create,
            onboardingCancelled: { cancellations += 1 },
            credentialUnavailable: { XCTFail("Expected available credentials") },
            completion: { completions.append($0) }
        )
        password.keychain = fixture.keychain
        let window = show(password)
        defer { window.close() }
        await waitUntil { password.passwordTextField.isEnabled }

        password.cancelButtonTapped(password.cancelButton)
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        await waitUntil { welcome.getStartedButton.isEnabled }
        password.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(cancellations, 0)

        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        let nextPassword = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        await waitUntil { window.delegate === nextPassword && nextPassword.passwordTextField.isEnabled }
        window.close()

        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(cancellations, 1)
    }

    func testClosingPasswordFailureRetiresCreateAndRepeatForms() async throws {
        for stage in [Stage.create, .repeatPassword] {
            let fixture = OnboardingKeychainFixture()
            let agent = Agent(approvalInbox: ApprovalInbox())
            agent.keychain = fixture.keychain
            let setupWindow = try await openOnboarding(agent)
            defer { setupWindow.close() }
            try await advance(setupWindow, to: stage)
            let staleForm = try XCTUnwrap(setupWindow.contentViewController as? PasswordViewController)
            fixture.readStatus = errSecInteractionNotAllowed
            let failure = try await showPasswordFailure(agent)
            let failureWindow = try XCTUnwrap(failure.controller.window)
            defer { failureWindow.close() }

            failureWindow.close()
            await waitUntil { !failureWindow.isVisible }
            XCTAssertFalse(failureWindow.isVisible)
            XCTAssertFalse(setupWindow.isVisible)
            fixture.readStatus = nil
            let cancelledReads = fixture.passwordReads
            for _ in 0..<3 {
                staleForm.passwordTextField.stringValue = "draft-password"
                staleForm.actionButtonTapped(staleForm.okButton as Any)
                await settleUI()
            }
            staleForm.cancelButtonTapped(staleForm.cancelButton)
            agent.applicationDidBecomeActive()

            XCTAssertEqual(fixture.addCount, 0)
            XCTAssertEqual(fixture.passwordReads, cancelledReads)
            XCTAssertNil(fixture.password)
            XCTAssertFalse(setupWindow.isVisible)

            let freshWindow = try await openOnboarding(agent)
            defer { freshWindow.close() }
            XCTAssertTrue(freshWindow.contentViewController is WelcomeViewController)
            failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: failureWindow))
            staleForm.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: setupWindow))
            let freshReads = fixture.passwordReads
            agent.applicationDidBecomeActive()

            XCTAssertGreaterThan(fixture.passwordReads, freshReads)
            XCTAssertTrue(freshWindow.isVisible)
            XCTAssertEqual(fixture.addCount, 0)
        }
    }

    func testStorageFailureReplacesEverySetupStageAndRequiresExplicitRetry() async throws {
        for stage in [Stage.welcome, .create, .repeatPassword] {
            let fixture = OnboardingKeychainFixture()
            let agent = Agent(approvalInbox: ApprovalInbox())
            agent.keychain = fixture.keychain
            let window = try await openOnboarding(agent)
            defer { window.close() }
            try await advance(window, to: stage)
            let originalForm = window.contentViewController as? PasswordViewController
            let originalWelcome = window.contentViewController as? WelcomeViewController
            fixture.readStatus = errSecInteractionNotAllowed
            let failure = try await showPasswordFailure(agent)

            XCTAssertTrue(failure.controller.window === window)
            XCTAssertTrue(window.contentViewController === failure.viewController)
            if let originalForm { XCTAssertTrue(originalForm.passwordTextField.stringValue.isEmpty) }
            fixture.readStatus = nil
            let reads = fixture.passwordReads
            for _ in 0..<3 {
                agent.applicationDidBecomeActive()
                NotificationCenter.default.post(name: .walletsChanged, object: nil)
                agent.open()
            }
            await settleUI()
            XCTAssertEqual(fixture.passwordReads, reads)
            XCTAssertTrue(window.contentViewController === failure.viewController)
            if let originalForm {
                originalForm.passwordTextField.stringValue = "retired-draft"
                originalForm.actionButtonTapped(originalForm.okButton as Any)
                originalForm.cancelButtonTapped(originalForm.cancelButton)
            }
            originalWelcome?.actionButtonTapped(originalWelcome?.getStartedButton as Any)
            XCTAssertEqual(fixture.passwordReads, reads)
            XCTAssertEqual(fixture.addCount, 0)

            failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
            await settleUI()
            let restarted = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
            XCTAssertFalse(restarted === originalWelcome)
            XCTAssertTrue(window.isVisible)
            failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
            XCTAssertTrue(window.contentViewController === restarted)
            XCTAssertEqual(fixture.addCount, 0)
        }
    }

    func testRetryRechecksUnavailableAndNewlyCreatedCredentials() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = SuspendedOnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try await advance(window, to: .repeatPassword)
        fixture.readStatus = errSecInteractionNotAllowed
        let firstFailure = try await showPasswordFailure(agent)

        firstFailure.viewController.actionButtonTapped(firstFailure.viewController.okButton as Any)
        await settleUI()
        let secondFailure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertEqual(secondFailure.okButton.title, Strings.tryAgain)
        XCTAssertEqual(agent.authenticationRequests, 0)
        fixture.readStatus = nil
        fixture.password = "externally-created-password"
        secondFailure.actionButtonTapped(secondFailure.okButton as Any)
        await waitUntil { agent.authenticationRequests == 1 }
        firstFailure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        secondFailure.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        for _ in 0..<3 { agent.open() }
        await settleUI()

        XCTAssertEqual(agent.authenticationRequests, 1)
        XCTAssertEqual(fixture.password, "externally-created-password")
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testOldSuccessfulAuthenticationCannotFinishReplacementFlow() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = SuspendedOnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        agent.open()
        await waitUntil { agent.authenticationRequests == 1 }
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let window = try XCTUnwrap(failure.controller.window)
        defer { window.close() }
        fixture.readStatus = nil
        failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
        await waitUntil { agent.authenticationRequests == 2 }

        agent.complete(1, result: true)
        await waitUntil { agent.cancelledAtReturn[1] != nil }
        failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        for _ in 0..<3 { agent.open() }
        await settleUI()

        XCTAssertEqual(agent.cancelledAtReturn[1], true)
        XCTAssertEqual(agent.authenticationRequests, 2)
        XCTAssertFalse(window.contentViewController is AccountsListViewController)
        agent.complete(2, result: false)
        await waitUntil { agent.cancelledAtReturn[2] != nil }
        await settleUI()
        let reads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, reads)
    }

    func testRetiredBiometricFailureCannotReplaceExplicitRetryScreen() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = BiometricFallbackAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAllDeviceAttempts() }
        agent.open()
        await waitUntil { agent.deviceAttempts == 1 }
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let window = try XCTUnwrap(failure.controller.window)
        defer { window.close() }
        agent.completeDeviceAttempt(1, outcome: .failed)
        await waitUntil { agent.authenticationResults.count == 1 }
        XCTAssertTrue(window.contentViewController === failure.viewController)
        XCTAssertEqual(agent.authenticationResults, [false])

        fixture.readStatus = nil
        failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
        await waitUntil { agent.deviceAttempts == 2 }
        let working = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        agent.completeDeviceAttempt(2, outcome: .failed)
        await waitUntil { window.contentViewController is PasswordViewController }
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        await waitUntil { password.passwordTextField.isEnabled }
        working.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertTrue(window.contentViewController === password)
        password.passwordTextField.stringValue = "stored-password"
        password.actionButtonTapped(password.okButton as Any)
        await waitUntil { agent.authenticationResults.count == 2 }

        XCTAssertEqual(agent.authenticationResults, [false, true])
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testStartupPasswordFailureUsesSameWindowAndRetiresForm() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = BiometricFallbackAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAllDeviceAttempts() }
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        agent.open()
        await waitUntil { agent.deviceAttempts == 1 }
        agent.completeDeviceAttempt(1, outcome: nil)
        let window = try await waitForPasswordWindow(excluding: priorWindows)
        defer { window.close() }
        let form = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        await waitUntil { form.passwordTextField.isEnabled }
        form.passwordTextField.stringValue = "draft-password"
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        XCTAssertTrue(failure.controller.window === window)
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        await waitUntil { agent.authenticationResults.count == 1 }

        window.close()
        await waitUntil { !window.isVisible }
        fixture.readStatus = nil
        let reads = fixture.passwordReads
        form.passwordTextField.stringValue = "stored-password"
        form.actionButtonTapped(form.okButton as Any)
        form.cancelButtonTapped(form.cancelButton)
        failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
        failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        agent.applicationDidBecomeActive()
        await settleUI()

        XCTAssertEqual(fixture.passwordReads, reads)
        XCTAssertEqual(agent.authenticationResults, [false])
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testPasswordDisappearingDuringAuthenticationRetiresItsResult() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = SuspendedOnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        agent.open()
        await waitUntil { agent.authenticationRequests == 1 }
        fixture.password = nil
        let window = try await openOnboarding(agent)
        defer { window.close() }
        agent.complete(1, result: true)
        await waitUntil { agent.cancelledAtReturn[1] != nil }
        await settleUI()

        XCTAssertEqual(agent.cancelledAtReturn[1], true)
        XCTAssertTrue(window.contentViewController is WelcomeViewController)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testRepeatedOpenDeduplicatesSetupAndAuthentication() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = SuspendedOnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        let welcome = window.contentViewController
        for _ in 0..<5 { agent.open() }
        XCTAssertTrue(window.contentViewController === welcome)
        fixture.password = "external-password"
        agent.applicationDidBecomeActive()
        await waitUntil { agent.authenticationRequests == 1 }
        for _ in 0..<5 {
            agent.open()
            agent.applicationDidBecomeActive()
        }
        await settleUI()
        XCTAssertEqual(agent.authenticationRequests, 1)
    }

    func testDockHandoffDeduplicatesAndIgnoresRetiredSuccess() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = DockHandoffAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        agent.open()
        await waitUntil { agent.handoffRequests == 1 }
        for _ in 0..<5 { agent.open() }
        await settleUI()
        XCTAssertEqual(agent.handoffRequests, 1)
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let window = try XCTUnwrap(failure.controller.window)
        defer { window.close() }
        fixture.readStatus = nil
        failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
        await waitUntil { agent.handoffRequests == 2 }
        agent.complete(1, result: true)
        await settleUI()
        XCTAssertEqual(agent.handoffRequests, 2)
        agent.complete(2, result: false)
        await waitUntil {
            (window.contentViewController as? WaitingViewController)?.okButton?.title == Strings.tryAgain
        }
        let currentFailure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        currentFailure.actionButtonTapped(currentFailure.okButton as Any)
        await waitUntil { agent.handoffRequests == 3 }
        agent.complete(3, result: true)
        await settleUI()
        let reads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, reads)
        XCTAssertEqual(agent.handoffRequests, 3)
    }

    func testCommittedPasswordCreationNotifiesAfterItsFlowCloses() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.allowsCreation = true
        let agent = Agent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try await advance(window, to: .repeatPassword)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        let changed = expectation(description: "Committed password notifies storage")
        changed.assertForOverFulfill = false
        let observation = NotificationCenter.default.addObserver(forName: .walletsChanged, object: nil, queue: nil) { _ in
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        fixture.afterInsertion = { [weak window] in MainActor.assumeIsolated { window?.close() } }
        defer { fixture.afterInsertion = nil }
        password.passwordTextField.stringValue = "draft-password"
        password.actionButtonTapped(password.okButton as Any)
        await fulfillment(of: [changed], timeout: 2)
        await waitUntil { !window.isVisible }

        XCTAssertEqual(fixture.password, "draft-password")
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertFalse(window.isVisible)
        let reads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        password.actionButtonTapped(password.okButton as Any)
        XCTAssertEqual(fixture.passwordReads, reads)
        XCTAssertFalse(window.isVisible)
    }

    private enum Stage { case welcome, create, repeatPassword, returnedWelcome }

    private func openOnboarding(_ agent: Agent) async throws -> NSWindow {
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        agent.open()
        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is WelcomeViewController
        })
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        await waitUntil { welcome.getStartedButton.isEnabled }
        return window
    }

    private func advance(_ window: NSWindow, to stage: Stage) async throws {
        guard stage != .welcome else { return }
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        await waitUntil { window.delegate === password && password.passwordTextField.isEnabled }
        switch stage {
        case .repeatPassword:
            password.passwordTextField.stringValue = "draft-password"
            password.actionButtonTapped(password.okButton as Any)
            XCTAssertEqual(password.titleLabel.stringValue, Strings.repeatPassword)
        case .returnedWelcome:
            password.cancelButtonTapped(password.cancelButton)
            let returned = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
            await waitUntil { returned.getStartedButton.isEnabled }
        case .welcome, .create:
            break
        }
    }

    private func showPasswordFailure(_ agent: Agent) async throws -> (controller: NSWindowController, viewController: WaitingViewController) {
        let priorControllers = Set(NSApp.windows.compactMap(\.contentViewController).map(ObjectIdentifier.init))
        agent.applicationDidBecomeActive()
        let window = try XCTUnwrap(NSApp.windows.first {
            guard $0.isVisible, let controller = $0.contentViewController as? WaitingViewController else { return false }
            return !priorControllers.contains(ObjectIdentifier(controller))
        })
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let controller = try XCTUnwrap(window.windowController)
        let waiting = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        await waitUntil { window.delegate === waiting }
        return (controller, waiting)
    }

    private func waitForPasswordWindow(excluding priorWindows: Set<ObjectIdentifier>) async throws -> NSWindow {
        var found: NSWindow?
        await waitUntil {
            found = NSApp.windows.first {
                !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible &&
                    $0.contentViewController is PasswordViewController
            }
            return found != nil
        }
        let window = try XCTUnwrap(found)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        await waitUntil { window.delegate === password }
        return window
    }

    private func show(_ controller: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        return window
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }

    private func settleUI() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
private final class OnboardingAuthenticationAgent: Agent {
    var readCount: () -> Int = { 0 }
    var authenticationRequests = 0
    var observedPendingIntent = false

    override func askAuthentication(for authentication: AuthenticationContext, reason: AuthenticationReason) async -> Bool {
        authenticationRequests += 1
        let previousReads = readCount()
        applicationDidBecomeActive()
        observedPendingIntent = readCount() > previousReads
        return false
    }
}

@MainActor
private final class SuspendedOnboardingAuthenticationAgent: Agent {
    var authenticationRequests = 0
    var cancelledAtReturn = [Int: Bool]()
    private var pending = [Int: CheckedContinuation<Bool, Never>]()

    override func askAuthentication(for authentication: AuthenticationContext, reason: AuthenticationReason) async -> Bool {
        authenticationRequests += 1
        let identifier = authenticationRequests
        let result = await withCheckedContinuation { pending[identifier] = $0 }
        cancelledAtReturn[identifier] = Task.isCancelled
        return result
    }

    func complete(_ identifier: Int, result: Bool = false) {
        pending.removeValue(forKey: identifier)?.resume(returning: result)
    }

    func completeAll() {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(returning: false) }
    }
}

@MainActor
private final class BiometricFallbackAgent: Agent {
    var deviceAttempts = 0
    var authenticationResults = [Bool]()
    private var pending = [Int: CheckedContinuation<DeviceAuthentication.Outcome?, Never>]()

    override func attemptDeviceAuthentication(reason: String) async -> DeviceAuthentication.Outcome? {
        deviceAttempts += 1
        let identifier = deviceAttempts
        return await withCheckedContinuation { pending[identifier] = $0 }
    }

    override func askAuthentication(for authentication: AuthenticationContext, reason: AuthenticationReason) async -> Bool {
        let result = await super.askAuthentication(for: authentication, reason: reason)
        authenticationResults.append(result)
        return false
    }

    func completeDeviceAttempt(_ identifier: Int, outcome: DeviceAuthentication.Outcome?) {
        pending.removeValue(forKey: identifier)?.resume(returning: outcome)
    }

    func completeAllDeviceAttempts() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: .failed) }
    }
}

@MainActor
private final class DockHandoffAgent: Agent {
    var handoffRequests = 0
    private var pending = [Int: CheckedContinuation<Bool, Never>]()

    override var canCreatePassword: Bool { false }

    override func openDockForOnboarding() async -> Bool {
        handoffRequests += 1
        let identifier = handoffRequests
        return await withCheckedContinuation { pending[identifier] = $0 }
    }

    func complete(_ identifier: Int, result: Bool) {
        pending.removeValue(forKey: identifier)?.resume(returning: result)
    }

    func completeAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: false) }
    }
}

private final class OnboardingKeychainFixture: Sendable {
    private struct State {
        var password: String?
        var passwordReads = 0
        var readStatus: OSStatus?
        var addCount = 0
        var allowsCreation = false
        var afterInsertion: (@Sendable () -> Void)?
    }
    private let state = Mutex(State())

    var password: String? {
        get { state.withLock { $0.password } }
        set { state.withLock { $0.password = newValue } }
    }

    var passwordReads: Int { state.withLock { $0.passwordReads } }
    var addCount: Int { state.withLock { $0.addCount } }
    var allowsCreation: Bool {
        get { state.withLock { $0.allowsCreation } }
        set { state.withLock { $0.allowsCreation = newValue } }
    }
    var afterInsertion: (@Sendable () -> Void)? {
        get { state.withLock { $0.afterInsertion } }
        set { state.withLock { $0.afterInsertion = newValue } }
    }

    var readStatus: OSStatus? {
        get { state.withLock { $0.readStatus } }
        set { state.withLock { $0.readStatus = newValue } }
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, result in
            let query = query as NSDictionary
            guard query[kSecAttrAccount] as? String == "org.lil.wallet.password" else {
                return errSecItemNotFound
            }
            let (password, status) = state.withLock { value in
                value.passwordReads += 1
                return (value.password, value.readStatus)
            }
            if let status { return status }
            guard let password else { return errSecItemNotFound }
            result?.pointee = Data(password.utf8) as CFData
            return errSecSuccess
        }, add: { [self] query, _ in
            let data = (query as NSDictionary)[kSecValueData] as? Data
            let result: (OSStatus, (@Sendable () -> Void)?) = state.withLock {
                $0.addCount += 1
                guard $0.allowsCreation, let data, let password = String(data: data, encoding: .utf8) else {
                    XCTFail("Cancellation tests must not create credentials")
                    return (errSecNotAvailable, nil)
                }
                guard $0.password == nil else { return (errSecDuplicateItem, nil) }
                $0.password = password
                return (errSecSuccess, $0.afterInsertion)
            }
            result.1?()
            return result.0
        }, update: { _, _ in
            XCTFail("Cancellation tests must not update credentials")
            return errSecNotAvailable
        }, delete: { _ in
            XCTFail("Cancellation tests must not delete credentials")
            return errSecNotAvailable
        })
    }
}
