import WalletDomain
@testable import WalletAuthority
import AppKit
import Security
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class WindowAuthenticationSessionTests: XCTestCase {
    func testPasswordSheetPreservesOwnerAndCompletesOnlyAfterDismissal() async throws {
        let fixture = AuthenticationKeychainFixture(password: "x")
        let controller = makeWindow()
        defer { controller.close() }
        let original = controller.contentViewController
        let authentication = begin(controller, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: controller)
        XCTAssertTrue(controller.contentViewController === original)
        XCTAssertTrue(sheet.sheetParent === controller.window)
        submit("x", to: form)
        let result = await authentication.value
        let grant = try XCTUnwrap(result)
        let access = try XCTUnwrap(fixture.credentials.accessSession(authorization: grant))
        XCTAssertTrue(fixture.credentials.isCurrent(access))
        XCTAssertNil(fixture.credentials.accessSession(authorization: grant))
        access.invalidate()
        XCTAssertNil(sheet.sheetParent)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        XCTAssertNil(controller.currentAuthenticationSession)
        XCTAssertTrue(controller.contentViewController === original)
        form.actionButtonTapped(form.okButton as Any)
        form.cancelButtonTapped(form.cancelButton)
        XCTAssertTrue(controller.contentViewController === original)
    }

    func testCancellationInvalidatesTheChallengeBeforeAuthenticationReturns() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let dependencies = dependencies(fixture)
        let challenge = dependencies.credentials.makeWalletAccessChallenge()
        let controller = makeWindow()
        defer { controller.close() }
        let authentication = Task {
            await controller.authenticate(reason: .showPrivateKey, challenge: challenge, dependencies: dependencies)
        }
        let (_, form) = try await passwordSheet(in: controller)
        form.cancelButtonTapped(form.cancelButton)
        await assertResult(authentication, equals: false)
        XCTAssertThrowsError(try dependencies.credentials.verify(password: "password", challenge: challenge)) { error in
            guard case WalletCredentialError.authorizationUnavailable = error else {
                return XCTFail("Expected retired authorization, received \(error)")
            }
        }
    }

    func testPasswordAuthenticationRestoresSecretOwnerEligibilityBeforeReturning() async throws {
        let initialActivationPolicy = NSApp.activationPolicy()
        defer { _ = NSApp.setActivationPolicy(initialActivationPolicy) }
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        let owner = try XCTUnwrap(controller.window)
        defer { controller.close() }
        try await requireActiveKeyWindow(owner)
        let dependencies = dependencies(fixture)
        var authenticationSheet: NSWindow?
        var wasDismissedAtReturn = false
        var ownerWasEligibleAtReturn = false
        let authentication = Task {
            let result = await controller.authenticate(reason: .showPrivateKey, challenge: dependencies.credentials.makeWalletAccessChallenge(), dependencies: dependencies)
            wasDismissedAtReturn = authenticationSheet?.sheetParent == nil && authenticationSheet?.isVisible == false
            ownerWasEligibleAtReturn = NSApp.isActive && NativeSecretAlertPresentation.acceptsKeyWindow(
                NSApp.keyWindow, owner: owner, presentation: nil
            )
            return result
        }
        defer { authentication.cancel() }
        let (sheet, form) = try await passwordSheet(in: controller)
        authenticationSheet = sheet
        try await requireActiveKeyWindow(sheet)
        submit("password", to: form)
        await assertResult(authentication, equals: true)
        XCTAssertTrue(wasDismissedAtReturn)
        XCTAssertTrue(ownerWasEligibleAtReturn)
        XCTAssertTrue(NSApp.keyWindow === owner)
    }

    func testPasswordCompletionPreservesUnrelatedFocusAndLeavesSecretOwnerIneligible() async throws {
        let initialActivationPolicy = NSApp.activationPolicy()
        defer { _ = NSApp.setActivationPolicy(initialActivationPolicy) }
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        let owner = try XCTUnwrap(controller.window)
        let otherController = makeWindow()
        let other = try XCTUnwrap(otherController.window)
        defer { controller.close(); otherController.close() }
        try await requireActiveKeyWindow(owner)
        let dependencies = dependencies(fixture)
        var authenticationSheet: NSWindow?
        var wasDismissedAtReturn = false
        var ownerWasEligibleAtReturn = true
        var otherWasKeyAtReturn = false
        let authentication = Task {
            let result = await controller.authenticate(reason: .showPrivateKey, challenge: dependencies.credentials.makeWalletAccessChallenge(), dependencies: dependencies)
            wasDismissedAtReturn = authenticationSheet?.sheetParent == nil && authenticationSheet?.isVisible == false
            ownerWasEligibleAtReturn = NativeSecretAlertPresentation.acceptsKeyWindow(
                NSApp.keyWindow, owner: owner, presentation: nil
            )
            otherWasKeyAtReturn = NSApp.keyWindow === other && other.isKeyWindow
            return result
        }
        defer { authentication.cancel() }
        let (sheet, form) = try await passwordSheet(in: controller)
        authenticationSheet = sheet
        try await requireActiveKeyWindow(sheet)
        form.passwordTextField.stringValue = "password"
        try await requireActiveKeyWindow(other)
        form.actionButtonTapped(form.okButton as Any)
        await assertResult(authentication, equals: true)
        XCTAssertTrue(wasDismissedAtReturn)
        XCTAssertFalse(ownerWasEligibleAtReturn)
        XCTAssertTrue(otherWasKeyAtReturn)
        XCTAssertTrue(NSApp.keyWindow === other)
    }

    func testSeparateWindowsAuthenticateIndependently() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let firstTask = begin(first, fixture: fixture)
        let secondTask = begin(second, fixture: fixture)
        let (firstSheet, firstForm) = try await passwordSheet(in: first)
        let (secondSheet, secondForm) = try await passwordSheet(in: second)
        XCTAssertFalse(firstSheet === secondSheet)
        submit("password", to: firstForm)
        await assertResult(firstTask, equals: true)
        XCTAssertNotNil(second.currentAuthenticationSession)
        XCTAssertTrue(secondSheet.sheetParent === second.window)
        secondForm.cancelButtonTapped(secondForm.cancelButton)
        await assertResult(secondTask, equals: false)
    }

    func testSameWindowDuplicateFailsWithoutChangingOriginalSession() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        defer { controller.close() }
        let first = begin(controller, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: controller)
        let originalSession = controller.currentAuthenticationSession
        let duplicate = await controller.authenticate(reason: .removeWallet, challenge: fixture.credentials.makeWalletAccessChallenge(), dependencies: dependencies(fixture))
        XCTAssertNil(duplicate)
        XCTAssertTrue(controller.currentAuthenticationSession === originalSession)
        XCTAssertTrue(controller.currentAuthenticationSession?.sheet === sheet)
        form.cancelButtonTapped(form.cancelButton)
        await assertResult(first, equals: false)
        let next = begin(controller, fixture: fixture)
        let (_, nextForm) = try await passwordSheet(in: controller)
        XCTAssertFalse(nextForm === form)
        submit("password", to: nextForm)
        await assertResult(next, equals: true)
    }

    func testQueuedAuthenticationCancellationPreservesExistingEditorSheet() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        let editorContent = NSViewController()
        editorContent.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let editor = NSWindow(contentViewController: editorContent)
        editor.isReleasedWhenClosed = false
        window.beginSheet(editor) { _ in editor.orderOut(nil) }
        let authentication = begin(controller, fixture: fixture)
        let (queued, form) = try await passwordSheet(in: controller)
        form.passwordTextField.stringValue = "draft-password"
        XCTAssertTrue(window.attachedSheet === editor)
        XCTAssertTrue(window.sheets.contains { $0 === queued })
        authentication.cancel()
        await assertResult(authentication, equals: false)
        XCTAssertTrue(window.attachedSheet === editor)
        XCTAssertTrue(editor.sheetParent === window)
        XCTAssertFalse(window.sheets.contains { $0 === queued })
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        let next = begin(controller, fixture: fixture)
        let (nextSheet, nextForm) = try await passwordSheet(in: controller)
        window.endSheet(editor)
        await waitUntil { window.attachedSheet === nextSheet }
        submit("password", to: nextForm)
        await assertResult(next, equals: true)
        XCTAssertNil(editor.sheetParent)
    }

    func testClosingOwnerCancelsQueuedSheetAndRetiresItsForm() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        let window = try XCTUnwrap(controller.window)
        let other = makeWindow()
        defer { controller.close(); other.close() }
        let editorContent = NSViewController()
        editorContent.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let editor = NSWindow(contentViewController: editorContent)
        editor.isReleasedWhenClosed = false
        window.beginSheet(editor) { _ in editor.orderOut(nil) }
        let authentication = begin(controller, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: controller)
        form.passwordTextField.stringValue = "password"
        window.close()
        await assertResult(authentication, equals: false)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        submit("password", to: form)
        XCTAssertNil(controller.currentAuthenticationSession)
        XCTAssertTrue(other.window?.isVisible == true)
        if editor.sheetParent != nil { window.endSheet(editor) }
    }

    func testExternalSheetDismissalClearsDraftAndFencesRetainedActions() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        defer { controller.close() }
        let authentication = begin(controller, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: controller)
        form.passwordTextField.stringValue = "password"
        controller.window?.endSheet(sheet, returnCode: .abort)
        await assertResult(authentication, equals: false)
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertNil(sheet.sheetParent)
        let reads = fixture.readCount
        submit("password", to: form)
        form.cancelButtonTapped(form.cancelButton)
        XCTAssertEqual(fixture.readCount, reads)
        XCTAssertNil(controller.currentAuthenticationSession)
    }

    func testCancellingDuringSuccessfulSheetDismissalCannotAuthenticate() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let controller = makeWindow()
        defer { controller.close() }
        let authentication = begin(controller, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: controller)
        submit("password", to: form)
        authentication.cancel()
        await assertResult(authentication, equals: false)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertNil(controller.currentAuthenticationSession)
    }

    func testReviewInvalidationDismissesOnlyItsAuthenticationSheet() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let review = try nativeReviewForTesting()
        let firstTask = begin(first, fixture: fixture, review: review)
        let secondTask = begin(second, fixture: fixture)
        let (sheet, form) = try await passwordSheet(in: first)
        let (otherSheet, otherForm) = try await passwordSheet(in: second)
        form.passwordTextField.stringValue = "password"
        review.invalidate()
        await assertResult(firstTask, equals: false)
        XCTAssertFalse(sheet.isVisible)
        XCTAssertTrue(form.passwordTextField.stringValue.isEmpty)
        XCTAssertTrue(otherSheet.sheetParent === second.window)
        submit("password", to: form)
        otherForm.cancelButtonTapped(otherForm.cancelButton)
        await assertResult(secondTask, equals: false)
    }

    func testLateBiometricSuccessCannotSurviveOwnerCloseOrReviewInvalidation() async throws {
        for invalidatesReview in [false, true] {
            let fixture = AuthenticationKeychainFixture(password: "password")
            let controller = makeWindow()
            defer { controller.close() }
            let review = try nativeReviewForTesting()
            let gate = BiometricGate()
            let dependencies = WindowAuthenticationSession.Dependencies(
                credentials: fixture.credentials, attemptBiometrics: { _, challenge in
                    fixture.authentication(await gate.attempt(), challenge: challenge)
                }
            )
            let authentication = Task {
                await controller.authenticate(reason: .sendTransaction, challenge: dependencies.credentials.makeWalletAccessChallenge(), review: review, dependencies: dependencies)
            }
            await gate.waitForEntry()
            if invalidatesReview { review.invalidate() }
            else { controller.close() }
            await assertResult(authentication, equals: false)
            gate.complete(.succeeded)
            await gate.waitForReturn()
            XCTAssertEqual(gate.cancelledAtReturn, true)
            XCTAssertNil(controller.currentAuthenticationSession)
            XCTAssertTrue(controller.window?.sheets.isEmpty == true)
        }
    }

    func testUnavailablePasswordStaysAnEntryFormAndRetryUsesCurrentStorage() async throws {
        let fixture = AuthenticationKeychainFixture(password: "密碼x")
        fixture.status = errSecInteractionNotAllowed
        let controller = makeWindow()
        defer { controller.close() }
        let authentication = begin(controller, fixture: fixture)
        let (_, form) = try await passwordSheet(in: controller)
        XCTAssertEqual(form.titleLabel.stringValue, Strings.failedToLoad)
        XCTAssertEqual(form.okButton.title, Strings.tryAgain)
        XCTAssertFalse(form.passwordTextField.isEnabled)
        fixture.status = nil
        form.actionButtonTapped(form.okButton as Any)
        XCTAssertEqual(form.titleLabel.stringValue, Strings.enterPassword)
        submit("密碼x", to: form)
        await assertResult(authentication, equals: true)
    }

    func testMissingPasswordNeverOffersCreationFromActionSheet() async throws {
        let fixture = AuthenticationKeychainFixture(password: nil)
        let controller = makeWindow()
        defer { controller.close() }
        let authentication = begin(controller, fixture: fixture)
        let (_, form) = try await passwordSheet(in: controller)
        XCTAssertEqual(form.titleLabel.stringValue, Strings.failedToLoad)
        form.actionButtonTapped(form.okButton as Any)
        XCTAssertEqual(form.titleLabel.stringValue, Strings.failedToLoad)
        form.cancelButtonTapped(form.cancelButton)
        await assertResult(authentication, equals: false)
    }

    func testActionBiometricsNeverFallBackAfterFailedAvailableAttempt() async throws {
        let fixture = AuthenticationKeychainFixture(password: "password")
        for outcome in [WalletAuthenticationOutcome.failed, .interactionUnavailable, .succeeded] {
            let controller = makeWindow()
            defer { controller.close() }
            let original = controller.contentViewController
            var dependencies = dependencies(fixture)
            dependencies.attemptBiometrics = { _, challenge in fixture.authentication(outcome, challenge: challenge) }
            let result = await controller.authenticate(reason: .removeWallet, challenge: dependencies.credentials.makeWalletAccessChallenge(), dependencies: dependencies)
            XCTAssertEqual(result != nil, outcome == .succeeded)
            XCTAssertTrue(controller.window?.sheets.isEmpty == true)
            XCTAssertTrue(controller.contentViewController === original)
        }
    }

    func testAbsentClosedOrRetiredOwnerNeverStartsAuthentication() async throws {
        let controller = makeWindow()
        controller.close()
        let review = try nativeReviewForTesting()
        review.invalidate()
        var calls = 0
        var dependencies = WindowAuthenticationSession.Dependencies()
        dependencies.attemptBiometrics = { _, _ in calls += 1; return .failed }
        let absent = await Window.authenticate(in: nil, reason: .removeWallet, challenge: dependencies.credentials.makeWalletAccessChallenge())
        let closed = await controller.authenticate(reason: .removeWallet, challenge: dependencies.credentials.makeWalletAccessChallenge(), dependencies: dependencies)
        let other = makeWindow()
        defer { other.close() }
        let retired = await other.authenticate(reason: .sendTransaction, challenge: dependencies.credentials.makeWalletAccessChallenge(), review: review, dependencies: dependencies)
        XCTAssertNil(absent)
        XCTAssertNil(closed)
        XCTAssertNil(retired)
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.currentAuthenticationSession)
        XCTAssertNil(other.currentAuthenticationSession)
    }

    private func requireActiveKeyWindow(_ window: NSWindow) async throws {
        guard NSApp.activationPolicy() == .regular || NSApp.setActivationPolicy(.regular) else {
            throw WindowFocusFailure(description: "Could not enable test-host activation: \(focusState(for: window))")
        }
        if window.sheetParent == nil { window.center() }
        NSApp.unhide(nil)
        let deadline = ContinuousClock.now + .seconds(5)
        let activation = Mutex<Result<Int32, WindowFocusFailure>?>(nil)
        let expectedPID = ProcessInfo.processInfo.processIdentifier
        var requestedActivation = false
        while ContinuousClock.now < deadline {
            if !NSApp.isActive, !requestedActivation {
                requestedActivation = true
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                configuration.allowsRunningApplicationSubstitution = false
                configuration.addsToRecentItems = false
                configuration.promptsUserIfNeeded = false
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
                    let result: Result<Int32, WindowFocusFailure>
                    if let application {
                        result = .success(application.processIdentifier)
                    } else {
                        result = .failure(WindowFocusFailure(description: error.map { String(describing: $0) } ?? "No application returned"))
                    }
                    activation.withLock { $0 = result }
                }
            }
            if requestedActivation {
                guard let result = activation.withLock({ $0 }) else {
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                switch result {
                case .success(let processIdentifier):
                    guard processIdentifier == expectedPID else {
                        throw WindowFocusFailure(description: "Launch Services activated PID \(processIdentifier), expected \(expectedPID): \(focusState(for: window))")
                    }
                case .failure(let error):
                    throw WindowFocusFailure(description: "Launch Services could not activate the test host: \(error); \(focusState(for: window))")
                }
            }
            if NSApp.isActive {
                window.makeKeyAndOrderFront(nil)
                if NSApp.isActive, NSApp.keyWindow === window, window.isKeyWindow { return }
            } else {
                NSApp.activate()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let activationCompleted = activation.withLock { $0 != nil }
        throw WindowFocusFailure(description: "Could not obtain active key-window ownership: launchServicesRequested=\(requestedActivation), launchServicesCompleted=\(activationCompleted), \(focusState(for: window))")
    }

    private func focusState(for window: NSWindow) -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return [
            "policy=\(NSApp.activationPolicy().rawValue)",
            "active=\(NSApp.isActive)",
            "hidden=\(NSApp.isHidden)",
            "running=\(NSApp.isRunning)",
            "screens=\(NSScreen.screens.count)",
            "target=\(window.windowNumber)",
            "targetKey=\(window.isKeyWindow)",
            "targetCanBecomeKey=\(window.canBecomeKey)",
            "targetVisible=\(window.isVisible)",
            "targetOnActiveSpace=\(window.isOnActiveSpace)",
            "sheetParent=\(window.sheetParent?.windowNumber.description ?? "nil")",
            "keyWindow=\(NSApp.keyWindow?.windowNumber.description ?? "nil")",
            "frontmostBundle=\(frontmost?.bundleIdentifier ?? "nil")",
            "frontmostPID=\(frontmost?.processIdentifier.description ?? "nil")",
        ].joined(separator: ", ")
    }

    private func makeWindow() -> WalletWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 350))
        window.contentViewController = content
        let controller = WalletWindowController(window: window)
        window.orderFront(nil)
        return controller
    }

    private func dependencies(_ fixture: AuthenticationKeychainFixture) -> WindowAuthenticationSession.Dependencies {
        var dependencies = WindowAuthenticationSession.Dependencies()
        dependencies.credentials = fixture.credentials
        dependencies.attemptBiometrics = { _, _ in nil }
        return dependencies
    }

    private func begin(_ controller: WalletWindowController, fixture: AuthenticationKeychainFixture, review: NativeApprovalReview? = nil) -> Task<WalletAuthenticationGrant?, Never> {
        let dependencies = dependencies(fixture)
        return Task {
            await controller.authenticate(reason: .showPrivateKey, challenge: dependencies.credentials.makeWalletAccessChallenge(), review: review, dependencies: dependencies)
        }
    }

    private func passwordSheet(in controller: WalletWindowController) async throws -> (NSWindow, PasswordViewController) {
        await waitUntil { controller.currentAuthenticationSession?.sheet != nil }
        let sheet = try XCTUnwrap(controller.currentAuthenticationSession?.sheet)
        let form = try XCTUnwrap(sheet.contentViewController as? PasswordViewController)
        _ = form.view
        return (sheet, form)
    }

    private func submit(_ password: String, to form: PasswordViewController) {
        form.passwordTextField.stringValue = password
        form.actionButtonTapped(form.okButton as Any)
    }

    private func assertResult(_ task: Task<WalletAuthenticationGrant?, Never>, equals expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await task.value
        XCTAssertEqual(result != nil, expected, file: file, line: line)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await expectEventually(file: file, line: line, predicate)
    }
}

