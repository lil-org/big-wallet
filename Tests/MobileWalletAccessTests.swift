#if os(iOS) || os(visionOS)
import UIKit
import XCTest
import WalletDomain
import WalletDomain
@testable import WalletAuthority
@testable import Big_Wallet

@MainActor
final class MobileWalletAccessTests: XCTestCase {
    func testBackgroundLocksOnlyAfterTheLastForegroundSceneLeaves() {
        var locks = [WalletAccessController.LockReason]()
        let scenes = MobileWalletSceneTracker { locks.append($0) }
        scenes.update(sceneID: "first", isForeground: true)
        scenes.update(sceneID: "second", isForeground: true)
        scenes.update(sceneID: "first", isForeground: false)
        XCTAssertTrue(locks.isEmpty)

        scenes.update(sceneID: "second", isForeground: true)
        scenes.update(sceneID: "second", isForeground: true)
        XCTAssertTrue(locks.isEmpty)
        scenes.update(sceneID: "second", isForeground: false)
        XCTAssertEqual(locks, [.background])
        scenes.update(sceneID: "second", isForeground: false)
        scenes.remove(sceneID: "second")
        XCTAssertEqual(locks, [.background])
    }

    func testDisconnectingTheLastForegroundSceneLocksOnce() {
        var locks = [WalletAccessController.LockReason]()
        let scenes = MobileWalletSceneTracker { locks.append($0) }
        scenes.update(sceneID: "first", isForeground: true)
        scenes.update(sceneID: "second", isForeground: true)
        scenes.remove(sceneID: "first")
        scenes.remove(sceneID: "unknown")
        XCTAssertTrue(locks.isEmpty)
        scenes.remove(sceneID: "second")
        scenes.remove(sceneID: "second")
        XCTAssertEqual(locks, [.background])
    }

