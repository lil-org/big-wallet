#if os(iOS) || os(visionOS)
import Security
import UIKit
import XCTest
import WalletDomain
@testable import WalletAuthority
@testable import Big_Wallet

@MainActor
final class MobileSecretLifetimeTests: XCTestCase {
    private enum Failure: Error { case failed }

    func testImportSuccessRetiresDraftBeforeCompletionAndDismissal() async throws {
        let controller = try makeImportController()
        let result = TestGate<WalletSnapshot>()
        let started = expectation(description: "import started")
        let completed = expectation(description: "completion delivered")
        controller.importWallet = { input, password in
            XCTAssertEqual(input, "disposable import")
            XCTAssertNil(password)
            started.fulfill()
            return await result.wait()
        }
        controller.onDismiss = { [weak controller] in
            guard let controller else { return XCTFail("Import controller disappeared before dismissal") }
            XCTAssertTrue(controller.isRetired)
            XCTAssertTrue(controller.textView.text.isEmpty)
        }
        controller.completion = { success in
            XCTAssertTrue(success)
            XCTAssertTrue(controller.isRetired)
            XCTAssertNil(controller.completion)
            XCTAssertTrue(controller.textView.text.isEmpty)
            XCTAssertFalse(controller.view.isUserInteractionEnabled)
            completed.fulfill()
        }
        controller.textView.text = "disposable import"
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [started], timeout: 2)
        result.resolve(wallet())
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(controller.dismissals, 1)
    }

    func testCanceledImportIgnoresLateSuccessAndRetainedSubmission() async throws {
        let controller = try makeImportController()
        let result = TestGate<WalletSnapshot>()
        let started = expectation(description: "import started")
        let returned = expectation(description: "late import returned")
        var imports = 0
        var completions = 0
        controller.importWallet = { _, _ in
            imports += 1
            started.fulfill()
            let wallet = await result.wait()
            returned.fulfill()
            return wallet
        }
        controller.completion = { _ in completions += 1 }
        controller.textView.text = "discarded import"
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [started], timeout: 2)

        controller.cancelImport()

        XCTAssertTrue(controller.isRetired)
        XCTAssertTrue(controller.textView.text.isEmpty)
        XCTAssertNil(controller.completion)
        result.resolve(wallet())
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        controller.okButtonTapped(controller.okButton as Any)
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(controller.dismissals, 1)
    }

    func testFailedImportPreservesEditableDraftForRetry() async throws {
        let controller = try makeImportController()
        let result = TestDeferred<WalletSnapshot>()
        let started = expectation(description: "import started")
        controller.importWallet = { _, _ in
            started.fulfill()
            return try await result.value()
        }
        controller.textView.text = "retryable import"
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [started], timeout: 2)
        result.resolve(.failure(Failure.failed))
        await expectEventually { !controller.presentedAlerts.isEmpty }

        XCTAssertFalse(controller.isRetired)
        XCTAssertTrue(controller.view.isUserInteractionEnabled)
        XCTAssertEqual(controller.textView.text, "retryable import")
        XCTAssertEqual(controller.dismissals, 0)
        controller.cancelImport()
    }

    func testImportChecksStoredCredentialsOnlyWhenSubmitting() async throws {
        for replaced in [false, true] {
            let fixture = WalletAccessTestFixture()
            try fixture.unlock()
            let controller = try makeImportController(access: fixture.access)
            var imports = 0
            controller.importWallet = { _, _ in imports += 1; return self.wallet() }
            if replaced { fixture.keychain.passwordData = Data("replacement".utf8) }
            else { fixture.keychain.readStatus = errSecInteractionNotAllowed }
            let passwordReads = fixture.keychain.passwordReadCount

            XCTAssertTrue(controller.textView(controller.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "retryable import"))
            controller.textView.text = "retryable import"
            controller.textViewDidChange(controller.textView)
            await expectEventually { controller.okButton.isEnabled }

            XCTAssertEqual(fixture.keychain.passwordReadCount, passwordReads)
            XCTAssertFalse(fixture.access.isLocked)
            controller.okButtonTapped(controller.okButton as Any)
            await expectEventually { controller.isRetired || !controller.presentedAlerts.isEmpty }

            XCTAssertEqual(imports, 0)
            XCTAssertEqual(fixture.keychain.passwordReadCount, passwordReads + 1)
            XCTAssertEqual(fixture.access.isLocked, replaced)
            if replaced {
                XCTAssertTrue(controller.isRetired)
                XCTAssertTrue(controller.textView.text.isEmpty)
            } else {
                XCTAssertFalse(controller.isRetired)
                XCTAssertEqual(controller.textView.text, "retryable import")
                XCTAssertTrue(controller.view.isUserInteractionEnabled)
            }
            fixture.access.lock(reason: .background)
        }
    }

    func testKeystoreImportWaitsForPromptDismissalAndClearsThePassword() async throws {
        let controller = try makeImportController()
        let shown = expectation(description: "keystore prompt shown")
        let imported = expectation(description: "keystore imported")
        var alert: UIAlertController?
        var finishDismissal: (@MainActor @Sendable () -> Void)?
        let prompt = LocalAuthentication.AlertRequest(show: { _, value in
            alert = value
            shown.fulfill()
        }, dismiss: { _, _, completion in finishDismissal = completion })
        controller.makePasswordPrompt = { prompt }
        controller.validateWalletInput = { _ in .requiresPassword }
        var importCount = 0
        controller.importWallet = { input, password in
            importCount += 1
            XCTAssertEqual(input, "encrypted import")
            XCTAssertEqual(password, "keystore password")
            imported.fulfill()
            throw Failure.failed
        }
        controller.textView.text = "encrypted import"
        controller.textViewDidChange(controller.textView)
        await expectEventually { controller.okButton.isEnabled }
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [shown], timeout: 2)
        try XCTUnwrap(alert?.textFields?.first).text = "keystore password"

        prompt.confirm()

        XCTAssertTrue(alert?.textFields?.first?.text?.isEmpty ?? false)
        XCTAssertEqual(importCount, 0)
        let dismiss = try XCTUnwrap(finishDismissal)
        finishDismissal = nil
        dismiss()
        await fulfillment(of: [imported], timeout: 2)
        await expectEventually { !controller.presentedAlerts.isEmpty }
        XCTAssertEqual(controller.textView.text, "encrypted import")
        XCTAssertFalse(controller.isRetired)
        controller.cancelImport()
    }

    func testCancelDuringKeystoreDismissalPreventsImportAndClearsDraft() async throws {
        let controller = try makeImportController()
        let shown = expectation(description: "keystore prompt shown")
        var alert: UIAlertController?
        var finishDismissal: (@MainActor @Sendable () -> Void)?
        let prompt = LocalAuthentication.AlertRequest(show: { _, value in
            alert = value
            shown.fulfill()
        }, dismiss: { _, _, completion in finishDismissal = completion })
        controller.makePasswordPrompt = { prompt }
        controller.validateWalletInput = { _ in .requiresPassword }
        var imports = 0
        controller.importWallet = { _, _ in imports += 1; return self.wallet() }
        controller.textView.text = "encrypted import"
        controller.textViewDidChange(controller.textView)
        await expectEventually { controller.okButton.isEnabled }
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [shown], timeout: 2)
        try XCTUnwrap(alert?.textFields?.first).text = "keystore password"
        prompt.confirm()

        controller.cancelImport()
        let dismiss = try XCTUnwrap(finishDismissal)
        finishDismissal = nil
        dismiss()
        await Task.yield()

        XCTAssertEqual(imports, 0)
        XCTAssertTrue(controller.isRetired)
        XCTAssertTrue(controller.textView.text.isEmpty)
        XCTAssertTrue(alert?.textFields?.first?.text?.isEmpty ?? false)
    }

    func testTransientAndCanceledRemovalPreserveDraftUntilRemovalCompletes() throws {
        let controller = try makeImportController()
        controller.textView.text = "retained import"
        controller.viewWillDisappear(false)
        controller.viewDidDisappear(false)
        XCTAssertFalse(controller.isRetired)
        XCTAssertEqual(controller.textView.text, "retained import")

        let transition = RemovalTransition()
        controller.removalTransition = transition
        controller.removing = true
        controller.viewWillDisappear(true)
        controller.viewDidDisappear(true)
        XCTAssertFalse(controller.isRetired)
        transition.finish(cancelled: true)
        XCTAssertFalse(controller.isRetired)
        XCTAssertEqual(controller.textView.text, "retained import")

        controller.viewWillDisappear(true)
        transition.finish(cancelled: false)
        XCTAssertTrue(controller.isRetired)
        XCTAssertTrue(controller.textView.text.isEmpty)
    }

    func testKeystoreConfirmationRenewsAccessButDelayedDismissalDoesNot() async throws {
        let fixture = WalletAccessTestFixture()
        try fixture.unlock()
        let controller = try makeImportController(access: fixture.access)
        let shown = expectation(description: "keystore prompt shown")
        let imported = expectation(description: "import reached backend")
        let result = TestDeferred<WalletSnapshot>()
        var alert: UIAlertController?
        var finishDismissal: (@MainActor @Sendable () -> Void)?
        let prompt = LocalAuthentication.AlertRequest(show: { _, value in
            alert = value
            shown.fulfill()
        }, dismiss: { _, _, completion in finishDismissal = completion })
        controller.makePasswordPrompt = { prompt }
        controller.validateWalletInput = { _ in .requiresPassword }
        controller.importWallet = { _, _ in
            imported.fulfill()
            return try await result.value()
        }
        controller.textView.text = "encrypted import"
        controller.textViewDidChange(controller.textView)
        await expectEventually { controller.okButton.isEnabled }
        controller.okButtonTapped(controller.okButton as Any)
        await fulfillment(of: [shown], timeout: 2)
        try XCTUnwrap(alert?.textFields?.first).text = "keystore password"
        fixture.advance(by: .seconds(100))
        let beforeConfirmation = fixture.scheduler.expirations.count

        prompt.confirm()

        XCTAssertEqual(fixture.scheduler.expirations.count, beforeConfirmation + 1)
        let afterConfirmation = fixture.scheduler.expirations.count
        fixture.advance(by: .seconds(400))
        let dismiss = try XCTUnwrap(finishDismissal)
        finishDismissal = nil
        dismiss()
        await fulfillment(of: [imported], timeout: 2)
        XCTAssertEqual(fixture.scheduler.expirations.count, afterConfirmation)
        fixture.advance(by: .seconds(500))
        XCTAssertFalse(fixture.access.checkAccess())
        XCTAssertTrue(controller.isRetired)
        await expectEventually { result.isCancelled }
    }

    func testPasswordDisappearanceWaitsForConfirmedTransitionBeforeClearingDrafts() {
        let fixture = WalletAccessTestFixture()
        fixture.keychain.passwordData = nil
        let controller = PasswordController()
        controller.credentials = fixture.credentials
        controller.access = fixture.access
        controller.passwordToRepeat = "draft-password"
        controller.loadViewIfNeeded()
        controller.passwordTextField.text = "draft-password"
        let transition = RemovalTransition()
        controller.removalTransition = transition
        controller.removing = true

        controller.viewWillDisappear(true)
        controller.viewDidDisappear(true)
        XCTAssertEqual(controller.passwordToRepeat, "draft-password")
        XCTAssertEqual(controller.passwordTextField.text, "draft-password")
        transition.finish(cancelled: true)
        XCTAssertEqual(controller.passwordToRepeat, "draft-password")
        XCTAssertEqual(controller.passwordTextField.text, "draft-password")

        controller.viewWillDisappear(true)
        transition.finish(cancelled: false)
        XCTAssertNil(controller.passwordToRepeat)
        XCTAssertTrue(controller.passwordTextField.text?.isEmpty ?? true)
    }

    func testRemovingImportFromItsParentRetiresTheDraft() throws {
        let controller = try makeImportController()
        let parent = UIViewController()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
        controller.textView.text = "removed import"

        controller.willMove(toParent: nil)
        controller.removeFromParent()

        XCTAssertTrue(controller.isRetired)
        XCTAssertTrue(controller.textView.text.isEmpty)
    }

    func testTerminalImportClearRemovesOnlyItsAuthenticUndoHistory() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = instantiate(ImportViewController.self, from: .main)
        controller.access = try unlockedWalletAccessForTesting()
        controller.validateWalletInput = { _ in .invalid }
        let host = UIViewController()
        window.rootViewController = host
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.view.frame = host.view.bounds
        controller.didMove(toParent: host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let input = try XCTUnwrap(controller.textView as? SecretImportTextView)
        let (unrelatedWindow, unrelated) = unrelatedInput(in: scene)
        defer {
            controller.cancelImport()
            unrelatedWindow.isHidden = true
            unrelatedWindow.rootViewController = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        XCTAssertTrue(input.becomeFirstResponder())
        let secretUndo = try XCTUnwrap(input.undoManager)
        secretUndo.beginUndoGrouping()
        input.insertText("disposable secret")
        secretUndo.endUndoGrouping()
        XCTAssertTrue(secretUndo.canUndo)
        secretUndo.undo()
        XCTAssertTrue(input.text.isEmpty)
        XCTAssertTrue(secretUndo.canRedo)
        secretUndo.redo()
        XCTAssertEqual(input.text, "disposable secret")
        unrelatedWindow.makeKeyAndVisible()
        XCTAssertTrue(unrelated.becomeFirstResponder())
        let unrelatedUndo = try XCTUnwrap(unrelated.undoManager)
        unrelatedUndo.beginUndoGrouping()
        unrelated.insertText("unrelated edit")
        unrelatedUndo.endUndoGrouping()
        XCTAssertTrue(unrelatedUndo.canUndo)
        XCTAssertFalse(secretUndo === unrelatedUndo)

        controller.cancelImport()

        XCTAssertFalse(secretUndo.canUndo)
        secretUndo.undo()
        XCTAssertTrue(input.text.isEmpty)
        XCTAssertTrue(unrelatedUndo.canUndo)
        for _ in 0..<8 where unrelatedUndo.canUndo && !unrelated.text.isEmpty {
            unrelatedUndo.undo()
        }
        XCTAssertTrue(unrelated.text.isEmpty)
        XCTAssertTrue(unrelatedUndo.canRedo)
    }

    func testLockedPasswordControlCannotRestoreAnAuthenticEditThroughUndo() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let fixture = WalletAccessTestFixture()
        fixture.keychain.passwordData = nil
        let controller = instantiate(PasswordViewController.self, from: .main)
        controller.credentials = fixture.credentials
        controller.access = fixture.access
        controller.passwordToRepeat = "confirmation draft"
        let host = UIViewController()
        window.rootViewController = host
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.view.frame = host.view.bounds
        controller.didMove(toParent: host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        let field = try XCTUnwrap(controller.passwordTextField)
        let (unrelatedWindow, unrelated) = unrelatedInput(in: scene)
        defer {
            fixture.access.lock(reason: .background)
            unrelatedWindow.isHidden = true
            unrelatedWindow.rootViewController = nil
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        XCTAssertTrue(field.becomeFirstResponder())
        let originalPasswordUndo = field.undoManager
        originalPasswordUndo?.beginUndoGrouping()
        field.insertText("disposable password")
        originalPasswordUndo?.endUndoGrouping()
        XCTAssertEqual(field.text, "disposable password")

        unrelatedWindow.makeKeyAndVisible()
        XCTAssertTrue(unrelated.becomeFirstResponder())
        let unrelatedUndo = try XCTUnwrap(unrelated.undoManager)
        unrelatedUndo.beginUndoGrouping()
        unrelated.insertText("unrelated edit")
        unrelatedUndo.endUndoGrouping()
        XCTAssertTrue(unrelatedUndo.canUndo)
        XCTAssertFalse(originalPasswordUndo === unrelatedUndo)

        fixture.access.lock(reason: .background)

        XCTAssertTrue(field.text?.isEmpty ?? true)
        XCTAssertNil(controller.passwordToRepeat)
        XCTAssertFalse(originalPasswordUndo?.canUndo ?? false,
            "Original manager \(String(describing: originalPasswordUndo.map(ObjectIdentifier.init))) current \(String(describing: field.undoManager.map(ObjectIdentifier.init)))")
        XCTAssertTrue(unrelatedUndo.canUndo)
        for _ in 0..<8 where unrelatedUndo.canUndo && !unrelated.text.isEmpty {
            unrelatedUndo.undo()
        }
        XCTAssertTrue(unrelated.text.isEmpty)
        XCTAssertTrue(unrelatedUndo.canRedo)
        var managers = [UndoManager]()
        for manager in [originalPasswordUndo, field.undoManager].compactMap({ $0 }) {
            if !managers.contains(where: { $0 === manager }) { managers.append(manager) }
        }
        for manager in managers {
            XCTAssertFalse(manager.canUndo)
            XCTAssertFalse(manager.canRedo)
            if !manager.canUndo && !manager.canRedo {
                manager.undo()
                manager.redo()
                XCTAssertTrue(field.text?.isEmpty ?? true)
            }
        }
        XCTAssertTrue(field.text?.isEmpty ?? true)
    }

    func testDynamicPasswordPromptClearsOnlyItsAuthenticHistoryOnConfirmCancelAndLock() async throws {
        enum Finish { case confirm, cancel, lock }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for finish in [Finish.confirm, .cancel, .lock] {
            let previous = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            let fixture = WalletAccessTestFixture()
            try fixture.unlock()
            let host = UIViewController()
            let presenter = PasswordPromptOwner()
            presenter.access = fixture.access
            window.rootViewController = host
            host.addChild(presenter)
            host.view.addSubview(presenter.view)
            presenter.view.frame = host.view.bounds
            presenter.didMove(toParent: host)
            let (unrelatedWindow, unrelated) = unrelatedInput(in: scene)
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            defer {
                presenter.prompt?.cancel()
                unrelatedWindow.isHidden = true
                unrelatedWindow.rootViewController = nil
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            unrelatedWindow.makeKeyAndVisible()
            XCTAssertTrue(unrelated.becomeFirstResponder())
            let unrelatedUndo = try XCTUnwrap(unrelated.undoManager)
            unrelatedUndo.beginUndoGrouping()
            unrelated.insertText("unrelated edit")
            unrelatedUndo.endUndoGrouping()
            XCTAssertTrue(unrelatedUndo.canUndo)
            window.makeKeyAndVisible()
            let shown = expectation(description: "real password prompt shown")
            var alert: UIAlertController?
            let prompt = LocalAuthentication.AlertRequest(show: { controller, value in
                alert = value
                controller.present(value, animated: false) { shown.fulfill() }
            })
            presenter.prompt = prompt
            let task = Task {
                await prompt.present(from: { presenter }, title: "Password", message: nil, requestsPassword: true)
            }
            await fulfillment(of: [shown], timeout: 3)
            let field = try XCTUnwrap(alert?.textFields?.first)
            XCTAssertTrue(field.becomeFirstResponder())
            let passwordUndo = try XCTUnwrap(field.undoManager)
            XCTAssertFalse(passwordUndo === unrelatedUndo)
            passwordUndo.beginUndoGrouping()
            field.insertText("disposable password")
            passwordUndo.endUndoGrouping()
            XCTAssertEqual(field.text, "disposable password")

            switch finish {
            case .confirm: prompt.confirm()
            case .cancel: prompt.cancel()
            case .lock: fixture.access.lock(reason: .background)
            }
            let result = await task.value

            if case .confirm = finish { XCTAssertEqual(result, "disposable password") }
            else { XCTAssertNil(result) }
            XCTAssertTrue(field.text?.isEmpty ?? true)
            XCTAssertFalse(passwordUndo.canUndo)
            XCTAssertFalse(passwordUndo.canRedo)
            if !passwordUndo.canUndo && !passwordUndo.canRedo {
                passwordUndo.undo()
                passwordUndo.redo()
            }
            XCTAssertTrue(field.text?.isEmpty ?? true)
            unrelatedWindow.makeKeyAndVisible()
            XCTAssertTrue(unrelated.becomeFirstResponder())
            XCTAssertTrue(unrelatedUndo.canUndo)
            for _ in 0..<8 where unrelatedUndo.canUndo && !unrelated.text.isEmpty { unrelatedUndo.undo() }
            XCTAssertTrue(unrelated.text.isEmpty)
            XCTAssertTrue(unrelatedUndo.canRedo)
        }
    }

    private func makeImportController(access: WalletAccessController? = nil) throws -> ImportController {
        let controller = ImportController()
        controller.access = try access ?? unlockedWalletAccessForTesting()
        controller.validateWalletInput = { _ in .valid }
        controller.loadViewIfNeeded()
        return controller
    }

    private func unrelatedInput(in scene: UIWindowScene) -> (UIWindow, UITextView) {
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let input = UITextView(frame: CGRect(x: 0, y: 100, width: 300, height: 100))
        controller.view.addSubview(input)
        window.rootViewController = controller
        return (window, input)
    }

    private func wallet() -> WalletSnapshot { .init(id: "imported", isMnemonic: true, accounts: []) }

    private final class ImportController: ImportViewController {
        var presentedAlerts = [UIAlertController]()
        var dismissals = 0
        var onDismiss: (() -> Void)?
        var removing = false
        var removalTransition: RemovalTransition?
        override var isBeingDismissed: Bool { removing }
        override var transitionCoordinator: (any UIViewControllerTransitionCoordinator)? { removalTransition }

        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let input = SecretImportTextView(frame: view.bounds)
            let placeholder = UILabel()
            let paste = UIButton(type: .system)
            let ok = UIButton(type: .system)
            let children: [UIView] = [input, placeholder, paste, ok]
            for child in children { view.addSubview(child) }
            textView = input
            placeholderLabel = placeholder
            pasteButton = paste
            okButton = ok
        }

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            if let alert = viewControllerToPresent as? UIAlertController { presentedAlerts.append(alert) }
            completion?()
        }

        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            dismissals += 1
            onDismiss?()
            completion?()
        }
    }

    private final class PasswordController: PasswordViewController {
        var removing = false
        var removalTransition: RemovalTransition?
        override var isBeingDismissed: Bool { removing }
        override var transitionCoordinator: (any UIViewControllerTransitionCoordinator)? { removalTransition }

        override func loadView() {
            view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            let input = UITextField()
            input.isSecureTextEntry = true
            let overlay = UIView()
            let ok = UIButton(type: .system)
            let children: [UIView] = [input, overlay, ok]
            for child in children { view.addSubview(child) }
            passwordTextField = input
            initialOverlayView = overlay
            okButton = ok
        }
    }

    private final class PasswordPromptOwner: WalletAccessViewController {
        var prompt: LocalAuthentication.AlertRequest?

        override func walletAccessDidLock() {
            super.walletAccessDidLock()
            prompt?.cancel()
        }
    }

    @MainActor
    private final class RemovalTransition: NSObject, UIViewControllerTransitionCoordinator {
        private var completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?
        var isCancelled = false
        let isAnimated = true
        let presentationStyle = UIModalPresentationStyle.pageSheet
        let initiallyInteractive = true
        let isInterruptible = true
        let isInteractive = true
        let transitionDuration: TimeInterval = 1
        let percentComplete: CGFloat = 0.5
        let completionVelocity: CGFloat = 0
        let completionCurve = UIView.AnimationCurve.linear
        let containerView = UIView()
        let targetTransform = CGAffineTransform.identity

        func finish(cancelled: Bool) {
            isCancelled = cancelled
            let completion = completion
            self.completion = nil
            completion?(self)
        }

        func animate(alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil) -> Bool {
            self.completion = completion
            return true
        }

        func animateAlongsideTransition(in view: UIView?, animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?, completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil) -> Bool {
            self.completion = completion
            return true
        }

        func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
#if os(iOS)
        func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
#endif
        func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
        func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }
    }
}
#endif
