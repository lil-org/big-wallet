import WalletDomain
@testable import WalletAuthority
import Security
import Synchronization
import XCTest
#if os(macOS)
import AppKit
#else
import LocalAuthentication
import UIKit
#endif
@testable import Big_Wallet

@MainActor
final class EditAccountsViewControllerTests: XCTestCase {
    func testWalletNotificationsRebaseTheOpenEditorAndStopAfterDeletion() async throws {
        let fixture = try AccountEditorFixture()
        addTeardownBlock { try await fixture.tearDown() }
        await assertWalletReload(fixture.manager)
        let host = try AccountEditorHost(manager: fixture.manager, access: fixture.accessFixture.access)
        defer { host.close() }
        let state = try XCTUnwrap(host.controller.previewState)
        await expectEventually(timeout: 5) { state.accounts.count >= 4 }
        let original = state.wallet.accounts
        let available = state.accounts.filter { !original.map(\.previewAccountKey).contains($0.previewAccountKey) }
        let local = try XCTUnwrap(available.first)
        let external = try XCTUnwrap(available.dropFirst().first)
        let localIndex = try XCTUnwrap(state.accounts.firstIndex { $0.previewAccountKey == local.previewAccountKey })
        state.toggle(at: localIndex)
        let loadedAccounts = state.accounts

        try await fixture.replaceAccounts(original + [external])

        XCTAssertEqual(host.departures, 0)
        XCTAssertEqual(Array(state.accounts.prefix(loadedAccounts.count)), loadedAccounts)
        XCTAssertTrue(state.isEnabled(local))
        XCTAssertTrue(state.isEnabled(external))
        XCTAssertTrue(state.hasChanges)
        XCTAssertTrue(host.controller.okButton.isEnabled)
        XCTAssertEqual(Set(state.enabledAccounts.map(\.previewAccountKey)), Set((original + [local, external]).map(\.previewAccountKey)))

        fixture.reader.attributes = []
        fixture.reader.walletData = [:]
        await assertWalletReload(fixture.manager)
        XCTAssertEqual(host.departures, 1)
        let retiredAccounts = state.wallet.accounts
        try await fixture.replaceAccounts([local])
        XCTAssertEqual(host.departures, 1)
        XCTAssertEqual(state.wallet.accounts, retiredAccounts)
    }

    func testOwnSaveNotificationDoesNotCancelTheSaveOrLeaveTheEditorEarly() async throws {
        weak var observedHost: AccountEditorHost?
        var departuresDuringPublication = [Int]()
        var cancellationDuringPublication = [Bool]()
        let fixture = try AccountEditorFixture {
            NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil)
            departuresDuringPublication.append(observedHost?.departures ?? -1)
            cancellationDuringPublication.append(Task.isCancelled)
        }
        addTeardownBlock { try await fixture.tearDown() }
        await assertWalletReload(fixture.manager)
        let host = try AccountEditorHost(manager: fixture.manager, access: fixture.accessFixture.access)
        observedHost = host
        defer { host.close() }
        let state = try XCTUnwrap(host.controller.previewState)
        await expectEventually(timeout: 5) { state.accounts.count >= 4 }
        let original = state.wallet.accounts
        let added = try XCTUnwrap(state.accounts.first { !state.isEnabled($0) })
        let index = try XCTUnwrap(state.accounts.firstIndex { $0.previewAccountKey == added.previewAccountKey })
        state.toggle(at: index)

        host.controller.okButtonTapped(host.controller.okButton as Any)

        await expectEventually(timeout: 5) { host.departures == 1 }
        XCTAssertEqual(departuresDuringPublication, [0])
        XCTAssertEqual(cancellationDuringPublication, [false])
        try fixture.verifySourceMutation()
        XCTAssertEqual(Set(fixture.manager.wallets[0].accounts.map(\.previewAccountKey)), Set((original + [added]).map(\.previewAccountKey)))
        XCTAssertFalse(state.hasChanges)
        let savedAccounts = state.wallet.accounts
        try await fixture.replaceAccounts(original)
        XCTAssertEqual(host.departures, 1)
        XCTAssertEqual(state.wallet.accounts, savedAccounts)
    }

