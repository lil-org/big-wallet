import WalletDomain
@testable import WalletAuthority
import AppKit
import Security
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class AccountsListViewControllerTests: XCTestCase {
    func testPendingAuthenticationSurvivesSuccessfulForegroundReload() async throws {
        for operation in WalletOperationRecoveryHost.Operation.allCases {
            let host = try await WalletOperationRecoveryHost()
            defer { host.close() }
            try await host.begin(operation)
            host.inventory.holdNextRead()
            let reload = Task { await host.manager.reloadFromStore() }
            defer { reload.cancel(); host.inventory.release() }
            await fulfillment(of: [host.inventory.entered], timeout: 3)
            XCTAssertEqual(host.manager.loadState, .loading)
            XCTAssertEqual(host.authentication.cancellations, 0)

            host.inventory.release()
            let loaded = await reload.value
            XCTAssertTrue(loaded)
            XCTAssertEqual(host.authentication.cancellations, 0)
            host.authentication.complete()

            await expectEventually(timeout: 5) { host.didPerform(operation) }
            XCTAssertEqual(host.authentication.cancellations, 0)
        }
    }

    func testSuccessfulAuthenticationWaitsForTheForegroundReloadBeforeExportOrDelete() async throws {
        for operation in WalletOperationRecoveryHost.Operation.allCases {
            let host = try await WalletOperationRecoveryHost()
            defer { host.close() }
            try await host.begin(operation)
            host.inventory.holdNextRead()
            let reload = Task { await host.manager.reloadFromStore() }
            defer { reload.cancel(); host.inventory.release() }
            await fulfillment(of: [host.inventory.entered], timeout: 3)

            host.authentication.complete()
            await fulfillment(of: [host.authentication.returned], timeout: 3)
            for _ in 0..<3 { await Task.yield() }
            XCTAssertEqual(host.manager.loadState, .loading)
            XCTAssertFalse(host.didPerform(operation))
            XCTAssertEqual(host.authentication.cancellations, 0)

            host.inventory.release()
            let loaded = await reload.value
            XCTAssertTrue(loaded)
            await expectEventually(timeout: 5) { host.didPerform(operation) }
            XCTAssertEqual(host.authentication.cancellations, 0)
        }
    }

    func testFailedForegroundReloadOrLockRetiresAuthenticationWithoutExportOrDelete() async throws {
        for operation in WalletOperationRecoveryHost.Operation.allCases {
            for lock in [false, true] {
                let host = try await WalletOperationRecoveryHost()
                defer { host.close() }
                try await host.begin(operation)
                host.inventory.holdNextRead()
                if !lock { host.reader.attributesStatus = errSecInteractionNotAllowed }
                let reload = Task { await host.manager.reloadFromStore() }
                defer { reload.cancel(); host.inventory.release() }
                await fulfillment(of: [host.inventory.entered], timeout: 3)
                if lock { host.access.access.lock(reason: .systemSleep) }
                else { host.inventory.release() }
                await fulfillment(of: [host.authentication.cancelled], timeout: 3)
                host.authentication.complete()
                await fulfillment(of: [host.authentication.returned], timeout: 3)
                host.inventory.release()
                _ = await reload.value
                host.reader.attributesStatus = errSecSuccess
                await assertWalletReload(host.manager)

                XCTAssertEqual(host.authentication.cancellations, 1)
                XCTAssertFalse(host.didPerform(operation))
                XCTAssertEqual(host.manager.wallets.count, 1)
            }
        }
    }

    func testInitialReadFailureOffersRetryBeforeEmptyWalletActions() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributesStatus = errSecInteractionNotAllowed
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager, succeeds: false)
        let controller = managementController(manager: manager)
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }

        XCTAssertEqual(controller.tableView.numberOfRows, 0)
        XCTAssertFalse(controller.content.loadStatusView?.isHidden ?? true)
        XCTAssertTrue(controller.content.loadRetryButton?.isEnabled == true)
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))
        XCTAssertTrue(window.contentViewController === controller)

        reader.attributesStatus = errSecSuccess
        controller.content.loadRetryButton?.performClick(nil)
        await expectEventually { manager.isStoreReady && controller.tableView.numberOfRows == 2 }

        XCTAssertTrue(controller.content.loadStatusView?.isHidden == true)
        XCTAssertEqual(controller.tableView.numberOfRows, 2)
    }

    func testFailedRefreshPreservesCachedRowsAndAllowsOnlyPublicAccountActions() async throws {
        let reader = KeychainCopyMatchingStub()
        let data = WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture
        let ids = (0..<12).map { "cached-wallet-\($0)" }
        reader.attributes = ids.map { reader.walletAttributes(id: $0) }
        reader.walletData = Dictionary(uniqueKeysWithValues: ids.map { ($0, data) })
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let controller = managementController(manager: manager)
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let rows = controller.tableView.numberOfRows
        controller.tableView.scrollRowToVisible(rows - 1)
        let origin = controller.tableView.enclosingScrollView?.contentView.bounds.origin

        reader.attributesStatus = errSecInteractionNotAllowed
        await assertWalletReload(manager, succeeds: false)

        XCTAssertEqual(controller.tableView.numberOfRows, rows)
        XCTAssertEqual(controller.tableView.enclosingScrollView?.contentView.bounds.origin, origin)
        XCTAssertFalse(controller.content.addButton.isEnabled)
        XCTAssertTrue(controller.content.loadRetryButton?.isEnabled == true)
        let menu = try XCTUnwrap(controller.menuForRow(1))
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("didClickCopyAddress:") }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("didClickShowKey:") }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("didClickEditAccountName:") }).isEnabled)

        reader.attributesStatus = errSecSuccess
        controller.content.loadRetryButton?.performClick(nil)
        await expectEventually { manager.isStoreReady && controller.content.addButton.isEnabled }
        XCTAssertEqual(controller.tableView.numberOfRows, rows)
        XCTAssertTrue(controller.content.loadStatusView?.isHidden == true)
    }

    func testRetiredWalletListDoesNotResumeLoadingOrPublishRows() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributesStatus = errSecInteractionNotAllowed
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager, succeeds: false)
        let controller = managementController(manager: manager)
        controller.retireForWalletLock()
        reader.attributesStatus = errSecSuccess
        controller.content.loadRetryButton?.performClick(nil)
        await Task.yield()
        XCTAssertEqual(manager.loadState, .failed(.unavailable))
        await assertWalletReload(manager)
        XCTAssertEqual(controller.tableView.numberOfRows, 0)
    }

    func testOrdinaryWalletCloseStillFencesRetainedActions() async throws {
        let controller = managementController(manager: try await accountSelectionWalletsManager())
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let menu = TrackingMenu()
        controller.content.addButton.menu = menu

        window.close()
        window.close()
        _ = controller.perform(NSSelectorFromString("didClickImportAccount"))

        XCTAssertFalse(controller is any NativeApprovalReviewTeardown)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertEqual(menu.cancellationCount, 1)
    }

    func testWalletListHidesApprovalControls() async {
        let controller = AccountsListViewController()
        _ = controller.view

        XCTAssertTrue(controller.content.bottomButtonsStackView.isHidden)
        XCTAssertTrue(controller.content.networkButton.isHidden)
        XCTAssertEqual(controller.content.accountsListBottomConstraint.constant, 0)
    }

    func testWalletListKeyboardSelectionOpensMenuAndAllowsNextClick() async throws {
        let controller = AccountsListViewController()
        controller.walletsManager = try await accountSelectionWalletsManager()
        _ = controller.view
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu
        let opened = [
            expectation(description: "initial click menu"),
            expectation(description: "keyboard menu"),
            expectation(description: "subsequent click menu")
        ]
        var rows = [Int]()
        menu.onPopup = { [weak table] in
            rows.append(table?.selectedRow ?? -1)
            if rows.count <= opened.count {
                opened[rows.count - 1].fulfill()
            }
        }

        try clickAccountRow(2, in: controller.tableView, window: window)
        await fulfillment(of: [opened[0]], timeout: 1)
        try pressDownArrow(in: table, window: window)
        await fulfillment(of: [opened[1]], timeout: 1)
        XCTAssertEqual(table.selectedRow, -1)

        try clickAccountRow(3, in: controller.tableView, window: window)
        await fulfillment(of: [opened[2]], timeout: 1)
        XCTAssertEqual(rows, [2, 1, 3])
        XCTAssertEqual(table.selectedRow, -1)
    }

    func testWalletListPendingMenuDoesNotOpenAfterSelectionClears() async throws {
        let controller = AccountsListViewController()
        controller.walletsManager = try await accountSelectionWalletsManager()
        _ = controller.view
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu
        let opened = expectation(description: "cancelled menu stays closed")
        opened.isInverted = true
        menu.onPopup = { opened.fulfill() }

        try pressDownArrow(in: table, window: window)
        XCTAssertEqual(table.selectedRow, 1)
        table.deselectAll(nil)

        await fulfillment(of: [opened], timeout: 0.1)
        XCTAssertEqual(table.selectedRow, -1)
    }

    func testEmptyWalletOptionsSupportKeyboardAndMouseImport() async throws {
        let reader = KeychainCopyMatchingStub()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        for useKeyboard in [true, false] {
            let controller = managementController(manager: manager)
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }
            let table = try XCTUnwrap(controller.tableView)
            XCTAssertTrue(window.makeFirstResponder(table))

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 0)
            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 1)
            try pressKey("\u{f700}", keyCode: 126, in: table, window: window)
            XCTAssertEqual(table.selectedRow, 0)
            XCTAssertTrue(window.contentViewController === controller)
            XCTAssertNil(window.attachedSheet)

            if useKeyboard {
                try pressDownArrow(in: table, window: window)
                try pressKey(" ", keyCode: 49, in: table, window: window)
            } else {
                try clickAccountRow(1, in: controller.tableView, window: window)
            }
            XCTAssertTrue(window.contentViewController is ImportViewController)
            XCTAssertTrue(manager.wallets.isEmpty)
        }
    }

    func testEmptyWalletCreateCanBeActivatedWithReturn() async throws {
        let reader = KeychainCopyMatchingStub()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let controller = managementController(manager: manager)
        let window = accountSelectionWindow(controller: controller)
        let windowController = WalletWindowController(window: window)
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        defer { windowController.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))

        try pressDownArrow(in: table, window: window)
        try pressKey("\r", keyCode: 36, in: table, window: window)
        XCTAssertEqual(table.selectedRow, -1)
        let confirmation = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(manager.wallets.isEmpty)
        window.endSheet(confirmation, returnCode: .alertSecondButtonReturn)
        confirmation.orderOut(nil)
    }

    func testWalletListCancelledDragClearsSelectionAndAllowsNextClick() async throws {
        let controller = AccountsListViewController()
        controller.walletsManager = try await accountSelectionWalletsManager()
        _ = controller.view
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        let menu = PopupRecordingMenu()
        menu.delegate = controller
        table.menu = menu

        for (destination, nextRow) in [(2, 3), (0, 2)] {
            let opened = expectation(description: "menu after cancelled drag to row \(destination)")
            var rows = [Int]()
            menu.onPopup = { [weak table] in
                rows.append(table?.selectedRow ?? -1)
                opened.fulfill()
            }

            try clickAccountRow(1, endingAt: destination, in: controller.tableView, window: window)
            XCTAssertEqual(table.selectedRow, -1)
            XCTAssertTrue(rows.isEmpty)

            try clickAccountRow(nextRow, in: controller.tableView, window: window)
            await fulfillment(of: [opened], timeout: 1)
            XCTAssertEqual(rows, [nextRow])
            XCTAssertEqual(table.selectedRow, -1)
        }
    }

    func testAccountHeaderTeardownCancelsItsMenu() async {
        let row = AccountsHeaderRowView()
        let button = NSButton()
        row.titleButton = button
        let menu = TrackingMenu()
        button.menu = menu

        row.cancelMenuTracking()

        XCTAssertEqual(menu.cancellationCount, 1)
    }

}

