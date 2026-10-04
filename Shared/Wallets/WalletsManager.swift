// ∅ 2026 lil org

import Foundation

struct WalletStoreSync {

#if os(macOS)
    private static let senderProcessId = String(ProcessInfo.processInfo.processIdentifier)
#endif

    static func postLocalChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .walletsChanged, object: nil)
        } else {
            Task { @MainActor in
                NotificationCenter.default.post(name: .walletsChanged, object: nil)
            }
        }
    }

    static func postLocalAndExternalChange(defaultsAlreadySynchronized: Bool = false) {
        if !defaultsAlreadySynchronized {
            Defaults.synchronize()
        }
        postLocalChange()
        postExternalChange()
    }

#if os(macOS)
    static func startObserving(_ observer: Any, selector: Selector) {
        DistributedNotificationCenter.default().addObserver(observer,
                                                            selector: selector,
                                                            name: .walletStoreChanged,
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    static func stopObserving(_ observer: Any) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    static func isExternalChange(_ notification: Notification) -> Bool {
        guard let sender = notification.object as? String else { return true }
        return sender != senderProcessId
    }

    private static func postExternalChange() {
        DistributedNotificationCenter.default().post(name: .walletStoreChanged, object: senderProcessId)
    }
#else
    static func startObserving(_: Any, selector _: Selector) {}
    static func stopObserving(_: Any) {}
    static func isExternalChange(_: Notification) -> Bool { false }
    private static func postExternalChange() {}
#endif

}

@MainActor
final class WalletsManager: NSObject {
    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
        case failedToDeriveAccount
    }

    enum InputValidationResult: Sendable {
        case valid, invalid, requiresPassword
    }

    struct PrivateKeyImport: Sendable {
        let privateKey: WalletPrivateKey
        let coin: WalletCoin
    }

    static let shared = WalletsManager()
    nonisolated let repository: WalletRepository
    private let reloadMetadata: @MainActor () -> Void
    private let publishLocalChange: @MainActor () -> Void
    private(set) var wallets = [WalletSnapshot]()
    private var repositoryRevision: UInt64 = 0
    private var isObservingExternalChanges = false
    private var externalReload: Task<Void, Never>?

    private override init() {
        repository = WalletRepository(keychain: .shared)
        reloadMetadata = WalletsMetadataService.reload
        publishLocalChange = WalletStoreSync.postLocalChange
        super.init()
    }

    init(
        keychain: Keychain,
        reloadMetadata: @escaping @MainActor () -> Void = {},
        publishLocalChange: (@MainActor () -> Void)? = nil,
        walletSourceMutator: any WalletSourceMutating = ExtensionBridge.WalletSourceMutator(),
        keyDerivation: WalletRepository.SigningKeyDerivation = .live
    ) {
        repository = WalletRepository(keychain: keychain, walletSourceMutator: walletSourceMutator, keyDerivation: keyDerivation)
        self.reloadMetadata = reloadMetadata
        self.publishLocalChange = publishLocalChange ?? WalletStoreSync.postLocalChange
        super.init()
    }

    isolated deinit {
        externalReload?.cancel()
        WalletStoreSync.stopObserving(self)
    }

    @discardableResult
    func start() async -> Bool {
        startObservingExternalChanges()
        return await reloadFromStore()
    }

    @discardableResult
    func reloadFromStore() async -> Bool {
        do {
            let state = try await repository.reload()
            apply(state)
            return true
        } catch {
            return false
        }
    }

    func reviewCatalog() -> WalletReviewCatalog? {
        guard let data = try? WalletAccountCatalog(snapshots: wallets).canonicalData() else { return nil }
        return WalletReviewCatalog(
            identity: WalletCatalogIdentity(generation: nil, catalogData: data),
            orderedAccounts: wallets.flatMap { wallet in
                wallet.accounts.map { SpecificWalletAccount(walletId: wallet.id, account: $0) }
            }
        )
    }

    func currentWallet(id: String) -> WalletSnapshot? {
        wallets.first { $0.id == id }
    }

#if os(iOS) || os(visionOS)
    nonisolated func safariApprovalSourceSnapshot() async throws -> SafariApprovalSourceSnapshot? {
        try await repository.safariApprovalSourceSnapshot()
    }
#endif

    nonisolated func validateWalletInput(_ input: String) async -> InputValidationResult {
        await WalletKeyPreparation.validateWalletInput(input)
    }

    func createWallet() async throws -> WalletSnapshot {
        let prepared = try await repository.prepareNewWallet(input: nil, inputPassword: nil)
        return try await commit { [repository] willMutate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate)
        }
    }

    func addWallet(input: String, inputPassword: String?) async throws -> WalletSnapshot {
        let prepared = try await repository.prepareNewWallet(input: input, inputPassword: inputPassword)
        return try await commit { [repository] willMutate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate)
        }
    }

    func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount]) async throws {
        _ = try await commit { [repository] willMutate in
            try await repository.update(wallet: wallet, enabledAccounts: enabledAccounts, willMutateSource: willMutate)
        }
    }

    func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount]) async throws {
        _ = try await commit { [repository] willMutate in
            try await repository.update(wallet: wallet, removeAccounts: removeAccounts, willMutateSource: willMutate)
        }
    }

    func delete(wallet: WalletSnapshot) async throws {
        let prepared = try await repository.prepareDeletion(wallet: wallet)
        _ = try await commit { [repository] willMutate in
            try await repository.delete(prepared, willMutateSource: willMutate)
        }
    }

    func exportPrivateKey(wallet: WalletSnapshot, account: WalletAccount? = nil) async throws -> String {
        try await repository.exportPrivateKey(wallet: wallet, account: account)
    }

    func exportMnemonic(wallet: WalletSnapshot) async throws -> String {
        try await repository.exportMnemonic(wallet: wallet)
    }

    nonisolated static func privateKeyImport(from input: String) -> PrivateKeyImport? {
        WalletKeyPreparation.privateKeyImport(from: input)
    }

    nonisolated static func privateKeyExportString(privateKey: WalletPrivateKey, coin: WalletCoin) -> String {
        WalletKeyPreparation.privateKeyExportString(privateKey: privateKey, coin: coin)
    }

    private func commit(
        _ operation: @Sendable (_ willMutateSource: @Sendable () throws -> Void) async throws -> WalletRepository.Change
    ) async throws -> WalletSnapshot {
        let change: WalletRepository.Change
#if os(iOS) || os(visionOS)
        change = try await SafariApprovalVaultHost.shared.performSourceMutation(operation)
#else
        change = try await operation({})
#endif
        apply(change.state)
        WalletStoreSync.postLocalAndExternalChange()
        return change.wallet
    }

    private func apply(_ state: WalletRepository.State) {
        guard state.revision >= repositoryRevision else { return }
        repositoryRevision = state.revision
        wallets = state.wallets
        reloadMetadata()
    }

    private func startObservingExternalChanges() {
        guard !isObservingExternalChanges else { return }
        isObservingExternalChanges = true
        WalletStoreSync.startObserving(self, selector: #selector(externalWalletStoreChanged(_:)))
    }

    @objc nonisolated private func externalWalletStoreChanged(_ notification: Notification) {
        guard WalletStoreSync.isExternalChange(notification) else { return }
        Task { @MainActor [weak self] in self?.scheduleExternalReload() }
    }

    private func scheduleExternalReload() {
        externalReload?.cancel()
        externalReload = Task { [weak self] in
            await self?.handleExternalWalletStoreChange()
        }
    }

    func handleExternalWalletStoreChange() async {
        guard await reloadFromStore() else { return }
        publishLocalChange()
    }

    func previewAccountsPager(wallet: WalletSnapshot) -> PreviewAccountsPager {
        PreviewAccountsPager(wallet: wallet, repository: repository)
    }

    @MainActor
    final class PreviewAccountsPager {
        private static let minimumPreviewInterval = Duration.milliseconds(230)
        private let wallet: WalletSnapshot
        private let repository: WalletRepository
        private var session: WalletPreviewSession?
        private var page = 0
        private var isLoading = false
        private var isPagingEnabled = false
        private var hasLoadedAllPages = false
        private var loadedCount = 0
        private var generation = 0
        private var lastPreview = ContinuousClock.now
        private var cancelWork: (@Sendable () -> Void)?

        fileprivate init(wallet: WalletSnapshot, repository: WalletRepository) {
            self.wallet = wallet
            self.repository = repository
        }

        isolated deinit {
            cancelWork?()
        }

        func reset() async -> [WalletAccount]? {
            invalidate()
            isLoading = true
            let generation = generation
            let task = Task { [repository, wallet] () -> (WalletPreviewSession, [WalletAccount])? in
                do {
                    let session = try await repository.previewSession(wallet: wallet)
                    let accounts = try await session.previewAccounts(page: 0)
                    try Task.checkCancellation()
                    return (session, accounts)
                } catch {
                    return nil
                }
            }
            cancelWork = { task.cancel() }
            let result = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard self.generation == generation else { return nil }
            cancelWork = nil
            isLoading = false
            guard !Task.isCancelled else { return nil }
            lastPreview = .now
            guard let (session, accounts) = result else { return nil }
            self.session = session
            loadedCount = accounts.count
            page = 1
            return accounts
        }

        func invalidate() {
            generation += 1
            cancelWork?()
            cancelWork = nil
            page = 0
            isLoading = false
            isPagingEnabled = false
            hasLoadedAllPages = false
            session = nil
            loadedCount = 0
        }

        func enablePaging() {
            isPagingEnabled = true
        }

        func previewMoreIfNeeded() async -> (accounts: [WalletAccount], range: Range<Int>)? {
            guard isPagingEnabled, let session, !isLoading, !hasLoadedAllPages else { return nil }
            isLoading = true
            let generation = generation
            let requestedPage = page
            let remainingDelay = Self.minimumPreviewInterval - lastPreview.duration(to: .now)
            let task = Task { () -> [WalletAccount]? in
                do {
                    if remainingDelay > .zero { try await Task.sleep(for: remainingDelay) }
                    let accounts = try await session.previewAccounts(page: requestedPage)
                    try Task.checkCancellation()
                    return accounts
                } catch {
                    return nil
                }
            }
            cancelWork = { task.cancel() }
            let accounts = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard self.generation == generation else { return nil }
            cancelWork = nil
            isLoading = false
            guard !Task.isCancelled else { return nil }
            guard let accounts else { return nil }
            lastPreview = .now
            let previousCount = loadedCount
            loadedCount += accounts.count
            hasLoadedAllPages = accounts.isEmpty
            page = requestedPage + 1
            return (accounts, previousCount..<loadedCount)
        }
    }
}