#if os(iOS) || os(visionOS)
    func testDisplayedThresholdRowCannotCancelPendingPagingActivation() async throws {
        let fixture = try AccountEditorFixture()
        addTeardownBlock { try await fixture.tearDown() }
        await assertWalletReload(fixture.manager)
        let access = fixture.accessFixture
        try access.unlock()
        let waitingForLayout = expectation(description: "Initial paging activation waits for layout")
        let layout = TestGate<Void>()
        let controller = AccountEditorController()
        controller.wallet = try XCTUnwrap(fixture.manager.wallets.first)
        controller.walletsManager = fixture.manager
        controller.access = access.access
        controller.waitForInitialPreviewLayout = {
            waitingForLayout.fulfill()
            await layout.wait()
        }
        controller.loadViewIfNeeded()
        defer {
            layout.resolve(())
            access.access.lock(reason: .background)
        }
        await fulfillment(of: [waitingForLayout], timeout: 5)
        let state = try XCTUnwrap(controller.previewState)
        let initialCount = state.accounts.count
        XCTAssertGreaterThan(initialCount, 0)
        controller.view.frame.size.height = 2_000
        controller.tableView.frame = controller.view.bounds
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        controller.tableView(controller.tableView, willDisplay: UITableViewCell(),
                             forRowAt: IndexPath(row: initialCount - 1, section: 0))
        layout.resolve(())

        await expectEventually(timeout: 5) { state.accounts.count > initialCount }
    }

    func testExternalWalletRemovalDoesNotRenewWalletAccess() async throws {
        let fixture = try AccountEditorFixture()
        addTeardownBlock { try await fixture.tearDown() }
        await assertWalletReload(fixture.manager)
        let access = fixture.accessFixture
        try access.unlock()
        let host = try AccountEditorHost(manager: fixture.manager, access: access.access)
        defer { host.close() }
        access.advance(by: .seconds(60))
        let expirationCount = access.scheduler.expirations.count

        fixture.reader.attributes = []
        fixture.reader.walletData = [:]
        await assertWalletReload(fixture.manager)

        XCTAssertEqual(host.departures, 1)
        XCTAssertEqual(access.scheduler.expirations.count, expirationCount)
    }

    func testWalletDeletionDismissesEditorAndPresentedAlert() async throws {
        let fixture = try AccountEditorFixture()
        addTeardownBlock { try await fixture.tearDown() }
        await assertWalletReload(fixture.manager)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        let controller = instantiate(EditAccountsViewController.self, from: .main)
        controller.access = fixture.accessFixture.access
        controller.wallet = try XCTUnwrap(fixture.manager.wallets.first)
        controller.walletsManager = fixture.manager
        let navigation = controller.inNavigationController
        let editorPresented = expectation(description: "Editor presented")
        presenter.present(navigation, animated: false) { editorPresented.fulfill() }
        await fulfillment(of: [editorPresented], timeout: 3)
        XCTAssertTrue(presenter.presentedViewController === navigation)
        let alert = UIAlertController(title: "Save failed", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let alertPresented = expectation(description: "Error alert presented")
        controller.present(alert, animated: false) { alertPresented.fulfill() }
        await fulfillment(of: [alertPresented], timeout: 3)
        XCTAssertTrue(controller.presentedViewController === alert)

        fixture.reader.attributes = []
        fixture.reader.walletData = [:]
        await assertWalletReload(fixture.manager)

        await expectEventually(timeout: 3) { presenter.presentedViewController == nil }
        XCTAssertNil(navigation.presentingViewController)
        XCTAssertNil(alert.presentingViewController)
    }
#endif
}