@MainActor
private final class WalletOperationRecoveryHost {
    enum Operation: CaseIterable { case export, delete }

    let access: WalletAccessTestFixture
    let reader = KeychainCopyMatchingStub()
    let inventory = HeldWalletInventory()
    let authentication = HeldWalletAuthentication()
    let manager: WalletsManager
    let controller = AccountsListViewController()
    let window: NSWindow
    private let windowController: WalletWindowController
    private let deletionCount: RecoveryDeletionCount
    private let previousActivationPolicy: NSApplication.ActivationPolicy
    private let walletID = "foreground-authentication"

    init() async throws {
        let access = WalletAccessTestFixture(password: String(decoding: WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword, as: UTF8.self))
        self.access = access
        try access.unlock()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture]
        reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
        let reader = reader
        let inventory = inventory
        let deletionCount = RecoveryDeletionCount()
        self.deletionCount = deletionCount
        let walletID = walletID
        let keychain = Keychain(copyMatching: { query, result in
            if (query as NSDictionary)[kSecReturnAttributes as String] as? Bool == true {
                inventory.waitIfHeld()
            }
            return reader.copyMatching(query, result)
        }, delete: { query in
            guard (query as NSDictionary)[kSecAttrAccount as String] as? String == "org.lil.wallet.wallet.\(walletID)" else {
                return errSecParam
            }
            deletionCount.increment()
            reader.attributes = []
            reader.walletData = [:]
            return errSecSuccess
        })
        manager = WalletsManager(keychain: keychain, walletSourceMutator: RecoveryWalletSourceMutator(),
            notifications: .init(
                postLocalChange: { NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil) },
                postMutation: { NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil) },
                startObserving: { _, _ in }, stopObserving: { _ in }, isExternalChange: { _ in false }
            ), authorityID: access.authorityID)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windowController = WalletWindowController(window: window)
        previousActivationPolicy = NSApp.activationPolicy()
        await assertWalletReload(manager)
        controller.walletsManager = manager
        controller.walletAccess = NativeWalletAccess(access.access)
        controller.authenticate = { [authentication] _, _, challenge in await authentication.run(challenge) }
        windowController.bindAccess(access.access, unlock: {})
        window.contentViewController = controller
        do { try await activate() }
        catch { close(); throw error }
    }

    func begin(_ operation: Operation) async throws {
        controller.tableView.deselectedRow = 1
        let selector = operation == .export ? "didClickShowKey:" : "didClickRemoveWallet:"
        let acceptWarning = Timer(timeInterval: 0.05, repeats: false) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let warning = NSApp.modalWindow else {
                    XCTFail("Expected the wallet warning modal")
                    NSApp.abortModal()
                    return
                }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                warning.orderOut(nil)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        RunLoop.main.add(acceptWarning, forMode: .modalPanel)
        defer { acceptWarning.invalidate() }
        _ = controller.perform(NSSelectorFromString(selector), with: NSMenuItem())
        let entered = await XCTWaiter.fulfillment(of: [authentication.entered], timeout: 3)
        XCTAssertEqual(entered, .completed)
    }

    func didPerform(_ operation: Operation) -> Bool {
        switch operation {
        case .delete: return deletionCount.value > 0
        case .export:
            guard let sheet = window.attachedSheet, let content = sheet.contentView else { return false }
            return containsMnemonic(content)
        }
    }

    private func containsMnemonic(_ view: NSView) -> Bool {
        if (view as? NSTextField)?.stringValue == WalletCoreProxyTestVectors.walletCoreJSONMnemonic { return true }
        return view.subviews.contains(where: containsMnemonic)
    }

    func close() {
        inventory.release()
        authentication.complete()
        Window.dismissSheets(in: window)
        windowController.close()
        _ = NSApp.setActivationPolicy(previousActivationPolicy)
    }

    private func activate() async throws {
        guard NSApp.activationPolicy() == .regular || NSApp.setActivationPolicy(.regular) else {
            throw RecoveryFocusFailure.unavailable
        }
        window.center()
        NSApp.unhide(nil)
        if !NSApp.isActive {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.addsToRecentItems = false
            configuration.promptsUserIfNeeded = false
            let activatedPID: Int32 = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
                    if let application { continuation.resume(returning: application.processIdentifier) }
                    else { continuation.resume(throwing: error ?? RecoveryFocusFailure.unavailable) }
                }
            }
            guard activatedPID == ProcessInfo.processInfo.processIdentifier else {
                throw RecoveryFocusFailure.unavailable
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            Window.activateWindow(window)
            if NSApp.isActive, window.isKeyWindow, NSApp.keyWindow === window { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RecoveryFocusFailure.unavailable
    }
}

