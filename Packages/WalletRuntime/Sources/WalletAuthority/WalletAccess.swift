import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation
import Synchronization

enum WalletUnlockResult: Sendable {
    case unlocked(catalog: WalletReviewCatalog, preparation: WalletSigningPreparation)
    case canceled
    case unavailable
}

final class WalletExecutionLease: Sendable {
    private let releaseOperation: Mutex<(@Sendable () -> Void)?>

    init(release: @escaping @Sendable () -> Void) {
        releaseOperation = Mutex(release)
    }

    func release() {
        let operation = releaseOperation.withLock { operation in
            let retained = operation
            operation = nil
            return retained
        }
        operation?()
    }

    deinit {
        release()
    }
}

enum WalletSigningCommit: Sendable {
    case native
    case vault(acquire: @MainActor @Sendable () async -> WalletExecutionLease?)

    enum Outcome: Sendable {
        case readyWithoutLease
        case lease(WalletExecutionLease)
        case unavailable

        func releaseLease() {
            if case .lease(let lease) = self { lease.release() }
        }
    }
}

protocol WalletSigning: AnyObject, Sendable {
    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure>
    func invalidate()
}

protocol WalletSigningSource: AnyObject, Sendable {
    var approvedAccount: WalletAccountDescriptor { get }
    var commit: WalletSigningCommit { get }

    func isCurrent() -> Bool

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure>

    // Cleanup is idempotent; retirement preserves the separate commit capability.
    func retireSigningMaterial()
    func invalidate()
}

enum WalletSigningFailure: Error, Equatable, Sendable {
    case authorizationUnavailable
    case invalidTransaction
    case failedToSign
}

enum WalletSigningOutput: Sendable {
    case response(ApprovedCompletion)
    case broadcast(PreparedBroadcast)

    var executionID: UUID {
        switch self {
        case .response(let value): value.executionID
        case .broadcast(let value): value.executionID
        }
    }

}

struct WalletSigningScope: Equatable, Sendable {
    let handle: RequestHandle
    let approvedAccount: WalletAccountDescriptor
    let signingDeadline: Date
}

extension WalletSigningScope {
    init?(permit: ExtensionBridge.ApprovedExecutionPermit) {
        guard case .signing(let approvedAccount, let payload) = permit.approval.kind,
              permit.request.id == permit.handle.id,
              permit.signingDeadline.timeIntervalSince1970.isFinite,
              approvedAccount.isValid,
              permit.request.authorizedAccount == approvedAccount,
              approvedAccount.coin.correspondingInpageProvider == permit.request.provider,
              payload.coin == approvedAccount.coin else { return nil }
        self.init(
            handle: permit.handle, approvedAccount: approvedAccount,
            signingDeadline: permit.signingDeadline
        )
    }
}

struct ApprovedCompletion: Sendable {
    let executionID: UUID
    private let value: ResponseToExtension

    private init(permit: ExtensionBridge.ApprovedExecutionPermit, response: ResponseToExtension) {
        executionID = permit.executionID
        value = response.markingApprovalCommitted()
    }

    func response(for permit: ExtensionBridge.ApprovedExecutionPermit) -> ResponseToExtension? {
        executionID == permit.executionID ? value : nil
    }

    static func failure(
        _ error: ProviderResponseError,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting else { return nil }
        return ApprovedCompletion(
            permit: permit, response: ResponseToExtension(for: permit.request, payload: .error(error))
        )
    }

    static func accountSelection(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        fallbackNetwork: () -> EthereumNetwork?
    ) -> ApprovedCompletion? {
        guard permit.isExecuting,
              case .accountSelection(let action, let selection) = permit.approval.kind else { return nil }
        return ApprovedCompletion(
            permit: permit,
            response: DappRequestProcessor.accountSelectionResponse(
                request: permit.request, action: action, selection: selection,
                fallbackNetwork: fallbackNetwork
            )
        )
    }

    fileprivate init(permit: ExtensionBridge.ApprovedExecutionPermit, result: ResponseToExtension.Result) {
        self.init(permit: permit, response: ResponseToExtension(for: permit.request, payload: .result(result)))
    }

