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
            presentation.show("disposable secret", title: "Secret", token: token, from: controller) {
                appeared.fulfill()
            }
            let alert = try XCTUnwrap(presentation.alert)
            await self.fulfillment(of: [appeared], timeout: 3)

            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: NSObject())
            XCTAssertTrue(presentation.accepts(token))
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)

            XCTAssertNil(alert.message)
            XCTAssertNil(presentation.alert)
            XCTAssertFalse(presentation.accepts(token))
            presentation.show("late export", title: "Secret", token: token, from: controller)
            XCTAssertNil(presentation.alert)
            await withCheckedContinuation { continuation in
                alert.dismissAfterCurrentTransition(animated: false) { continuation.resume() }
            }
        }
    }

    func testNavigationRevokesExportBeforeControllerFinishesDisappearing() async throws {
        try await withVisibleAccounts { controller, _ in
            let token = try XCTUnwrap(controller.beginSecretPresentation())
            controller.beginAppearanceTransition(false, animated: true)
            defer { controller.endAppearanceTransition() }

            controller.secretPresentation.show("late export", title: "Secret", token: token, from: controller)

            XCTAssertNil(controller.secretPresentation.alert)
            XCTAssertFalse(controller.secretPresentation.accepts(token))
            XCTAssertNil(controller.beginSecretPresentation())
        }
    }

    private func withVisibleAccounts(_ body: (AccountsListViewController, UIWindowScene) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = instantiate(AccountsListViewController.self, from: .main)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        for _ in 0..<200 where !controller.canPresentSecret {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.viewIfLoaded?.window === window)
        XCTAssertTrue(controller.canPresentSecret)
        try await body(controller, scene)
    }

    private final class Presenter: UIViewController {
        var presentedAlerts = [UIAlertController]()
        var delaysCompletion = false
        var pendingCompletion: (() -> Void)?

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            if let alert = viewControllerToPresent as? UIAlertController {
                presentedAlerts.append(alert)
            }
            if delaysCompletion { pendingCompletion = completion }
            else { completion?() }
        }
    }

    func testRevocationBeforeQueuedPresentationCompletesKeepsSecretHidden() throws {
        let presentation = SecretAlertPresentation(isActive: { true })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        presenter.delaysCompletion = true
        presentation.show("queued secret", title: "Secret", token: token, from: presenter)
        let alert = try XCTUnwrap(presentation.alert)

        presentation.invalidate()
        alert.loadViewIfNeeded()
        presenter.pendingCompletion?()

        XCTAssertNil(alert.message)
        XCTAssertTrue(alert.view.isHidden)
        XCTAssertFalse(presentation.accepts(token))
    }

    func testDeactivationClearsVisibleSecretAndDisablesRetainedCopyCallback() throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(isActive: { true }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        presentation.show("disposable secret", title: "Secret", token: token, from: presenter)
        let alert = try XCTUnwrap(presenter.presentedAlerts.first)
        alert.loadViewIfNeeded()

        presentation.invalidate()
        presentation.finish(token, copying: true)

        XCTAssertNil(alert.message)
        XCTAssertTrue(alert.view.isHidden)
        XCTAssertNil(presentation.alert)
        XCTAssertFalse(presentation.accepts(token))
        XCTAssertTrue(copies.isEmpty)
    }

    func testLateExportCannotReappearAfterReturnToForeground() throws {
        var active = true
        let presentation = SecretAlertPresentation(isActive: { active })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        active = false
        presentation.invalidate()
        active = true

        presentation.show("late secret", title: "Secret", token: token, from: presenter)

        XCTAssertTrue(presenter.presentedAlerts.isEmpty)
        XCTAssertFalse(presentation.accepts(token))
        XCTAssertNotNil(presentation.begin())
    }

    func testOldCallbackCannotCopyOrDismissANewerReveal() throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(isActive: { true }, copy: { copies.append($0) })
        let presenter = Presenter()
        let old = try XCTUnwrap(presentation.begin())
        presentation.show("old secret", title: "Secret", token: old, from: presenter)
        let retainedOldAlert = try XCTUnwrap(presentation.alert)
        let current = try XCTUnwrap(presentation.begin())
        presentation.show("current secret", title: "Secret", token: current, from: presenter)

        presentation.finish(old, copying: true)

        XCTAssertNil(retainedOldAlert.message)
        XCTAssertEqual(presentation.alert?.message, "current secret")
        XCTAssertTrue(copies.isEmpty)
        presentation.finish(current, copying: true)
        XCTAssertEqual(copies, ["current secret"])
        XCTAssertNil(presentation.alert)
    }

    func testInactivePresentationRejectsExportBeforeNotificationArrives() throws {
        var active = true
        let presentation = SecretAlertPresentation(isActive: { active })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        active = false

        presentation.show("late secret", title: "Secret", token: token, from: presenter)

        XCTAssertTrue(presenter.presentedAlerts.isEmpty)
        XCTAssertNil(presentation.alert)
    }

    func testCopyChecksActivityEvenBeforeLifecycleNotificationArrives() throws {
        var active = true
        var copies = [String]()
        let presentation = SecretAlertPresentation(isActive: { active }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        presentation.show("secret", title: "Secret", token: token, from: presenter)
        active = false

        presentation.finish(token, copying: true)

        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(presenter.presentedAlerts.first?.message)
        XCTAssertNil(presentation.begin())
    }

    func testDoneClearsSecretWithoutCopying() throws {
        var copies = [String]()
        let presentation = SecretAlertPresentation(isActive: { true }, copy: { copies.append($0) })
        let token = try XCTUnwrap(presentation.begin())
        let presenter = Presenter()
        presentation.show("secret", title: "Secret", token: token, from: presenter)

        presentation.finish(token, copying: false)
        presentation.finish(token, copying: true)

        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(presenter.presentedAlerts.first?.message)
    }

    func testReleasingPresentationClearsAnAlertRetainedByUIKit() throws {
        var presentation: SecretAlertPresentation? = SecretAlertPresentation(isActive: { true })
        let presenter = Presenter()
        let token = try XCTUnwrap(presentation?.begin())
        presentation?.show("secret", title: "Secret", token: token, from: presenter)

        presentation = nil

        XCTAssertNil(presenter.presentedAlerts.first?.message)
    }
}
#endif
