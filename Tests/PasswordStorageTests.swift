import Foundation
import Security
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import Big_Wallet

@MainActor
final class PasswordStorageTests: XCTestCase {
#if os(macOS)
    func testMacPasswordRetryNeverInterpretsUnavailableStorageAsMissing() async throws {
        let fixture = PasswordKeychainFixture()
        fixture.readStatus = errSecInteractionNotAllowed
        var events = [StartupCredentialCoordinator.Event]()
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.credentials = WalletCredentials(keychain: fixture.keychain, messages: .testingEnglish, authorityID: UUID())
        dependencies.canCreatePassword = true
        dependencies.attemptBiometrics = { _, _ in nil }
        let flow = StartupCredentialCoordinator(dependencies: dependencies) { events.append($0) }
        defer { flow.cancel() }
        flow.requestAccess()
        let window = try XCTUnwrap(flow.windowController?.window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertEqual(failure.titleLabel.stringValue, Strings.failedToLoad)
        XCTAssertEqual(failure.okButton.title, Strings.tryAgain)
        failure.actionButtonTapped(failure.okButton as Any)
        XCTAssertTrue(window.contentViewController is WaitingViewController)
        XCTAssertTrue(events.isEmpty)
        fixture.readStatus = nil
        let retry = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        retry.actionButtonTapped(retry.okButton as Any)
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        let create = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        create.passwordTextField.stringValue = "draft"
        create.actionButtonTapped(create.okButton as Any)
        let repeatForm = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        XCTAssertEqual(repeatForm.titleLabel.stringValue, Strings.repeatPassword)
        repeatForm.passwordTextField.stringValue = "draft"
        fixture.passwordData = Data("other-session".utf8)
        repeatForm.actionButtonTapped(repeatForm.okButton as Any)
        await expectEventually { (window.contentViewController as? PasswordViewController)?.titleLabel.stringValue == Strings.enterPassword }
        let enter = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        XCTAssertEqual(enter.titleLabel.stringValue, Strings.enterPassword)
        XCTAssertTrue(repeatForm.passwordTextField.stringValue.isEmpty)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(try fixture.keychain.readPassword(), "other-session")
    }

    func testMacPasswordEntryAcceptsExistingShortPasswordAfterRetry() async throws {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("x".utf8)
        fixture.readStatus = errSecInteractionNotAllowed
        var events = [StartupCredentialCoordinator.Event]()
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.credentials = WalletCredentials(keychain: fixture.keychain, messages: .testingEnglish, authorityID: UUID())
        dependencies.attemptBiometrics = { _, _ in nil }
        let flow = StartupCredentialCoordinator(dependencies: dependencies) { events.append($0) }
        defer { flow.cancel() }
        flow.requestAccess()
        let window = try XCTUnwrap(flow.windowController?.window)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertTrue(events.isEmpty)
        fixture.readStatus = nil
        failure.actionButtonTapped(failure.okButton as Any)
        await expectEventually { window.contentViewController is PasswordViewController }
        let controller = try XCTUnwrap(window.contentViewController as? PasswordViewController)
        controller.passwordTextField.stringValue = "x"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(controller.okButton.isEnabled)
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(events, [.authenticated])
    }

    func testMacWelcomeReportsUnavailableStorageAndRetiresItsCallbacks() throws {
        let fixture = PasswordKeychainFixture()
        var events = [StartupCredentialCoordinator.Event]()
        var dependencies = StartupCredentialCoordinator.Dependencies()
        dependencies.credentials = WalletCredentials(keychain: fixture.keychain, messages: .testingEnglish, authorityID: UUID())
        dependencies.canCreatePassword = true
        dependencies.attemptBiometrics = { _, _ in nil }
        let flow = StartupCredentialCoordinator(dependencies: dependencies) { events.append($0) }
        defer { flow.cancel() }
        flow.requestAccess()
        let window = try XCTUnwrap(flow.windowController?.window)
        let welcome = try XCTUnwrap(window.contentViewController as? WelcomeViewController)
        fixture.readStatus = errSecInteractionNotAllowed
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        let failure = try XCTUnwrap(window.contentViewController as? WaitingViewController)
        XCTAssertTrue(events.isEmpty)
        fixture.readStatus = nil
        fixture.passwordData = Data("existing".utf8)
        welcome.actionButtonTapped(welcome.getStartedButton as Any)
        XCTAssertTrue(window.contentViewController === failure)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(fixture.addCount, 0)
    }

#else
    func testPasswordFallbackReadFailureRetriesWithoutReportingMismatch() async {
        var prompts = [LocalAuthentication.Prompt]()
        var verificationAttempts = 0
        let result: Bool? = await LocalAuthentication.authorize(
            passwordReason: nil,
            biometrics: { nil },
            verifyPassword: { _ in
                verificationAttempts += 1
                throw WalletCredentialError.failedToRead(errSecInteractionNotAllowed)
            }
        ) { prompt in
            prompts.append(prompt)
            switch prompt {
            case .password: return "entered-password"
            case .unavailable: return verificationAttempts == 1 ? "" : nil
            case .mismatch:
                XCTFail("A failed Keychain read is not a password mismatch")
                return nil
            }
        }
        XCTAssertNil(result)
        XCTAssertEqual(verificationAttempts, 2)
        XCTAssertEqual(prompts, [.password(reason: nil), .unavailable, .unavailable])
    }

    func testPasswordAlertClearsInputAndWaitsForDismissalBeforeResolving() async throws {
        let presenter = UIViewController()
        var presented: UIAlertController?
        var completeDismissal: (@MainActor @Sendable () -> Void)?
        var dismissalCount = 0
        var returned = false
        let shown = expectation(description: "password alert presented")
        let request = LocalAuthentication.AlertRequest(show: { _, alert in
            presented = alert
            shown.fulfill()
        }, dismiss: { _, _, completion in
            dismissalCount += 1
            completeDismissal = completion
        })
        let task = Task {
            let result = await request.present(
                from: { presenter }, title: "Password", message: nil, requestsPassword: true
            )
            returned = true
            return result
        }
        await fulfillment(of: [shown], timeout: 2)
        let alert = try XCTUnwrap(presented)
        alert.textFields?.first?.text = "entered-password"
        request.finish("entered-password")
        XCTAssertTrue(alert.textFields?.first?.text?.isEmpty ?? true)
        XCTAssertFalse(returned)
        XCTAssertEqual(dismissalCount, 1)
        request.cancel()
        XCTAssertFalse(returned)
        try XCTUnwrap(completeDismissal)()
        let result = await task.value
        XCTAssertNil(result)
        request.finish("late-value")
        XCTAssertEqual(dismissalCount, 1)
    }

    func testUIKitPasswordReadFailureClearsDraftAndRecoversThroughRetry() {
        let fixture = PasswordKeychainFixture()
        fixture.readStatus = errSecInteractionNotAllowed
        let controller = instantiate(PasswordViewController.self, from: .main)
        controller.credentials = fixture.credentials
        controller.passwordToRepeat = "draft"
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.dataState, .failedToLoad)
        XCTAssertNil(controller.passwordToRepeat)
        XCTAssertFalse(controller.passwordTextField.isEnabled)
        controller.okButtonTapped(controller.okButton as Any)
        XCTAssertEqual(fixture.addCount, 0)
        fixture.readStatus = nil
        controller.okButtonTapped(controller.okButton as Any)
        XCTAssertEqual(controller.dataState, .hasData)
        XCTAssertTrue(controller.passwordTextField.isEnabled)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testUIKitStaleRepeatLoadDoesNotMutateNavigationUntilVisible() async {
        let fixture = PasswordKeychainFixture()
        let first = instantiate(PasswordViewController.self, from: .main)
        first.credentials = fixture.credentials
        let navigation = UINavigationController(rootViewController: first)
        first.loadViewIfNeeded()
        let repeated = instantiate(PasswordViewController.self, from: .main)
        repeated.credentials = fixture.credentials
        repeated.passwordToRepeat = "draft"
        fixture.passwordData = Data("other-session".utf8)
        navigation.setViewControllers([first, repeated], animated: false)
        repeated.loadViewIfNeeded()
        NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil)
        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertNil(repeated.passwordToRepeat)
        XCTAssertEqual(fixture.addCount, 0)
        repeated.viewDidAppear(false)
        await expectEventually { navigation.viewControllers.count == 1 }
        repeated.viewDidDisappear(false)
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertTrue(navigation.topViewController === repeated)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testUIKitStaleRepeatSubmissionDropsDraftWithoutCreatingPassword() {
        let fixture = PasswordKeychainFixture()
        let repeated = instantiate(PasswordViewController.self, from: .main)
        repeated.credentials = fixture.credentials
        repeated.passwordToRepeat = "draft"
        repeated.loadViewIfNeeded()
        repeated.passwordTextField.text = "draft"
        fixture.passwordData = Data("other-session".utf8)
        repeated.okButtonTapped(repeated.okButton as Any)
        XCTAssertNil(repeated.passwordToRepeat)
        XCTAssertTrue(repeated.passwordTextField.text?.isEmpty ?? true)
        XCTAssertEqual(fixture.addCount, 0)
    }
#endif
}
