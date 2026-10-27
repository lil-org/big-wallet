import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation
import CryptoKit
import Synchronization

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

struct WalletStoreChangeNotifications: Sendable {
    let postLocalChange: @MainActor @Sendable () -> Void
    let postMutation: @MainActor @Sendable () -> Void
    let startObserving: @MainActor @Sendable (Any, Selector) -> Void
    let stopObserving: @MainActor @Sendable (Any) -> Void
    let isExternalChange: @Sendable (Notification) -> Bool

    static let live = WalletStoreChangeNotifications(
        postLocalChange: { WalletStoreSync.postLocalChange() },
        postMutation: { WalletStoreSync.postLocalAndExternalChange() },
        startObserving: { WalletStoreSync.startObserving($0, selector: $1) },
        stopObserving: { WalletStoreSync.stopObserving($0) },
        isExternalChange: { WalletStoreSync.isExternalChange($0) }
    )
}

private struct UnavailableWalletSourceMutator: WalletSourceMutating {
    func perform<Payload, Result>(
        preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void,
        commit: (Payload) throws -> Result
    ) throws -> Result {
        throw WalletsManager.Error.keychainAccessFailure
    }
}

@MainActor
public final class WalletsManager: NSObject {
    public enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
        case failedToDeriveAccount
    }

    public enum InputValidationResult: Sendable {
        case valid, invalid, requiresPassword
    }

    struct PrivateKeyImport: Sendable {
        let privateKey: WalletPrivateKey
        let coin: WalletCoin
    }

    nonisolated let repository: WalletRepository
#if os(iOS) || os(visionOS)
    var approvalVaultHost: SafariApprovalVaultHost!
