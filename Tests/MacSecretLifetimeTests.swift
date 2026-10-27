import AppKit
import Security
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority
@testable import Big_Wallet

@MainActor
final class MacSecretLifetimeTests: XCTestCase {
    func testAccountsNavigationCancelsPendingMutationBeforeLockAndReleasesItsController() async throws {
        for (opensEditor, retainsController, locksDuringNavigation) in [
            (false, true, false), (true, true, false), (false, false, false),
            (false, true, true), (true, true, true),
        ] {
            let fixture = WalletAccessTestFixture(password: String(decoding: WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword, as: UTF8.self))
            try fixture.unlock()
            let entered = expectation(description: "account mutation reached commit boundary")
            let exited = expectation(description: "cancelled account mutation returned")
            let mutation = HeldAccountMutation(entered: entered, exited: exited)
            defer { mutation.release() }
            let reader = KeychainCopyMatchingStub()
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture))
            key.addAccountDerivation(address: WalletCoreProxyTestVectors.abandonEthereumSecondAddress,
                coin: .ethereum, derivation: .custom, derivationPath: "m/44'/60'/0'/0/1",
                publicKey: WalletCoreProxyTestVectors.abandonEthereumSecondPublicKey,
                extendedPublicKey: WalletCoreProxyTestVectors.abandonEthereumExtendedPublicKey)
            let original = try XCTUnwrap(key.exportJSON())
            reader.attributes = [reader.walletAttributes(id: "retired-accounts")]
            reader.walletData = ["retired-accounts": original]
            reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
            let writes = Mutex(0)
            var publications = 0
            let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching, update: { _, attributes in
                writes.withLock { $0 += 1 }
                reader.walletData["retired-accounts"] = (attributes as NSDictionary)[kSecValueData as String] as? Data
                return errSecSuccess
            }), walletSourceMutator: mutation, notifications: .init(
                postLocalChange: {}, postMutation: { publications += 1 },
                startObserving: { _, _ in }, stopObserving: { _ in }, isExternalChange: { _ in false }
            ), authorityID: fixture.authorityID)
            await assertWalletReload(manager)
            XCTAssertEqual(manager.wallets.first?.accounts.count, 2)
            var controller: AccountsListViewController? = AccountsListViewController()
            controller?.walletsManager = manager
            controller?.walletAccess = NativeWalletAccess(fixture.access)
            weak var retiredController = controller
            let window = SecretLifetimeWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let windowController = WalletWindowController(window: window)
            windowController.bindAccess(fixture.access, unlock: {})
            window.contentViewController = controller
            window.orderFront(nil)
            defer { windowController.close() }
            controller?.tableView.deselectedRow = 1
            _ = controller?.perform(NSSelectorFromString("didClickRemoveAccount:"), with: NSMenuItem())
            await fulfillment(of: [entered], timeout: 3)
            if locksDuringNavigation {
                fixture.access.isProtectedDataAvailable = { [weak window] in
                    !(window?.contentViewController is ImportViewController || window?.contentViewController is EditAccountsViewController)
                }
            }

            if opensEditor {
                let header = try XCTUnwrap(controller?.tableView.rowView(atRow: 0, makeIfNecessary: true))
                controller?.didClickEditAccounts(sender: header)
                if !locksDuringNavigation { XCTAssertTrue(window.contentViewController is EditAccountsViewController) }
            } else {
                _ = controller?.perform(NSSelectorFromString("didClickImportAccount"))
                if !locksDuringNavigation { XCTAssertTrue(window.contentViewController is ImportViewController) }
            }
            XCTAssertEqual(controller?.tableView.numberOfRows, 0)
            if locksDuringNavigation { XCTAssertTrue(fixture.access.isLocked) }
            else { fixture.access.lock(reason: .systemSleep) }
            let locked = try XCTUnwrap(window.contentViewController as? WalletLockedViewController)
            _ = controller?.perform(NSSelectorFromString("didClickImportAccount"))
            XCTAssertTrue(window.contentViewController === locked)
            if !retainsController {
                controller = nil
                await expectEventually { retiredController == nil }
            }

            mutation.release()
            await fulfillment(of: [exited], timeout: 3)
            await assertWalletReload(manager)
            if retainsController { XCTAssertNotNil(controller) }
            XCTAssertTrue(mutation.wasCancelled)
            XCTAssertEqual(writes.withLock { $0 }, 0)
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(reader.walletData["retired-accounts"], original)
            XCTAssertEqual(manager.wallets.first?.accounts.count, 2)
            XCTAssertTrue(window.contentViewController === locked)
            XCTAssertNil(window.attachedSheet)
        }
    }

    func testImportRevalidatesChangedCredentialsBeforeMutatingTheWallet() async throws {
        let host = try ImportHost()
        defer { host.close() }
        var imports = 0
        host.controller.dependencies.importWallet = { _, _, _ in imports += 1; return Self.wallet }
        let reads = host.fixture.keychain.passwordReadCount
        host.fixture.keychain.passwordData = Data("replacement".utf8)

        let editor = try enter("disposable import draft", in: host.controller.textField)
        await expectEventually { host.controller.okButton.isEnabled }

        XCTAssertFalse(host.fixture.access.isLocked)
        XCTAssertEqual(host.fixture.keychain.passwordReadCount, reads)
        host.controller.actionButtonTapped(host.controller.okButton as Any)
        await expectEventually { host.fixture.access.isLocked }

        XCTAssertEqual(imports, 0)
        XCTAssertEqual(host.fixture.keychain.passwordReadCount, reads + 1)
        XCTAssertTrue(host.window.contentViewController is WalletLockedViewController)
        XCTAssertTrue(host.controller.textField.stringValue.isEmpty)
        XCTAssertTrue(editor.string.isEmpty)
    }

    func testSuccessfulImportClearsTheDraftBeforeReplacingContent() async throws {
        let host = try ImportHost()
        defer { host.close() }
        let started = expectation(description: "import started")
        let result = TestGate<Result<WalletSnapshot, Error>>()
        defer { result.resolve(.failure(CancellationError())) }
        host.controller.dependencies.importWallet = { input, password, _ in
            XCTAssertEqual(input, "disposable import draft")
            XCTAssertNil(password)
            started.fulfill()
            return try await result.wait().get()
        }
        let editor = try enter("disposable import draft", in: host.controller.textField)
        await expectEventually { host.controller.okButton.isEnabled }
        var clearedBeforeNavigation = false
        host.window.beforeContentReplacement = { next in
            guard next is AccountsListViewController else { return }
            clearedBeforeNavigation = host.controller.textField.stringValue.isEmpty && editor.string.isEmpty &&
                !host.controller.textField.isEnabled && !host.controller.okButton.isEnabled
        }

        host.controller.actionButtonTapped(host.controller.okButton as Any)
        await fulfillment(of: [started], timeout: 2)
        result.resolve(.success(Self.wallet))
        await expectEventually { host.window.contentViewController is AccountsListViewController }

        XCTAssertTrue(clearedBeforeNavigation)
        XCTAssertNil(host.controller.textField.currentEditor())
        XCTAssertFalse(editor.allowsUndo)
        let current = host.window.contentViewController
        host.controller.textField.stringValue = "retained callback input"
        host.controller.actionButtonTapped(host.controller.okButton as Any)
        host.controller.cancelButtonTapped(host.controller.cancelButton)
        XCTAssertTrue(host.window.contentViewController === current)
    }

    func testCancelClearsTheDraftAndRejectsLateValidationInTheSameAccessSession() async throws {
        let host = try ImportHost()
        defer { host.close() }
        let entered = expectation(description: "validation entered")
        let returned = expectation(description: "validation returned")
        let validation = TestGate<WalletsManager.InputValidationResult>()
        defer { validation.resolve(.invalid) }
        host.controller.dependencies.validate = { _ in
            entered.fulfill()
            let result = await validation.wait()
            returned.fulfill()
            return result
        }
        var imports = 0
        host.controller.dependencies.importWallet = { _, _, _ in imports += 1; return Self.wallet }
        let editor = try enter("cancelled draft", in: host.controller.textField)
        await fulfillment(of: [entered], timeout: 2)
        let generation = host.fixture.access.generation

        host.controller.cancelButtonTapped(host.controller.cancelButton)
        let replacement = host.window.contentViewController
        validation.resolve(.valid)
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()

        XCTAssertEqual(host.fixture.access.generation, generation)
        XCTAssertTrue(host.controller.textField.stringValue.isEmpty)
        XCTAssertTrue(editor.string.isEmpty)
        XCTAssertFalse(host.controller.okButton.isEnabled)
        host.controller.actionButtonTapped(host.controller.okButton as Any)
        XCTAssertEqual(imports, 0)
        XCTAssertTrue(host.window.contentViewController === replacement)
    }

    func testRemovalCloseAndLockRetireAnImportBeforeItsLateSuccess() async throws {
        for end in [End.removal, .windowClose, .lock] {
            let host = try ImportHost()
            defer { host.close() }
            let started = expectation(description: "held import started")
            let returned = expectation(description: "held import returned")
            let result = TestGate<Result<WalletSnapshot, Error>>()
            defer { result.resolve(.failure(CancellationError())) }
            host.controller.dependencies.importWallet = { _, _, _ in
                started.fulfill()
                let value = await result.wait()
                returned.fulfill()
                return try value.get()
            }
            let editor = try enter("in-flight draft", in: host.controller.textField)
            await expectEventually { host.controller.okButton.isEnabled }
            host.controller.actionButtonTapped(host.controller.okButton as Any)
            await fulfillment(of: [started], timeout: 2)
            let replacement = NSViewController()
            replacement.view = NSView(frame: host.controller.view.frame)
            switch end {
            case .removal: host.window.contentViewController = replacement
            case .windowClose: host.window.close()
            case .lock: host.fixture.access.lock(reason: .idle)
            }
            await expectEventually { host.controller.textField.stringValue.isEmpty }
            let current = host.window.contentViewController
            result.resolve(.success(Self.wallet))
            await fulfillment(of: [returned], timeout: 2)
            await Task.yield()

            XCTAssertTrue(editor.string.isEmpty)
            XCTAssertFalse(host.controller.textField.isEnabled)
            XCTAssertFalse(host.controller.okButton.isEnabled)
            XCTAssertTrue(host.window.contentViewController === current)
            if end == .windowClose { XCTAssertFalse(host.window.isVisible) }
        }
    }

    func testRecoverableFailureKeepsTheDraftButClearsTheKeystorePasswordBeforeImport() async throws {
        let host = try ImportHost()
        defer { host.close() }
        host.windowController.approvalPeer = PeerMeta(title: "fixture")
        host.controller.dependencies.validate = { _ in .requiresPassword }
        var passwordField: NSSecureTextField?
        var passwordEditor: NSTextView?
        host.controller.dependencies.runPasswordPrompt = { alert in
            let field = alert.accessoryView as! NSSecureTextField
            passwordField = field
            alert.layout()
            XCTAssertTrue(field.window === alert.window)
            alert.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            alert.window.orderFront(nil)
            XCTAssertTrue(alert.window.makeFirstResponder(field))
            defer { alert.window.orderOut(nil) }
            passwordEditor = try? self.enter("keystore-password", in: field)
            return .alertFirstButtonReturn
        }
        let imported = expectation(description: "password cleared before import")
        host.controller.dependencies.importWallet = { input, password, _ in
            XCTAssertEqual(input, "encrypted wallet draft")
            XCTAssertEqual(password, "keystore-password")
            XCTAssertEqual(passwordField?.stringValue, "")
            XCTAssertEqual(passwordEditor?.string, "")
            imported.fulfill()
            throw ImportFailure.expected
        }
        _ = try enter("encrypted wallet draft", in: host.controller.textField)
        await expectEventually { host.controller.okButton.isEnabled }

        host.controller.actionButtonTapped(host.controller.okButton as Any)
        await fulfillment(of: [imported], timeout: 2)
        await expectEventually { host.window.attachedSheet != nil }

        XCTAssertTrue(host.window.contentViewController === host.controller)
        XCTAssertEqual(host.controller.textField.stringValue, "encrypted wallet draft")
        XCTAssertTrue(host.controller.textField.isEnabled)
        XCTAssertTrue(host.controller.okButton.isEnabled)
        XCTAssertTrue(host.controller.cancelButton.isEnabled)
        XCTAssertFalse(try XCTUnwrap(passwordEditor).allowsUndo)
        Window.dismissSheets(in: host.window)
    }

    func testCancellingKeystorePromptClearsOnlyItsPassword() async throws {
        let host = try ImportHost()
        defer { host.close() }
        host.controller.dependencies.validate = { _ in .requiresPassword }
        var passwordField: NSSecureTextField?
        var passwordEditor: NSTextView?
        host.controller.dependencies.runPasswordPrompt = { alert in
            let field = alert.accessoryView as! NSSecureTextField
            passwordField = field
            alert.layout()
            XCTAssertTrue(field.window === alert.window)
            alert.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            alert.window.orderFront(nil)
            XCTAssertTrue(alert.window.makeFirstResponder(field))
            defer { alert.window.orderOut(nil) }
            passwordEditor = try? self.enter("cancelled password", in: field)
            return .alertSecondButtonReturn
        }
        var imports = 0
        host.controller.dependencies.importWallet = { _, _, _ in imports += 1; return Self.wallet }
        _ = try enter("recoverable draft", in: host.controller.textField)
        await expectEventually { host.controller.okButton.isEnabled }

        host.controller.actionButtonTapped(host.controller.okButton as Any)

        XCTAssertEqual(passwordField?.stringValue, "")
        XCTAssertEqual(passwordEditor?.string, "")
        XCTAssertFalse(try XCTUnwrap(passwordEditor).allowsUndo)
        XCTAssertEqual(host.controller.textField.stringValue, "recoverable draft")
        XCTAssertTrue(host.controller.textField.isEnabled)
        XCTAssertEqual(imports, 0)
    }

    func testImportSecretEditingDoesNotCreateUndoOrDeleteUnrelatedTextUndo() throws {
        let host = try ImportHost()
        defer { host.close() }
        let unrelated = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 30))
        unrelated.allowsUndo = true
        host.controller.view.addSubview(unrelated)
        XCTAssertTrue(host.window.makeFirstResponder(unrelated))
        unrelated.insertText("unrelated notes", replacementRange: NSRange(location: 0, length: 0))
        unrelated.breakUndoCoalescing()
        let undo = try XCTUnwrap(unrelated.undoManager)
        XCTAssertTrue(undo === host.window.ownedUndoManager)
        XCTAssertTrue(undo.canUndo)
        let editor = try enter("secret that must not be undoable", in: host.controller.textField)
        XCTAssertFalse(editor.allowsUndo)

        host.controller.cancelButtonTapped(host.controller.cancelButton)

        XCTAssertTrue(host.controller.textField.stringValue.isEmpty)
        XCTAssertTrue(editor.string.isEmpty)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(unrelated.string, "")
        XCTAssertTrue(host.controller.textField.stringValue.isEmpty)
        XCTAssertTrue(editor.string.isEmpty)
    }

    func testLockDuringKeystorePromptClearsBothInputsAndRejectsItsConfirmation() async throws {
        let host = try ImportHost()
        defer { host.close() }
        host.controller.dependencies.validate = { _ in .requiresPassword }
        var imports = 0
        host.controller.dependencies.importWallet = { _, _, _ in imports += 1; return Self.wallet }
        var passwordField: NSSecureTextField?
        var passwordEditor: NSTextView?
        host.controller.dependencies.runPasswordPrompt = { [weak host] alert in
            guard let host else {
                XCTFail("Import host disappeared before its prompt completed")
                return .alertSecondButtonReturn
            }
            let field = alert.accessoryView as! NSSecureTextField
            passwordField = field
            alert.layout()
            XCTAssertTrue(field.window === alert.window)
            alert.window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            alert.window.orderFront(nil)
            XCTAssertTrue(alert.window.makeFirstResponder(field))
            defer { alert.window.orderOut(nil) }
            passwordEditor = try? self.enter("interrupted password", in: field)
            host.fixture.access.lock(reason: .systemSleep)
            XCTAssertTrue(field.stringValue.isEmpty)
            XCTAssertTrue(host.controller.textField.stringValue.isEmpty)
            return .alertFirstButtonReturn
        }
        _ = try enter("interrupted keystore", in: host.controller.textField)
        await expectEventually { host.controller.okButton.isEnabled }

        host.controller.actionButtonTapped(host.controller.okButton as Any)

        XCTAssertEqual(passwordField?.stringValue, "")
        XCTAssertEqual(passwordEditor?.string, "")
        XCTAssertEqual(imports, 0)
        XCTAssertTrue(host.window.contentViewController is WalletLockedViewController)
    }

    func testRetiredPasswordClearsItsRealFieldEditorWithoutUndo() throws {
        var submissions = 0
        let controller = PasswordViewController.with(configuration: .init(mode: .enter)) { _ in submissions += 1 }
        let window = SecretLifetimeWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        let editor = try enter("secret password", in: controller.passwordTextField)
        XCTAssertFalse(editor.allowsUndo)
        XCTAssertFalse(window.ownedUndoManager.canUndo)

        controller.retire()

        XCTAssertTrue(controller.passwordTextField.stringValue.isEmpty)
        XCTAssertTrue(editor.string.isEmpty)
        XCTAssertNil(controller.passwordTextField.currentEditor())
        XCTAssertFalse(window.ownedUndoManager.canUndo)
        controller.passwordTextField.stringValue = "retained password"
        controller.actionButtonTapped(controller.okButton as Any)
        controller.cancelButtonTapped(controller.cancelButton)
        XCTAssertEqual(submissions, 0)
    }

    private func enter(_ text: String, in field: NSTextField) throws -> NSTextView {
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        field.validateEditing()
        XCTAssertEqual(field.stringValue, text)
        return editor
    }

    private enum End { case removal, windowClose, lock }
    private enum ImportFailure: Error { case expected }
    private static var wallet: WalletSnapshot { .init(id: "imported-fixture", isMnemonic: true, accounts: []) }
}