actor WalletRepository {
    struct State: Sendable {
        let revision: UInt64
        let wallets: [WalletSnapshot]
    }

    struct Change: Sendable {
        let state: State
        let wallet: WalletSnapshot
    }

    struct Source: Sendable {
        let walletID: String
        let data: Data
        let password: Data
    }

    struct SigningAttempt: Sendable {
        let source: Source?
        let result: Result<WalletSigningOutput, WalletSigningFailure>
    }

    struct SigningKeyDerivation: Sendable {
        let derive: @Sendable (Source, WalletAccount) async throws -> WalletPrivateKey

        static let live = SigningKeyDerivation(derive: { source, account in
            try await WalletKeyPreparation.privateKey(source, account: account)
        })
    }

    struct PreparedCreation: Sendable {
        let walletID: String
        let data: Data
        let password: Data
    }

    private struct PreparedUpdate {
        let wallet: WalletContainer
        let data: Data
        let removedAccounts: [WalletAccount]
    }

    private nonisolated let keychain: Keychain
    private let walletSourceMutator: any WalletSourceMutating
    private let keyDerivation: SigningKeyDerivation
    private var wallets = [WalletContainer]()
    private var revision: UInt64 = 0

    init(
        keychain: Keychain,
        walletSourceMutator: any WalletSourceMutating = ExtensionBridge.WalletSourceMutator(),
        keyDerivation: SigningKeyDerivation = .live
    ) {
        self.keychain = keychain
        self.walletSourceMutator = walletSourceMutator
        self.keyDerivation = keyDerivation
    }

    func reload() throws -> State {
        let walletIDs = try keychain.readAllWalletIDs()
        var loaded = [WalletContainer]()
        loaded.reserveCapacity(walletIDs.count)
        for id in walletIDs {
            guard let data = try keychain.readWalletData(id: id),
                  let wallet = walletContainer(id: id, data: data) else { continue }
            loaded.append(wallet)
        }
        try Task.checkCancellation()
        wallets = loaded
        return snapshot()
    }

    func prepareNewWallet(input: String?, inputPassword: String?) async throws -> PreparedCreation {
        guard let password = try keychain.readPasswordData() else {
            throw WalletsManager.Error.keychainAccessFailure
        }
        return try await WalletKeyPreparation.prepareNewWallet(input: input, inputPassword: inputPassword, password: password)
    }

    func saveNewWallet(_ prepared: PreparedCreation, willMutateSource: @Sendable () throws -> Void) throws -> Change {
        let wallet = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard try keychain.readPasswordData() == prepared.password,
                  try keychain.readWalletData(id: prepared.walletID) == nil,
                  let wallet = walletContainer(id: prepared.walletID, data: prepared.data) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            return PreparedWalletSourceMutation(payload: wallet, authorityRemovals: [])
        }, beforeCommit: willMutateSource) { wallet in
            try Task.checkCancellation()
            try keychain.saveWallet(id: wallet.id, data: prepared.data)
            wallets.append(wallet)
            return WalletSnapshot(wallet)
        }
        return Change(state: snapshot(), wallet: wallet)
    }

    func prepareDeletion(wallet: WalletSnapshot) async throws -> Source {
        let source = try source(walletID: wallet.id)
        try await WalletKeyPreparation.validateDeletion(source)
        return source
    }

    func delete(_ source: Source, willMutateSource: @Sendable () throws -> Void) throws -> Change {
        let removed = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard try sourceIsCurrent(source), let wallet = walletContainer(id: source.walletID, data: source.data) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            return PreparedWalletSourceMutation(payload: WalletSnapshot(wallet), authorityRemovals: [.wallet(id: wallet.id)])
        }, beforeCommit: willMutateSource) { wallet in
            try Task.checkCancellation()
            try keychain.removeWallet(id: wallet.id)
            wallets.removeAll { $0.id == wallet.id }
            WalletsMetadataService.removeMetadataForWallet(wallet, postChange: false)
            return wallet
        }
        return Change(state: snapshot(), wallet: removed)
    }

    func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, willMutateSource: willMutateSource) { current in
            let originalKeys = Set(wallet.accounts.map(\.previewAccountKey))
            let enabledKeys = Set(enabledAccounts.map(\.previewAccountKey))
            let disabledByThisEdit = originalKeys.subtracting(enabledKeys)
            var merged = current.accounts.filter { !disabledByThisEdit.contains($0.previewAccountKey) }
            var mergedKeys = Set(merged.map(\.previewAccountKey))
            for account in enabledAccounts where !originalKeys.contains(account.previewAccountKey) && mergedKeys.insert(account.previewAccountKey).inserted {
                merged.append(account)
            }
            return merged
        }
    }

    func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, willMutateSource: willMutateSource) { current in
            let removed = Set(removeAccounts.map(\.previewAccountKey))
            return current.accounts.filter { !removed.contains($0.previewAccountKey) }
        }
    }

    private func update(wallet: WalletSnapshot, willMutateSource: @Sendable () throws -> Void, accounts: (WalletContainer) throws -> [WalletAccount]) throws -> Change {
        let updated = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard let data = try keychain.readWalletData(id: wallet.id),
                  let current = walletContainer(id: wallet.id, data: data) else {
                throw WalletKeyStoreError.accountNotFound
            }
            let originalAccounts = current.accounts
            let replacement = try accounts(current)
            guard !replacement.isEmpty else { throw WalletsManager.Error.invalidInput }
            for account in originalAccounts {
                current.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
            }
            for account in replacement {
                current.key.addAccountDerivation(address: account.address, coin: account.coin,
                    derivation: account.derivation, derivationPath: account.derivationPath,
                    publicKey: account.publicKey, extendedPublicKey: account.extendedPublicKey)
            }
            guard let data = current.key.exportJSON() else { throw WalletKeyStoreError.invalidPassword }
            let retained = Set(replacement.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) })
            let removed = originalAccounts.filter { !retained.contains(WalletAccountDescriptor(walletID: wallet.id, account: $0)) }
            let removals: [WalletAuthorityRemoval] = removed.isEmpty ? [] : [.accounts(Set(removed.map {
                WalletAccountDescriptor(walletID: wallet.id, account: $0)
            }))]
            return PreparedWalletSourceMutation(
                payload: PreparedUpdate(wallet: current, data: data, removedAccounts: removed),
                authorityRemovals: removals
            )
        }, beforeCommit: willMutateSource) { prepared in
            try Task.checkCancellation()
            try keychain.updateWallet(id: prepared.wallet.id, data: prepared.data)
            if !prepared.removedAccounts.isEmpty {
                WalletsMetadataService.removeMetadataForAccounts(walletId: prepared.wallet.id, accounts: prepared.removedAccounts, postChange: false)
            }
            if let index = wallets.firstIndex(where: { $0.id == prepared.wallet.id }) {
                wallets[index] = prepared.wallet
            } else {
                wallets.append(prepared.wallet)
            }
            return WalletSnapshot(prepared.wallet)
        }
        return Change(state: snapshot(), wallet: updated)
    }

    func exportPrivateKey(wallet: WalletSnapshot, account: WalletAccount?) async throws -> String {
        let source = try source(walletID: wallet.id)
        let result = try await WalletKeyPreparation.exportPrivateKey(source, account: account)
        guard try sourceIsCurrent(source) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return result
    }

    func exportMnemonic(wallet: WalletSnapshot) async throws -> String {
        let source = try source(walletID: wallet.id)
        let result = try await WalletKeyPreparation.exportMnemonic(source)
        guard try sourceIsCurrent(source) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return result
    }

    func sign(_ operation: ApprovedWalletSigningOperation) async -> SigningAttempt {
        var preparedSource: Source?
        do {
            let source = try source(walletID: operation.approvedAccount.walletID, account: operation.approvedAccount.account)
            preparedSource = source
            let key = try await keyDerivation.derive(source, operation.approvedAccount.account)
            try Task.checkCancellation()
            guard WalletSnapshotValidation.accountMatches(operation.approvedAccount.account, privateKey: key) else {
                return SigningAttempt(source: source, result: .failure(.failedToSign))
            }
            let result = operation.sign(with: key, validatingSource: {
                (try? sourceIsCurrent(source)) == true
            })
            return SigningAttempt(source: source, result: result)
        } catch is CancellationError {
            return SigningAttempt(source: preparedSource, result: .failure(.authorizationUnavailable))
        } catch WalletKeyStoreError.accountNotFound {
            return SigningAttempt(source: preparedSource, result: .failure(.authorizationUnavailable))
        } catch {
            return SigningAttempt(source: preparedSource, result: .failure(preparedSource == nil ? .authorizationUnavailable : .failedToSign))
        }
    }

    func previewSession(wallet: WalletSnapshot) async throws -> WalletPreviewSession {
        let source = try source(walletID: wallet.id)
        let hdWallet = try await WalletKeyPreparation.previewWallet(source)
        guard try sourceIsCurrent(source) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return WalletPreviewSession(wallet: hdWallet)
    }