#endif
    private let reloadMetadata: @MainActor () -> Void
    private let publishLocalChange: @MainActor () -> Void
    private nonisolated let notifications: WalletStoreChangeNotifications
    public private(set) var wallets = [WalletSnapshot]()
    private var repositoryRevision: UInt64 = 0
    private var isObservingExternalChanges = false
    private var externalReload: Task<Void, Never>?
    private let authorityID: UUID
    private let clock: @Sendable () -> Date
    private struct InitialBackupAuthorization {
        let binding: WalletSecretExportBinding
        let deadline: Date
    }
    private var initialBackupBindings = [String: InitialBackupAuthorization]()

    init(
        keychain: Keychain,
        reloadMetadata: @escaping @MainActor () -> Void = {},
        publishLocalChange: (@MainActor () -> Void)? = nil,
        walletSourceMutator: (any WalletSourceMutating)? = nil,
        keyDerivation: WalletRepository.SigningKeyDerivation = .live,
        notifications: WalletStoreChangeNotifications = .live,
        metadataMutations: WalletRepository.MetadataMutations = .none,
        authorityID: UUID = UUID(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        repository = WalletRepository(
            keychain: keychain, walletSourceMutator: walletSourceMutator,
            keyDerivation: keyDerivation, metadataMutations: metadataMutations
        )
        self.reloadMetadata = reloadMetadata
        self.publishLocalChange = publishLocalChange ?? notifications.postLocalChange
        self.notifications = notifications
        self.authorityID = authorityID
        self.clock = clock
        super.init()
    }

    isolated deinit {
        externalReload?.cancel()
        notifications.stopObserving(self)
    }

    @discardableResult
    public func start() async -> Bool {
        startObservingExternalChanges()
        return await reloadFromStore()
    }

    @discardableResult
    public func reloadFromStore() async -> Bool {
        do {
            let state = try await repository.reload()
            apply(state)
            publishLocalChange()
            return true
        } catch {
            return false
        }
    }

    public func reviewCatalog() -> WalletReviewCatalog? {
        guard let data = try? WalletAccountCatalog(snapshots: wallets).canonicalData() else { return nil }
        return WalletReviewCatalog(
            identity: WalletCatalogIdentity(generation: nil, catalogData: data),
            orderedAccounts: wallets.flatMap { wallet in
                wallet.accounts.map { SpecificWalletAccount(walletId: wallet.id, account: $0) }
            }
        )
    }

    public func currentWallet(id: String) -> WalletSnapshot? {
        wallets.first { $0.id == id }
    }

#if os(iOS) || os(visionOS)
    nonisolated func safariApprovalSourceSnapshot() async throws -> SafariApprovalSourceSnapshot? {
        try await repository.safariApprovalSourceSnapshot()
    }
#endif

    public nonisolated func validateWalletInput(_ input: String) async -> InputValidationResult {
        await WalletKeyPreparation.validateWalletInput(input)
    }

    public func createWallet() async throws -> WalletSnapshot {
        let prepared = try await repository.prepareNewWallet(input: nil, inputPassword: nil)
        let wallet = try await commit { [repository] willMutate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate)
        }
        if !Task.isCancelled {
            let binding = WalletSecretExportBinding(
                walletID: prepared.walletID, account: nil, kind: .mnemonic,
                sourceDigest: Data(SHA256.hash(data: prepared.data)),
                credentialDigest: prepared.credentialDigest
            )
            initialBackupBindings[wallet.id] = InitialBackupAuthorization(
                binding: binding, deadline: clock().addingTimeInterval(ExtensionBridge.executionLifetime)
            )
        }
        return wallet
    }

    public func addWallet(input: String, inputPassword: String?) async throws -> WalletSnapshot {
        let prepared = try await repository.prepareNewWallet(input: input, inputPassword: inputPassword)
        return try await commit { [repository] willMutate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate)
        }
    }

    public func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount]) async throws {
        _ = try await commit { [repository] willMutate in
            try await repository.update(wallet: wallet, enabledAccounts: enabledAccounts, willMutateSource: willMutate)
        }
    }

    public func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount]) async throws {
        _ = try await commit { [repository] willMutate in
            try await repository.update(wallet: wallet, removeAccounts: removeAccounts, willMutateSource: willMutate)
        }
    }

    public func delete(wallet: WalletSnapshot) async throws {
        let prepared = try await repository.prepareDeletion(wallet: wallet)
        _ = try await commit { [repository] willMutate in
            try await repository.delete(prepared, willMutateSource: willMutate)
        }
    }


    public func previewSession(wallet: WalletSnapshot) async throws -> WalletPreviewSession {
        try await repository.previewSession(wallet: wallet)
    }

    public func makeExportChallenge(
        wallet: WalletSnapshot,
        account: WalletAccount? = nil,
        kind: WalletSecretExport
    ) async throws -> WalletAuthenticationChallenge {
        let binding = try await repository.exportBinding(wallet: wallet, account: account, kind: kind)
        try Task.checkCancellation()
        return WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: .secretExport(binding),
            deadline: clock().addingTimeInterval(ExtensionBridge.executionLifetime), clock: clock
        )
    }

    public func takeInitialBackupAuthorization(wallet: WalletSnapshot) -> WalletAuthenticationGrant? {
        guard let initial = initialBackupBindings.removeValue(forKey: wallet.id),
              clock() < initial.deadline else { return nil }
        let binding = initial.binding
        let challenge = WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: .secretExport(binding),
            deadline: initial.deadline, clock: clock
        )
        let repository = repository
        return challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: {
            repository.sourceMatches(binding) ? .current : .changed
        }))
    }

    public func exportPrivateKey(
        wallet: WalletSnapshot,
        account: WalletAccount? = nil,
        authorization: WalletAuthenticationGrant
    ) async throws -> String {
        let descriptor = account.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) }
        guard let binding = authorization.consumeExport(
            authorityID: authorityID, walletID: wallet.id, account: descriptor, kind: .privateKey
        ) else { throw Error.keychainAccessFailure }
        return try await repository.exportPrivateKey(wallet: wallet, account: account, binding: binding)
    }

    public func exportMnemonic(wallet: WalletSnapshot, authorization: WalletAuthenticationGrant) async throws -> String {
        guard let binding = authorization.consumeExport(
            authorityID: authorityID, walletID: wallet.id, account: nil, kind: .mnemonic
        ) else { throw Error.keychainAccessFailure }
        return try await repository.exportMnemonic(wallet: wallet, binding: binding)
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
        change = try await approvalVaultHost.performSourceMutation(operation)
#else
        change = try await operation({})
#endif
        apply(change.state)
        notifications.postMutation()
        return change.wallet
    }

    private func apply(_ state: WalletRepository.State) {
        guard state.revision >= repositoryRevision else { return }
        repositoryRevision = state.revision
        wallets = state.wallets
        let currentWalletIDs = Set(wallets.map(\.id))
        initialBackupBindings = initialBackupBindings.filter {
            currentWalletIDs.contains($0.key) && clock() < $0.value.deadline
        }
        reloadMetadata()
    }

    private func startObservingExternalChanges() {
        guard !isObservingExternalChanges else { return }
        isObservingExternalChanges = true
        notifications.startObserving(self, #selector(externalWalletStoreChanged(_:)))
    }

    @objc nonisolated private func externalWalletStoreChanged(_ notification: Notification) {
        guard notifications.isExternalChange(notification) else { return }
        Task { @MainActor [weak self] in self?.scheduleExternalReload() }
    }

    private func scheduleExternalReload() {
        externalReload?.cancel()
        externalReload = Task { [weak self] in
            await self?.handleExternalWalletStoreChange()
        }
    }

    func handleExternalWalletStoreChange() async {
        _ = await reloadFromStore()
    }


}