private struct WindowFocusFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class BiometricGate {
    private let gate = TestGate<WalletAuthenticationOutcome?>()
    private let entered = XCTestExpectation(description: "biometrics entered")
    private let returned = XCTestExpectation(description: "biometrics returned")
    private(set) var cancelledAtReturn: Bool?

    func attempt() async -> WalletAuthenticationOutcome? {
        entered.fulfill()
        let result = await gate.wait()
        cancelledAtReturn = Task.isCancelled
        returned.fulfill()
        return result
    }
    func complete(_ outcome: WalletAuthenticationOutcome?) { gate.resolve(outcome) }
    func waitForEntry() async {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func waitForReturn() async {
        let result = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}

private final class AuthenticationKeychainFixture: Sendable {
    private struct State {
        var password: String?
        var status: OSStatus?
        var readCount = 0
    }
    private let state: Mutex<State>
    private let authorityID = UUID()

    var credentials: WalletCredentials {
        WalletCredentials(keychain: keychain, messages: .testingEnglish, authorityID: authorityID)
    }

    func authentication(_ outcome: WalletAuthenticationOutcome?, challenge: WalletAuthenticationChallenge) -> WalletAuthenticationResult? {
        switch outcome {
        case .succeeded?:
            guard let password = state.withLock({ $0.password }),
                  let grant = try? credentials.verify(password: password, challenge: challenge) else { return .failed }
            return .granted(grant)
        case .failed?: return .failed
        case .interactionUnavailable?: return .interactionUnavailable
        case nil: return nil
        }
    }

    init(password: String?) { state = Mutex(State(password: password)) }

    var status: OSStatus? {
        get { state.withLock { $0.status } }
        set { state.withLock { $0.status = newValue } }
    }

    var readCount: Int { state.withLock { $0.readCount } }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, result in
            guard (query as NSDictionary)[kSecAttrAccount] as? String == "org.lil.wallet.password" else {
                return errSecItemNotFound
            }
            let (password, status) = state.withLock {
                $0.readCount += 1
                return ($0.password, $0.status)
            }
            if let status { return status }
            guard let password else { return errSecItemNotFound }
            result?.pointee = Data(password.utf8) as CFData
            return errSecSuccess
        }, add: { _, _ in
            XCTFail("Action authentication must not create credentials")
            return errSecNotAvailable
        }, update: { _, _ in
            XCTFail("Action authentication must not update credentials")
            return errSecNotAvailable
        }, delete: { _ in
            XCTFail("Action authentication must not delete credentials")
            return errSecNotAvailable
        })
    }
}