#if os(iOS) || os(visionOS)
    func safariApprovalSourceSnapshot() throws -> SafariApprovalSourceSnapshot? {
        guard let password = try keychain.readPasswordData() else { return nil }
        let walletIDs = try keychain.readAllWalletIDs()
        var snapshots = [WalletSnapshot]()
        var records = [SafariApprovalWalletRecord]()
        snapshots.reserveCapacity(walletIDs.count)
        records.reserveCapacity(walletIDs.count)
        for id in walletIDs {
            guard let data = try keychain.readWalletData(id: id), let wallet = walletContainer(id: id, data: data) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            snapshots.append(WalletSnapshot(wallet))
            records.append(SafariApprovalWalletRecord(walletID: id, storedKeyJSON: data))
        }
        let catalog = WalletAccountCatalog(snapshots: snapshots)
        guard catalog.isValid else { throw WalletsManager.Error.invalidInput }
        return SafariApprovalSourceSnapshot(catalog: catalog, password: password, wallets: records)
    }
#endif

    private func source(walletID: String, account: WalletAccount? = nil) throws -> Source {
        guard let data = try keychain.readWalletData(id: walletID) else { throw WalletsManager.Error.keychainAccessFailure }
        if let account, walletContainer(id: walletID, data: data)?.hasAccountMatching(account) != true {
            throw WalletKeyStoreError.accountNotFound
        }
        guard let password = try keychain.readPasswordData() else { throw WalletsManager.Error.keychainAccessFailure }
        return Source(walletID: walletID, data: data, password: password)
    }

    nonisolated func sourceIsCurrent(_ source: Source) throws -> Bool {
        try keychain.readWalletData(id: source.walletID) == source.data &&
            keychain.readPasswordData() == source.password
    }

    private func snapshot() -> State {
        revision += 1
        return State(revision: revision, wallets: wallets.map(WalletSnapshot.init))
    }

    private func walletContainer(id: String, data: Data) -> WalletContainer? {
        guard let key = WalletStoredKey.importJSON(json: data) else { return nil }
        return WalletContainer(id: id, key: key)
    }
}