    func testAllRootsLockWithoutStartingAuthenticationUntilUnlockIsSelected() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        var firstAuthentications = 0
        var secondAuthentications = 0
        let first = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in UIViewController() }, makeAuthentication: { _ in
                firstAuthentications += 1
                return UIViewController()
            })
        let second = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in UIViewController() }, makeAuthentication: { _ in
                secondAuthentications += 1
                return UIViewController()
            })
        first.loadViewIfNeeded()
        second.loadViewIfNeeded()

        fixture.access.lock(reason: .idle)

        XCTAssertTrue(first.content is MobileWalletLockedViewController)
        XCTAssertTrue(second.content is MobileWalletLockedViewController)
        XCTAssertEqual(firstAuthentications, 0)
        XCTAssertEqual(secondAuthentications, 0)
        let locked = try XCTUnwrap(first.content as? MobileWalletLockedViewController)
        locked.loadViewIfNeeded()
        let unlock = try XCTUnwrap(button(in: locked.view, identifier: "wallet-unlock"))
        unlock.sendActions(for: .touchUpInside)
        XCTAssertEqual(firstAuthentications, 1)
        XCTAssertEqual(secondAuthentications, 0)
        XCTAssertTrue(second.content is MobileWalletLockedViewController)

        try fixture.unlock()

        XCTAssertFalse(first.content is MobileWalletLockedViewController)
        XCTAssertFalse(second.content is MobileWalletLockedViewController)
        fixture.access.lock(reason: .background)
        XCTAssertTrue(first.content is MobileWalletLockedViewController)
        XCTAssertTrue(second.content is MobileWalletLockedViewController)
        XCTAssertEqual(firstAuthentications, 1)
        XCTAssertEqual(secondAuthentications, 0)
    }

    func testRetainedManagementControllerCannotActAfterRelockingAndUnlocking() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let old = WalletAccessViewController()
        old.access = fixture.access
        old.loadViewIfNeeded()
        XCTAssertTrue(old.beginWalletAction())

        fixture.access.lock(reason: .background)
        XCTAssertFalse(old.view.isUserInteractionEnabled)
        try fixture.unlock()

        XCTAssertFalse(old.beginWalletAction())
        let passwordReads = fixture.keychain.passwordReadCount
        XCTAssertThrowsError(try old.requireCurrentCredentials())
        XCTAssertEqual(fixture.keychain.passwordReadCount, passwordReads)
        let current = WalletAccessViewController()
        current.access = fixture.access
        current.loadViewIfNeeded()
        XCTAssertTrue(current.beginWalletAction())
    }

    func testEachVisibleLockedRootCanReplaceAnotherRootsAuthentication() throws {
        let fixture = WalletAccessTestFixture()
        fixture.access.lock(reason: .idle)
        var firstAttempts = 0
        var secondAttempts = 0
        var firstCancellations = 0
        let first = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in UIViewController() }, makeAuthentication: { access in
                AuthenticationViewController {
                    firstAttempts += 1
                    access.beginAuthentication { firstCancellations += 1 }
                }
            })
        let second = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in UIViewController() }, makeAuthentication: { access in
                AuthenticationViewController {
                    secondAttempts += 1
                    access.beginAuthentication(cancel: {})
                }
            })
        first.loadViewIfNeeded()
        second.loadViewIfNeeded()
        let firstLocked = try XCTUnwrap(first.content as? MobileWalletLockedViewController)
        let secondLocked = try XCTUnwrap(second.content as? MobileWalletLockedViewController)
        let firstUnlock = try XCTUnwrap(button(in: firstLocked.view, identifier: "wallet-unlock"))
        let secondUnlock = try XCTUnwrap(button(in: secondLocked.view, identifier: "wallet-unlock"))
        let initialGeneration = fixture.access.generation

        firstUnlock.sendActions(for: .touchUpInside)

        XCTAssertEqual(firstAttempts, 1)
        XCTAssertGreaterThan(fixture.access.generation, initialGeneration)
        XCTAssertTrue(first.content is AuthenticationViewController)
        XCTAssertTrue(second.content === secondLocked)
        let firstGeneration = fixture.access.generation

        secondUnlock.sendActions(for: .touchUpInside)

        XCTAssertEqual(secondAttempts, 1)
        XCTAssertEqual(firstCancellations, 1)
        XCTAssertGreaterThan(fixture.access.generation, firstGeneration)
        XCTAssertTrue(second.content is AuthenticationViewController)
        let replacementGeneration = fixture.access.generation
        firstUnlock.sendActions(for: .touchUpInside)
        secondUnlock.sendActions(for: .touchUpInside)
        XCTAssertEqual(firstAttempts, 1)
        XCTAssertEqual(secondAttempts, 1)
        XCTAssertEqual(fixture.access.generation, replacementGeneration)
    }

    func testPasswordEntryPublishesSessionAndRetiresItsOldCallbacks() throws {
        let fixture = WalletAccessTestFixture()
        let controller = instantiate(PasswordViewController.self, from: .main)
        controller.credentials = fixture.credentials
        controller.access = fixture.access
        controller.loadViewIfNeeded()
        controller.passwordTextField.text = "password"

        controller.okButtonTapped(controller.okButton as Any)

        let session = try XCTUnwrap(fixture.access.session)
        XCTAssertTrue(fixture.credentials.validateAccess(session))
        XCTAssertFalse(fixture.access.isLocked)
        XCTAssertTrue(controller.passwordTextField.text?.isEmpty ?? true)
        fixture.access.lock(reason: .background)
        try fixture.unlock()
        let generation = fixture.access.generation
        controller.passwordTextField.text = "password"
        controller.okButtonTapped(controller.okButton as Any)
        XCTAssertEqual(fixture.access.generation, generation)
    }

    func testReplacingAuthenticationLeavesTheOtherSceneUsableWithoutAnotherPrompt() throws {
        let fixture = WalletAccessTestFixture()
        let first = instantiate(PasswordViewController.self, from: .main)
        first.credentials = fixture.credentials
        first.access = fixture.access
        let firstNavigation = first.inNavigationController
        first.loadViewIfNeeded()
        first.viewDidAppear(false)
        first.passwordTextField.text = "discarded draft"

        let second = instantiate(PasswordViewController.self, from: .main)
        second.credentials = fixture.credentials
        second.access = fixture.access
        let secondNavigation = second.inNavigationController
        second.loadViewIfNeeded()
        second.viewDidAppear(false)

        XCTAssertTrue(first.initialOverlayView.isHidden)
        XCTAssertFalse(firstNavigation.isNavigationBarHidden)
        XCTAssertTrue(first.passwordTextField.isEnabled)
        XCTAssertTrue(first.okButton.isEnabled)
        XCTAssertTrue(first.passwordTextField.text?.isEmpty ?? true)
        second.viewDidDisappear(false)
        XCTAssertTrue(fixture.access.isLocked)
        first.passwordTextField.text = "password"
        first.okButtonTapped(first.okButton as Any)
        XCTAssertFalse(fixture.access.isLocked)
        XCTAssertNotNil(fixture.access.session)
        first.viewDidDisappear(false)
        withExtendedLifetime(secondNavigation) {}
    }

    func testLockClearsImportDraftAndRejectsRetainedSubmission() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let controller = instantiate(ImportViewController.self, from: .main)
        controller.access = fixture.access
        controller.loadViewIfNeeded()
        controller.textView.text = "disposable secret draft"
        var completed = false
        controller.completion = { _ in completed = true }

        fixture.access.lock(reason: .protectedDataUnavailable)

        XCTAssertTrue(controller.textView.text.isEmpty)
        XCTAssertFalse(controller.view.isUserInteractionEnabled)
        XCTAssertNil(controller.completion)
        try fixture.unlock()
        controller.okButtonTapped(controller.okButton as Any)
        XCTAssertFalse(completed)
        XCTAssertFalse(controller.hasWalletAccess)
    }

    func testAccessibilityScrollRenewsBothAccountTablesButProgrammaticScrollingDoesNot() throws {
        for editing in [false, true] {
            let fixture = WalletAccessTestFixture()
            try fixture.unlock()
            let controller: WalletAccessViewController
            let table: WalletActivityTableView
            if editing {
                let editor = instantiate(EditAccountsViewController.self, from: .main)
                editor.access = fixture.access
                editor.wallet = WalletSnapshot(id: "accessibility-test", isMnemonic: true, accounts: [])
                editor.loadViewIfNeeded()
                controller = editor
                table = try XCTUnwrap(editor.tableView as? WalletActivityTableView)
            } else {
                let accounts = instantiate(AccountsListViewController.self, from: .main)
                accounts.access = fixture.access
                accounts.loadViewIfNeeded()
                controller = accounts
                table = try XCTUnwrap(accounts.tableView as? WalletActivityTableView)
            }
            defer { fixture.access.lock(reason: .background) }
            fixture.advance(by: .seconds(30))
            let beforeScrolling = fixture.scheduler.expirations.count
            let passwordReads = fixture.keychain.passwordReadCount
            table.setContentOffset(CGPoint(x: 0, y: 20), animated: false)
            XCTAssertEqual(fixture.scheduler.expirations.count, beforeScrolling)

            _ = table.accessibilityScroll(.down)

            XCTAssertEqual(fixture.scheduler.expirations.count, beforeScrolling + 1)
            XCTAssertEqual(fixture.keychain.passwordReadCount, passwordReads)
            fixture.advance(by: .seconds(900))
            XCTAssertFalse(table.accessibilityScroll(.down))
            XCTAssertTrue(fixture.access.isLocked)
            try fixture.unlock()
            let afterUnlock = fixture.scheduler.expirations.count
            XCTAssertFalse(table.accessibilityScroll(.up))
            XCTAssertEqual(fixture.scheduler.expirations.count, afterUnlock)
            XCTAssertFalse(controller.hasWalletAccess)
        }
    }

    func testLockWhileLoadingAccountsCannotInstallItsViewAboveTheLockedScreen() throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let retired = LockingViewController { fixture.access.lock(reason: .idle) }
        let root = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in retired }, makeAuthentication: { _ in UIViewController() })

        root.loadViewIfNeeded()

        let locked = try XCTUnwrap(root.content as? MobileWalletLockedViewController)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertTrue(root.children.first === locked)
        XCTAssertEqual(root.view.subviews.count, 1)
        XCTAssertTrue(root.view.subviews.first === locked.view)
        XCTAssertNil(retired.parent)
        XCTAssertNil(retired.viewIfLoaded?.superview)
    }

    func testSceneNotificationsCoverTransientInactivityAndLockOnBackground() throws {
        try withRegistryWindow { fixture, center, window, scene, root, cover, _ in
            let session = try XCTUnwrap(fixture.access.session)
            let generation = fixture.access.generation
            center.post(name: UIScene.willDeactivateNotification, object: NSObject())
            XCTAssertTrue(cover.isHidden)

            center.post(name: UIScene.willDeactivateNotification, object: scene)
            XCTAssertFalse(cover.isHidden)
            XCTAssertTrue(window.subviews.last === cover)
            XCTAssertTrue(root.view.accessibilityElementsHidden)
            XCTAssertTrue(fixture.access.session === session)
            XCTAssertEqual(fixture.access.generation, generation)

            center.post(name: UIScene.didActivateNotification, object: scene)
            XCTAssertTrue(cover.isHidden)
            XCTAssertFalse(root.view.accessibilityElementsHidden)
            XCTAssertTrue(fixture.access.session === session)

            center.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            XCTAssertFalse(cover.isHidden)
            XCTAssertEqual(fixture.access.lockReason, .background)
            XCTAssertTrue(root.content is MobileWalletLockedViewController)
            XCTAssertFalse(fixture.credentials.validateAccess(session))

            center.post(name: UIScene.didActivateNotification, object: scene)
            XCTAssertTrue(cover.isHidden)
            XCTAssertTrue(fixture.access.isLocked)
            XCTAssertTrue(root.content is MobileWalletLockedViewController)
        }
    }

    func testProtectedDataLossKeepsPrivacyCoverThroughLateActivation() throws {
        try withRegistryWindow { fixture, center, _, scene, root, cover, availability in
            let pending = fixture.access.beginAuthentication(cancel: {})
            let lateSession = try fixture.makeSession()
            availability.value = false
            center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
            XCTAssertFalse(cover.isHidden)
            XCTAssertEqual(fixture.access.lockReason, .protectedDataUnavailable)
            XCTAssertTrue(root.content is MobileWalletLockedViewController)

            center.post(name: UIScene.didActivateNotification, object: scene)
            XCTAssertFalse(cover.isHidden)
            XCTAssertFalse(fixture.access.completeAuthentication(lateSession, generation: pending))
            XCTAssertTrue(fixture.access.isLocked)

            availability.value = true
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            XCTAssertTrue(cover.isHidden)
            XCTAssertTrue(fixture.access.isLocked)
            XCTAssertTrue(root.content is MobileWalletLockedViewController)
        }
    }

    private final class Availability {
        var value = true
    }

    private final class AuthenticationViewController: UIViewController {
        private let authenticate: () -> Void
        private var started = false

        init(authenticate: @escaping () -> Void) {
            self.authenticate = authenticate
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard parent != nil, !started else { return }
            started = true
            authenticate()
        }
    }

    private final class LockingViewController: UIViewController {
        private let loaded: () -> Void

        init(loaded: @escaping () -> Void) {
            self.loaded = loaded
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            loaded()
        }
    }

    private func withRegistryWindow(
        _ body: (WalletAccessTestFixture, NotificationCenter, UIWindow, UIWindowScene,
                 MobileWalletRootViewController, UIView, Availability) throws -> Void
    ) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let center = NotificationCenter()
        let availability = Availability()
        let registry = MobileWalletSceneRegistry(access: fixture.access, notifications: center,
            protectedDataAvailable: { availability.value })
        let window = UIWindow(windowScene: scene)
        let root = MobileWalletRootViewController(access: fixture.access, registerWindow: { _ in },
            makeAccounts: { _ in UIViewController() }, makeAuthentication: { _ in UIViewController() })
        window.rootViewController = root
        root.loadViewIfNeeded()
        registry.register(window)
        let cover = try XCTUnwrap(window.subviews.first { $0.accessibilityIdentifier == "wallet-privacy-cover" })
        defer {
            center.post(name: UIScene.didDisconnectNotification, object: scene)
            window.rootViewController = nil
        }
        try body(fixture, center, window, scene, root, cover, availability)
        withExtendedLifetime(registry) {}
    }

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0, identifier: identifier) }.first
    }
}
#endif
