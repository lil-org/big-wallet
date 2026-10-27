import WalletFlows
import WalletDomain
@testable import WalletAuthority
import AppKit
import Security
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class OnboardingCancellationTests: XCTestCase {
    func testTemporaryKeychainFailureShowsRetryWithoutDiscardingTheAccessSession() throws {
        let fixture = WalletAccessTestFixture()
        let session = try fixture.unlock()
        var authenticationAttempts = 0
        var events = [StartupCredentialCoordinator.Event]()
        let flow = StartupCredentialCoordinator(dependencies: .init(
            credentials: fixture.credentials,
            attemptBiometrics: { _, _ in authenticationAttempts += 1; return nil },
            access: fixture.access
        )) { events.append($0) }
        defer { flow.windowController?.close() }
        flow.requestAccess()
        fixture.keychain.readStatus = errSecInteractionNotAllowed

        flow.requestAccess()

        let unavailable = try XCTUnwrap(flow.windowController?.contentViewController as? WaitingViewController)
        XCTAssertFalse(fixture.access.isLocked)
        XCTAssertTrue(flow.accessSession === session)
        XCTAssertEqual(events, [.authenticated])
        fixture.keychain.readStatus = nil
        unavailable.actionButtonTapped(unavailable.okButton as Any)
        XCTAssertEqual(events, [.authenticated, .authenticated])
        XCTAssertEqual(authenticationAttempts, 0)
        XCTAssertTrue(flow.accessSession === session)
        XCTAssertNil(flow.windowController)
    }

    func testExplicitOpenUpdatesAnExistingCredentialRetry() async throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        var events = [StartupCredentialCoordinator.Event]()
        let flow = StartupCredentialCoordinator(dependencies: .init(
            credentials: fixture.credentials, attemptBiometrics: { _, _ in nil }, access: fixture.access
        )) { events.append($0) }
        defer { flow.windowController?.close(); flow.cancel() }
        fixture.keychain.readStatus = errSecInteractionNotAllowed
        flow.requestAccess()
        let previous = try XCTUnwrap(flow.windowController?.contentViewController as? WaitingViewController)

        flow.requestAccess(openWallet: true)

        let current = try XCTUnwrap(flow.windowController?.contentViewController as? WaitingViewController)
        XCTAssertFalse(current === previous)
        fixture.keychain.readStatus = nil
        fixture.keychain.passwordData = Data("replacement".utf8)
        previous.actionButtonTapped(previous.okButton as Any)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(fixture.access.isLocked)
        current.actionButtonTapped(current.okButton as Any)
        XCTAssertEqual(events, [.unlockRequested])
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let password = try XCTUnwrap(flow.windowController?.contentViewController as? PasswordViewController)
        password.passwordTextField.stringValue = "replacement"
        password.actionButtonTapped(password.okButton as Any)

        XCTAssertEqual(events, [.unlockRequested, .authenticated])
        XCTAssertTrue(fixture.access.checkAccess())
        XCTAssertNil(flow.windowController)
    }

    func testLockClearsStartupPasswordAndRequiresExplicitUnlock() async throws {
        let fixture = WalletAccessTestFixture()
        var attempts = 0
        var events = [StartupCredentialCoordinator.Event]()
        let flow = StartupCredentialCoordinator(dependencies: .init(
            credentials: fixture.credentials,
            attemptBiometrics: { _, _ in attempts += 1; return nil },
            access: fixture.access
        )) { events.append($0) }
        defer { flow.windowController?.close(); flow.cancel() }
        flow.requestAccess()
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let window = try XCTUnwrap(flow.windowController?.window)
        let oldForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        oldForm.passwordTextField.stringValue = "password"

        fixture.access.lock(reason: .systemSleep)

        let locked = try XCTUnwrap(window.contentViewController as? WalletLockedViewController)
        XCTAssertTrue(oldForm.passwordTextField.stringValue.isEmpty)
        XCTAssertFalse(oldForm.passwordTextField.isEnabled)
        oldForm.actionButtonTapped(oldForm.okButton as Any)
        for _ in 0..<3 { flow.refresh() }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(window.contentViewController === locked)

        locked.unlockWallet()
        XCTAssertEqual(events, [.unlockRequested])
        await waitUntil { window.contentViewController is PasswordViewController }
        let freshForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        freshForm.passwordTextField.stringValue = "password"
        freshForm.actionButtonTapped(freshForm.okButton as Any)
        XCTAssertEqual(events, [.unlockRequested, .authenticated])
        XCTAssertTrue(fixture.access.checkAccess())
        locked.unlockWallet()
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(flow.windowController)
    }

    func testExplicitStartupUnlockOpensAccountsAfterTheOriginalOpenWasCanceledByLock() async throws {
        let fixture = WalletAccessTestFixture()
        let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
            credentials: fixture.credentials, attemptBiometrics: { _, _ in nil }, access: fixture.access
        ))
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
        }
        agent.open()
        await waitUntil {
            NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController }
        }
        let startup = try XCTUnwrap(NSApp.windows.first {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController
        })
        fixture.access.lock(reason: .systemSleep)
        let locked = try XCTUnwrap(startup.contentViewController as? WalletLockedViewController)
        agent.applicationDidBecomeActive()
        XCTAssertTrue(startup.contentViewController === locked)
        XCTAssertFalse(NSApp.windows.contains {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController
        })

        locked.unlockWallet()
        await waitUntil { startup.contentViewController is PasswordViewController }
        let password = try XCTUnwrap(startup.contentViewController as? PasswordViewController)
        password.passwordTextField.stringValue = "password"
        password.actionButtonTapped(password.okButton as Any)

        await waitUntil {
            NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController }
        }
        XCTAssertFalse(startup.isVisible)
        XCTAssertTrue(fixture.access.checkAccess())
        XCTAssertEqual(NSApp.windows.filter {
            !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController
        }.count, 1)
    }

    func testExplicitOpenSurvivesCredentialReplacementOrRemoval() async throws {
        enum Change: CaseIterable { case replacement, removal, replacementAfterRetry }
        for change in Change.allCases {
            let fixture = WalletAccessTestFixture()
            let previous = try fixture.unlock()
            let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
                credentials: fixture.credentials, canCreatePassword: true,
                attemptBiometrics: { _, _ in nil }, access: fixture.access
            ))
            let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            defer {
                NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            }
            agent.open()
            let accountsWindow = try XCTUnwrap(NSApp.windows.first {
                !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController
            })
            let unavailable: WaitingViewController?
            if change == .replacementAfterRetry {
                fixture.keychain.readStatus = errSecInteractionNotAllowed
                agent.open()
                unavailable = try XCTUnwrap(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }
                    .compactMap { $0.contentViewController as? WaitingViewController }.first)
                XCTAssertTrue(fixture.access.session === previous)
                XCTAssertFalse(fixture.access.isLocked)
                fixture.keychain.readStatus = nil
            } else { unavailable = nil }
            fixture.keychain.passwordData = change == .removal ? nil : Data("replacement".utf8)

            if let unavailable { unavailable.actionButtonTapped(unavailable.okButton as Any) }
            else { agent.open() }

            XCTAssertTrue(fixture.access.isLocked)
            XCTAssertFalse(fixture.credentials.validateAccess(previous))
            XCTAssertTrue(accountsWindow.contentViewController is WalletLockedViewController)
            if change == .removal {
                XCTAssertTrue(NSApp.windows.contains {
                    !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is WelcomeViewController
                })
                fixture.keychain.passwordData = Data("replacement".utf8)
                agent.applicationDidBecomeActive()
            }
            await waitUntil {
                NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController }
            }
            let startup = try XCTUnwrap(NSApp.windows.first {
                !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController
            })
            let password = try XCTUnwrap(startup.contentViewController as? PasswordViewController)
            password.passwordTextField.stringValue = "replacement"
            password.actionButtonTapped(password.okButton as Any)

            XCTAssertTrue(fixture.access.checkAccess())
            XCTAssertFalse(startup.isVisible)
            XCTAssertTrue(accountsWindow.isVisible)
            XCTAssertTrue(accountsWindow.contentViewController is AccountsListViewController)
            XCTAssertEqual(NSApp.windows.filter {
                !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController
            }.count, 1)
        }
    }

    func testCredentialReauthenticationStopsAfterCancellationOrAnotherLock() async throws {
        for locksAgain in [false, true] {
            let fixture = WalletAccessTestFixture()
            try fixture.unlock()
            let agent = Agent(approvalInbox: ApprovalInbox(), credentialDependencies: .init(
                credentials: fixture.credentials, attemptBiometrics: { _, _ in nil }, access: fixture.access
            ))
            let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            defer {
                NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.forEach { $0.close() }
            }
            agent.open()
            fixture.keychain.passwordData = Data("replacement".utf8)
            agent.open()
            await waitUntil {
                NSApp.windows.contains { !originalWindows.contains(ObjectIdentifier($0)) && $0.contentViewController is PasswordViewController }
            }
            let password = try XCTUnwrap(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }
                .compactMap { $0.contentViewController as? PasswordViewController }.first)
            password.passwordTextField.stringValue = "replacement"

            if locksAgain { fixture.access.lock(reason: .systemSleep) }
            else { password.cancelButtonTapped(password.cancelButton) }
            password.actionButtonTapped(password.okButton as Any)
            agent.applicationDidBecomeActive()

            XCTAssertTrue(fixture.access.isLocked)
            XCTAssertTrue(password.passwordTextField.stringValue.isEmpty)
            XCTAssertFalse(NSApp.windows.contains {
                !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible && $0.contentViewController is AccountsListViewController
            })
        }
    }

    func testLockDiscardsSuccessfulStartupBiometricsThatReturnLate() async throws {
        let fixture = WalletAccessTestFixture()
        let gate = AuthenticationGate()
        var returnedGrant: WalletAuthenticationGrant?
        var events = [StartupCredentialCoordinator.Event]()
        let flow = StartupCredentialCoordinator(dependencies: .init(
            credentials: fixture.credentials,
            attemptBiometrics: { _, challenge in
                guard let grant = try? fixture.credentials.verify(password: "password", challenge: challenge) else { return .failed }
                returnedGrant = grant
                _ = await gate.attempt()
                return .granted(grant)
            },
            access: fixture.access
        )) { events.append($0) }
        defer { flow.windowController?.close(); gate.completeAll() }
        flow.requestAccess()
        await gate.waitForAttempt(1)
        fixture.access.lock(reason: .sessionInactive)
        gate.complete(1, outcome: .succeeded)
        await gate.waitForReturn(1)
        await Task.yield()
        flow.refresh()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(fixture.access.isLocked)
        XCTAssertNil(flow.accessSession)
        XCTAssertNil(flow.windowController)
        XCTAssertEqual(gate.count, 1)
        let grant = try XCTUnwrap(returnedGrant)
        XCTAssertNil(fixture.credentials.accessSession(authorization: grant))
    }

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
                NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil)
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
                NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil)
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
        let fixture = OnboardingKeychainFixture(postCreation: {
            NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil)
        })
        fixture.allowsCreation = true
        let agent = makeAgent(fixture)
        let window = try await openOnboarding(agent)
        defer { window.close() }
        try advance(window, to: .repeatPassword)
        let password = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        let changed = expectation(description: "Committed password notifies storage")
        changed.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("walletsChanged"), object: nil, queue: nil) { _ in changed.fulfill() }
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

    func testReplacingAnExistingCredentialRequiresAFreshStartupSession() async throws {
        let fixture = OnboardingKeychainFixture()
        fixture.password = "original"
        let flow = makeFlow(fixture)
        defer { flow.cancel() }
        flow.requestAccess()
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let first = try XCTUnwrap(flow.windowController?.contentViewController as? PasswordViewController)
        first.passwordTextField.stringValue = "original"
        first.actionButtonTapped(first.okButton as Any)
        let previous = try XCTUnwrap(flow.accessSession)
        XCTAssertTrue(fixture.credentials.validateAccess(previous))

        fixture.password = "replacement"
        flow.requestAccess()

        XCTAssertNil(flow.accessSession)
        XCTAssertFalse(fixture.credentials.validateAccess(previous))
        await waitUntil { flow.windowController?.contentViewController is PasswordViewController }
        let second = try XCTUnwrap(flow.windowController?.contentViewController as? PasswordViewController)
        second.passwordTextField.stringValue = "replacement"
        second.actionButtonTapped(second.okButton as Any)
        let current = try XCTUnwrap(flow.accessSession)
        XCTAssertFalse(current === previous)
        XCTAssertTrue(fixture.credentials.validateAccess(current))
    }

    private enum Stage { case welcome, create, repeatPassword, returnedWelcome }

    private func dependencies(_ fixture: OnboardingKeychainFixture, authentication: AuthenticationGate? = nil) -> StartupCredentialCoordinator.Dependencies {
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.credentials = fixture.credentials
        dependencies.canCreatePassword = true
        dependencies.attemptBiometrics = { _, challenge in
            fixture.authentication(await authentication?.attempt(), challenge: challenge)
        }
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
    private var pending = [Int: TestGate<WalletAuthenticationOutcome?>]()
    private var entries = [Int: XCTestExpectation]()
    private var returns = [Int: XCTestExpectation]()

    func attempt() async -> WalletAuthenticationOutcome? {
        count += 1
        let identifier = count
        let gate = TestGate<WalletAuthenticationOutcome?>()
        pending[identifier] = gate
        entries.removeValue(forKey: identifier)?.fulfill()
        let outcome = await gate.wait()
        cancelledAtReturn[identifier] = Task.isCancelled
        returns.removeValue(forKey: identifier)?.fulfill()
        return outcome
    }
    func complete(_ identifier: Int, outcome: WalletAuthenticationOutcome?) {
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
    private let authorityID = UUID()
    private let postCreation: @MainActor @Sendable () -> Void

    init(postCreation: @escaping @MainActor @Sendable () -> Void = {}) {
        self.postCreation = postCreation
    }

    var credentials: WalletCredentials {
        WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID,
            postCreation: postCreation)
    }

    func authentication(_ outcome: WalletAuthenticationOutcome?, challenge: WalletAuthenticationChallenge) -> WalletAuthenticationResult? {
        switch outcome {
        case .succeeded?:
            guard let password,
                  let grant = try? credentials.verify(password: password, challenge: challenge) else { return .failed }
            return .granted(grant)
        case .failed?: return .failed
        case .interactionUnavailable?: return .interactionUnavailable
        case nil: return nil
        }
    }

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