actor WalletPreviewSession {
    private let wallet: WalletHDWallet

    init(wallet: WalletHDWallet) {
        self.wallet = wallet
    }

    func previewAccounts(page: Int) throws -> [WalletAccount] {
        try Task.checkCancellation()
        let accounts = try WalletAccountDerivation.previewAccounts(hdWallet: wallet, page: page, coin: nil)
        try Task.checkCancellation()
        return accounts
    }
}

private enum WalletKeyPreparation {
    private static let solanaBase58SecretKeyLengthRange = 32...88
    private static let maxSolanaSecretKeyByteArrayStringLength = 1024
    private static let defaultCoin = WalletCoin.ethereum
    private static let defaultMnemonicCoinDerivations: [(coin: WalletCoin, derivation: WalletDerivation)] = [
        (.ethereum, .default), (.solana, .solanaSolana)
    ]

    @concurrent
    static func validateWalletInput(_ input: String) async -> WalletsManager.InputValidationResult {
        let trimmed = input.singleSpaced
        if WalletCrypto.isValidMnemonic(mnemonic: trimmed) || privateKeyImport(from: trimmed) != nil { return .valid }
        return input.maybeJSON ? .requiresPassword : .invalid
    }

    @concurrent
    static func prepareNewWallet(input: String?, inputPassword: String?, password: Data) async throws -> WalletRepository.PreparedCreation {
        try Task.checkCancellation()
        guard let passwordString = String(data: password, encoding: .utf8) else { throw WalletsManager.Error.keychainAccessFailure }
        let wallet: WalletContainer
        if let input {
            let trimmed = input.singleSpaced
            if WalletCrypto.isValidMnemonic(mnemonic: trimmed) {
                wallet = try importMnemonic(trimmed, name: "", encryptPassword: passwordString)
            } else if let imported = privateKeyImport(from: trimmed) {
                wallet = try importPrivateKey(imported.privateKey, name: "", password: passwordString, coin: imported.coin)
            } else if input.maybeJSON, let inputPassword, let data = input.data(using: .utf8) {
                wallet = try importJSON(data, name: "", password: inputPassword, newPassword: passwordString, coin: defaultCoin)
            } else {
                throw WalletsManager.Error.invalidInput
            }
        } else {
            wallet = try createWallet(name: "", password: passwordString)
        }
        guard let data = wallet.key.exportJSON() else { throw WalletKeyStoreError.invalidKey }
        try Task.checkCancellation()
        return WalletRepository.PreparedCreation(walletID: wallet.id, data: data, password: password)
    }