    static func chainAdded(
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard permit.isExecuting,
              case .addEthereumChain(let action) = permit.approval.kind,
              case .ethereum(let body) = permit.request.body,
              body.method == .addEthereumChain,
              let chainID = Int(hexString: action.chainToAdd.chainId), chainID > 0 else { return nil }
        return ApprovedCompletion(
            permit: permit,
            response: ResponseToExtension(
                for: permit.request, payload: .result(.null),
                mutation: .ethereumChain(String.hex(chainID, withPrefix: true))
            )
        )
    }

    fileprivate static func broadcastResponse(
        _ response: ResponseToExtension,
        permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion {
        ApprovedCompletion(permit: permit, response: response)
    }
}

struct PreparedBroadcast: Sendable {
    enum Transaction: Sendable {
        case ethereum(String, String, ResolvedEthereumNetwork)
        case solana(String, String, Solana.Cluster, SolanaRPCEndpoint, Solana.PreparedSendOptions)
    }

    let executionID: UUID
    let transaction: Transaction
    private let identity = UUID()

    fileprivate init(permit: ExtensionBridge.ApprovedExecutionPermit, transaction: Transaction) {
        executionID = permit.executionID
        self.transaction = transaction
    }

    func hasSameIdentity(as other: Self) -> Bool {
        executionID == other.executionID && identity == other.identity
    }

    func recoveryCompletion(
        for permit: ExtensionBridge.ApprovedExecutionPermit
    ) -> ApprovedCompletion? {
        guard executionID == permit.executionID else { return nil }
        let response: ResponseToExtension
        switch transaction {
        case .ethereum(_, let hash, _):
            response = EthereumDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: permit.request, transactionHash: hash
            )
        case .solana(_, let signature, _, _, _):
            response = SolanaDappRequestProcessor.transactionSubmissionUnknownResponse(
                to: permit.request, signature: signature
            )
        }
        return .broadcastResponse(response, permit: permit)
    }

    @MainActor
    func dispatch(
        using dispatch: ExtensionBridge.BroadcastDispatchPermit,
        broadcaster: any SignedTransactionBroadcasting
    ) async -> ApprovedCompletion? {
        let permit = dispatch.approvedPermit
        guard executionID == permit.executionID,
              executionID == dispatch.broadcast.executionID,
              identity == dispatch.broadcast.identity,
              dispatch.consume(), let recovery = recoveryCompletion(for: permit),
              let recoveryResponse = recovery.response(for: permit) else { return nil }
        let response: ResponseToExtension
        switch transaction {
        case .ethereum(let signed, let expectedHash, let network):
            guard !Task.isCancelled else { return recovery }
            AuthorityExecutionHooks.emit(.init(.broadcastDispatch, context: .init(permit: permit)))
            let outcome = await AuthorityExecutionContext.$current.withValue(.init(permit: permit)) {
                await broadcaster.broadcast(.ethereum(
                    signedTransaction: signed, expectedHash: expectedHash, network: network
                ))
            }
            guard let result = outcome.ethereumResult else { return recovery }
            response = EthereumDappRequestProcessor.transactionBroadcastResponse(
                to: permit.request, expectedHash: expectedHash,
                recoveryResponse: recoveryResponse, result: result
            )
        case .solana(let signed, let expectedSignature, let cluster, let endpoint, let options):
            guard !Task.isCancelled else { return recovery }
            AuthorityExecutionHooks.emit(.init(.broadcastDispatch, context: .init(permit: permit)))
            let outcome = await AuthorityExecutionContext.$current.withValue(.init(permit: permit)) {
                await broadcaster.broadcast(.solana(
                    signedTransaction: signed, expectedSignature: expectedSignature,
                    cluster: cluster, endpoint: endpoint, options: options
                ))
            }
            guard let result = outcome.solanaResult else { return recovery }
            response = SolanaDappRequestProcessor.transactionBroadcastResponse(
                to: permit.request, expectedSignature: expectedSignature,
                recoveryResponse: recoveryResponse, result: result
            )
        }
        return .broadcastResponse(response, permit: permit)
    }
}

struct ApprovedWalletSigningOperation: Sendable {

    enum Payload: Sendable {
        case signature(SignaturePayload)
        case ethereumTransaction(Transaction, ResolvedEthereumNetwork)
        case solanaLegacyBroadcast(
            Solana.PreparedLegacySignAndSendTransaction,
            Solana.PreparedSendOptions,
            Solana.Cluster,
            SolanaRPCEndpoint
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.PreparedSendOptions,
            Solana.Cluster,
            SolanaRPCEndpoint
        )

