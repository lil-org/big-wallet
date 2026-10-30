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

private final class WalletStoreReadiness: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var ready = false
    }

    private let state = Mutex(State())

    func setReady(_ ready: Bool) {
        state.withLock {
            if $0.ready != ready { $0.generation &+= 1 }
            $0.ready = ready
        }
    }

    func token() throws -> UInt64 {
        try state.withLock {
            guard $0.ready else { throw WalletsManager.Error.keychainAccessFailure }
            return $0.generation
        }
    }

    func validate(_ token: UInt64) throws {
        guard state.withLock({ $0.ready && $0.generation == token }) else {
            throw WalletsManager.Error.keychainAccessFailure
        }
    }
}

@MainActor
public final class WalletsManager: NSObject {
    public enum LoadFailure: Swift.Error, Equatable, Sendable {
        case unavailable, corrupt
    }

    public enum LoadState: Equatable, Sendable {
        case idle, loading, ready, failed(LoadFailure)
    }

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
    public private(set) var loadState = LoadState.idle
    public private(set) var hasLoadedSnapshot = false
    public var isStoreReady: Bool { loadState == .ready }
    private let readiness = WalletStoreReadiness()
    private final class ReloadWaiter: Sendable {
        let cancelled = Mutex(false)
    }
    @MainActor
    private final class ReloadAttempt {
        let previousState: LoadState
        var task: Task<WalletRepository.LoadResult, Never>
        var storeChangeRevision: UInt64
        var pass: UInt64 = 0
        var waiters = [ReloadWaiter]()
        var result: Bool?

        init(previousState: LoadState, storeChangeRevision: UInt64, repository: WalletRepository) {
            self.previousState = previousState
            self.storeChangeRevision = storeChangeRevision
            task = Task { await repository.load() }
        }
    }
    private var reloadAttempt: ReloadAttempt?
    private var storeChangeRevision: UInt64 = 0
    private var repositoryRevision: UInt64 = 0
    private var isObservingExternalChanges = false
    private var externalReload: Task<Void, Never>?
    let authorityID: UUID
    private let clock: @Sendable () -> Date
    private struct InitialBackupAuthorization {
        let binding: WalletSecretExportBinding
        let deadline: Date
        let access: WalletAccessSession
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
        reloadAttempt?.task.cancel()
        notifications.stopObserving(self)
    }

    @discardableResult
    public func start() async -> Bool {
        startObservingExternalChanges()
        return await reloadFromStore()
    }

    @discardableResult
    public func reloadFromStore() async -> Bool {
        guard !Task.isCancelled else { return false }
        if let pending = reloadAttempt { cancelReloadIfUnobserved(pending) }
        let attempt: ReloadAttempt
        let waiter = ReloadWaiter()
        if let pending = reloadAttempt {
            attempt = pending
            attempt.waiters.append(waiter)
        } else {
            attempt = ReloadAttempt(previousState: loadState, storeChangeRevision: storeChangeRevision, repository: repository)
            attempt.waiters.append(waiter)
            reloadAttempt = attempt
            setLoadState(.loading)
        }
        return await withTaskCancellationHandler {
            while true {
                let pass = attempt.pass
                let result = await attempt.task.value
                guard !Task.isCancelled, !waiter.cancelled.withLock({ $0 }) else {
                    waiter.cancelled.withLock { $0 = true }
                    cancelReloadIfUnobserved(attempt)
                    return false
                }
                if let completed = attempt.result { return completed }
                guard reloadAttempt === attempt else { return false }
                guard pass == attempt.pass else { continue }
                if attempt.storeChangeRevision != storeChangeRevision {
                    attempt.storeChangeRevision = storeChangeRevision
                    attempt.pass &+= 1
                    attempt.task = Task { [repository] in await repository.load() }
                    continue
                }
                return finishReload(attempt, result: result)
            }
        } onCancel: {
            waiter.cancelled.withLock { $0 = true }
            Task { @MainActor [weak self] in self?.cancelReloadIfUnobserved(attempt) }
        }
    }

    private func cancelReloadIfUnobserved(_ attempt: ReloadAttempt) {
        guard reloadAttempt === attempt,
              attempt.waiters.allSatisfy({ $0.cancelled.withLock { $0 } }) else { return }
        reloadAttempt = nil
        attempt.result = false
        attempt.task.cancel()
        setLoadState(attempt.previousState)
    }

    private func finishReload(_ attempt: ReloadAttempt, result: WalletRepository.LoadResult) -> Bool {
        if let completed = attempt.result { return completed }
        guard reloadAttempt === attempt else { return false }
        reloadAttempt = nil
        switch result {
        case .loaded(let state):
            let applied = apply(state)
            attempt.result = true
            setLoadState(.ready)
            if applied {
                reloadMetadata()
                publishLocalChange()
            }
            return true
        case .failed(let failure, let revision):
            guard revision >= repositoryRevision else {
                attempt.result = hasLoadedSnapshot
                setLoadState(hasLoadedSnapshot ? .ready : attempt.previousState)
                return hasLoadedSnapshot
            }
            repositoryRevision = revision
            attempt.result = false
            setLoadState(.failed(failure))
            return false
        case .cancelled:
            attempt.result = false
            setLoadState(attempt.previousState)
            return false
        }
    }