    @concurrent
    static func validateDeletion(_ source: WalletRepository.Source) async throws {
        try Task.checkCancellation()
        guard let key = WalletStoredKey.importJSON(json: source.data),
              var secret = key.decryptPrivateKey(password: source.password) else { throw WalletKeyStoreError.invalidKey }
        defer { secret.resetBytes(in: 0..<secret.count) }
        try Task.checkCancellation()
    }

    @concurrent
    static func exportPrivateKey(_ source: WalletRepository.Source, account: WalletAccount?) async throws -> String {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let account = account ?? wallet.accounts.first else { throw WalletKeyStoreError.accountNotFound }
        guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        let key = try wallet.privateKey(passwordData: source.password, account: account)
        try Task.checkCancellation()
        return privateKeyExportString(privateKey: key, coin: account.coin)
    }

    @concurrent
    static func exportMnemonic(_ source: WalletRepository.Source) async throws -> String {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let mnemonic = wallet.key.decryptMnemonic(password: source.password) else { throw WalletKeyStoreError.invalidPassword }
        try Task.checkCancellation()
        return mnemonic
    }

    @concurrent
    static func privateKey(_ source: WalletRepository.Source, account: WalletAccount) async throws -> WalletPrivateKey {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        let key = try wallet.privateKey(passwordData: source.password, account: account)
        try Task.checkCancellation()
        return key
    }