private enum RecoveryFocusFailure: Error { case unavailable }

private final class HeldWalletInventory: Sendable {
    let entered = XCTestExpectation(description: "foreground inventory read held")
    private let armed = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)

    func holdNextRead() { armed.withLock { $0 = true } }
    func release() { gate.signal() }

    func waitIfHeld() {
        guard armed.withLock({ value in defer { value = false }; return value }) else { return }
        entered.fulfill()
        XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
    }
}

private final class HeldWalletAuthentication: Sendable {
    let entered = XCTestExpectation(description: "wallet authentication pending")
    let returned = XCTestExpectation(description: "wallet authentication returned")
    let cancelled = XCTestExpectation(description: "wallet authentication cancelled")
    private let gate = TestGate<Void>()
    private let cancellationCount = Mutex(0)

    var cancellations: Int { cancellationCount.withLock { $0 } }

    func complete() { gate.resolve(()) }

    func run(_ challenge: WalletAuthenticationChallenge) async -> WalletAuthenticationGrant? {
        await withTaskCancellationHandler {
            entered.fulfill()
            await gate.wait()
            let grant = Task.isCancelled ? nil : challenge.issueGrant(for: challenge.authorityID,
                credentialIdentity: .init(status: { .current }))
            returned.fulfill()
            return grant
        } onCancel: {
            challenge.invalidate()
            cancellationCount.withLock { $0 += 1 }
            cancelled.fulfill()
        }
    }
}

private struct RecoveryWalletSourceMutator: WalletSourceMutating {
    func perform<Payload, Result>(preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void, commit: (Payload) throws -> Result) throws -> Result {
        let prepared = try preparing()
        try beforeCommit()
        return try commit(prepared.payload)
    }
}

private final class RecoveryDeletionCount: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