        var coin: WalletCoin {
            switch self {
            case .signature(let payload):
                return payload.coin
            case .ethereumTransaction:
                return .ethereum
            case .solanaLegacyBroadcast, .solanaSerializedBroadcast:
                return .solana
            }
        }

        var isEthereumTransaction: Bool {
            if case .ethereumTransaction = self { return true }
            return false
        }
    }

    let scope: WalletSigningScope
    let payload: Payload
    fileprivate let permit: ExtensionBridge.ApprovedExecutionPermit

    var handle: RequestHandle { scope.handle }
    var approvedAccount: WalletAccountDescriptor { scope.approvedAccount }
    var deadline: Date { scope.signingDeadline }
    var isAuthorizedToSign: Bool { permit.isSigningAuthorized }

    fileprivate init?(
        permit: ExtensionBridge.ApprovedExecutionPermit,
        scope: WalletSigningScope
    ) {
        guard case .signing(_, let payload) = permit.approval.kind,
              permit.issueSigningOperation() else { return nil }
        self.permit = permit
        self.scope = scope
        self.payload = payload
    }

    fileprivate func beginAttempt() -> Bool { permit.beginSigningAttempt() }
    fileprivate func finishAttempt() { permit.finishSigningAttempt() }
    fileprivate var isAttemptCurrent: Bool { permit.isSigningAttemptCurrent }

    func withCurrentAuthority<Value>(_ operation: () throws -> Value) rethrows -> Value? {
        try permit.withCurrentAuthority(operation)
    }

    func sign(
        with privateKey: WalletPrivateKey,
        validatingSource: () -> Bool = { true }
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        permit.withCurrentAuthority {
            guard !Task.isCancelled, validatingSource() else {
                return .failure(.authorizationUnavailable)
            }
            let result = performSigning(with: privateKey)
            let output: WalletSigningOutput?
            if case .success(let value) = result { output = value }
            else { output = nil }
            AuthorityExecutionHooks.emit(.init(.signingFinished, succeeded: output != nil, signingOutput: output))
            return result
        } ?? .failure(.authorizationUnavailable)
    }

    private func performSigning(with privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard !Task.isCancelled, permit.consumeSigningUse() else {
            return .failure(.authorizationUnavailable)
        }
        AuthorityExecutionHooks.emit(.init(.signingStarted))
        switch payload {
        case .signature(let payload):
            return signSignature(payload, with: privateKey)
        case .ethereumTransaction(let transaction, let network):
            switch EthereumSigner.signedTransaction(
                transaction: transaction, privateKey: privateKey, network: network.network
            ) {
            case .failure(.invalidTransaction):
                return .failure(.invalidTransaction)
            case .failure(.failedToSign):
                return .failure(.failedToSign)
            case .success(let signed):
                guard let hash = EthereumSigner.transactionHash(signedTransaction: signed)
                else { return .failure(.invalidTransaction) }
                return .success(.broadcast(.init(
                    permit: permit, transaction: .ethereum(signed, hash, network)
                )))
            }
        case .solanaLegacyBroadcast(let transaction, let options, let cluster, let endpoint):
            return solanaTransactionOutput(
                SolanaSigner.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction, privateKey: privateKey
                ), options: options, cluster: cluster, endpoint: endpoint
            )
        case .solanaSerializedBroadcast(let transaction, let options, let cluster, let endpoint):
            return solanaTransactionOutput(
                SolanaSigner.signedTransactionForSignAndSend(
                    preparedSerializedTransaction: transaction, privateKey: privateKey
                ), options: options, cluster: cluster, endpoint: endpoint
            )
        }
    }

    private func signSignature(
        _ payload: SignaturePayload,
        with privateKey: WalletPrivateKey
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        switch payload {
        case .ethereumPersonalMessage(let data):
            guard let signature = try? EthereumSigner.signPersonalMessage(data: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return signatureOutput(.string(signature))
        case .ethereumTypedData(let data):
            guard let signature = try? EthereumSigner.sign(typedData: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return signatureOutput(.string(signature))
        case .solanaMessage(let data):
            return solanaSignature(data, privateKey: privateKey)
        case .solanaTransaction(let transaction):
            return solanaSignature(transaction.messageData, privateKey: privateKey)
        case .solanaTransactions(let transactions):
            guard let signatures = SolanaSigner.sign(
                messageDataList: transactions.map(\.messageData), privateKey: privateKey
            ), signatures.count == transactions.count else { return .failure(.failedToSign) }
            return signatureOutput(.strings(signatures))
        }
    }

    private func solanaSignature(_ data: Data, privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signature = SolanaSigner.sign(messageData: data, privateKey: privateKey)
        else { return .failure(.failedToSign) }
        return signatureOutput(.string(signature))
    }

    private func signatureOutput(_ result: ResponseToExtension.Result) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        .success(.response(.init(permit: permit, result: result)))
    }

    private func solanaTransactionOutput(
        _ signedTransaction: String?,
        options: Solana.PreparedSendOptions,
        cluster: Solana.Cluster,
        endpoint: SolanaRPCEndpoint
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signedTransaction,
              let signature = SolanaSigner.transactionSignature(signedTransaction: signedTransaction)
        else { return .failure(.invalidTransaction) }
        return .success(.broadcast(.init(
            permit: permit, transaction: .solana(signedTransaction, signature, cluster, endpoint, options)
        )))
    }
}