    @concurrent
    static func previewWallet(_ source: WalletRepository.Source) async throws -> WalletHDWallet {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let hdWallet = wallet.key.wallet(password: source.password) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return hdWallet
    }

    private static func wallet(_ source: WalletRepository.Source) throws -> WalletContainer {
        guard let key = WalletStoredKey.importJSON(json: source.data) else { throw WalletKeyStoreError.invalidKey }
        return WalletContainer(id: source.walletID, key: key)
    }
    private static func createWallet(name: String, password: String) throws -> WalletContainer {
        guard let key = WalletStoredKey(name: name, password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: password)
        return wallet
    }

    private static func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: WalletCoin) throws -> WalletContainer {
        guard let key = WalletStoredKey.importJSON(json: json) else { throw WalletKeyStoreError.invalidKey }
        guard var data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidPassword }
        defer { data.resetBytes(in: 0..<data.count) }
        if let mnemonic = checkMnemonic(data) { return try importMnemonic(mnemonic, name: name, encryptPassword: newPassword) }
        guard let privateKey = WalletPrivateKey(data: data) else { throw WalletKeyStoreError.invalidKey }
        return try importPrivateKey(privateKey, name: name, password: newPassword, coin: coin)
    }

    private static func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), WalletCrypto.isValidMnemonic(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    private static func importPrivateKey(_ privateKey: WalletPrivateKey, name: String, password: String, coin: WalletCoin) throws -> WalletContainer {
        let passwordData = Data(password.utf8)
        guard let newKey = privateKey.withData({
            WalletStoredKey.importPrivateKey(privateKey: $0, name: name, password: passwordData, coin: coin)
        }) else { throw WalletKeyStoreError.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        return wallet
    }

    private static func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String) throws -> WalletContainer {
        guard let key = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: defaultCoin) else { throw WalletKeyStoreError.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: encryptPassword)
        return wallet
    }

    static func privateKeyExportString(privateKey: WalletPrivateKey, coin: WalletCoin) -> String {
        switch coin {
        case .solana:
            return solanaSecretKeyExportString(privateKey: privateKey)
        default:
            return hexPrivateKeyExportString(privateKey: privateKey)
        }
    }

    static func privateKeyImport(from input: String) -> WalletsManager.PrivateKeyImport? {
        if let ethereumPrivateKey = ethereumPrivateKeyImport(from: input) {
            return WalletsManager.PrivateKeyImport(privateKey: ethereumPrivateKey, coin: .ethereum)
        }

        if let solanaPrivateKey = solanaPrivateKeyImport(from: input) {
            return WalletsManager.PrivateKeyImport(privateKey: solanaPrivateKey, coin: .solana)
        }

        return nil
    }

    private static func ethereumPrivateKeyImport(from input: String) -> WalletPrivateKey? {
        guard var privateKeyData = WalletCrypto.hexData(string: input),
              WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .ethereum)
        else { return nil }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        return WalletPrivateKey(data: privateKeyData)
    }

    private static func solanaPrivateKeyImport(from input: String) -> WalletPrivateKey? {
        if solanaBase58SecretKeyLengthRange.contains(input.count),
           let secretKey = WalletCrypto.base58Decode(string: input) {
            return solanaPrivateKeyImport(secretKey: secretKey)
        }

        if let secretKey = solanaSecretKeyData(fromByteArrayString: input) {
            return solanaPrivateKeyImport(secretKey: secretKey)
        }

        return nil
    }

    private static func solanaSecretKeyData(fromByteArrayString input: String) -> Data? {
        guard input.hasPrefix("["),
              input.hasSuffix("]"),
              input.count <= maxSolanaSecretKeyByteArrayStringLength,
              let inputData = input.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: inputData),
              let values = jsonObject as? [Any],
              values.count == 32 || values.count == 64
        else { return nil }

        var secretKey = Data()
        secretKey.reserveCapacity(values.count)

        for value in values {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let byteValue = number.doubleValue
            guard byteValue.rounded() == byteValue,
                  byteValue >= Double(UInt8.min),
                  byteValue <= Double(UInt8.max)
            else { return nil }
            secretKey.append(UInt8(byteValue))
        }

        return secretKey
    }

    private static func solanaPrivateKeyImport(secretKey: Data) -> WalletPrivateKey? {
        var secretKeyData = secretKey
        defer { secretKeyData.resetBytes(in: 0..<secretKeyData.count) }

        switch secretKeyData.count {
        case 32:
            guard WalletCrypto.isValidPrivateKeyData(data: secretKeyData, coin: .solana) else { return nil }
            return WalletPrivateKey(data: secretKeyData)
        case 64:
            var privateKeyData = Data(secretKeyData.prefix(32))
            defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
            guard WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .solana),
                  let privateKey = WalletPrivateKey(data: privateKeyData)
            else { return nil }

            let expectedPublicKey = privateKey.publicKeyData(coin: .solana)
            let exportedPublicKey = Data(secretKeyData.suffix(32))
            return exportedPublicKey == expectedPublicKey ? privateKey : nil
        default:
            return nil
        }
    }

    private static func solanaSecretKeyExportString(privateKey: WalletPrivateKey) -> String {
        return privateKey.withData { privateKeyData in
            var secretKey = privateKeyData
            defer { secretKey.resetBytes(in: 0..<secretKey.count) }

            if secretKey.count == 32 {
                secretKey.append(privateKey.publicKeyData(coin: .solana))
            }

            return WalletCrypto.base58Encode(data: secretKey)
        }
    }

    private static func hexPrivateKeyExportString(privateKey: WalletPrivateKey) -> String {
        return privateKey.withData { WalletCrypto.hexString(data: $0) }
    }

    private static func addMnemonicAccounts(to wallet: WalletContainer,
                                     password: String,
                                     coinDerivations: [(coin: WalletCoin, derivation: WalletDerivation)]) throws {
        guard wallet.isMnemonic else { return }

        let hdWallet = wallet.key.wallet(password: Data(password.utf8))
        for (coin, derivation) in coinDerivations
        where !wallet.accounts.contains(where: { $0.coin == coin && $0.derivation == derivation }) {
            guard wallet.key.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: hdWallet) != nil else {
                throw WalletKeyStoreError.invalidPassword
            }
        }
    }

    private static func addDefaultMnemonicAccounts(to wallet: WalletContainer, password: String) throws {
        try addMnemonicAccounts(to: wallet, password: password, coinDerivations: defaultMnemonicCoinDerivations)
    }

    private static func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }

}