private final class HeldAccountMutation: WalletSourceMutating {
    private let entered: XCTestExpectation
    private let exited: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)
    private let cancelled = Mutex(false)

    init(entered: XCTestExpectation, exited: XCTestExpectation) {
        self.entered = entered
        self.exited = exited
    }

    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func release() { gate.signal() }

    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        let prepared = try preparing()
        entered.fulfill()
        defer { exited.fulfill() }
        guard gate.wait(timeout: .now() + 10) == .success else {
            XCTFail("Account mutation was not released")
            throw CancellationError()
        }
        cancelled.withLock { $0 = Task.isCancelled }
        try beforeCommit()
        return try commit(prepared.payload)
    }
}

@MainActor
private final class ImportHost {
    let fixture = WalletAccessTestFixture()
    let controller: ImportViewController
    let window: SecretLifetimeWindow
    let windowController: WalletWindowController

    init() throws {
        try fixture.unlock()
        controller = instantiate(ImportViewController.self)
        controller.walletAccess = NativeWalletAccess(fixture.access)
        controller.dependencies.validate = { _ in .valid }
        controller.dependencies.importWallet = { _, _, _ in throw CancellationError() }
        window = SecretLifetimeWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windowController = WalletWindowController(window: window)
        windowController.bindAccess(fixture.access, unlock: {})
        window.contentViewController = controller
        window.orderFront(nil)
    }

    func close() {
        window.beforeContentReplacement = nil
        Window.dismissSheets(in: window)
        window.close()
    }
}

@MainActor
private final class SecretLifetimeWindow: NSWindow {
    let ownedUndoManager = UndoManager()
    var beforeContentReplacement: ((NSViewController?) -> Void)?

    override var undoManager: UndoManager? { ownedUndoManager }

    override var contentViewController: NSViewController? {
        willSet { beforeContentReplacement?(newValue) }
    }
}
