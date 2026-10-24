import AppKit
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeAccountSelectionViewControllerTests: XCTestCase {
    func testControllersLoadIndependentInstancesOfTheSharedAccountView() async throws {
        let manager = try await accountSelectionWalletsManager()
        let selection = try accountSelectionController(manager: manager, mode: .selectAccount, selectedAccounts: [])
        let management = managementController(manager: manager)
        XCTAssertFalse(selection.content === management.content)
        XCTAssertFalse(selection.tableView === management.tableView)
        XCTAssertEqual(selection.content.frame.size, management.content.frame.size)
        XCTAssertEqual(selection.content.accountsListBottomConstraint.constant, 62)
        XCTAssertEqual(management.content.accountsListBottomConstraint.constant, 0)
        XCTAssertTrue(selection.tableView(selection.tableView, rowViewForRow: 1) is AccountCellView)
        XCTAssertTrue(management.tableView(management.tableView, rowViewForRow: 1) is AccountCellView)
    }

    func testApprovalPickerBlocksWalletManagementActions() async throws {
        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let manager = try await accountSelectionWalletsManager()
            let wallet = try XCTUnwrap(manager.wallets.first)
            let selected = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])
            let controller = try accountSelectionController(
                manager: manager, mode: mode, selectedAccounts: [selected]
            )
            let window = accountSelectionWindow(controller: controller)
            let windowController = WalletWindowController(window: window)
            windowController.approvalPeer = PeerMeta(title: "wallet.example")
            defer { windowController.close() }
            let table = try XCTUnwrap(controller.tableView)
            let header = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true) as? AccountsHeaderRowView)
            let menu = PopupRecordingMenu()
            header.titleButton.menu = menu
            menu.onPopup = { XCTFail("Approval headers must not open management menus") }
            let originalAccounts = wallet.accounts

            XCTAssertTrue(controller.content.addButton.isHidden)
            XCTAssertNil(controller.tableView.menu)
            XCTAssertNil(controller.tableView.menuSource)
            XCTAssertFalse((controller as AnyObject) is any TableViewMenuSource)
            XCTAssertFalse((controller as AnyObject) is any AccountsHeaderDelegate)
            XCTAssertFalse(header.titleButton.isEnabled)
            XCTAssertNil(header.titleButton.image)
            header.titleButtonTapped(header.titleButton)
            XCTAssertNil(controller.content.addButton.target)
            XCTAssertNil(controller.content.addButton.action)
            for selector in ["didClickCreateAccount", "didClickImportAccount", "didClickRemoveWallet:",
                             "didClickRemoveAccount:", "didClickEditAccountName:", "didClickShowKey:",
                             "didClickShowSpecificPrivateKey:"] {
                XCTAssertFalse(controller.responds(to: NSSelectorFromString(selector)))
            }
            XCTAssertFalse(controller.responds(to: NSSelectorFromString("didClickEditAccountsWithSender:")))
            XCTAssertFalse(controller.responds(to: NSSelectorFromString("didClickEditNameWithSender:")))
            XCTAssertFalse(controller.responds(to: NSSelectorFromString("didClickShowSecretWordsWithSender:")))
            XCTAssertFalse(controller.responds(to: NSSelectorFromString("didClickRemoveWalletWithSender:")))

            XCTAssertTrue(window.contentViewController === controller)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [selected])
            XCTAssertFalse(try XCTUnwrap(controller.accountSelection).hasCompleted)
            await assertWalletReload(manager)
            XCTAssertEqual(manager.currentWallet(id: wallet.id)?.accounts, originalAccounts)
        }
    }

    func testManageWalletsHandoffKeepsApprovalPendingAndFencesLateCallbacks() async throws {
        let controller = try accountSelectionController(
            manager: try await accountSelectionWalletsManager(), mode: .selectAccount,
            selectedAccounts: []
        )
        let window = accountSelectionWindow(controller: controller)
        let windowController = WalletWindowController(window: window)
        windowController.approvalPeer = PeerMeta(title: "wallet.example")
        defer { windowController.close() }
        let session = try XCTUnwrap(controller.accountSelection)
        var launches = 0
        let entered = (1...3).map { expectation(description: "management launch \($0) entered") }
        let replies = (1...3).map { _ in TestGate<Bool>() }
        defer { replies.forEach { $0.resolve(false) } }
        controller.openWalletManagement = {
            let index = launches
            launches += 1
            guard replies.indices.contains(index) else {
                XCTFail("Retired management action launched again")
                return false
            }
            entered[index].fulfill()
            return await replies[index].wait()
        }
        let manageRow = controller.numberOfRows(in: controller.tableView) - 1
        try clickAccountRow(manageRow, in: controller.tableView, window: window)
        _ = controller.perform(NSSelectorFromString("manageWallets"))
        await fulfillment(of: [entered[0]], timeout: 2)
        XCTAssertEqual(launches, 1)
        replies[0].resolve(true)
        await expectEventually { controller.tableView(controller.tableView, rowViewForRow: manageRow)?.alphaValue == 1 }
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertTrue(session.review.isActive)
        XCTAssertFalse(session.hasCompleted)
        XCTAssertNil(window.attachedSheet)

        _ = controller.perform(NSSelectorFromString("manageWallets"))
        await fulfillment(of: [entered[1]], timeout: 2)
        XCTAssertEqual(launches, 2)
        replies[1].resolve(false)
        await expectEventually { window.attachedSheet != nil }
        let errorSheet = try XCTUnwrap(window.attachedSheet)
        window.endSheet(errorSheet, returnCode: .alertFirstButtonReturn)
        errorSheet.orderOut(nil)
        XCTAssertFalse(session.hasCompleted)

        _ = controller.perform(NSSelectorFromString("manageWallets"))
        await fulfillment(of: [entered[2]], timeout: 2)
        XCTAssertEqual(launches, 3)
        session.review.invalidate()
        replies[2].resolve(false)
        _ = controller.perform(NSSelectorFromString("manageWallets"))
        XCTAssertEqual(launches, 3)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertFalse(session.hasCompleted)
    }

    func testEmptyApprovalShowsRequesterAndSeparateWalletManagement() async throws {
        let reader = KeychainCopyMatchingStub()
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = try accountSelectionController(manager: manager, mode: mode, selectedAccounts: [])
            let window = accountSelectionWindow(controller: controller)
            let windowController = WalletWindowController(window: window)
            windowController.approvalPeer = PeerMeta(title: "wallet.example")
            defer { windowController.close() }
            controller.viewDidAppear()
            var launches = 0
            controller.openWalletManagement = { launches += 1; return true }
            XCTAssertFalse(controller.content.websiteNameStackView.isHidden)
            XCTAssertEqual(controller.content.websiteNameLabel.stringValue, "wallet.example")
            XCTAssertEqual(controller.content.websiteNameStackView.arrangedSubviews.count, 1)
            XCTAssertTrue(controller.content.websiteNameStackView.arrangedSubviews.first === controller.content.websiteNameLabel)
            XCTAssertEqual(controller.titleLabel.stringValue,
                           (mode == .selectAccount ? Strings.selectAccount : Strings.switchAccount)
                            .replacingOccurrences(of: " ", with: "\n"))
            XCTAssertFalse(controller.primaryButton.isEnabled)
            XCTAssertTrue(controller.content.addButton.isHidden)
            XCTAssertEqual(controller.numberOfRows(in: controller.tableView), 2)
            let guidance = try XCTUnwrap(controller.tableView(controller.tableView, rowViewForRow: 0))
            XCTAssertTrue(guidance.subviews.contains {
                ($0 as? NSTextField)?.stringValue == Strings.manageWalletsToConnect
            })
            XCTAssertFalse(controller.tableView(controller.tableView, shouldSelectRow: 0))
            XCTAssertTrue(window.makeFirstResponder(controller.tableView))
            try pressDownArrow(in: controller.tableView, window: window)
            XCTAssertEqual(controller.tableView.selectedRow, 1)
            try pressKey(" ", keyCode: 49, in: controller.tableView, window: window)
            await expectEventually { launches == 1 }
            XCTAssertEqual(launches, 1)
            XCTAssertTrue(window.contentViewController === controller)
            XCTAssertFalse(try XCTUnwrap(controller.accountSelection).hasCompleted)
        }
    }

    func testApprovalPickerRefreshPreservesOnlyExistingSelectionsWithoutSubmitting() async throws {
        typealias Vectors = WalletCoreProxyTestVectors
        let reader = KeychainCopyMatchingStub()
        let walletID = "selection-wallet"
        reader.attributes = [reader.walletAttributes(id: walletID)]
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))
        reader.walletData[walletID] = try XCTUnwrap(key.exportJSON())
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        await assertWalletReload(manager)
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let selected = SpecificWalletAccount(walletId: walletID, account: account)
        var submissions = 0
        let controller = try accountSelectionController(
            manager: manager, mode: .selectAccount, selectedAccounts: [selected],
            completion: { _, _ in submissions += 1 }
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let initialRows = controller.numberOfRows(in: controller.tableView)
        key.addAccountDerivation(
            address: Vectors.abandonEthereumSecondAddress, coin: .ethereum, derivation: .custom,
            derivationPath: "m/44'/60'/0'/0/1", publicKey: Vectors.abandonEthereumSecondPublicKey,
            extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey
        )
        reader.walletData[walletID] = try XCTUnwrap(key.exportJSON())
        await manager.handleExternalWalletStoreChange()
        XCTAssertEqual(controller.numberOfRows(in: controller.tableView), initialRows + 1)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [selected])
        XCTAssertTrue(controller.primaryButton.isEnabled)
        XCTAssertEqual(submissions, 0)

        key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        reader.walletData[walletID] = try XCTUnwrap(key.exportJSON())
        await manager.handleExternalWalletStoreChange()
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertEqual(submissions, 0)
    }

    func testSelectionSubmissionKeepsReviewAliveAndFencesReentrantSubmission() async throws {
        let lifetime = try nativeReviewForTesting()
        var completions = 0
        let session = NativeAccountSelectionSession(
            action: .init(coinType: nil, selectedAccounts: [],
                          initiallyConnectedProviders: [], network: nil),
            mode: .selectAccount, review: lifetime
        ) { _, _ in completions += 1 }

        session.complete(accounts: []) {
            XCTAssertTrue(session.hasCompleted)
            XCTAssertTrue(lifetime.isActive)
            session.complete(accounts: nil)
        }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(lifetime.isActive)
        lifetime.invalidate()
        session.complete(accounts: nil)
        XCTAssertEqual(completions, 1)
    }

    func testSwitchAccountHeaderDoesNotDependOnConnectedProviders() async throws {
        let action = SelectAccountAction(
            coinType: nil,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: nil
        )
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .switchAccount,
            review: try nativeReviewForTesting(),
            completion: { _, _ in }
        )

        let controller = NativeAccountSelectionViewController(accountSelection: session)
        _ = controller.view
        XCTAssertEqual(controller.titleLabel.stringValue, Strings.switchAccount.replacingOccurrences(of: " ", with: "\n"))
    }

    func testAccountSelectionCompletionUsesSessionNetwork() async throws {
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum
        )
        let changedNetwork = try XCTUnwrap(Networks.withChainId(10))
        var completedNetwork: EthereumNetwork?
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            review: try nativeReviewForTesting(),
            completion: { _, network in completedNetwork = network }
        )
        session.network = changedNetwork

        session.complete(accounts: [])

        XCTAssertEqual(completedNetwork, changedNetwork)
    }

    func testAccountSelectionUsesCompactNetworkButtonWithAccessibleIdentity() async throws {
        let template = try XCTUnwrap(Networks.withChainId(58_008))
        let network = EthereumNetwork(
            chainId: template.chainId,
            name: "Public Goods Network Sepolia With A Very Long Custom Name",
            symbol: template.symbol,
            rpcEndpoint: template.rpcEndpoint,
            isTestnet: template.isTestnet,
            mightShowPrice: template.mightShowPrice,
            explorer: template.explorer
        )
        let identity = "\(network.chainIdHexString) · \(network.name)"
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: network
        )
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            review: try nativeReviewForTesting(),
            completion: { _, _ in }
        )
        let controller = NativeAccountSelectionViewController(accountSelection: session)
        _ = controller.view
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.networkButton.title.isEmpty)
        XCTAssertEqual(controller.networkButton.imagePosition, .imageOnly)
        XCTAssertNotNil(controller.networkButton.image)
        XCTAssertEqual(controller.networkButton.toolTip, identity)
        XCTAssertEqual(
            controller.networkButton.accessibilityValue() as? String,
            identity
        )
        XCTAssertTrue(
            controller.content.bottomButtonsStackView.arrangedSubviews.contains(
                controller.networkButton
            )
        )
        XCTAssertEqual(controller.networkButton.frame.width, 32)
        XCTAssertEqual(controller.content.accountsListBottomConstraint.constant, 62)
    }

    func testAccountSelectionSubmissionImmediatelyFencesControls() async throws {
        let action = SelectAccountAction(
            coinType: .ethereum,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: Networks.ethereum
        )
        var completionCount = 0
        let session = NativeAccountSelectionSession(
            action: action,
            mode: .selectAccount,
            review: try nativeReviewForTesting(),
            completion: { _, _ in completionCount += 1 }
        )
        let controller = NativeAccountSelectionViewController(accountSelection: session)
        _ = controller.view

        controller.didClickSecondaryButton(controller.secondaryButton as Any)
        controller.didClickPrimaryButton(controller.primaryButton as Any)

        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(controller.content.addButton.isEnabled)
        XCTAssertFalse(controller.networkButton.isEnabled)
        XCTAssertFalse(controller.primaryButton.isEnabled)
        XCTAssertFalse(controller.secondaryButton.isEnabled)
        XCTAssertFalse(controller.tableView.isEnabled)
    }

    func testAccountSelectionQueriesDoNotChangeSelectedAccounts() async throws {
        let manager = try await accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let original = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])

        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = try accountSelectionController(
                manager: manager,
                mode: mode,
                selectedAccounts: [original]
            )

            for _ in 0..<3 {
                XCTAssertFalse(controller.tableView(controller.tableView, shouldSelectRow: 2))
                XCTAssertEqual(controller.accountSelection.selectedAccounts, [original])
            }
        }
    }

    func testAccountSelectionClickSwitchesAndDeselectsOncePreservingOtherCoin() async throws {
        let manager = try await accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let accounts = wallet.accounts.map {
            SpecificWalletAccount(walletId: wallet.id, account: $0)
        }

        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = try accountSelectionController(
                manager: manager,
                mode: mode,
                selectedAccounts: [accounts[0], accounts[2]]
            )
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }

            try clickAccountRow(2, in: controller.tableView, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[1], accounts[2]])

            try clickAccountRow(2, in: controller.tableView, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[2]])

            try clickAccountRow(1, in: controller.tableView, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[0], accounts[2]])
            XCTAssertTrue(controller.primaryButton.isEnabled)
        }
    }

    func testAccountPickerKeyboardNavigatesAndActivatesWithoutSubmitting() async throws {
        let manager = try await accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let accounts = wallet.accounts.map {
            SpecificWalletAccount(walletId: wallet.id, account: $0)
        }
        for mode in [NativeAccountSelectionMode.selectAccount, .switchAccount] {
            let controller = try accountSelectionController(manager: manager, mode: mode, selectedAccounts: [])
            let window = accountSelectionWindow(controller: controller)
            defer { window.close() }
            let table = try XCTUnwrap(controller.tableView)
            XCTAssertTrue(window.makeFirstResponder(table))
            XCTAssertFalse(controller.primaryButton.isEnabled)

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 1)
            let focusedRow = try XCTUnwrap(table.rowView(atRow: 1, makeIfNecessary: true))
            XCTAssertEqual(focusedRow.interiorBackgroundStyle, .normal)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[0]])
            XCTAssertTrue(controller.primaryButton.isEnabled)

            try pressDownArrow(in: table, window: window)
            XCTAssertEqual(table.selectedRow, 2)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[0]])
            try pressKey("\r", keyCode: 36, in: table, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[1]])
            XCTAssertTrue(table.isEnabled)

            try pressDownArrow(in: table, window: window)
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[1], accounts[2]])
            try pressKey(" ", keyCode: 49, in: table, window: window, isRepeat: true)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[1], accounts[2]])
            try pressKey(" ", keyCode: 49, in: table, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [accounts[1]])

            try pressKey("\u{f700}", keyCode: 126, in: table, window: window)
            XCTAssertEqual(table.selectedRow, 2)
            try pressKey("\u{3}", keyCode: 76, in: table, window: window)
            XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
            XCTAssertFalse(controller.primaryButton.isEnabled)
        }
    }

    func testAccountPickerKeyboardSkipsDisabledCoinsAndFollowsMouseFocus() async throws {
        let manager = try await accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let account = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])
        let controller = try accountSelectionController(
            manager: manager,
            mode: .selectAccount,
            selectedAccounts: [account],
            coinType: .ethereum
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertEqual(table.selectedRow, 1)

        try pressDownArrow(in: table, window: window)
        try pressDownArrow(in: table, window: window)
        XCTAssertEqual(table.selectedRow, controller.numberOfRows(in: table) - 1)
        try pressKey("\u{f700}", keyCode: 126, in: table, window: window)
        XCTAssertEqual(table.selectedRow, 2)
        try pressKey(" ", keyCode: 49, in: table, window: window)
        try clickAccountRow(1, in: controller.tableView, window: window, targetWindowOnly: true)
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [account])
        try pressKey(" ", keyCode: 49, in: table, window: window)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
        XCTAssertFalse(controller.primaryButton.isEnabled)

        controller.accountSelection.review.invalidate()
        try pressKey(" ", keyCode: 49, in: table, window: window)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
    }

    func testAccountSelectionClickIgnoresOtherCoinAndCanClearSelection() async throws {
        let manager = try await accountSelectionWalletsManager()
        let wallet = try XCTUnwrap(manager.wallets.first)
        let original = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[0])
        let replacement = SpecificWalletAccount(walletId: wallet.id, account: wallet.accounts[1])
        let controller = try accountSelectionController(
            manager: manager,
            mode: .selectAccount,
            selectedAccounts: [original],
            coinType: .ethereum
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }

        try clickAccountRow(3, in: controller.tableView, window: window)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [original])

        try clickAccountRow(2, in: controller.tableView, window: window)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [replacement])
        XCTAssertTrue(controller.primaryButton.isEnabled)

        try clickAccountRow(2, in: controller.tableView, window: window)
        XCTAssertEqual(controller.accountSelection.selectedAccounts, [])
        XCTAssertFalse(controller.primaryButton.isEnabled)
    }

    func testAccountSelectionTeardownFencesNavigationAndClosesItsSheet() async throws {
        let controller = try accountSelectionController(
            manager: try await accountSelectionWalletsManager(), mode: .selectAccount, selectedAccounts: []
        )
        let window = accountSelectionWindow(controller: controller)
        defer { window.close() }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet) { _ in }
        controller.accountSelection.review.invalidate()
        controller.accountSelection.review.invalidate()
        XCTAssertFalse(controller.responds(to: NSSelectorFromString("didClickImportAccount")))
        XCTAssertNil(controller.tableView.menu)
        XCTAssertNil(controller.tableView.menuSource)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.contentViewController === controller)
    }
}
