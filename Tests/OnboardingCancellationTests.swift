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
            let window = try await openOnboarding(agent)
            defer { window.close() }
            try await advance(window, to: stage)

            window.close()
            await settleUI()
            let passwordReads = fixture.passwordReads
            for _ in 0..<3 { agent.applicationDidBecomeActive() }

            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(fixture.passwordReads, passwordReads)
            XCTAssertFalse(NSApp.windows.contains { candidate in
                candidate.isVisible && (candidate.contentViewController is WelcomeViewController ||
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

    func testClosingRetiredSetupWindowDoesNotCancelExternalCredentialHandoff() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = OnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        agent.readCount = { fixture.passwordReads }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try await advance(window, to: .create)
        fixture.password = "externally-created-password"

        agent.applicationDidBecomeActive()
        window.close()
        await waitUntil { agent.authenticationRequests == 1 }

        XCTAssertTrue(agent.observedPendingIntent)
        XCTAssertFalse(window.isVisible)
    }

    func testReturningToWelcomeRetiresOldPasswordCallbacksAndKeepsCancellation() async throws {
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
            await settleUI()
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

    func testPasswordFailureRetryPreservesSetupAndIgnoresOldFailureClose() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = Agent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        let setupWindow = try await openOnboarding(agent)
        defer { setupWindow.close() }
        try await advance(setupWindow, to: .repeatPassword)
        let originalForm = try XCTUnwrap(setupWindow.contentViewController as? PasswordViewController)
        fixture.readStatus = errSecInteractionNotAllowed
        let firstFailure = try await showPasswordFailure(agent)
        let firstFailureWindow = try XCTUnwrap(firstFailure.controller.window)
        defer { firstFailureWindow.close() }

        fixture.readStatus = nil
        firstFailure.viewController.actionButtonTapped(firstFailure.viewController.okButton as Any)
        await settleUI()

        XCTAssertFalse(firstFailureWindow.isVisible)
        XCTAssertTrue(setupWindow.isVisible)
        XCTAssertTrue(setupWindow.contentViewController === originalForm)
        XCTAssertNil(fixture.password)
        XCTAssertEqual(fixture.addCount, 0)

        fixture.readStatus = errSecInteractionNotAllowed
        let currentFailure = try await showPasswordFailure(agent)
        let currentFailureWindow = try XCTUnwrap(currentFailure.controller.window)
        defer { currentFailureWindow.close() }
        firstFailure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstFailureWindow))
        XCTAssertTrue(currentFailureWindow.isVisible)
        XCTAssertTrue(setupWindow.isVisible)

        fixture.readStatus = nil
        currentFailure.viewController.actionButtonTapped(currentFailure.viewController.okButton as Any)
        await settleUI()
        let activeReads = fixture.passwordReads
        agent.applicationDidBecomeActive()

        XCTAssertGreaterThan(fixture.passwordReads, activeReads)
        XCTAssertFalse(currentFailureWindow.isVisible)
        XCTAssertTrue(setupWindow.isVisible)
        XCTAssertTrue(setupWindow.contentViewController === originalForm)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testClosingPasswordFailureCancelsStartupWithoutCorruptingNewAuthentication() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = SuspendedOnboardingAuthenticationAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAll() }
        agent.open()
        await waitUntil { agent.authenticationRequests == 1 }
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let failureWindow = try XCTUnwrap(failure.controller.window)
        defer { failureWindow.close() }

        failureWindow.close()
        fixture.readStatus = nil
        let cancelledReads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, cancelledReads)
        XCTAssertEqual(agent.authenticationRequests, 1)

        agent.open()
        await waitUntil { agent.authenticationRequests == 2 }
        agent.complete(1)
        await waitUntil { agent.cancelledAtReturn[1] != nil }
        await settleUI()
        XCTAssertEqual(agent.cancelledAtReturn[1], true)
        failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: failureWindow))
        let activeReads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        await settleUI()

        XCTAssertGreaterThan(fixture.passwordReads, activeReads)
        XCTAssertEqual(agent.authenticationRequests, 2)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testBiometricFailureReplacesErrorWithLivePasswordFallback() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = BiometricFallbackAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAllDeviceAttempts() }
        agent.open()
        await waitUntil { agent.deviceAttempts == 1 }
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let failureWindow = try XCTUnwrap(failure.controller.window)
        defer { failureWindow.close() }
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))

        agent.completeDeviceAttempt(1, outcome: .failed)
        let passwordWindow = try await waitForPasswordWindow(excluding: priorWindows)
        defer { passwordWindow.close() }
        let password = try XCTUnwrap(passwordWindow.contentViewController as? PasswordViewController)
        await waitUntil { password.okButton.title == Strings.tryAgain }

        XCTAssertFalse(failureWindow.isVisible)
        XCTAssertTrue(passwordWindow.isVisible)
        XCTAssertTrue(agent.authenticationResults.isEmpty)
        XCTAssertEqual(agent.deviceAttempts, 1)
        fixture.readStatus = nil
        password.actionButtonTapped(password.okButton as Any)
        XCTAssertTrue(password.passwordTextField.isEnabled)
        password.passwordTextField.stringValue = "stored-password"
        password.actionButtonTapped(password.okButton as Any)
        await waitUntil { agent.authenticationResults.count == 1 }
        await settleUI()

        XCTAssertEqual(agent.authenticationResults, [true])
        XCTAssertFalse(passwordWindow.isVisible)
        XCTAssertFalse(failureWindow.isVisible)
        XCTAssertEqual(fixture.password, "stored-password")
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testClosingSetupAlsoClosesCredentialErrorAndRetiresRetry() async throws {
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

            setupWindow.close()
            await settleUI()

            XCTAssertFalse(setupWindow.isVisible)
            XCTAssertFalse(failureWindow.isVisible)
            fixture.readStatus = nil
            let cancelledReads = fixture.passwordReads
            failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
            failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: failureWindow))
            for _ in 0..<3 {
                staleForm.passwordTextField.stringValue = "draft-password"
                staleForm.actionButtonTapped(staleForm.okButton as Any)
                await settleUI()
            }
            agent.applicationDidBecomeActive()

            XCTAssertEqual(fixture.passwordReads, cancelledReads)
            XCTAssertEqual(fixture.addCount, 0)
            XCTAssertNil(fixture.password)
            XCTAssertFalse(setupWindow.isVisible)
            XCTAssertFalse(failureWindow.isVisible)
            XCTAssertFalse(NSApp.windows.contains { candidate in
                candidate.isVisible && (candidate.contentViewController is WelcomeViewController ||
                    candidate.contentViewController is PasswordViewController ||
                    candidate.contentViewController is WaitingViewController)
            })
        }
    }

    func testClosingStartupPasswordAlsoClosesCredentialErrorAndRetiresRetry() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let agent = BiometricFallbackAgent(approvalInbox: ApprovalInbox())
        agent.keychain = fixture.keychain
        defer { agent.completeAllDeviceAttempts() }
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        agent.open()
        await waitUntil { agent.deviceAttempts == 1 }
        agent.completeDeviceAttempt(1, outcome: nil)
        let passwordWindow = try await waitForPasswordWindow(excluding: priorWindows)
        defer { passwordWindow.close() }
        let staleForm = try XCTUnwrap(passwordWindow.contentViewController as? PasswordViewController)
        await waitUntil { staleForm.passwordTextField.isEnabled }
        fixture.readStatus = errSecInteractionNotAllowed
        let failure = try await showPasswordFailure(agent)
        let failureWindow = try XCTUnwrap(failure.controller.window)
        defer { failureWindow.close() }

        passwordWindow.close()
        await waitUntil { agent.authenticationResults.count == 1 }
        await settleUI()

        XCTAssertEqual(agent.authenticationResults, [false])
        XCTAssertFalse(passwordWindow.isVisible)
        XCTAssertFalse(failureWindow.isVisible)
        fixture.readStatus = nil
        let cancelledReads = fixture.passwordReads
        failure.viewController.actionButtonTapped(failure.viewController.okButton as Any)
        failure.viewController.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: failureWindow))
        staleForm.passwordTextField.stringValue = "stored-password"
        staleForm.actionButtonTapped(staleForm.okButton as Any)
        staleForm.cancelButtonTapped(staleForm.cancelButton)
        agent.applicationDidBecomeActive()
        await settleUI()

        XCTAssertEqual(agent.authenticationResults, [false])
        XCTAssertEqual(agent.deviceAttempts, 1)
        XCTAssertEqual(fixture.passwordReads, cancelledReads)
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertFalse(passwordWindow.isVisible)
        XCTAssertFalse(failureWindow.isVisible)
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
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        agent.applicationDidBecomeActive()
        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is WaitingViewController
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

    func complete(_ identifier: Int) {
        pending.removeValue(forKey: identifier)?.resume(returning: false)
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

private final class OnboardingKeychainFixture: Sendable {
    private struct State {
        var password: String?
        var passwordReads = 0
        var readStatus: OSStatus?
        var addCount = 0
    }
    private let state = Mutex(State())

    var password: String? {
        get { state.withLock { $0.password } }
        set { state.withLock { $0.password = newValue } }
    }

    var passwordReads: Int { state.withLock { $0.passwordReads } }
    var addCount: Int { state.withLock { $0.addCount } }

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
        }, add: { [self] _, _ in
            state.withLock { $0.addCount += 1 }
            XCTFail("Cancellation tests must not create credentials")
            return errSecNotAvailable
        }, update: { _, _ in
            XCTFail("Cancellation tests must not update credentials")
            return errSecNotAvailable
        }, delete: { _ in
            XCTFail("Cancellation tests must not delete credentials")
            return errSecNotAvailable
        })
    }
}