private final class RepositoryWalletSigningSource: WalletSigningSource {
    private enum State: Sendable {
        case pending
        case source(WalletRepository.SourceIdentity)
        case invalidated
    }

    let approvedAccount: WalletAccountDescriptor
    let commit = WalletSigningCommit.native
    private let repository: WalletRepository
    private let state = Mutex(State.pending)

    init(approvedAccount: WalletAccountDescriptor, repository: WalletRepository) {
        self.approvedAccount = approvedAccount
        self.repository = repository
    }

    func isCurrent() -> Bool {
        switch state.withLock({ $0 }) {
        case .pending: return approvedAccount.isValid
        case .source(let source): return (try? repository.sourceIsCurrent(source)) == true
        case .invalidated: return false
        }
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount,
              operation.isAuthorizedToSign, !Task.isCancelled else {
            return .failure(.authorizationUnavailable)
        }
        let attempt = await repository.sign(operation)
        let retained = state.withLock { state in
            guard case .pending = state else { return false }
            if let source = attempt.sourceIdentity { state = .source(source) }
            return true
        }
        guard retained, !Task.isCancelled else { return .failure(.authorizationUnavailable) }
        return attempt.result
    }

    func invalidate() {
        state.withLock { $0 = .invalidated }
    }

    func retireSigningMaterial() {
        invalidate()
    }
}

enum WalletSnapshotValidation {

    static func wallets(
        catalog: WalletAccountCatalog,
        walletRecords: [(id: String, data: Data)]
    ) -> [WalletContainer]? {
        var wallets = [WalletContainer]()
        wallets.reserveCapacity(walletRecords.count)
        guard Set(walletRecords.map(\.id)).count == walletRecords.count
        else { return nil }
        for record in walletRecords {
            guard let key = WalletStoredKey.importJSON(json: record.data, requireCompleteAccounts: true)
            else { return nil }
            let wallet = WalletContainer(id: record.id, key: key)
            guard wallet.accounts.count == wallet.key.accountCount else {
                return nil
            }
            wallets.append(wallet)
        }
        guard WalletAccountCatalog(wallets: wallets).accounts == catalog.accounts else {
            return nil
        }

        return wallets
    }

    static func visitOwnedAccountKeys(
        _ wallet: WalletContainer,
        password: SecretBytes,
        checkCancellation: () throws -> Void = {},
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        try checkCancellation()
        let accounts = wallet.accounts
        guard accounts.count == wallet.key.accountCount,
              let secret = wallet.key.decryptPrivateKey(password: password)
        else { return false }
        defer { secret.invalidate() }
        try checkCancellation()

        if wallet.isMnemonic {
            return try visitMnemonicAccountKeys(
                accounts,
                secret: secret,
                checkCancellation: checkCancellation,
                visit: visit
            )
        }
        return try visitPrivateKeyAccounts(
            accounts,
            secret: secret,
            checkCancellation: checkCancellation,
            visit: visit
        )
    }

    private static func visitMnemonicAccountKeys(
        _ accounts: [WalletAccount],
        secret: SecretBytes,
        checkCancellation: () throws -> Void,
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        guard let wallet = WalletHDWallet(storedMnemonic: secret) else { return false }
        defer { wallet.invalidate() }
        return try accounts.allSatisfy { account in
            try checkCancellation()
            guard let privateKey = wallet.privateKey(
                coin: account.coin,
                derivationPath: account.derivationPath
            ) else { return false }
            defer { privateKey.invalidate() }
            try checkCancellation()
            guard accountMatches(account, privateKey: privateKey) else { return false }
            try checkCancellation()
            try visit(account, privateKey)
            return true
        }
    }

