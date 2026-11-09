import WalletDomain
@testable import WalletAuthority
#if os(iOS) || os(visionOS)
import UIKit
import XCTest
@testable import Big_Wallet

@MainActor
final class SecretAlertPresentationTests: XCTestCase {
    func testOwningSceneDeactivationRevokesControllerReveal() async throws {
        try await withVisibleAccounts { controller, scene in
            let token = try XCTUnwrap(controller.beginSecretPresentation())
            let presentation = controller.secretPresentation
            let appeared = self.expectation(description: "Secret alert appeared")
            let manager = controller.walletsManager
            let wallet = try XCTUnwrap(manager.wallets.first)
            let challenge = try await manager.makeExportChallenge(wallet: wallet, kind: .mnemonic)
            let grant = try XCTUnwrap(challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current })))
            let secret = try await manager.exportMnemonic(wallet: wallet, authorization: grant)
            presentation.show(secret, title: "Secret", token: token, from: controller) {
                appeared.fulfill()
            }
            await self.fulfillment(of: [appeared], timeout: 3)
            let alert = try XCTUnwrap(presentation.alert)

            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
            XCTAssertTrue(presentation.validate(token))
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)

            XCTAssertNil(alert.message)
            XCTAssertNil(presentation.alert)
            XCTAssertFalse(presentation.validate(token))
            presentation.show(WalletExportedSecret(text: "late export"), title: "Secret", token: token, from: controller)
            XCTAssertNil(presentation.alert)
            let dismissed = self.expectation(description: "secret alert dismissed")
            alert.dismissAfterCurrentTransition(animated: false) { dismissed.fulfill() }
            await self.fulfillment(of: [dismissed], timeout: 3)
        }
    }

    func testNavigationRevokesExportBeforeControllerFinishesDisappearing() async throws {
        try await withVisibleAccounts { controller, _ in
            let token = try XCTUnwrap(controller.beginSecretPresentation())
            controller.beginAppearanceTransition(false, animated: true)
            defer { controller.endAppearanceTransition() }

            controller.secretPresentation.show(WalletExportedSecret(text: "late export"), title: "Secret", token: token, from: controller)

            XCTAssertNil(controller.secretPresentation.alert)
            XCTAssertFalse(controller.secretPresentation.validate(token))
            XCTAssertNil(controller.beginSecretPresentation())
        }
    }

    private func withVisibleAccounts(_ body: (AccountsListViewController, UIWindowScene) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = instantiate(AccountsListViewController.self, from: .main)
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: "scene-reveal")]
        reader.walletData = ["scene-reveal": WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture]
        reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        controller.walletsManager = manager
        controller.access = try unlockedWalletAccessForTesting()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await expectEventually { controller.validateSecretPresentation() }
        XCTAssertTrue(controller.viewIfLoaded?.window === window)
        XCTAssertTrue(controller.validateSecretPresentation())
        try await body(controller, scene)
    }

    private final class Presenter: UIViewController {
        var presentedAlerts = [UIAlertController]()
        var delaysCompletion = false
        var pendingCompletion: (() -> Void)?

        @discardableResult
        func show(_ text: String, with presentation: SecretAlertPresentation, token: SecretAlertPresentation.Token) async throws -> UIAlertController {
            presentation.show(WalletExportedSecret(text: text), title: "Secret", token: token, from: self)
            await expectEventually { presentation.alert != nil }
            return try XCTUnwrap(presentation.alert)
        }

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            if let alert = viewControllerToPresent as? UIAlertController {
                presentedAlerts.append(alert)
            }
            if delaysCompletion { pendingCompletion = completion }
            else { completion?() }
        }
    }

    func testRevocationBeforeQueuedPresentationCompletesKeepsSecretHidden() async throws {
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in true })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        presenter.delaysCompletion = true
        let alert = try await presenter.show("queued secret", with: presentation, token: token)

        presentation.invalidate()
        alert.loadViewIfNeeded()
        presenter.pendingCompletion?()

        XCTAssertNil(alert.message)
        XCTAssertTrue(alert.view.isHidden)
        XCTAssertFalse(presentation.validate(token))
    }

    func testDeactivationClearsVisibleSecretAndDisablesRetainedCopyCallback() async throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in true }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        let alert = try await presenter.show("disposable secret", with: presentation, token: token)
        alert.loadViewIfNeeded()

        presentation.invalidate()
        presentation.finish(token, copying: true)

        XCTAssertNil(alert.message)
        XCTAssertTrue(alert.view.isHidden)
        XCTAssertNil(presentation.alert)
        XCTAssertFalse(presentation.validate(token))
        XCTAssertTrue(copies.isEmpty)
    }

    func testLateExportCannotReappearAfterReturnToForeground() throws {
        var active = true
        let presentation = SecretAlertPresentation(validateSource: { active }, validateExport: { _ in true })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        active = false
        presentation.invalidate()
        active = true

        presentation.show(WalletExportedSecret(text: "late secret"), title: "Secret", token: token, from: presenter)

        XCTAssertTrue(presenter.presentedAlerts.isEmpty)
        XCTAssertFalse(presentation.validate(token))
        XCTAssertNotNil(presentation.begin())
    }

    func testOldCallbackCannotCopyOrDismissANewerReveal() async throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in true }, copy: { copies.append($0) })
        let presenter = Presenter()
        let old = try XCTUnwrap(presentation.begin())
        let retainedOldAlert = try await presenter.show("old secret", with: presentation, token: old)
        let current = try XCTUnwrap(presentation.begin())
        try await presenter.show("current secret", with: presentation, token: current)

        presentation.finish(old, copying: true)

        XCTAssertNil(retainedOldAlert.message)
        XCTAssertEqual(presentation.alert?.message, "current secret")
        XCTAssertTrue(copies.isEmpty)
        presentation.finish(current, copying: true)
        await expectEventually { presentation.alert == nil }
        XCTAssertEqual(copies, ["current secret"])
        XCTAssertNil(presentation.alert)
    }

    func testReplacingRevealWhileCopyValidationIsPendingKeepsNewSecret() async throws {
        var copies = [String]()
        var holdCopy = false
        var checkedOldCopy = false
        var pending: CheckedContinuation<Bool, Never>?
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in
            guard holdCopy else { return true }
            let result = await withCheckedContinuation { pending = $0 }
            checkedOldCopy = true
            return result
        }, copy: { copies.append($0) })
        let presenter = Presenter()
        let old = try XCTUnwrap(presentation.begin())
        let oldAlert = try await presenter.show("old secret", with: presentation, token: old)
        holdCopy = true
        presentation.finish(old, copying: true)
        guard await expectEventually({ pending != nil }) else { return }
        defer { pending?.resume(returning: false) }
        XCTAssertNil(oldAlert.message)

        holdCopy = false
        let current = try XCTUnwrap(presentation.begin())
        let currentAlert = try await presenter.show("current secret", with: presentation, token: current)
        pending?.resume(returning: true)
        pending = nil
        await expectEventually { checkedOldCopy }
        XCTAssertTrue(presentation.alert === currentAlert)
        XCTAssertEqual(currentAlert.message, "current secret")
        XCTAssertTrue(copies.isEmpty)
    }

    func testInactivePresentationRejectsExportBeforeNotificationArrives() throws {
        var active = true
        let presentation = SecretAlertPresentation(validateSource: { active }, validateExport: { _ in true })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        active = false

        presentation.show(WalletExportedSecret(text: "late secret"), title: "Secret", token: token, from: presenter)

        XCTAssertTrue(presenter.presentedAlerts.isEmpty)
        XCTAssertNil(presentation.alert)
    }

    func testCopyChecksActivityEvenBeforeLifecycleNotificationArrives() async throws {
        var active = true
        var copies = [String]()
        let presentation = SecretAlertPresentation(validateSource: { active }, validateExport: { _ in true }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        try await presenter.show("secret", with: presentation, token: token)
        active = false

        presentation.finish(token, copying: true)

        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(presenter.presentedAlerts.first?.message)
        XCTAssertNil(presentation.begin())
    }

    func testCopyRevalidatesTheExportBeforeCatalogNotification() async throws {
        var isCurrent = true
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in isCurrent },
            copy: { _ in XCTFail("A replaced source must not be copied") })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        let alert = try await presenter.show("secret", with: presentation, token: token)

        isCurrent = false
        presentation.finish(token, copying: true)
        await expectEventually { presentation.alert == nil }

        XCTAssertNil(presentation.alert)
        XCTAssertNil(alert.message)
    }

    func testCopyPreservesAPublicAddressWrittenWhileExportValidationIsPending() async throws {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        var holdCopy = false
        var pending: CheckedContinuation<Bool, Never>?
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in
            guard holdCopy else { return true }
            return await withCheckedContinuation { pending = $0 }
        }, pasteboardChangeCount: { pasteboard.changeCount }, copy: { pasteboard.string = $0 })
        let presenter = Presenter()
        let token = try XCTUnwrap(presentation.begin())
        let alert = try await presenter.show("secret", with: presentation, token: token)

        holdCopy = true
        presentation.finish(token, copying: true)
        guard await expectEventually({ pending != nil }) else { return }
        pasteboard.string = "public address"
        pending?.resume(returning: true)
        await expectEventually { presentation.alert == nil }

        XCTAssertEqual(pasteboard.string, "public address")
        XCTAssertNil(alert.message)
    }

    func testDoneClearsSecretWithoutCopying() async throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in true }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        try await presenter.show("secret", with: presentation, token: token)

        presentation.finish(token, copying: false)
        presentation.finish(token, copying: true)

        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(presenter.presentedAlerts.first?.message)
    }

    func testReleasingPresentationClearsAnAlertRetainedByUIKit() async throws {
        var presentation: SecretAlertPresentation? = SecretAlertPresentation(validateSource: { true }, validateExport: { _ in true })
        let presenter = Presenter()
        let token = try XCTUnwrap(presentation?.begin())
        try await presenter.show("secret", with: XCTUnwrap(presentation), token: token)

        presentation = nil

        XCTAssertNil(presenter.presentedAlerts.first?.message)
    }
}
#endif
