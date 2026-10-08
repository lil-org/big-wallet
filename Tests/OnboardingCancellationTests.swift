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
            let agent = makeAgent(fixture)
            let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let window = try await openOnboarding(agent)
            defer { window.close() }
            try advance(window, to: stage)
            window.close()
            await waitUntil { !window.isVisible }
            let reads = fixture.passwordReads
            for _ in 0..<3 {
                agent.applicationDidBecomeActive()
                NotificationCenter.default.post(name: .walletsChanged, object: nil)
            }
            XCTAssertEqual(fixture.passwordReads, reads)
            XCTAssertFalse(NSApp.windows.contains {
                !priorWindows.contains(ObjectIdentifier($0)) && $0.isVisible
            })
        }
    }

    func testRetiredFormAndWindowCannotCancelReplacementOnboarding() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = makeAgent(fixture)
        let first = try await openOnboarding(agent)
        try advance(first, to: .repeatPassword)
        let retired = try XCTUnwrap(first.contentViewController as? PasswordViewController)
        first.close()
        let next = try await openOnboarding(agent)
        defer { next.close() }
        retired.passwordTextField.stringValue = "draft-password"
        retired.actionButtonTapped(retired.okButton as Any)
        retired.cancelButtonTapped(retired.cancelButton)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: first)
        let reads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertGreaterThan(fixture.passwordReads, reads)
        XCTAssertTrue(next.isVisible)
        XCTAssertTrue(next.contentViewController is WelcomeViewController)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testExternalCredentialRequiresAuthenticationAndRetiresSetupCallbacks() async throws {
        let fixture = OnboardingKeychainFixture()
        let authentication = AuthenticationGate()
        let agent = makeAgent(fixture, authentication: authentication)
        defer { authentication.completeAll() }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try advance(window, to: .create)
        let oldForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        fixture.password = "externally-created-password"
        agent.applicationDidBecomeActive()
        oldForm.cancelButtonTapped(oldForm.cancelButton)
        await authentication.waitForAttempt(1)
        XCTAssertTrue(window.contentViewController is WaitingViewController)
        XCTAssertTrue(oldForm.passwordTextField.stringValue.isEmpty)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testReturningToWelcomeRetiresOldActionsAndKeepsWindowCancellation() async throws {
        let fixture = OnboardingKeychainFixture()
        let agent = makeAgent(fixture)
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try advance(window, to: .create)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        password.cancelButtonTapped(password.cancelButton)
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        password.passwordTextField.stringValue = "draft-password"
        password.actionButtonTapped(password.okButton as Any)
        password.cancelButtonTapped(password.cancelButton)
        XCTAssertTrue(window.contentViewController === welcome)
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        window.close()
        let reads = fixture.passwordReads
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, reads)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testStorageFailureReplacesEverySetupStageAndRequiresExplicitRetry() async throws {
        for stage in [Stage.welcome, .create, .repeatPassword] {
            let fixture = OnboardingKeychainFixture()
            let agent = makeAgent(fixture)
            let window = try await openOnboarding(agent)
            defer { window.close() }
            try advance(window, to: stage)
            let oldForm = window.contentViewController as? PasswordViewController
            let oldWelcome = window.contentViewController as? WelcomeViewController
            fixture.readStatus = errSecInteractionNotAllowed
            agent.applicationDidBecomeActive()
            let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
            XCTAssertEqual(failure.okButton.title, Strings.tryAgain)
            XCTAssertEqual(oldForm?.passwordTextField.stringValue ?? "", "")
            fixture.readStatus = nil
            let reads = fixture.passwordReads
            for _ in 0..<3 {
                agent.open()
                agent.applicationDidBecomeActive()
                NotificationCenter.default.post(name: .walletsChanged, object: nil)
            }
            oldForm?.actionButtonTapped(oldForm?.okButton as Any)
            if let oldForm { oldForm.cancelButtonTapped(oldForm.cancelButton) }
            oldWelcome?.actionButtonTapped(oldWelcome?.getStartedButton as Any)
            XCTAssertEqual(fixture.passwordReads, reads)
            XCTAssertTrue(window.contentViewController === failure)
            failure.actionButtonTapped(failure.okButton as Any)
            let fresh = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
            failure.actionButtonTapped(failure.okButton as Any)
            failure.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            XCTAssertTrue(window.contentViewController === fresh)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(fixture.addCount, 0)
        }
    }

    func testClosingPasswordFailureRetiresSetupAndRetryCallbacks() async throws {
        for stage in [Stage.create, .repeatPassword] {
            let fixture = OnboardingKeychainFixture()
            let agent = makeAgent(fixture)
            let window = try await openOnboarding(agent)
            try advance(window, to: stage)
            let oldForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
            fixture.readStatus = errSecInteractionNotAllowed
            agent.applicationDidBecomeActive()
            let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
            window.close()
            fixture.readStatus = nil
            let reads = fixture.passwordReads
            oldForm.passwordTextField.stringValue = "retired-password"
            oldForm.actionButtonTapped(oldForm.okButton as Any)
            oldForm.cancelButtonTapped(oldForm.cancelButton)
            failure.actionButtonTapped(failure.okButton as Any)
            agent.applicationDidBecomeActive()
            XCTAssertEqual(fixture.passwordReads, reads)
            XCTAssertEqual(fixture.addCount, 0)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testRetryRechecksUnavailableAndNewlyCreatedCredentials() async throws {
        let fixture = OnboardingKeychainFixture()
        let authentication = AuthenticationGate()
        let agent = makeAgent(fixture, authentication: authentication)
        defer { authentication.completeAll() }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try advance(window, to: .repeatPassword)
        fixture.readStatus = errSecInteractionNotAllowed
        agent.applicationDidBecomeActive()
        let firstFailure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        firstFailure.actionButtonTapped(firstFailure.okButton as Any)
        let nextFailure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertFalse(firstFailure === nextFailure)
        XCTAssertEqual(authentication.count, 0)
        fixture.readStatus = nil
        fixture.password = "externally-created-password"
        nextFailure.actionButtonTapped(nextFailure.okButton as Any)
        await authentication.waitForAttempt(1)
        firstFailure.actionButtonTapped(firstFailure.okButton as Any)
        nextFailure.actionButtonTapped(nextFailure.okButton as Any)
        for _ in 0..<3 { agent.open() }
        XCTAssertEqual(authentication.count, 1)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testOldSuccessfulAuthenticationCannotFinishReplacementFlow() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let authentication = AuthenticationGate()
        var results = [StartupCredentialCoordinator.Event]()
        let flow = makeFlow(fixture, authentication: authentication) { results.append($0) }
        defer { flow.cancel(); authentication.completeAll() }
        flow.requestAccess()
        await authentication.waitForAttempt(1)
        fixture.readStatus = errSecInteractionNotAllowed
        flow.refresh()
        let window = try XCTUnwrap(flow.windowController?.window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        fixture.readStatus = nil
        failure.actionButtonTapped(failure.okButton as Any)
        await authentication.waitForAttempt(2)
        authentication.complete(1, outcome: .succeeded)
        await authentication.waitForReturn(1)
        XCTAssertEqual(authentication.cancelledAtReturn[1], true)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(window.contentViewController is WaitingViewController)
        authentication.complete(2, outcome: nil)
        await waitUntil { window.contentViewController is PasswordViewController }
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        password.cancelButtonTapped(password.cancelButton)
        XCTAssertEqual(results, [.cancelled])
    }

    func testRetiredBiometricFailureCannotReplaceExplicitRetryScreen() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let authentication = AuthenticationGate()
        let flow = makeFlow(fixture, authentication: authentication)
        defer { flow.cancel(); authentication.completeAll() }
        flow.requestAccess()
        await authentication.waitForAttempt(1)
        fixture.readStatus = errSecInteractionNotAllowed
        flow.refresh()
        let window = try XCTUnwrap(flow.windowController?.window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        authentication.complete(1, outcome: .failed)
        await authentication.waitForReturn(1)
        XCTAssertTrue(window.contentViewController === failure)
        fixture.readStatus = nil
        failure.actionButtonTapped(failure.okButton as Any)
        await authentication.waitForAttempt(2)
        authentication.complete(2, outcome: .failed)
        await waitUntil { window.contentViewController is PasswordViewController }
        XCTAssertTrue(window.isVisible)
    }

    func testStartupPasswordFailureUsesSameWindowAndRetiresForm() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let flow = makeFlow(fixture)
        defer { flow.cancel() }
        flow.requestAccess()
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let window = try XCTUnwrap(flow.windowController?.window)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        password.passwordTextField.stringValue = "draft-password"
        fixture.readStatus = errSecInteractionNotAllowed
        flow.refresh()
        XCTAssertTrue(flow.windowController?.window === window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertTrue(password.passwordTextField.stringValue.isEmpty)
        window.close()
        fixture.readStatus = nil
        let reads = fixture.passwordReads
        password.passwordTextField.stringValue = "stored-password"
        password.actionButtonTapped(password.okButton as Any)
        failure.actionButtonTapped(failure.okButton as Any)
        flow.refresh()
        XCTAssertEqual(fixture.passwordReads, reads)
        XCTAssertFalse(window.isVisible)
    }

    func testPasswordDisappearingDuringAuthenticationRetiresItsResult() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "stored-password"
        let authentication = AuthenticationGate()
        var results = [StartupCredentialCoordinator.Event]()
        let flow = makeFlow(fixture, authentication: authentication) { results.append($0) }
        defer { flow.cancel(); authentication.completeAll() }
        flow.requestAccess()
        await authentication.waitForAttempt(1)
        fixture.password = nil
        flow.refresh()
        let window = try XCTUnwrap(flow.windowController?.window)
        authentication.complete(1, outcome: .succeeded)
        await authentication.waitForReturn(1)
        XCTAssertTrue(window.contentViewController is WelcomeViewController)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(authentication.cancelledAtReturn[1], true)
    }

    func testRepeatedOpenDeduplicatesSetupAndAuthentication() async throws {
        let fixture = OnboardingKeychainFixture()
        let authentication = AuthenticationGate()
        let agent = makeAgent(fixture, authentication: authentication)
        defer { authentication.completeAll() }
        let window = try await openOnboarding(agent)
        defer { window.close() }
        let welcome = window.contentViewController
        for _ in 0..<5 { agent.open() }
        XCTAssertTrue(window.contentViewController === welcome)
        fixture.password = "external-password"
        agent.applicationDidBecomeActive()
        await authentication.waitForAttempt(1)
        for _ in 0..<5 {
            agent.open()
            agent.applicationDidBecomeActive()
        }
        XCTAssertEqual(authentication.count, 1)
    }

    func testDockHandoffDeduplicatesAndIgnoresRetiredSuccess() async throws {
        let fixture = OnboardingKeychainFixture()
        let handoff = HandoffGate()
        var events = [StartupCredentialCoordinator.Event]()
        var dependencies = dependencies(fixture)
        dependencies.canCreatePassword = false
        dependencies.openDock = { await handoff.open() }
        let flow = StartupCredentialCoordinator(dependencies: dependencies) { events.append($0) }
        defer { flow.cancel(); handoff.completeAll() }
        flow.requestAccess()
        await handoff.waitForAttempt(1)
        XCTAssertEqual(events, [.setupRequiredInDockApp])
        for _ in 0..<5 { flow.requestAccess() }
        XCTAssertEqual(events, Array(repeating: .setupRequiredInDockApp, count: 6))
        XCTAssertEqual(handoff.count, 1)
        fixture.readStatus = errSecInteractionNotAllowed
        flow.refresh()
        let window = try XCTUnwrap(flow.windowController?.window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        fixture.readStatus = nil
        failure.actionButtonTapped(failure.okButton as Any)
        await handoff.waitForAttempt(2)
        handoff.complete(1, result: true)
        await handoff.waitForReturn(1)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(events.contains(.handedOff))
        handoff.complete(2, result: false)
        await waitUntil { (window.contentViewController as? WaitingViewController)?.okButton.title == Strings.tryAgain }
        let nextFailure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        nextFailure.actionButtonTapped(nextFailure.okButton as Any)
        await handoff.waitForAttempt(3)
        handoff.complete(3, result: true)
        await waitUntil { !window.isVisible }
        XCTAssertEqual(events.filter { $0 == .handedOff }.count, 1)
        let reads = fixture.passwordReads
        flow.refresh()
        XCTAssertEqual(fixture.passwordReads, reads)
    }

    func testCommittedPasswordCreationNotifiesAfterItsFlowCloses() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.allowsCreation = true
        let agent = makeAgent(fixture)
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try advance(window, to: .repeatPassword)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        let changed = expectation(description: "Committed password notifies storage")
        changed.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: .walletsChanged, object: nil, queue: nil) { _ in changed.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
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
        password.actionButtonTapped(password.okButton as Any)
        agent.applicationDidBecomeActive()
        XCTAssertEqual(fixture.passwordReads, reads)
    }

    func testStartupAuthenticationIsRememberedOnlyUntilCredentialStateChanges() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "x"
        var events = [StartupCredentialCoordinator.Event]()
        let flow = makeFlow(fixture) { events.append($0) }
        defer { flow.cancel() }
        flow.requestAccess()
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let form = try XCTUnwrap(flow.windowController?.contentViewController as? PasswordViewController)
        form.passwordTextField.stringValue = "x"
        form.actionButtonTapped(form.okButton as Any)
        XCTAssertEqual(events, [.authenticated])
        XCTAssertNil(flow.windowController)
        flow.requestAccess()
        XCTAssertEqual(events, [.authenticated, .authenticated])
        fixture.password = nil
        flow.requestAccess()
        XCTAssertTrue(flow.windowController?.contentViewController is WelcomeViewController)
        fixture.password = "winner"
        flow.refresh()
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        XCTAssertEqual(events, [.authenticated, .authenticated])
        XCTAssertEqual(fixture.addCount, 0)
    }

    private enum Stage { case welcome, create, repeatPassword, returnedWelcome }

    private func dependencies(_ fixture: OnboardingKeychainFixture, authentication: AuthenticationGate? = nil) -> StartupCredentialCoordinator.Dependencies {
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.keychain = fixture.keychain
        dependencies.canCreatePassword = true
        dependencies.attemptBiometrics = { _ in await authentication?.attempt() }
        return dependencies
    }

    private func makeAgent(_ fixture: OnboardingKeychainFixture, authentication: AuthenticationGate? = nil) -> Agent {
        Agent(approvalInbox: ApprovalInbox(), credentialDependencies: dependencies(fixture, authentication: authentication))
    }

    private func makeFlow(_ fixture: OnboardingKeychainFixture, authentication: AuthenticationGate? = nil, onEvent: @escaping (StartupCredentialCoordinator.Event) -> Void = { _ in }) -> StartupCredentialCoordinator {
        StartupCredentialCoordinator(dependencies: dependencies(fixture, authentication: authentication), onEvent: onEvent)
    }

    private func openOnboarding(_ agent: Agent) async throws -> NSWindow {
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        agent.open()
        let window = try XCTUnwrap(NSApp.windows.first {
            !priorWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is WelcomeViewController
        })
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        return window
    }

    private func advance(_ window: NSWindow, to stage: Stage) throws {
        guard stage != .welcome else { return }
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        switch stage {
        case .repeatPassword:
            password.passwordTextField.stringValue = "draft-password"
            password.actionButtonTapped(password.okButton as Any)
            let repeated = try XCTUnwrap(window.contentViewController as? PasswordViewController)
            XCTAssertEqual(repeated.titleLabel.stringValue, Strings.repeatPassword)
            XCTAssertTrue(password.passwordTextField.stringValue.isEmpty)
        case .returnedWelcome:
            password.cancelButtonTapped(password.cancelButton)
            XCTAssertTrue(window.contentViewController is WelcomeViewController)
        case .welcome, .create:
            break
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        await expectEventually(predicate)
    }

}

@MainActor
private final class AuthenticationGate {
    private(set) var count = 0
    private(set) var cancelledAtReturn = [Int: Bool]()
    private var pending = [Int: TestGate<DeviceAuthentication.Outcome?>]()
    private var entries = [Int: XCTestExpectation]()
    private var returns = [Int: XCTestExpectation]()

    func attempt() async -> DeviceAuthentication.Outcome? {
        count += 1
        let identifier = count
        let gate = TestGate<DeviceAuthentication.Outcome?>()
        pending[identifier] = gate
        entries.removeValue(forKey: identifier)?.fulfill()
        let outcome = await gate.wait()
        cancelledAtReturn[identifier] = Task.isCancelled
        returns.removeValue(forKey: identifier)?.fulfill()
        return outcome
    }
    func complete(_ identifier: Int, outcome: DeviceAuthentication.Outcome?) {
        pending.removeValue(forKey: identifier)?.resolve(outcome)
    }
    func completeAll() {
        let gates = Array(pending.values)
        pending.removeAll()
        gates.forEach { $0.resolve(.failed) }
    }
    func waitForAttempt(_ identifier: Int) async {
        guard count < identifier else { return }
        let event = XCTestExpectation(description: "authentication attempt entered")
        entries[identifier] = event
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func waitForReturn(_ identifier: Int) async {
        guard cancelledAtReturn[identifier] == nil else { return }
        let event = XCTestExpectation(description: "authentication attempt returned")
        returns[identifier] = event
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}

@MainActor
private final class HandoffGate {
    private(set) var count = 0
    private var pending = [Int: TestGate<Bool>]()
    private var returned = Set<Int>()
    private var entries = [Int: XCTestExpectation]()
    private var returns = [Int: XCTestExpectation]()

    func open() async -> Bool {
        count += 1
        let identifier = count
        let gate = TestGate<Bool>()
        pending[identifier] = gate
        entries.removeValue(forKey: identifier)?.fulfill()
        let result = await gate.wait()
        returned.insert(identifier)
        returns.removeValue(forKey: identifier)?.fulfill()
        return result
    }
    func complete(_ identifier: Int, result: Bool) {
        pending.removeValue(forKey: identifier)?.resolve(result)
    }
    func completeAll() {
        let gates = Array(pending.values)
        pending.removeAll()
        gates.forEach { $0.resolve(false) }
    }
    func waitForAttempt(_ identifier: Int) async {
        guard count < identifier else { return }
        let event = XCTestExpectation(description: "handoff entered")
        entries[identifier] = event
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func waitForReturn(_ identifier: Int) async {
        guard !returned.contains(identifier) else { return }
        let event = XCTestExpectation(description: "handoff returned")
        returns[identifier] = event
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 2)
        XCTAssertEqual(result, .completed)
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