@MainActor
private final class AccountEditorFixture {
    private static let walletID = "account-editor"
    let reader: KeychainCopyMatchingStub
    let manager: WalletsManager
    let accessFixture: WalletAccessTestFixture
    private let sourceMutator: AccountEditorSourceMutator
#if os(iOS) || os(visionOS)
    private let vaultHost: SafariApprovalVaultHost
    private let vaultKeys: AccountEditorApprovalKeys
    private let vaultURL: URL
    private let directory: URL
    private let defaultsSuite: String
#endif

    init(postMutation: @escaping @MainActor @Sendable () -> Void = {
        NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil, userInfo: nil)
    }) throws {
        let accessFixture = WalletAccessTestFixture(password: String(decoding: WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword, as: UTF8.self))
        self.accessFixture = accessFixture
        try accessFixture.unlock()
        let reader = KeychainCopyMatchingStub()
        let sourceMutator = AccountEditorSourceMutator()
        self.reader = reader
        self.sourceMutator = sourceMutator
        reader.attributes = [reader.walletAttributes(id: Self.walletID)]
        reader.walletData = [Self.walletID: WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture]
        reader.passwordData = WalletCoreProxyTestVectors.walletCoreJSONMnemonicPassword
#if os(iOS) || os(visionOS)
        let defaultsSuite = "AccountEditorTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(defaultsSuite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vaultURL = directory.appendingPathComponent("approval-vault")
        let keys = AccountEditorApprovalKeys()
        let vaultHost = SafariApprovalVaultHost(
            vault: SafariApprovalVault(fileURL: vaultURL, keyStore: keys),
            defaults: UserDefaultsPreferenceStorage(suiteName: defaultsSuite)!, integrityKeyStore: keys, sourceSnapshot: { nil }
        )
        self.defaultsSuite = defaultsSuite
        self.directory = directory
        self.vaultURL = vaultURL
        self.vaultKeys = keys
        self.vaultHost = vaultHost
#endif
        let keychain = Keychain(copyMatching: reader.copyMatching, add: { _, _ in
            XCTFail("Account editing must not add Keychain items")
            return errSecParam
        }, update: { query, attributes in
            guard let key = (query as NSDictionary)[kSecAttrAccount as String] as? String,
                  key.hasPrefix("org.lil.wallet.wallet."),
                  let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
            reader.walletData[String(key.dropFirst("org.lil.wallet.wallet.".count))] = data
            return errSecSuccess
        }, delete: { _ in
            XCTFail("Account editing must not delete Keychain items")
            return errSecParam
        })
        manager = WalletsManager(
            keychain: keychain,
            walletSourceMutator: sourceMutator,
            notifications: WalletStoreChangeNotifications(
                postLocalChange: { NotificationCenter.default.post(name: Notification.Name("walletsChanged"), object: nil) },
                postMutation: postMutation,
                startObserving: { _, _ in }, stopObserving: { _ in }, isExternalChange: { _ in false }
            ),
            metadataMutations: .init(removeWallet: { _ in }, removeAccounts: { _, _ in }),
            authorityID: accessFixture.authorityID
        )
#if os(iOS) || os(visionOS)
        manager.approvalVaultHost = vaultHost
#endif
    }

    func verifySourceMutation() throws {
        XCTAssertEqual(sourceMutator.calls, 1)
#if os(iOS) || os(visionOS)
        XCTAssertEqual(vaultKeys.removalCount, 1)
        XCTAssertEqual(try Data(contentsOf: vaultURL), Data())
#endif
    }

    func tearDown() async throws {
#if os(iOS) || os(visionOS)
        await vaultHost.waitForReconciliation()
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.removeItem(at: directory)
#endif
    }

    func replaceAccounts(_ accounts: [WalletAccount]) async throws {
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: WalletCoreProxyTestVectors.walletCoreJSONMnemonicFixture))
        let existing = WalletSnapshot(WalletContainer(id: Self.walletID, key: key))
        for account in existing.accounts {
            key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        for account in accounts {
            key.addAccountDerivation(address: account.address, coin: account.coin,
                derivation: account.derivation, derivationPath: account.derivationPath,
                publicKey: account.publicKey, extendedPublicKey: account.extendedPublicKey)
        }
        reader.attributes = [reader.walletAttributes(id: Self.walletID)]
        reader.walletData = [Self.walletID: try XCTUnwrap(key.exportJSON())]
        await assertWalletReload(manager)
    }
}

