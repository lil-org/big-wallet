import AppKit
import XCTest
@testable import Big_Wallet

@MainActor
final class AccountsListViewControllerTests: XCTestCase {
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