    private func setLoadState(_ state: LoadState) {
        guard loadState != state else { return }
        loadState = state
        readiness.setReady(state == .ready)
        NotificationCenter.default.post(name: .walletsLoadStateChanged, object: self)
    }

    private func requireReadyStore() async throws -> UInt64 {
        try Task.checkCancellation()
        if loadState == .idle { _ = await reloadFromStore() }
        try Task.checkCancellation()
        return try readiness.token()
    }

    public func reviewCatalog() -> WalletReviewCatalog? {
        guard isStoreReady else { return nil }
        let catalog = WalletAccountCatalog(snapshots: wallets)
        guard catalog.isValid, let data = try? catalog.canonicalData() else { return nil }
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

    public func createWallet(access: WalletAccessSession) async throws -> WalletSnapshot {
        try validateManagementAccess(access)
        let token = try await requireReadyStore()
        let prepared = try await repository.prepareNewWallet(input: nil, inputPassword: nil)
        let wallet = try await commit(access: access, readinessToken: token) { [repository] willMutate, validate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate, validateAccess: validate)
        }
        if !Task.isCancelled {
            let binding = WalletSecretExportBinding(
                walletID: prepared.walletID, account: nil, kind: .mnemonic,
                sourceDigest: Data(SHA256.hash(data: prepared.data)),
                credentialDigest: prepared.credentialDigest
            )
            initialBackupBindings[wallet.id] = InitialBackupAuthorization(
                binding: binding, deadline: clock().addingTimeInterval(ExtensionBridge.executionLifetime), access: access
            )
        }
        return wallet
    }

    public func addWallet(input: String, inputPassword: String?, access: WalletAccessSession) async throws -> WalletSnapshot {
        try validateManagementAccess(access)
        let token = try await requireReadyStore()
        let prepared = try await repository.prepareNewWallet(input: input, inputPassword: inputPassword)
        return try await commit(access: access, readinessToken: token) { [repository] willMutate, validate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate, validateAccess: validate)
        }
    }

    public func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount], access: WalletAccessSession) async throws {
        _ = try await commit(access: access) { [repository] willMutate, validate in
            try await repository.update(wallet: wallet, enabledAccounts: enabledAccounts, willMutateSource: willMutate, validateAccess: validate)
        }
    }

    public func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount], access: WalletAccessSession) async throws {
        _ = try await commit(access: access) { [repository] willMutate, validate in
            try await repository.update(wallet: wallet, removeAccounts: removeAccounts, willMutateSource: willMutate, validateAccess: validate)
        }
    }

    public func delete(wallet: WalletSnapshot, access: WalletAccessSession) async throws {
        try validateManagementAccess(access)
        let token = try await requireReadyStore()
        let prepared = try await repository.prepareDeletion(wallet: wallet)
        _ = try await commit(access: access, readinessToken: token) { [repository] willMutate, validate in
            try await repository.delete(prepared, willMutateSource: willMutate, validateAccess: validate)
        }
    }


    public func previewSession(wallet: WalletSnapshot, access: WalletAccessSession) async throws -> WalletPreviewSession {
        try validateManagementAccess(access)
        let token = try await requireReadyStore()
        let session = try await repository.previewSession(wallet: wallet, access: access, authorityID: authorityID)
        do {
            try readiness.validate(token)
            try Task.checkCancellation()
            return session
        } catch {
            session.invalidate()
            throw error
        }
    }

    public func makeExportChallenge(
        wallet: WalletSnapshot,
        account: WalletAccount? = nil,
        kind: WalletSecretExport
    ) async throws -> WalletAuthenticationChallenge {
        let token = try await requireReadyStore()
        let binding = try await repository.exportBinding(wallet: wallet, account: account, kind: kind)
        try readiness.validate(token)
        try Task.checkCancellation()
        return WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: .secretExport(binding),
            deadline: clock().addingTimeInterval(ExtensionBridge.executionLifetime), clock: clock
        )
    }

    public func takeInitialBackupAuthorization(wallet: WalletSnapshot) -> WalletAuthenticationGrant? {
        guard isStoreReady, let initial = initialBackupBindings.removeValue(forKey: wallet.id),
              clock() < initial.deadline else { return nil }
        let binding = initial.binding
        let challenge = WalletAuthenticationChallenge(
            authorityID: authorityID, purpose: .secretExport(binding),
            deadline: initial.deadline, clock: clock
        )
        let repository = repository
        let authorityID = authorityID
        return challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: {
            initial.access.validateCredentials(for: authorityID) && repository.sourceMatches(binding) ? .current : .changed
        }))
    }

    public func exportPrivateKey(
        wallet: WalletSnapshot,
        account: WalletAccount? = nil,
        authorization: WalletAuthenticationGrant
    ) async throws -> WalletExportedSecret {
        let token = try await requireReadyStore()
        let descriptor = account.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) }
        guard let binding = authorization.consumeExport(
            authorityID: authorityID, walletID: wallet.id, account: descriptor, kind: .privateKey
        ) else { throw Error.keychainAccessFailure }
        let secret = try await repository.exportPrivateKey(wallet: wallet, account: account, binding: binding)
        return try validateExport(secret, readinessToken: token)
    }

    public func exportMnemonic(wallet: WalletSnapshot, authorization: WalletAuthenticationGrant) async throws -> WalletExportedSecret {
        let token = try await requireReadyStore()
        guard let binding = authorization.consumeExport(
            authorityID: authorityID, walletID: wallet.id, account: nil, kind: .mnemonic
        ) else { throw Error.keychainAccessFailure }
        let secret = try await repository.exportMnemonic(wallet: wallet, binding: binding)
        return try validateExport(secret, readinessToken: token)
    }

    private func validateExport(_ secret: WalletExportedSecret, readinessToken: UInt64) throws -> WalletExportedSecret {
        do {
            try Task.checkCancellation()
            try readiness.validate(readinessToken)
            return secret
        } catch {
            secret.invalidate()
            throw error
        }
    }

    nonisolated static func privateKeyImport(from input: String) -> PrivateKeyImport? {
        WalletKeyPreparation.privateKeyImport(from: input)
    }

    private func commit(
        access: WalletAccessSession,
        readinessToken: UInt64? = nil,
        _ operation: @Sendable (_ willMutateSource: @Sendable () throws -> Void, _ validateAccess: @Sendable () throws -> Void) async throws -> WalletRepository.Change
    ) async throws -> WalletSnapshot {
        try validateManagementAccess(access)
        let token: UInt64
        if let readinessToken { token = readinessToken }
        else { token = try await requireReadyStore() }
        try readiness.validate(token)
        let authorityID = authorityID
        let validate: @Sendable () throws -> Void = { [readiness] in
            try Task.checkCancellation()
            try readiness.validate(token)
            guard access.validateCredentials(for: authorityID) else { throw WalletCredentialError.authorizationUnavailable }
        }
        let change: WalletRepository.Change
#if os(iOS) || os(visionOS)
        change = try await approvalVaultHost.performSourceMutation { willMutate in
            try await operation(willMutate, validate)
        }
#else
        change = try await operation({}, validate)
#endif
        if apply(change.state) {
            if reloadAttempt == nil { setLoadState(.ready) }
            reloadMetadata()
        }
        notifications.postMutation()
        return change.wallet
    }

    private func validateManagementAccess(_ access: WalletAccessSession) throws {
        try Task.checkCancellation()
        guard access.validateCredentials(for: authorityID) else { throw WalletCredentialError.authorizationUnavailable }
    }

    @discardableResult
    private func apply(_ state: WalletRepository.State) -> Bool {
        guard state.revision >= repositoryRevision else { return false }
        repositoryRevision = state.revision
        wallets = state.wallets
        hasLoadedSnapshot = true
        let currentWalletIDs = Set(wallets.map(\.id))
        initialBackupBindings = initialBackupBindings.filter {
            currentWalletIDs.contains($0.key) && clock() < $0.value.deadline
        }
        return true
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
        storeChangeRevision &+= 1
        _ = await reloadFromStore()
    }


}