private final class AccountEditorSourceMutator: WalletSourceMutating {
    private let mutations = Mutex(0)
    var calls: Int { mutations.withLock { $0 } }

    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        let prepared = try preparing()
        try beforeCommit()
        mutations.withLock { $0 += 1 }
        return try commit(prepared.payload)
    }
}

#if os(iOS) || os(visionOS)
private final class AccountEditorApprovalKeys: SafariApprovalKeyStoring, SafariApprovalIntegrityKeyStoring {
    private struct State {
        var keys = [SafariApprovalKeyIdentity: Data]()
        var removals = 0
    }
    private let state = Mutex(State())

    var removalCount: Int { state.withLock { $0.removals } }

    func store(_ key: SecretBytes, identity: SafariApprovalKeyIdentity) throws {
        let data = try key.withUnsafeBytes { Data($0) }
        state.withLock { $0.keys[identity] = data }
    }

    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> SecretBytes {
        try state.withLock {
            guard let key = $0.keys[identity] else { throw SafariApprovalVault.Error.invalidKey }
            return SecretBytes(copying: key)
        }
    }

    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        state.withLock { state in
            Dictionary(uniqueKeysWithValues: identities.map { ($0, state.keys[$0] == nil ? .missing : .present) })
        }
    }

    func removeAll() throws {
        state.withLock {
            $0.keys.removeAll()
            $0.removals += 1
        }
    }

    func loadOrCreate() throws -> SecretBytes {
        SecretBytes(copying: Data(repeating: 0x47, count: 32))
    }
}
#endif

@MainActor
private final class AccountEditorHost {
#if os(macOS)
    let controller: EditAccountsViewController
    private let window: AccountEditorWindow
    var departures: Int { window.departures }
#else
    let controller = AccountEditorController()
    var departures: Int { controller.dismissals }
#endif

    init(manager: WalletsManager, access: WalletAccessController) throws {
#if os(macOS)
        controller = instantiate(EditAccountsViewController.self)
        window = AccountEditorWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 320, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
#endif
        controller.wallet = try XCTUnwrap(manager.wallets.first)
        controller.walletsManager = manager
#if os(iOS) || os(visionOS)
        controller.access = access
#else
        controller.walletAccess = NativeWalletAccess(access)
#endif
        _ = controller.view
#if os(macOS)
        window.contentViewController = controller
#endif
    }

    func close() {
#if os(macOS)
        if window.contentViewController === controller { controller.cancelButtonTapped(controller.cancelButton as Any) }
        window.contentViewController = nil
        window.close()
#else
        if departures == 0 { _ = controller.perform(NSSelectorFromString("closeEditor")) }
#endif
    }
}

#if os(macOS)
@MainActor
private final class AccountEditorWindow: NSPanel {
    private(set) var departures = 0

    override var contentViewController: NSViewController? {
        didSet {
            if oldValue is EditAccountsViewController, contentViewController !== oldValue { departures += 1 }
        }
    }
}
#else
@MainActor
private final class AccountEditorController: EditAccountsViewController {
    private(set) var dismissals = 0

    override func loadView() {
        view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        let table = UITableView(frame: view.bounds)
        view.addSubview(table)
        tableView = table
        let ok = UIButton(type: .system)
        view.addSubview(ok)
        okButton = ok
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissals += 1
        completion?()
    }
}
#endif