enum WalletAccountDerivation {
    private static let previewAccountsPageSize = 11

    static func previewAccounts(hdWallet: WalletHDWallet, page: Int, coin: WalletCoin?) throws -> [WalletAccount] {
        guard let coin else {
            return try Self.collectPreviewAccounts(coins: [.ethereum, .solana]) { previewCoin in
                try previewAccounts(hdWallet: hdWallet, page: page, coin: previewCoin)
            }
        }

        switch coin {
        case .ethereum:
            guard let range = Self.previewAccountIndexRange(page: page) else { throw WalletsManager.Error.failedToDeriveAccount }
            guard let accounts = hdWallet.ethereumPreviewAccounts(accountRange: range) else { throw WalletsManager.Error.failedToDeriveAccount }
            return accounts
        case .solana:
            return try previewSolanaAccounts(hdWallet: hdWallet, page: page)
        }
    }

    static func collectPreviewAccounts(coins: [WalletCoin],
                                       previewAccountsForCoin: (WalletCoin) throws -> [WalletAccount]) throws -> [WalletAccount] {
        var accountGroups = [[WalletAccount]]()
        var firstError: Swift.Error?

        for coin in coins {
            do {
                accountGroups.append(try previewAccountsForCoin(coin))
            } catch {
                firstError = firstError ?? error
            }
        }

        let accounts = interleaved(accountGroups)
        if accounts.isEmpty, let firstError {
            throw firstError
        }

        return accounts
    }