    private static func visitPrivateKeyAccounts(
        _ accounts: [WalletAccount],
        secret: SecretBytes,
        checkCancellation: () throws -> Void,
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        guard let privateKey = WalletPrivateKey(taking: secret) else {
            return false
        }
        return try accounts.allSatisfy { account in
            try checkCancellation()
            guard privateKey.isValid(for: account.coin) else { return false }
            guard accountMatches(account, privateKey: privateKey) else { return false }
            try checkCancellation()
            try visit(account, privateKey)
            return true
        }
    }

    static func accountMatches(
        _ account: WalletAccount,
        privateKey: WalletPrivateKey
    ) -> Bool {
        let publicKey = privateKey.publicKeyData(coin: account.coin)
        let derivedAddress = WalletCrypto.addressFromPublicKeyData(
            publicKey,
            coin: account.coin
        )
        return !derivedAddress.isEmpty &&
            account.coin.normalizedAddress(derivedAddress) ==
            account.coin.normalizedAddress(account.address)
    }
}

final class UnlockedAccountSigner: Sendable {
    private let approvedAccount: WalletAccountDescriptor
    private struct State {
        var privateKey: WalletPrivateKey?
        var taken = false
    }
    private let state: Mutex<State>

    init?(
        approvedAccount: WalletAccountDescriptor,
        taking privateKey: WalletPrivateKey
    ) {
        guard approvedAccount.isValid,
              WalletSnapshotValidation.accountMatches(approvedAccount.account, privateKey: privateKey) else {
            privateKey.invalidate()
            return nil
        }
        self.approvedAccount = approvedAccount
        state = Mutex(State(privateKey: privateKey))
    }

    @MainActor
    func sign(
        _ operation: ApprovedWalletSigningOperation,
        validating source: any WalletSigningSource
    ) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount,
              source.approvedAccount == approvedAccount, operation.isAuthorizedToSign else {
            return .failure(.authorizationUnavailable)
        }
        guard !Task.isCancelled else {
            invalidate()
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = state.withLock({ state in
            guard !state.taken else { return nil as WalletPrivateKey? }
            state.taken = true
            return state.privateKey
        }) else { return .failure(.authorizationUnavailable) }
        defer { invalidate() }
        guard let result = await awaitBackgroundOperation({
            operation.sign(with: privateKey, validatingSource: { source.isCurrent() })
        }), operation.isAuthorizedToSign else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {
        let retired = state.withLock { state in
            defer { state.privateKey = nil; state.taken = true }
            return state.privateKey
        }
        retired?.invalidate()
    }

    deinit {
        invalidate()
    }
}

final class WalletSigningPreparation: Sendable {
    let scope: WalletSigningScope
    private let source: Mutex<(any WalletSigningSource)?>
    private let commit: WalletSigningCommit
    private let clock: @MainActor @Sendable () -> Date

    var approvedAccount: WalletAccountDescriptor { scope.approvedAccount }
    var requiresCommitLease: Bool {
        if case .vault = commit { return true }
        return false
    }

    init(
        source: any WalletSigningSource,
        scope: WalletSigningScope,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.source = Mutex(source)
        self.scope = scope
        commit = source.commit
        self.clock = clock
    }

    @MainActor
    static func fromSource(
        scope: WalletSigningScope,
        walletsManager: WalletsManager,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> WalletSigningPreparation {
        let source = RepositoryWalletSigningSource(approvedAccount: scope.approvedAccount, repository: walletsManager.repository)
        return WalletSigningPreparation(source: source, scope: scope, clock: clock)
    }

    func validateCurrent() -> Bool {
        guard let current = source.withLock({ $0 }) else { return false }
        guard current.approvedAccount == approvedAccount, current.isCurrent() else {
            invalidate()
            return false
        }
        return source.withLock { $0 === current }
    }

    @MainActor
    func consume(permit: ExtensionBridge.ApprovedExecutionPermit) -> WalletSigningSession? {
        guard let source = takeSource() else { return nil }
        var transferred = false
        defer { if !transferred { source.invalidate() } }
        guard !Task.isCancelled,
              WalletSigningScope(permit: permit) == scope,
              source.approvedAccount == approvedAccount,
              clock() < scope.signingDeadline,
              source.isCurrent(),
              !Task.isCancelled,
              clock() < scope.signingDeadline,
              let operation = ApprovedWalletSigningOperation(permit: permit, scope: scope)
        else { return nil }
        let session = WalletSigningSession(source: source, commit: commit, operation: operation, clock: clock)
        transferred = true
        return session
    }

    func invalidate() {
        takeSource()?.invalidate()
    }

    private func takeSource() -> (any WalletSigningSource)? {
        source.withLock { source in
            defer { source = nil }
            return source
        }
    }

    deinit { invalidate() }
}

@MainActor
final class WalletSigningSession: WalletSigning {
    private enum Phase: Sendable {
        case active
        case acquiringCommit
        case closed
    }