actor WalletRepository {
    struct MetadataMutations: Sendable {
        let removeWallet: @Sendable (WalletSnapshot) -> Void
        let removeAccounts: @Sendable (String, [WalletAccount]) -> Void

        static let none = MetadataMutations(removeWallet: { _ in }, removeAccounts: { _, _ in })
    }

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

        var identity: SourceIdentity {
            SourceIdentity(walletID: walletID, sourceDigest: Data(SHA256.hash(data: data)),
                credentialDigest: Data(SHA256.hash(data: password)))
        }
    }

    struct SourceIdentity: Equatable, Sendable {
        let walletID: String
        let sourceDigest: Data
        let credentialDigest: Data

        func matches(_ binding: WalletSecretExportBinding) -> Bool {
            walletID == binding.walletID && sourceDigest == binding.sourceDigest &&
                credentialDigest == binding.credentialDigest
        }
    }

    struct SigningAttempt: Sendable {
        let sourceIdentity: SourceIdentity?
        let result: Result<WalletSigningOutput, WalletSigningFailure>
    }

    private struct PreparedSigningKey: Sendable {
        let sourceIdentity: SourceIdentity
        let result: Result<WalletPrivateKey, WalletSigningFailure>
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
        let credentialDigest: Data
    }

    struct PreparedDeletion: Sendable {
        let wallet: WalletSnapshot
        let sourceIdentity: SourceIdentity
    }

    private struct PreparedUpdate {
        let wallet: WalletContainer
        let data: Data
        let removedAccounts: [WalletAccount]
    }

    private nonisolated let keychain: Keychain
    private let walletSourceMutator: any WalletSourceMutating
    private let keyDerivation: SigningKeyDerivation
    private let metadataMutations: MetadataMutations
    private var wallets = [WalletContainer]()
    private var revision: UInt64 = 0

    init(
        keychain: Keychain,
        walletSourceMutator: (any WalletSourceMutating)? = nil,
        keyDerivation: SigningKeyDerivation = .live,
        metadataMutations: MetadataMutations = .none
    ) {
        self.keychain = keychain
        self.walletSourceMutator = walletSourceMutator ?? UnavailableWalletSourceMutator()
        self.keyDerivation = keyDerivation
        self.metadataMutations = metadataMutations
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
            guard let password = try keychain.readPasswordData(),
                  Data(SHA256.hash(data: password)) == prepared.credentialDigest,
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

    func prepareDeletion(wallet: WalletSnapshot) async throws -> PreparedDeletion {
        try await WalletKeyPreparation.prepareDeletion(source(walletID: wallet.id))
    }

    func delete(_ prepared: PreparedDeletion, willMutateSource: @Sendable () throws -> Void) throws -> Change {
        let removed = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard try sourceIsCurrent(prepared.sourceIdentity) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            return PreparedWalletSourceMutation(payload: prepared.wallet, authorityRemovals: [.wallet(id: prepared.wallet.id)])
        }, beforeCommit: willMutateSource) { wallet in
            try Task.checkCancellation()
            try keychain.removeWallet(id: wallet.id)
            wallets.removeAll { $0.id == wallet.id }
            metadataMutations.removeWallet(wallet)
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
                metadataMutations.removeAccounts(prepared.wallet.id, prepared.removedAccounts)
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

    func exportBinding(wallet: WalletSnapshot, account: WalletAccount?, kind: WalletSecretExport) throws -> WalletSecretExportBinding {
        guard kind != .mnemonic || account == nil else { throw WalletsManager.Error.invalidInput }
        let identity = try source(walletID: wallet.id, account: account).identity
        return WalletSecretExportBinding(
            walletID: wallet.id,
            account: account.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) },
            kind: kind,
            sourceDigest: identity.sourceDigest,
            credentialDigest: identity.credentialDigest
        )
    }

    nonisolated func sourceMatches(_ binding: WalletSecretExportBinding) -> Bool {
        (try? sourceIsCurrent(SourceIdentity(walletID: binding.walletID,
            sourceDigest: binding.sourceDigest, credentialDigest: binding.credentialDigest))) == true
    }

    func exportPrivateKey(wallet: WalletSnapshot, account: WalletAccount?, binding: WalletSecretExportBinding) async throws -> String {
        let result = try await WalletKeyPreparation.exportPrivateKey(
            source(walletID: wallet.id), account: account, binding: binding
        )
        guard try sourceIsCurrent(result.identity) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return result.value
    }

    func exportMnemonic(wallet: WalletSnapshot, binding: WalletSecretExportBinding) async throws -> String {
        let result = try await WalletKeyPreparation.exportMnemonic(source(walletID: wallet.id), binding: binding)
        guard try sourceIsCurrent(result.identity) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return result.value
    }

    func sign(_ operation: ApprovedWalletSigningOperation) async -> SigningAttempt {
        let prepared: PreparedSigningKey
        do {
            prepared = try await prepareSigningKey(
                source(walletID: operation.approvedAccount.walletID, account: operation.approvedAccount.account),
                account: operation.approvedAccount.account
            )
        } catch {
            return SigningAttempt(sourceIdentity: nil, result: .failure(.authorizationUnavailable))
        }
        let identity = prepared.sourceIdentity
        switch prepared.result {
        case .failure(let failure):
            return SigningAttempt(sourceIdentity: identity, result: .failure(failure))
        case .success(let key):
            guard WalletSnapshotValidation.accountMatches(operation.approvedAccount.account, privateKey: key) else {
                return SigningAttempt(sourceIdentity: identity, result: .failure(.failedToSign))
            }
            let result = operation.sign(with: key, validatingSource: {
                (try? sourceIsCurrent(identity)) == true
            })
            return SigningAttempt(sourceIdentity: identity, result: result)
        }
    }

    private func prepareSigningKey(_ source: Source, account: WalletAccount) async -> PreparedSigningKey {
        let identity = source.identity
        let result: Result<WalletPrivateKey, WalletSigningFailure>
        do {
            let key = try await keyDerivation.derive(source, account)
            try Task.checkCancellation()
            result = .success(key)
        } catch is CancellationError {
            result = .failure(.authorizationUnavailable)
        } catch WalletKeyStoreError.accountNotFound {
            result = .failure(.authorizationUnavailable)
        } catch {
            result = .failure(.failedToSign)
        }
        return PreparedSigningKey(sourceIdentity: identity, result: result)
    }

    func previewSession(wallet: WalletSnapshot) async throws -> WalletPreviewSession {
        let result = try await WalletKeyPreparation.previewWallet(source(walletID: wallet.id))
        guard try sourceIsCurrent(result.identity) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return WalletPreviewSession(wallet: result.value)
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

    nonisolated func sourceIsCurrent(_ identity: SourceIdentity) throws -> Bool {
        guard let data = try keychain.readWalletData(id: identity.walletID),
              Data(SHA256.hash(data: data)) == identity.sourceDigest else { return false }
        guard let password = try keychain.readPasswordData() else { return false }
        return Data(SHA256.hash(data: password)) == identity.credentialDigest
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

public actor WalletPreviewSession {
    private nonisolated let wallet: Mutex<WalletHDWallet?>
    private let deriveAccounts: @Sendable (WalletHDWallet, Int) throws -> [WalletAccount]

    init(
        wallet: WalletHDWallet,
        deriveAccounts: @escaping @Sendable (WalletHDWallet, Int) throws -> [WalletAccount] = {
            try WalletAccountDerivation.previewAccounts(hdWallet: $0, page: $1, coin: nil)
        }
    ) {
        self.wallet = Mutex(wallet)
        self.deriveAccounts = deriveAccounts
    }

    public func previewAccounts(page: Int) throws -> [WalletAccount] {
        try Task.checkCancellation()
        guard let wallet = wallet.withLock({ $0 }) else { throw CancellationError() }
        let accounts = try deriveAccounts(wallet, page)
        try Task.checkCancellation()
        guard self.wallet.withLock({ $0 != nil }) else { throw CancellationError() }
        return accounts
    }

    public nonisolated func invalidate() {
        wallet.withLock { $0 = nil }
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
        guard WalletImportLimits.acceptsInput(input) else { return .invalid }
        let trimmed = input.singleSpaced
        if WalletCrypto.isValidMnemonic(mnemonic: trimmed) || privateKeyImport(from: trimmed) != nil { return .valid }
        return input.maybeJSON ? .requiresPassword : .invalid
    }

    @concurrent
    static func prepareNewWallet(input: String?, inputPassword: String?, password: Data) async throws -> WalletRepository.PreparedCreation {
        try Task.checkCancellation()
        let passwordString = String(decoding: password, as: UTF8.self)
        let wallet: WalletContainer
        if let input {
            guard WalletImportLimits.acceptsInput(input) else { throw WalletImportError.limitExceeded }
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
        return WalletRepository.PreparedCreation(walletID: wallet.id, data: data,
            credentialDigest: Data(SHA256.hash(data: password)))
    }

    @concurrent
    static func prepareDeletion(_ source: WalletRepository.Source) async throws -> WalletRepository.PreparedDeletion {
        try Task.checkCancellation()
        guard let key = WalletStoredKey.importJSON(json: source.data),
              var secret = key.decryptPrivateKey(password: source.password) else { throw WalletKeyStoreError.invalidKey }
        defer { secret.resetBytes(in: 0..<secret.count) }
        try Task.checkCancellation()
        return WalletRepository.PreparedDeletion(wallet: WalletSnapshot(WalletContainer(id: source.walletID, key: key)),
            sourceIdentity: source.identity)
    }

    @concurrent
    static func exportPrivateKey(
        _ source: WalletRepository.Source,
        account: WalletAccount?,
        binding: WalletSecretExportBinding
    ) async throws -> (value: String, identity: WalletRepository.SourceIdentity) {
        let identity = source.identity
        guard identity.matches(binding) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let account = account ?? wallet.accounts.first else { throw WalletKeyStoreError.accountNotFound }
        guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        let key = try wallet.privateKey(passwordData: source.password, account: account)
        try Task.checkCancellation()
        return (privateKeyExportString(privateKey: key, coin: account.coin), identity)
    }

    @concurrent
    static func exportMnemonic(
        _ source: WalletRepository.Source,
        binding: WalletSecretExportBinding
    ) async throws -> (value: String, identity: WalletRepository.SourceIdentity) {
        let identity = source.identity
        guard identity.matches(binding) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let mnemonic = wallet.key.decryptMnemonic(password: source.password) else { throw WalletKeyStoreError.invalidPassword }
        try Task.checkCancellation()
        return (mnemonic, identity)
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
    static func previewWallet(_ source: WalletRepository.Source) async throws -> (value: WalletHDWallet, identity: WalletRepository.SourceIdentity) {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let hdWallet = wallet.key.wallet(password: source.password) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        return (hdWallet, source.identity)
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
        let key = try WalletStoredKey.importUserJSON(json: json)
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