    private static func interleaved(_ accountGroups: [[WalletAccount]]) -> [WalletAccount] {
        let totalCount = accountGroups.reduce(0) { $0 + $1.count }
        let maxCount = accountGroups.map { $0.count }.max() ?? 0
        var accounts = [WalletAccount]()
        accounts.reserveCapacity(totalCount)

        for index in 0..<maxCount {
            for group in accountGroups where index < group.count {
                accounts.append(group[index])
            }
        }

        return accounts
    }

    private static func previewAccountIndexRange(page: Int) -> Range<Int>? {
        guard page >= 0 else { return nil }

        let startResult = page.multipliedReportingOverflow(by: previewAccountsPageSize)
        guard !startResult.overflow else { return nil }

        let endResult = startResult.partialValue.addingReportingOverflow(previewAccountsPageSize)
        guard !endResult.overflow else { return nil }

        let end = endResult.partialValue
        guard UInt32(exactly: end - 1) != nil else { return nil }

        return startResult.partialValue..<end
    }

    private static func previewSolanaAccounts(hdWallet: WalletHDWallet, page: Int) throws -> [WalletAccount] {
        guard let range = Self.previewAccountIndexRange(page: page) else { throw WalletsManager.Error.failedToDeriveAccount }
        guard let accounts = hdWallet.solanaPreviewAccounts(accountRange: range) else { throw WalletsManager.Error.failedToDeriveAccount }
        return accounts
    }

}

extension WalletContainer {

    func hasAccountMatching(_ account: WalletAccount) -> Bool {
        let normalizedAddress = account.coin.normalizedAddress(account.address)
        return accounts.contains { currentAccount in
            currentAccount.coin == account.coin &&
            currentAccount.derivationPath == account.derivationPath &&
            account.coin.normalizedAddress(currentAccount.address) == normalizedAddress
        }
    }

}
