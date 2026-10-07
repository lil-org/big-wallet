import Foundation
import Security
import Synchronization
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import Big_Wallet

@MainActor
final class PasswordStorageTests: XCTestCase {
    func testPasswordReadDistinguishesMissingUnavailableAndCorruptData() throws {
        let fixture = PasswordKeychainFixture()
        XCTAssertNil(try fixture.keychain.readPassword())
        XCTAssertEqual(try fixture.keychain.passwordState(), .missing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            fixture.readStatus = status
            XCTAssertThrowsError(try fixture.keychain.passwordState()) { error in
                guard case Keychain.KeychainError.failedToRead(let actual) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actual, status)
            }
        }
        fixture.readStatus = nil
        for data in [Data(), Data([0xff, 0xfe]), Data([0xef, 0xbb, 0xbf])] {
            fixture.passwordData = data
            XCTAssertThrowsError(try fixture.keychain.readPasswordData()) { error in
                guard case Keychain.KeychainError.invalidPasswordData = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        fixture.wrongReturnType = true
        XCTAssertThrowsError(try fixture.keychain.readPassword()) { error in
            guard case Keychain.KeychainError.failedToRead(errSecDecode) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExistingShortAndUnicodePasswordsRemainReadableAndVerifiable() throws {
        let fixture = PasswordKeychainFixture()
        for password in ["x", "пароль🔐"] {
            fixture.passwordData = Data(password.utf8)
            XCTAssertEqual(try fixture.keychain.readPassword(), password)
            XCTAssertEqual(try fixture.keychain.passwordState(), .present)
            XCTAssertTrue(try DeviceAuthentication.verify(password: password, keychain: fixture.keychain))
            XCTAssertFalse(try DeviceAuthentication.verify(password: "different", keychain: fixture.keychain))
        }
        fixture.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try DeviceAuthentication.verify(password: "different", keychain: fixture.keychain))
        fixture.readStatus = nil
        fixture.passwordData = nil
        XCTAssertThrowsError(try DeviceAuthentication.verify(password: "", keychain: fixture.keychain))
    }

    func testInitialCreationNeverDeletesOrUpdatesAnExistingPassword() throws {
        let fixture = PasswordKeychainFixture()
        var invalidations = 0
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("first", beforeInsert: {
            invalidations += 1
        }), .created)
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("second", beforeInsert: {
            invalidations += 1
        }), .alreadyExists)
        XCTAssertEqual(try fixture.keychain.readPassword(), "first")
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testPasswordWithUTF8BOMKeepsExistingDecodingWithoutRewritingStorage() throws {
        let fixture = PasswordKeychainFixture()
        for count in 1...2 {
            let original = String(repeating: "\u{feff}", count: count) + "password"
            let expected = String(repeating: "\u{feff}", count: count - 1) + "password"
            let stored = Data(original.utf8)
            fixture.passwordData = stored

            XCTAssertEqual(try fixture.keychain.readPassword(), expected)
            XCTAssertTrue(try DeviceAuthentication.verify(password: expected, keychain: fixture.keychain))
            XCTAssertFalse(try DeviceAuthentication.verify(password: original, keychain: fixture.keychain))
            XCTAssertEqual(try fixture.keychain.readPasswordData(), Data(expected.utf8))
            XCTAssertEqual(fixture.passwordData, stored)
        }
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testPasswordCreationFailsBeforeInvalidationForUnreadableCorruptOrOrphanedStorage() throws {
        let fixture = PasswordKeychainFixture()
        let beforeInsert = { XCTFail("Storage must be checked before invalidating the vault") }
        fixture.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.readStatus = nil
        fixture.passwordData = Data([0xff])
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.passwordData = nil
        fixture.walletIDs = ["retained-wallet"]
        XCTAssertThrowsError(try fixture.keychain.passwordState()) { error in
            guard case Keychain.KeychainError.orphanedWallets = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.walletIDs = []
        fixture.inventoryStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testDuplicateBetweenRecheckAndInsertPreservesWinningPassword() throws {
        let fixture = PasswordKeychainFixture()
        let result = try fixture.keychain.createPasswordIfMissing("loser", beforeInsert: {
            fixture.passwordData = Data("winner".utf8)
        })
        XCTAssertEqual(result, .alreadyExists)
        XCTAssertEqual(try fixture.keychain.readPassword(), "winner")
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testFailedInvalidationAndFailedInsertPreserveStorageAndAllowRetry() throws {
        let fixture = PasswordKeychainFixture()
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {
            throw CocoaError(.fileWriteUnknown)
        }))
        XCTAssertEqual(fixture.addCount, 0)
        fixture.addStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {})) { error in
            guard case Keychain.KeychainError.failedToSave(errSecInteractionNotAllowed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(fixture.passwordData)
        fixture.addStatus = nil
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {}), .created)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testConcurrentInitialCreationHasOneWinner() async throws {
        let fixture = PasswordKeychainFixture()
        let results = try await withThrowingTaskGroup(of: Keychain.PasswordCreationResult.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try fixture.keychain.createPasswordIfMissing("password-\(index)", beforeInsert: {})
                }
            }
            var results = [Keychain.PasswordCreationResult]()
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 == .created }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyExists }.count, 15)
        XCTAssertTrue(try XCTUnwrap(fixture.keychain.readPassword()).hasPrefix("password-"))
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testCancelledCreationDoesNotInvalidateOrInsert() async {
        let fixture = PasswordKeychainFixture()
        let task = Task {
            try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {
                XCTFail("Canceled creation must not invalidate the vault")
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fixture.addCount, 0)
    }

#if os(macOS)
    func testMacPasswordRetryNeverInterpretsUnavailableStorageAsMissing() throws {
        let fixture = PasswordKeychainFixture()
        fixture.readStatus = errSecInteractionNotAllowed
        var completions = [Bool]()
        let controller = PasswordViewController.with(mode: .create) { completions.append($0) }
        controller.keychain = fixture.keychain
        _ = controller.view
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(controller.titleLabel.stringValue, Strings.failedToLoad)
        XCTAssertEqual(controller.okButton.title, Strings.tryAgain)
        XCTAssertFalse(controller.passwordTextField.isEnabled)
        XCTAssertTrue(completions.isEmpty)
        fixture.readStatus = nil
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(controller.titleLabel.stringValue, Strings.createPassword)
        controller.passwordTextField.stringValue = "draft"
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(controller.titleLabel.stringValue, Strings.repeatPassword)
        controller.passwordTextField.stringValue = "draft"
        fixture.passwordData = Data("other-session".utf8)
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(completions, [false])
        XCTAssertTrue(controller.passwordTextField.stringValue.isEmpty)
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(try fixture.keychain.readPassword(), "other-session")
    }

    func testMacPasswordEntryAcceptsExistingShortPasswordAfterRetry() {
        let fixture = PasswordKeychainFixture()
        fixture.passwordData = Data("x".utf8)
        fixture.readStatus = errSecInteractionNotAllowed
        var completions = [Bool]()
        let controller = PasswordViewController.with(mode: .enter) { completions.append($0) }
        controller.keychain = fixture.keychain
        _ = controller.view
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertTrue(completions.isEmpty)
        fixture.readStatus = nil
        controller.actionButtonTapped(controller.okButton as Any)
        controller.passwordTextField.stringValue = "x"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(controller.okButton.isEnabled)
        controller.actionButtonTapped(controller.okButton as Any)
        XCTAssertEqual(completions, [true])
    }

    func testMacWelcomeReportsUnavailableStorageAndRetiresItsCallbacks() {
        let fixture = PasswordKeychainFixture()
        fixture.readStatus = errSecInteractionNotAllowed
        var completions = [Bool]()
        var failures = 0
        var controller: WelcomeViewController!
        controller = WelcomeViewController.new(credentialUnavailable: {
            failures += 1
            controller.retireCredentialPresentation()
        }) { completions.append($0) }
        controller.keychain = fixture.keychain
        _ = controller.view
        controller.actionButtonTapped(controller.getStartedButton as Any)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(completions.isEmpty)
        fixture.readStatus = nil
        fixture.passwordData = Data("existing".utf8)
        controller.actionButtonTapped(controller.getStartedButton as Any)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(fixture.addCount, 0)
    }

#else
    func testPasswordFallbackReadFailureRetriesWithoutReportingMismatch() async {
        var prompts = [LocalAuthentication.Prompt]()
        var verificationAttempts = 0
        let result = await LocalAuthentication.attempt(
            passwordReason: nil,
            biometrics: { .failed },
            passwordState: { .present },
            verifyPassword: { _ in
                verificationAttempts += 1
                throw Keychain.KeychainError.failedToRead(errSecInteractionNotAllowed)
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
        XCTAssertFalse(result)
        XCTAssertEqual(verificationAttempts, 2)
        XCTAssertEqual(prompts, [.password(reason: nil), .unavailable, .unavailable])
    }

    func testPasswordAlertClearsInputAndWaitsForDismissalBeforeResolving() async throws {
        let presenter = UIViewController()
        var presented: UIAlertController?
        var completeDismissal: (@MainActor @Sendable () -> Void)?
        var dismissalCount = 0
        var returned = false
        let request = LocalAuthentication.AlertRequest(show: { _, alert in
            presented = alert
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
        for _ in 0..<10 where presented == nil { await Task.yield() }
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
        controller.keychain = fixture.keychain
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
        first.keychain = fixture.keychain
        let navigation = UINavigationController(rootViewController: first)
        first.loadViewIfNeeded()
        let repeated = instantiate(PasswordViewController.self, from: .main)
        repeated.keychain = fixture.keychain
        repeated.passwordToRepeat = "draft"
        fixture.passwordData = Data("other-session".utf8)
        navigation.setViewControllers([first, repeated], animated: false)
        repeated.loadViewIfNeeded()
        NotificationCenter.default.post(name: .walletsChanged, object: nil)
        XCTAssertEqual(navigation.viewControllers.count, 2)
        XCTAssertNil(repeated.passwordToRepeat)
        XCTAssertEqual(fixture.addCount, 0)
        repeated.viewDidAppear(false)
        for _ in 0..<5 { await Task.yield() }
        repeated.viewDidDisappear(false)
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertTrue(navigation.topViewController === repeated)
        XCTAssertEqual(fixture.addCount, 0)
    }

    func testUIKitStaleRepeatSubmissionDropsDraftWithoutCreatingPassword() {
        let fixture = PasswordKeychainFixture()
        let repeated = instantiate(PasswordViewController.self, from: .main)
        repeated.keychain = fixture.keychain
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

private final class PasswordKeychainFixture: Sendable {
    private struct State {
        var passwordData: Data?
        var readStatus: OSStatus?
        var inventoryStatus: OSStatus?
        var addStatus: OSStatus?
        var wrongReturnType = false
        var walletIDs = [String]()
        var addCount = 0
        var deleteCount = 0
        var updateCount = 0
    }

    private let state = Mutex(State())

    var passwordData: Data? {
        get { state.withLock { $0.passwordData } }
        set { state.withLock { $0.passwordData = newValue } }
    }
    var readStatus: OSStatus? {
        get { state.withLock { $0.readStatus } }
        set { state.withLock { $0.readStatus = newValue } }
    }
    var inventoryStatus: OSStatus? {
        get { state.withLock { $0.inventoryStatus } }
        set { state.withLock { $0.inventoryStatus = newValue } }
    }
    var addStatus: OSStatus? {
        get { state.withLock { $0.addStatus } }
        set { state.withLock { $0.addStatus = newValue } }
    }
    var wrongReturnType: Bool {
        get { state.withLock { $0.wrongReturnType } }
        set { state.withLock { $0.wrongReturnType = newValue } }
    }
    var walletIDs: [String] {
        get { state.withLock { $0.walletIDs } }
        set { state.withLock { $0.walletIDs = newValue } }
    }
    var addCount: Int { state.withLock { $0.addCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }
    var updateCount: Int { state.withLock { $0.updateCount } }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, output in
            let query = query as NSDictionary
            return state.withLock { state in
                if query[kSecAttrAccount as String] as? String == "org.lil.wallet.password" {
                    if let status = state.readStatus { return status }
                    if state.wrongReturnType {
                        output?.pointee = "unexpected" as CFString
                        return errSecSuccess
                    }
                    guard let data = state.passwordData else { return errSecItemNotFound }
                    output?.pointee = data as CFData
                    return errSecSuccess
                }
                if let status = state.inventoryStatus { return status }
                guard !state.walletIDs.isEmpty else { return errSecItemNotFound }
                output?.pointee = state.walletIDs.map {
                    [kSecAttrAccount as String: "org.lil.wallet.wallet." + $0]
                } as CFArray
                return errSecSuccess
            }
        }, add: { [self] query, _ in
            let query = query as NSDictionary
            return state.withLock { state in
                state.addCount += 1
                if let status = state.addStatus { return status }
                guard state.passwordData == nil else { return errSecDuplicateItem }
                guard let data = query[kSecValueData as String] as? Data else { return errSecParam }
                state.passwordData = data
                return errSecSuccess
            }
        }, update: { [self] _, _ in
            state.withLock { $0.updateCount += 1 }
            return errSecSuccess
        }, delete: { [self] _ in
            state.withLock { $0.deleteCount += 1 }
            return errSecSuccess
        })
    }
}