actor WalletRepository {
    enum LoadResult: Sendable {
        case loaded(State)
        case failed(WalletsManager.LoadFailure, revision: UInt64)
        case cancelled
    }

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
        let password: SecretBytes
        let identity: SourceIdentity

        init(walletID: String, data: Data, password: SecretBytes) throws {
            self.walletID = walletID
            self.data = data
            self.password = password
            identity = SourceIdentity(walletID: walletID, sourceDigest: Data(SHA256.hash(data: data)),
                credentialDigest: try password.sha256Digest())
        }

        func invalidate() { password.invalidate() }
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

    struct PreviewIdentity: Equatable, Sendable {
        let walletID: String
        let encryptedMaterialDigest: Data
        let credentialDigest: Data
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
    private struct PreviewReference {
        weak var session: WalletPreviewSession?
    }
    private var previewSessions = [UUID: PreviewReference]()

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

    func load() -> LoadResult {
        do {
            return .loaded(try reload())
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            revision += 1
            let failure = error as? WalletsManager.LoadFailure ?? .unavailable
            return .failed(failure, revision: revision)
        }
    }

    func reload() throws -> State {
        defer { retireStalePreviews() }
        let loaded = try readWallets()
        guard WalletAccountCatalog(wallets: loaded).hasValidAccounts else { throw WalletsManager.LoadFailure.corrupt }
        try Task.checkCancellation()
        wallets = loaded
        return snapshot()
    }

    private func readWallets() throws -> [WalletContainer] {
        try Task.checkCancellation()
        let walletIDs = try keychain.readAllWalletIDs()
        guard Set(walletIDs).count == walletIDs.count else { throw WalletsManager.LoadFailure.corrupt }
        var loaded = [WalletContainer]()
        loaded.reserveCapacity(walletIDs.count)
        for id in walletIDs {
            try Task.checkCancellation()
            guard let data = try keychain.readWalletData(id: id) else { throw WalletsManager.LoadFailure.unavailable }
            guard let wallet = walletContainer(id: id, data: data),
                  wallet.accounts.count == wallet.key.accountCount else { throw WalletsManager.LoadFailure.corrupt }
            loaded.append(wallet)
        }
        return loaded
    }

    private func validateCatalog(replacing wallet: WalletContainer) throws {
        let current = try readWallets()
        let proposed = WalletAccountCatalog(wallets: current.filter { $0.id != wallet.id } + [wallet])
        guard proposed.isValid ||
              (proposed.hasValidAccounts && Set(proposed.accounts).isSubset(of: Set(WalletAccountCatalog(wallets: current).accounts)))
        else { throw WalletsManager.Error.invalidInput }
    }

    func prepareNewWallet(input: String?, inputPassword: String?) async throws -> PreparedCreation {
        guard let password = try keychain.readPasswordSecret() else {
            throw WalletsManager.Error.keychainAccessFailure
        }
        defer { password.invalidate() }
        return try await withTaskCancellationHandler {
            do { return try await WalletKeyPreparation.prepareNewWallet(input: input, inputPassword: inputPassword, password: password) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            password.invalidate()
        }
    }

    func saveNewWallet(_ prepared: PreparedCreation, willMutateSource: @Sendable () throws -> Void,
                      validateAccess: @Sendable () throws -> Void) throws -> Change {
        defer { retireStalePreviews() }
        let wallet = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard let password = try keychain.readPasswordSecret() else { throw WalletsManager.Error.keychainAccessFailure }
            defer { password.invalidate() }
            guard try password.sha256Digest() == prepared.credentialDigest,
                  try keychain.readWalletData(id: prepared.walletID) == nil,
                  let wallet = walletContainer(id: prepared.walletID, data: prepared.data) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            try validateCatalog(replacing: wallet)
            return PreparedWalletSourceMutation(payload: wallet, authorityRemovals: [])
        }, beforeCommit: {
            try validateAccess()
            try willMutateSource()
        }) { wallet in
            try Task.checkCancellation()
            try validateAccess()
            try keychain.saveWallet(id: wallet.id, data: prepared.data)
            wallets.append(wallet)
            return WalletSnapshot(wallet)
        }
        return Change(state: snapshot(), wallet: wallet)
    }

    func prepareDeletion(wallet: WalletSnapshot) async throws -> PreparedDeletion {
        let source = try source(walletID: wallet.id)
        defer { source.invalidate() }
        return try await withTaskCancellationHandler {
            do { return try await WalletKeyPreparation.prepareDeletion(source) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            source.invalidate()
        }
    }

    func delete(_ prepared: PreparedDeletion, willMutateSource: @Sendable () throws -> Void,
                validateAccess: @Sendable () throws -> Void) throws -> Change {
        defer { retireStalePreviews() }
        let removed = try walletSourceMutator.perform(preparing: {
            try Task.checkCancellation()
            guard try sourceIsCurrent(prepared.sourceIdentity) else {
                throw WalletsManager.Error.keychainAccessFailure
            }
            return PreparedWalletSourceMutation(payload: prepared.wallet, authorityRemovals: [.wallet(id: prepared.wallet.id)])
        }, beforeCommit: {
            try validateAccess()
            try willMutateSource()
        }) { wallet in
            try Task.checkCancellation()
            try validateAccess()
            try keychain.removeWallet(id: wallet.id)
            wallets.removeAll { $0.id == wallet.id }
            metadataMutations.removeWallet(wallet)
            return wallet
        }
        return Change(state: snapshot(), wallet: removed)
    }

    func update(wallet: WalletSnapshot, enabledAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void,
                validateAccess: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, willMutateSource: willMutateSource, validateAccess: validateAccess) { current in
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

    func update(wallet: WalletSnapshot, removeAccounts: [WalletAccount], willMutateSource: @Sendable () throws -> Void,
                validateAccess: @Sendable () throws -> Void) throws -> Change {
        try update(wallet: wallet, willMutateSource: willMutateSource, validateAccess: validateAccess) { current in
            let removed = Set(removeAccounts.map(\.previewAccountKey))
            return current.accounts.filter { !removed.contains($0.previewAccountKey) }
        }
    }

    private func update(wallet: WalletSnapshot, willMutateSource: @Sendable () throws -> Void,
                        validateAccess: @Sendable () throws -> Void,
                        accounts: (WalletContainer) throws -> [WalletAccount]) throws -> Change {
        defer { retireStalePreviews() }
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
            try validateCatalog(replacing: current)
            let retained = Set(replacement.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) })
            let removed = originalAccounts.filter { !retained.contains(WalletAccountDescriptor(walletID: wallet.id, account: $0)) }
            let removals: [WalletAuthorityRemoval] = removed.isEmpty ? [] : [.accounts(Set(removed.map {
                WalletAccountDescriptor(walletID: wallet.id, account: $0)
            }))]
            return PreparedWalletSourceMutation(
                payload: PreparedUpdate(wallet: current, data: data, removedAccounts: removed),
                authorityRemovals: removals
            )
        }, beforeCommit: {
            try validateAccess()
            try willMutateSource()
        }) { prepared in
            try Task.checkCancellation()
            try validateAccess()
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
        let source = try source(walletID: wallet.id, account: account)
        defer { source.invalidate() }
        let identity = source.identity
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

    func exportPrivateKey(wallet: WalletSnapshot, account: WalletAccount?, binding: WalletSecretExportBinding) async throws -> WalletExportedSecret {
        let source = try source(walletID: wallet.id)
        defer { source.invalidate() }
        let result = try await withTaskCancellationHandler {
            do { return try await WalletKeyPreparation.exportPrivateKey(source, account: account, binding: binding) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            source.invalidate()
        }
        var transferred = false
        defer { if !transferred { result.value.invalidate() } }
        guard try sourceIsCurrent(result.identity) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        transferred = true
        return result.value
    }

    func exportMnemonic(wallet: WalletSnapshot, binding: WalletSecretExportBinding) async throws -> WalletExportedSecret {
        let source = try source(walletID: wallet.id)
        defer { source.invalidate() }
        let result = try await withTaskCancellationHandler {
            do { return try await WalletKeyPreparation.exportMnemonic(source, binding: binding) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            source.invalidate()
        }
        var transferred = false
        defer { if !transferred { result.value.invalidate() } }
        guard try sourceIsCurrent(result.identity) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        transferred = true
        return result.value
    }

    func sign(_ operation: ApprovedWalletSigningOperation) async -> SigningAttempt {
        let prepared: PreparedSigningKey
        do {
            let source = try source(walletID: operation.approvedAccount.walletID, account: operation.approvedAccount.account)
            defer { source.invalidate() }
            prepared = await withTaskCancellationHandler {
                await prepareSigningKey(source, account: operation.approvedAccount.account)
            } onCancel: {
                source.invalidate()
            }
        } catch {
            return SigningAttempt(sourceIdentity: nil, result: .failure(.authorizationUnavailable))
        }
        let identity = prepared.sourceIdentity
        switch prepared.result {
        case .failure(let failure):
            return SigningAttempt(sourceIdentity: identity, result: .failure(failure))
        case .success(let key):
            defer { key.invalidate() }
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
            do { try Task.checkCancellation() }
            catch { key.invalidate(); throw error }
            result = .success(key)
        } catch is CancellationError {
            result = .failure(.authorizationUnavailable)
        } catch WalletKeyStoreError.accountNotFound {
            result = .failure(.authorizationUnavailable)
        } catch {
            result = .failure(Task.isCancelled ? .authorizationUnavailable : .failedToSign)
        }
        return PreparedSigningKey(sourceIdentity: identity, result: result)
    }

    func previewSession(wallet: WalletSnapshot, access: WalletAccessSession, authorityID: UUID) async throws -> WalletPreviewSession {
        let source = try source(walletID: wallet.id)
        defer { source.invalidate() }
        guard let key = WalletStoredKey.importJSON(json: source.data, requireCompleteAccounts: true), key.isMnemonic,
              let material = key.encryptedMaterialDigest else { throw WalletsManager.Error.keychainAccessFailure }
        let identity = PreviewIdentity(walletID: wallet.id, encryptedMaterialDigest: material,
            credentialDigest: source.identity.credentialDigest)
        let result = try await withTaskCancellationHandler {
            do { return try await WalletKeyPreparation.previewWallet(source) }
            catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            source.invalidate()
        }
        var transferred = false
        defer { if !transferred { result.value.invalidate() } }
        guard access.validateCredentials(for: authorityID), try sourceIsCurrent(identity) else {
            throw WalletCredentialError.authorizationUnavailable
        }
        try Task.checkCancellation()
        let session = WalletPreviewSession(wallet: result.value, access: access, authorityID: authorityID,
            isCurrent: { [repository = self] in
                access.validateCredentials(for: authorityID) && (try? repository.sourceIsCurrent(identity)) == true
            })
        previewSessions = previewSessions.filter { $0.value.session?.isActive == true }
        previewSessions[UUID()] = PreviewReference(session: session)
        transferred = true
        return session
    }

#if os(iOS) || os(visionOS)
    func safariApprovalSourceSnapshot() throws -> SafariApprovalSourceSnapshot? {
        guard let password = try keychain.readPasswordSecret() else { return nil }
        var transferred = false
        defer { if !transferred { password.invalidate() } }
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
        transferred = true
        return SafariApprovalSourceSnapshot(catalog: catalog, password: password, wallets: records)
    }
#endif

    private func source(walletID: String, account: WalletAccount? = nil) throws -> Source {
        guard let data = try keychain.readWalletData(id: walletID) else { throw WalletsManager.Error.keychainAccessFailure }
        if let account, walletContainer(id: walletID, data: data)?.hasAccountMatching(account) != true {
            throw WalletKeyStoreError.accountNotFound
        }
        guard let password = try keychain.readPasswordSecret() else { throw WalletsManager.Error.keychainAccessFailure }
        return try Source(walletID: walletID, data: data, password: password)
    }

    nonisolated func sourceIsCurrent(_ identity: SourceIdentity) throws -> Bool {
        guard let data = try keychain.readWalletData(id: identity.walletID),
              Data(SHA256.hash(data: data)) == identity.sourceDigest else { return false }
        guard let password = try keychain.readPasswordSecret() else { return false }
        defer { password.invalidate() }
        return try password.sha256Digest() == identity.credentialDigest
    }

    nonisolated func sourceIsCurrent(_ identity: PreviewIdentity) throws -> Bool {
        guard let data = try keychain.readWalletData(id: identity.walletID),
              let key = WalletStoredKey.importJSON(json: data, requireCompleteAccounts: true), key.isMnemonic,
              key.encryptedMaterialDigest == identity.encryptedMaterialDigest,
              let password = try keychain.readPasswordSecret() else { return false }
        defer { password.invalidate() }
        return try password.sha256Digest() == identity.credentialDigest
    }

    private func snapshot() -> State {
        revision += 1
        return State(revision: revision, wallets: wallets.map(WalletSnapshot.init))
    }

    private func retireStalePreviews() {
        previewSessions = previewSessions.filter { $0.value.session?.revalidateSource() == true }
    }

    private func walletContainer(id: String, data: Data) -> WalletContainer? {
        guard let key = WalletStoredKey.importJSON(json: data, requireCompleteAccounts: true) else { return nil }
        return WalletContainer(id: id, key: key)
    }
}

public actor WalletPreviewSession {
    private nonisolated let wallet: Mutex<WalletHDWallet?>
    private let deriveAccounts: @Sendable (WalletHDWallet, Int) throws -> [WalletAccount]
    private nonisolated let isCurrent: @Sendable () -> Bool
    private nonisolated let access: WalletAccessSession?
    private nonisolated let invalidationObserver = Mutex<UUID?>(nil)

    init(
        wallet: WalletHDWallet,
        access: WalletAccessSession? = nil,
        authorityID: UUID? = nil,
        isCurrent: @escaping @Sendable () -> Bool = { true },
        deriveAccounts: @escaping @Sendable (WalletHDWallet, Int) throws -> [WalletAccount] = {
            try WalletAccountDerivation.previewAccounts(hdWallet: $0, page: $1, coin: nil)
        }
    ) {
        self.wallet = Mutex(wallet)
        self.deriveAccounts = deriveAccounts
        self.isCurrent = isCurrent
        self.access = access
        if let access, let authorityID {
            let observer = access.observeInvalidation(for: authorityID) { [weak self] in self?.invalidate() }
            invalidationObserver.withLock { $0 = observer }
        }
    }

    public func previewAccounts(page: Int) throws -> [WalletAccount] {
        try Task.checkCancellation()
        guard isCurrent() else { invalidate(); throw CancellationError() }
        guard let wallet = wallet.withLock({ $0 }) else { throw CancellationError() }
        let accounts: [WalletAccount]
        do { accounts = try deriveAccounts(wallet, page) }
        catch {
            guard self.wallet.withLock({ $0 != nil }), isCurrent(), !Task.isCancelled else {
                invalidate()
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        guard isCurrent(), self.wallet.withLock({ $0 != nil }) else { invalidate(); throw CancellationError() }
        return accounts
    }

    nonisolated var isActive: Bool { wallet.withLock { $0 != nil } }

    @discardableResult
    nonisolated func revalidateSource() -> Bool {
        guard isActive, isCurrent() else { invalidate(); return false }
        return isActive
    }

    public nonisolated func invalidate() {
        let retired = wallet.withLock { wallet in
            defer { wallet = nil }
            return wallet
        }
        retired?.invalidate()
        let observer = invalidationObserver.withLock { observer in
            defer { observer = nil }
            return observer
        }
        if let observer { access?.removeInvalidationObserver(observer) }
    }

    deinit { invalidate() }
}

private enum WalletKeyPreparation {
    private static let solanaBase58SecretKeyLengthRange = 32...88
    private static let maxSolanaSecretKeyByteArrayStringLength = 1024
    private static let base58Values = Dictionary(uniqueKeysWithValues:
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8.enumerated().map { ($0.element, $0.offset) }
    )
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
    static func prepareNewWallet(input: String?, inputPassword: String?, password: SecretBytes) async throws -> WalletRepository.PreparedCreation {
        try Task.checkCancellation()
        let wallet: WalletContainer
        if let input {
            guard WalletImportLimits.acceptsInput(input) else { throw WalletImportError.limitExceeded }
            let trimmed = input.singleSpaced
            if WalletCrypto.isValidMnemonic(mnemonic: trimmed) {
                wallet = try importMnemonic(trimmed, name: "", encryptPassword: password)
            } else if let imported = privateKeyImport(from: trimmed) {
                defer { imported.privateKey.invalidate() }
                wallet = try importPrivateKey(imported.privateKey, name: "", password: password, coin: imported.coin)
            } else if input.maybeJSON, let inputPassword, let data = input.data(using: .utf8) {
                wallet = try importJSON(data, name: "", password: inputPassword, newPassword: password, coin: defaultCoin)
            } else {
                throw WalletsManager.Error.invalidInput
            }
        } else {
            wallet = try createWallet(name: "", password: password)
        }
        guard let data = wallet.key.exportJSON() else { throw WalletKeyStoreError.invalidKey }
        try Task.checkCancellation()
        return WalletRepository.PreparedCreation(walletID: wallet.id, data: data,
            credentialDigest: try password.sha256Digest())
    }

    @concurrent
    static func prepareDeletion(_ source: WalletRepository.Source) async throws -> WalletRepository.PreparedDeletion {
        try Task.checkCancellation()
        guard let key = WalletStoredKey.importJSON(json: source.data, requireCompleteAccounts: true),
              let secret = key.decryptPrivateKey(password: source.password) else { throw WalletKeyStoreError.invalidKey }
        defer { secret.invalidate() }
        try Task.checkCancellation()
        return WalletRepository.PreparedDeletion(wallet: WalletSnapshot(WalletContainer(id: source.walletID, key: key)),
            sourceIdentity: source.identity)
    }

    @concurrent
    static func exportPrivateKey(
        _ source: WalletRepository.Source,
        account: WalletAccount?,
        binding: WalletSecretExportBinding
    ) async throws -> (value: WalletExportedSecret, identity: WalletRepository.SourceIdentity) {
        let identity = source.identity
        guard identity.matches(binding) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let account = account ?? wallet.accounts.first else { throw WalletKeyStoreError.accountNotFound }
        guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        let key = try wallet.privateKey(password: source.password, account: account)
        defer { key.invalidate() }
        try Task.checkCancellation()
        return (try WalletExportedSecret.privateKey(key, coin: account.coin), identity)
    }

    @concurrent
    static func exportMnemonic(
        _ source: WalletRepository.Source,
        binding: WalletSecretExportBinding
    ) async throws -> (value: WalletExportedSecret, identity: WalletRepository.SourceIdentity) {
        let identity = source.identity
        guard identity.matches(binding) else { throw WalletsManager.Error.keychainAccessFailure }
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let mnemonic = wallet.key.decryptMnemonicSecret(password: source.password) else { throw WalletKeyStoreError.invalidPassword }
        var transferred = false
        defer { if !transferred { mnemonic.invalidate() } }
        try Task.checkCancellation()
        transferred = true
        return (WalletExportedSecret(bytes: mnemonic), identity)
    }

    @concurrent
    static func privateKey(_ source: WalletRepository.Source, account: WalletAccount) async throws -> WalletPrivateKey {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        let key = try wallet.privateKey(password: source.password, account: account)
        do { try Task.checkCancellation() }
        catch { key.invalidate(); throw error }
        return key
    }

    @concurrent
    static func previewWallet(_ source: WalletRepository.Source) async throws -> (value: WalletHDWallet, identity: WalletRepository.SourceIdentity) {
        try Task.checkCancellation()
        let wallet = try wallet(source)
        guard let hdWallet = wallet.key.wallet(password: source.password) else { throw WalletsManager.Error.keychainAccessFailure }
        do { try Task.checkCancellation() }
        catch { hdWallet.invalidate(); throw error }
        return (hdWallet, source.identity)
    }

    private static func wallet(_ source: WalletRepository.Source) throws -> WalletContainer {
        guard let key = WalletStoredKey.importJSON(json: source.data, requireCompleteAccounts: true) else { throw WalletKeyStoreError.invalidKey }
        return WalletContainer(id: source.walletID, key: key)
    }
    private static func createWallet(name: String, password: SecretBytes) throws -> WalletContainer {
        guard let key = WalletStoredKey(name: name, password: password) else { throw WalletKeyStoreError.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: password)
        return wallet
    }

    private static func importJSON(_ json: Data, name: String, password: String, newPassword: SecretBytes, coin: WalletCoin) throws -> WalletContainer {
        let key = try WalletStoredKey.importUserJSON(json: json)
        let inputPassword = SecretBytes(utf8: password)
        defer { inputPassword.invalidate() }
        guard let data = key.decryptPrivateKey(password: inputPassword) else { throw WalletKeyStoreError.invalidPassword }
        defer { data.invalidate() }
        if data.count != 32, try data.withUnsafeBytes({ BIP39.isValidMnemonic($0) }) {
            return try importMnemonic(data, name: name, encryptPassword: newPassword)
        }
        guard let privateKey = WalletPrivateKey(taking: data) else { throw WalletKeyStoreError.invalidKey }
        defer { privateKey.invalidate() }
        return try importPrivateKey(privateKey, name: name, password: newPassword, coin: coin)
    }

    private static func importPrivateKey(_ privateKey: WalletPrivateKey, name: String, password: SecretBytes, coin: WalletCoin) throws -> WalletContainer {
        guard let newKey = WalletStoredKey.importPrivateKey(privateKey: privateKey, name: name, password: password, coin: coin)
        else { throw WalletKeyStoreError.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        return wallet
    }

    private static func importMnemonic(_ mnemonic: String, name: String, encryptPassword: SecretBytes) throws -> WalletContainer {
        let secret = SecretBytes(utf8: mnemonic)
        defer { secret.invalidate() }
        return try importMnemonic(secret, name: name, encryptPassword: encryptPassword)
    }

    private static func importMnemonic(_ mnemonic: SecretBytes, name: String, encryptPassword: SecretBytes) throws -> WalletContainer {
        guard let key = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: encryptPassword, coin: defaultCoin) else { throw WalletKeyStoreError.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: encryptPassword)
        return wallet
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
        guard var privateKeyData = WalletCrypto.hexData(string: input) else { return nil }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        guard WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .ethereum) else { return nil }
        return WalletPrivateKey(data: privateKeyData)
    }

    private static func solanaPrivateKeyImport(from input: String) -> WalletPrivateKey? {
        if solanaBase58SecretKeyLengthRange.contains(input.count),
           let secretKey = decodedSolanaSecretKey(input) {
            return solanaPrivateKeyImport(taking: secretKey)
        }

        if let secretKey = solanaSecretKeyBytes(fromByteArrayString: input) {
            return solanaPrivateKeyImport(taking: secretKey)
        }

        return nil
    }

    private static func decodedSolanaSecretKey(_ input: String) -> SecretBytes? {
        guard input.utf8.count <= solanaBase58SecretKeyLengthRange.upperBound else { return nil }
        let leadingZeros = input.utf8.prefix(while: { $0 == 49 }).count
        var length = 0
        guard let decoded = try? SecretBytes(count: input.utf8.count, initialize: { output in
            output.initializeMemory(as: UInt8.self, repeating: 0)
            for byte in input.utf8 {
                guard let value = base58Values[byte] else { throw WalletKeyStoreError.invalidKey }
                var carry = value
                for index in 0..<length {
                    carry += Int(output[index]) * 58
                    output[index] = UInt8(carry & 0xff)
                    carry >>= 8
                }
                while carry > 0 {
                    output[length] = UInt8(carry & 0xff)
                    length += 1
                    carry >>= 8
                }
            }
        }) else { return nil }
        defer { decoded.invalidate() }
        let count = leadingZeros + length
        guard count == 32 || count == 64 else { return nil }
        return try? decoded.withUnsafeBytes { bytes in
            SecretBytes(count: count) { output in
                output.initializeMemory(as: UInt8.self, repeating: 0)
                for index in 0..<length { output[leadingZeros + index] = bytes[length - index - 1] }
            }
        }
    }

    private static func solanaSecretKeyBytes(fromByteArrayString input: String) -> SecretBytes? {
        guard input.hasPrefix("["),
              input.hasSuffix("]"),
              input.count <= maxSolanaSecretKeyByteArrayStringLength,
              var inputData = input.data(using: .utf8) else { return nil }
        defer { inputData.resetBytes(in: 0..<inputData.count) }
        guard let jsonObject = try? JSONSerialization.jsonObject(with: inputData),
              let values = jsonObject as? [Any],
              values.count == 32 || values.count == 64
        else { return nil }

        return try? SecretBytes(count: values.count) { output in
            for (index, value) in values.enumerated() {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    throw WalletKeyStoreError.invalidKey
                }
                let byteValue = number.doubleValue
                guard byteValue.rounded() == byteValue, byteValue >= Double(UInt8.min), byteValue <= Double(UInt8.max) else {
                    throw WalletKeyStoreError.invalidKey
                }
                output[index] = UInt8(byteValue)
            }
        }
    }

    private static func solanaPrivateKeyImport(taking secretKey: SecretBytes) -> WalletPrivateKey? {
        switch secretKey.count {
        case 32:
            return WalletPrivateKey(taking: secretKey)
        case 64:
            defer { secretKey.invalidate() }
            guard let seed = try? secretKey.copy(in: 0..<32),
                  let privateKey = WalletPrivateKey(taking: seed) else { return nil }
            let expectedPublicKey = privateKey.publicKeyData(coin: .solana)
            guard (try? secretKey.withUnsafeBytes({ expectedPublicKey.elementsEqual($0.suffix(32)) })) == true else {
                privateKey.invalidate()
                return nil
            }
            return privateKey
        default:
            secretKey.invalidate()
            return nil
        }
    }

    private static func addMnemonicAccounts(to wallet: WalletContainer,
                                     password: SecretBytes,
                                     coinDerivations: [(coin: WalletCoin, derivation: WalletDerivation)]) throws {
        guard wallet.isMnemonic else { return }

        let hdWallet = wallet.key.wallet(password: password)
        defer { hdWallet?.invalidate() }
        for (coin, derivation) in coinDerivations
        where !wallet.accounts.contains(where: { $0.coin == coin && $0.derivation == derivation }) {
            guard wallet.key.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: hdWallet) != nil else {
                throw WalletKeyStoreError.invalidPassword
            }
        }
    }

    private static func addDefaultMnemonicAccounts(to wallet: WalletContainer, password: SecretBytes) throws {
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