    private nonisolated let phase = Mutex(Phase.active)
    private nonisolated let source: any WalletSigningSource
    private nonisolated let operation: ApprovedWalletSigningOperation
    private let commit: WalletSigningCommit
    private let clock: @MainActor @Sendable () -> Date

    nonisolated var approvedAccount: WalletAccountDescriptor { operation.approvedAccount }

    fileprivate nonisolated init(
        source: any WalletSigningSource,
        commit: WalletSigningCommit,
        operation: ApprovedWalletSigningOperation,
        clock: @escaping @MainActor @Sendable () -> Date
    ) {
        self.source = source
        self.commit = commit
        self.operation = operation
        self.clock = clock
    }

    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        return await performSigning()
    }

    private func performSigning() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard phase.withLock({ phase in
            guard case .active = phase else { return false }
            return operation.beginAttempt()
        }) else { return .failure(.authorizationUnavailable) }
        defer {
            operation.finishAttempt()
            source.retireSigningMaterial()
        }
        return await withTaskCancellationHandler {
            do { try await AuthorityExecutionHooks.reach(.beforeSigning) }
            catch { return .failure(.authorizationUnavailable) }
            guard await authorizationIsCurrent() else { return .failure(.authorizationUnavailable) }
            let result = await source.sign(operation)
            do { try await AuthorityExecutionHooks.reach(.afterSigning) }
            catch { return .failure(.authorizationUnavailable) }
            if case .failure(.authorizationUnavailable) = result { return result }
            guard await authorizationIsCurrent() else { return .failure(.authorizationUnavailable) }
            return result
        } onCancel: {
            self.invalidate()
        }
    }

    private func authorizationIsCurrent() async -> Bool {
        guard isLocallyAuthorizedToSign else { return false }
        guard await awaitBackgroundOperation({ [source, operation] in
            operation.withCurrentAuthority { source.isCurrent() } ?? false
        }) == true else { return false }
        return isLocallyAuthorizedToSign
    }

    private var isLocallyAuthorizedToSign: Bool {
        !Task.isCancelled && clock() < operation.deadline && operation.isAttemptCurrent
    }

    func takeCommit() async -> WalletSigningCommit.Outcome {
        guard !Task.isCancelled else {
            invalidate()
            return .unavailable
        }
        guard phase.withLock({ phase in
            guard case .active = phase else { return false }
            phase = .acquiringCommit
            operation.finishAttempt()
            return true
        }) else { return .unavailable }
        source.retireSigningMaterial()
        return await withTaskCancellationHandler {
            do { try await AuthorityExecutionHooks.reach(.beforeCommitLease) }
            catch { invalidate(); return .unavailable }
            let outcome: WalletSigningCommit.Outcome
            switch commit {
            case .native:
                outcome = .readyWithoutLease
            case .vault(let acquire):
                if let lease = await acquire() {
                    outcome = .lease(lease)
                } else {
                    outcome = .unavailable
                }
            }
            do { try await AuthorityExecutionHooks.reach(.afterCommitLease) }
            catch {
                outcome.releaseLease()
                invalidate()
                return .unavailable
            }
            let canTransfer = phase.withLock { phase in
                guard case .acquiringCommit = phase else { return false }
                phase = .closed
                return !Task.isCancelled
            }
            guard canTransfer else {
                outcome.releaseLease()
                return .unavailable
            }
            return outcome
        } onCancel: {
            self.invalidate()
        }
    }

    nonisolated func invalidate() {
        phase.withLock { phase in
            phase = .closed
            operation.finishAttempt()
        }
        source.invalidate()
    }

    deinit { invalidate() }
}

