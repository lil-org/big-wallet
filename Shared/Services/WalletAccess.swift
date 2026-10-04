// ∅ 2026 lil org

import Foundation
import Synchronization

struct WalletAccountDescriptor: Codable, Equatable, Hashable, Sendable {

    let walletID: String
    let coin: WalletCoin
    let normalizedAddress: String
    let derivationPath: String

    private enum CodingKeys: String, CodingKey {
        case walletID
        case coin
        case normalizedAddress
        case derivationPath
    }

    init(
        walletID: String,
        coin: WalletCoin,
        normalizedAddress: String,
        derivationPath: String
    ) {
        self.walletID = walletID
        self.coin = coin
        self.normalizedAddress = normalizedAddress
        self.derivationPath = derivationPath
    }

    init(walletID: String, account: WalletAccount) {
        self.init(
            walletID: walletID,
            coin: account.coin,
            normalizedAddress: account.coin.normalizedAddress(account.address),
            derivationPath: account.derivationPath
        )
    }

    func matches(walletID: String, account: WalletAccount) -> Bool {
        isValid && self == Self(walletID: walletID, account: account)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        walletID = try container.decode(String.self, forKey: .walletID)
        let rawCoin = try container.decode(UInt32.self, forKey: .coin)
        guard let coin = WalletCoin(rawValue: rawCoin) else {
            throw DecodingError.dataCorruptedError(
                forKey: .coin,
                in: container,
                debugDescription: "unsupported wallet coin"
            )
        }
        self.coin = coin
        normalizedAddress = try container.decode(
            String.self,
            forKey: .normalizedAddress
        )
        derivationPath = try container.decode(
            String.self,
            forKey: .derivationPath
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletID, forKey: .walletID)
        try container.encode(coin.rawValue, forKey: .coin)
        try container.encode(normalizedAddress, forKey: .normalizedAddress)
        try container.encode(derivationPath, forKey: .derivationPath)
    }

    var account: WalletAccount {
        WalletAccount(
            address: normalizedAddress,
            coin: coin,
            derivation: .custom,
            derivationPath: derivationPath,
            publicKey: "",
            extendedPublicKey: ""
        )
    }

    var specificAccount: SpecificWalletAccount {
        SpecificWalletAccount(walletId: walletID, account: account)
    }

    var isValid: Bool {
        guard !walletID.isEmpty,
              walletID.utf8.count <= 256,
              !normalizedAddress.isEmpty,
              normalizedAddress.utf8.count <= 256,
              !derivationPath.isEmpty,
              derivationPath.utf8.count <= 1_024,
              coin.normalizedAddress(normalizedAddress) == normalizedAddress
        else { return false }

        switch coin {
        case .ethereum:
            return EthereumCodec.parseAddress(normalizedAddress) != nil
        case .solana:
            return WalletCrypto.base58Decode(string: normalizedAddress)?.count == 32
        }
    }
}

struct WalletAccountCatalog: Codable, Equatable, Sendable {

    let accounts: [WalletAccountDescriptor]

    init(accounts: [WalletAccountDescriptor]) {
        self.accounts = accounts
    }

    init(wallets: [WalletContainer]) {
        accounts = wallets.flatMap { wallet in
            wallet.accounts.map { account in
                WalletAccountDescriptor(walletID: wallet.id, account: account)
            }
        }
    }

    init(snapshots: [WalletSnapshot]) {
        accounts = snapshots.flatMap { wallet in
            wallet.accounts.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) }
        }
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    var isValid: Bool {
        accounts.count <= 16_384 &&
            accounts.allSatisfy(\.isValid) &&
            Set(accounts).count == accounts.count
    }
}

struct ValidatedWalletAccountCatalog: Sendable {

    let catalog: WalletAccountCatalog
    let data: Data

    init?(data: Data) {
        guard let catalog = try? JSONDecoder().decode(
                  WalletAccountCatalog.self,
                  from: data
              ),
              catalog.isValid,
              (try? catalog.canonicalData()) == data else {
            return nil
        }
        self.catalog = catalog
        self.data = data
    }
}

struct WalletCatalogIdentity: Equatable, Sendable {
    let generation: UUID?
    let catalogData: Data
}

enum WalletUnlockResult: Sendable {
    case unlocked(catalog: WalletReviewCatalog, session: WalletSigningSession)
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

protocol WalletSigning: AnyObject, Sendable {
    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure>
    func invalidate()
}

protocol OwnedWalletSigningAccess: AnyObject, Sendable {
    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure>
    func invalidate()
}

enum WalletSigningFailure: Error, Equatable, Sendable {
    case authorizationUnavailable
    case invalidTransaction
    case failedToSign
}

enum WalletSigningOutput: Sendable {
    case ethereumSignature(String)
    case solanaSignature(String)
    case solanaSignatures([String])
    case ethereumTransaction(
        signedTransaction: String,
        transactionHash: String
    )
    case solanaTransaction(
        signedTransaction: String,
        signature: String
    )
}

struct WalletSigningAuthorization: Equatable, Sendable {
    let handle: ExtensionBridge.Handle
    let approvedAccount: WalletAccountDescriptor
    let signingDeadline: Date
}

struct ApprovedWalletSigningOperation: Sendable {

    enum Payload: Sendable {
        case signature(SignaturePayload)
        case ethereumTransaction(Transaction, ResolvedEthereumNetwork)
        case solanaLegacyBroadcast(
            Solana.PreparedLegacySignAndSendTransaction,
            Solana.PreparedSendOptions,
            Solana.Cluster
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.PreparedSendOptions,
            Solana.Cluster
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

    let authorization: WalletSigningAuthorization
    let payload: Payload
    fileprivate let permit: ExtensionBridge.ApprovedExecutionPermit

    var handle: ExtensionBridge.Handle { authorization.handle }
    var approvedAccount: WalletAccountDescriptor { authorization.approvedAccount }
    var deadline: Date { authorization.signingDeadline }
    var isAuthorizedToSign: Bool { permit.isSigningAuthorized }

    init?(permit: ExtensionBridge.ApprovedExecutionPermit) {
        guard case .signing(let approvedAccount, let payload) = permit.approval.kind,
              permit.request.id == permit.handle.id,
              permit.signingDeadline.timeIntervalSince1970.isFinite,
              approvedAccount.isValid,
              permit.request.authorizedAccount == approvedAccount,
              approvedAccount.coin.correspondingInpageProvider == permit.request.provider,
              payload.coin == approvedAccount.coin,
              permit.consumeSigningOperation() else { return nil }
        self.permit = permit
        authorization = WalletSigningAuthorization(
            handle: permit.handle, approvedAccount: approvedAccount,
            signingDeadline: permit.signingDeadline
        )
        self.payload = payload
    }

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
            return performSigning(with: privateKey)
        } ?? .failure(.authorizationUnavailable)
    }

    private func performSigning(with privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard !Task.isCancelled, isAuthorizedToSign, permit.consumeSigningUse() else {
            return .failure(.authorizationUnavailable)
        }
        switch payload {
        case .signature(let payload):
            return signSignature(payload, with: privateKey)
        case .ethereumTransaction(let transaction, let network):
            switch Ethereum.signedTransaction(
                transaction: transaction, privateKey: privateKey, network: network.network
            ) {
            case .failure(.invalidTransaction):
                return .failure(.invalidTransaction)
            case .failure(.failedToSign):
                return .failure(.failedToSign)
            case .success(let signed):
                guard let hash = Ethereum.transactionHash(signedTransaction: signed)
                else { return .failure(.invalidTransaction) }
                return .success(.ethereumTransaction(
                    signedTransaction: signed, transactionHash: hash
                ))
            }
        case .solanaLegacyBroadcast(let transaction, _, _):
            return solanaTransactionOutput(
                Solana.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction, privateKey: privateKey
                )
            )
        case .solanaSerializedBroadcast(let transaction, _, _):
            return solanaTransactionOutput(
                Solana.signedTransactionForSignAndSend(
                    preparedSerializedTransaction: transaction, privateKey: privateKey
                )
            )
        }
    }

    private func signSignature(
        _ payload: SignaturePayload,
        with privateKey: WalletPrivateKey
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        switch payload {
        case .ethereumPersonalMessage(let data):
            guard let signature = try? Ethereum.signPersonalMessage(data: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return .success(.ethereumSignature(signature))
        case .ethereumTypedData(let data):
            guard let signature = try? Ethereum.sign(typedData: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return .success(.ethereumSignature(signature))
        case .solanaMessage(let data):
            return solanaSignature(data, privateKey: privateKey)
        case .solanaTransaction(let transaction):
            return solanaSignature(transaction.messageData, privateKey: privateKey)
        case .solanaTransactions(let transactions):
            guard let signatures = Solana.sign(
                messageDataList: transactions.map(\.messageData), privateKey: privateKey
            ), signatures.count == transactions.count else { return .failure(.failedToSign) }
            return .success(.solanaSignatures(signatures))
        }
    }

    private func solanaSignature(_ data: Data, privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signature = Solana.sign(messageData: data, privateKey: privateKey)
        else { return .failure(.failedToSign) }
        return .success(.solanaSignature(signature))
    }

    private func solanaTransactionOutput(
        _ signedTransaction: String?
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signedTransaction,
              let signature = Solana.transactionSignature(signedTransaction: signedTransaction)
        else { return .failure(.invalidTransaction) }
        return .success(.solanaTransaction(
            signedTransaction: signedTransaction, signature: signature
        ))
    }
}

struct WalletReviewCatalog: Sendable {

    let identity: WalletCatalogIdentity
    let orderedAccounts: [SpecificWalletAccount]

    func specificAccount(
        coin: WalletCoin,
        address: String
    ) -> SpecificWalletAccount? {
        let normalized = coin.normalizedAddress(address)
        return orderedAccounts.first { candidate in
            candidate.account.coin == coin &&
                coin.normalizedAddress(candidate.account.address) == normalized
        }
    }

    func specificAccount(descriptor: WalletAccountDescriptor) -> SpecificWalletAccount? {
        orderedAccounts.first {
            descriptor.matches(walletID: $0.walletId, account: $0.account)
        }
    }

    func suggestedAccounts(coin: WalletCoin? = nil) -> [SpecificWalletAccount] {
        guard let account = orderedAccounts.first(where: {
            $0.account.coin == (coin ?? .ethereum)
        }) else { return [] }
        return [account]
    }
}

private final class SourceWalletSigningAccess: OwnedWalletSigningAccess {
    private enum State: Sendable {
        case pending
        case source(WalletRepository.Source)
        case invalidated
    }

    let approvedAccount: WalletAccountDescriptor
    private let repository: WalletRepository
    private let state = Mutex(State.pending)

    init(approvedAccount: WalletAccountDescriptor, repository: WalletRepository) {
        self.approvedAccount = approvedAccount
        self.repository = repository
    }

    var isCurrent: Bool {
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
            if let source = attempt.source { state = .source(source) }
            return true
        }
        guard retained, !Task.isCancelled else { return .failure(.authorizationUnavailable) }
        return attempt.result
    }

    func invalidate() {
        state.withLock { $0 = .invalidated }
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
            guard let key = WalletStoredKey.importJSON(json: record.data)
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
        password: Data,
        checkCancellation: () throws -> Void = {},
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        try checkCancellation()
        let accounts = wallet.accounts
        guard accounts.count == wallet.key.accountCount,
              var secret = wallet.key.decryptPrivateKey(password: password)
        else { return false }
        defer { secret.resetBytes(in: 0..<secret.count) }
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
        secret: Data,
        checkCancellation: () throws -> Void,
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        guard let mnemonic = String(data: secret, encoding: .utf8),
              let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: "")
        else { return false }
        return try accounts.allSatisfy { account in
            try checkCancellation()
            guard let privateKey = wallet.privateKey(
                coin: account.coin,
                derivationPath: account.derivationPath
            ) else { return false }
            try checkCancellation()
            guard accountMatches(account, privateKey: privateKey) else { return false }
            try checkCancellation()
            try visit(account, privateKey)
            return true
        }
    }

    private static func visitPrivateKeyAccounts(
        _ accounts: [WalletAccount],
        secret: Data,
        checkCancellation: () throws -> Void,
        visit: (WalletAccount, WalletPrivateKey) throws -> Void
    ) throws -> Bool {
        guard let privateKey = WalletPrivateKey(data: secret) else {
            return false
        }
        return try accounts.allSatisfy { account in
            try checkCancellation()
            guard WalletCrypto.isValidPrivateKeyData(
                secret,
                coin: account.coin
            ) else { return false }
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

final class UnlockedAccountSigner: OwnedWalletSigningAccess {
    private let approvedAccount: WalletAccountDescriptor
    private let privateKey: Mutex<WalletPrivateKey?>
    private let sourceIsCurrent: @Sendable () -> Bool

    init?(
        approvedAccount: WalletAccountDescriptor,
        privateKey: WalletPrivateKey,
        sourceIsCurrent: @escaping @Sendable () -> Bool = { true }
    ) {
        guard approvedAccount.isValid,
              WalletSnapshotValidation.accountMatches(approvedAccount.account, privateKey: privateKey) else { return nil }
        self.approvedAccount = approvedAccount
        self.privateKey = Mutex(privateKey)
        self.sourceIsCurrent = sourceIsCurrent
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount, operation.isAuthorizedToSign else {
            return .failure(.authorizationUnavailable)
        }
        guard !Task.isCancelled else {
            invalidate()
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = privateKey.withLock({ key in
            let retained = key
            key = nil
            return retained
        }) else { return .failure(.authorizationUnavailable) }
        guard let result = await awaitBackgroundOperation({ [sourceIsCurrent] in
            operation.sign(with: privateKey, validatingSource: sourceIsCurrent)
        }), operation.isAuthorizedToSign else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {
        privateKey.withLock { $0 = nil }
    }

    deinit {
        invalidate()
    }
}

@MainActor
final class WalletSigningSession: WalletSigning {
    private struct Binding: Sendable {
        let operation: ApprovedWalletSigningOperation
        let authorityIsCurrent: @MainActor @Sendable (ExtensionBridge.Handle) async -> Bool
    }

    private enum Resources: Sendable {
        case available(Binding?)
        case spent
        case acquiringCommitLease
        case leaseTransferred
        case invalidated

        var permitsCommit: Bool {
            switch self {
            case .available, .spent: true
            case .acquiringCommitLease, .leaseTransferred, .invalidated: false
            }
        }

        var binding: Binding? {
            guard case .available(let binding) = self else { return nil }
            return binding
        }
    }

    private struct State: Sendable {
        var resources = Resources.available(nil)
        var access: (any OwnedWalletSigningAccess)?
    }

    nonisolated let authorization: WalletSigningAuthorization
    nonisolated var approvedAccount: WalletAccountDescriptor { authorization.approvedAccount }
    var requiresCommitLease: Bool { acquireCommitLease != nil }

    private nonisolated let state: Mutex<State>
    private nonisolated let sessionID = UUID()
    private let isCurrent: @Sendable () -> Bool
    private let acquireCommitLease: (@MainActor @Sendable () async -> WalletExecutionLease?)?
    private let clock: @MainActor @Sendable () -> Date

    nonisolated init(
        _ access: any OwnedWalletSigningAccess,
        authorization: WalletSigningAuthorization,
        isCurrent: @escaping @Sendable () -> Bool,
        acquireCommitLease: (@MainActor @Sendable () async -> WalletExecutionLease?)? = nil,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        state = Mutex(State(access: access))
        self.authorization = authorization
        self.isCurrent = isCurrent
        self.acquireCommitLease = acquireCommitLease
        self.clock = clock
    }

    static func fromSource(
        operation: ApprovedWalletSigningOperation,
        walletsManager: WalletsManager = .shared,
        authorityIsCurrent: @escaping @MainActor @Sendable (ExtensionBridge.Handle) async -> Bool,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) -> WalletSigningSession {
        let access = SourceWalletSigningAccess(approvedAccount: operation.approvedAccount, repository: walletsManager.repository)
        let session = WalletSigningSession(
            access, authorization: operation.authorization,
            isCurrent: { access.isCurrent },
            clock: clock
        )
        _ = session.bind(operation: operation, authorityIsCurrent: authorityIsCurrent)
        return session
    }

    func validateCurrent() -> Bool {
        guard isCurrent() else {
            invalidate()
            return false
        }
        return state.withLock { $0.resources.permitsCommit }
    }

    func bind(operation: ApprovedWalletSigningOperation, authorityIsCurrent: @escaping @MainActor @Sendable (ExtensionBridge.Handle) async -> Bool) -> Bool {
        guard operation.authorization == authorization,
              clock() < authorization.signingDeadline, validateCurrent() else { return false }
        return state.withLock { state in
            guard case .available(nil) = state.resources, state.access != nil,
                  operation.permit.bindSigningOperation(to: sessionID) else { return false }
            state.resources = .available(Binding(operation: operation, authorityIsCurrent: authorityIsCurrent))
            return true
        }
    }

    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        let bound = state.withLock { state -> (Binding, any OwnedWalletSigningAccess)? in
            guard let binding = state.resources.binding, let access = state.access,
                  binding.operation.permit.beginSigningAttempt(for: sessionID) else { return nil }
            return (binding, access)
        }
        guard let (binding, access) = bound else { return .failure(.authorizationUnavailable) }
        defer { finishSigningAttempt(binding) }
        return await withTaskCancellationHandler {
            guard await authorizationIsCurrent(binding) else { return .failure(.authorizationUnavailable) }
            let result = await access.sign(binding.operation)
            if case .failure(.authorizationUnavailable) = result { return result }
            guard await authorizationIsCurrent(binding) else { return .failure(.authorizationUnavailable) }
            return result
        } onCancel: {
            self.invalidate()
        }
    }

    private func authorizationIsCurrent(_ binding: Binding) async -> Bool {
        guard isLocallyAuthorizedToSign(binding),
              await binding.authorityIsCurrent(authorization.handle) else { return false }
        let operation = binding.operation
        guard await awaitBackgroundOperation({ [isCurrent] in
            operation.withCurrentAuthority { isCurrent() } ?? false
        }) == true else { return false }
        return isLocallyAuthorizedToSign(binding)
    }

    private func isLocallyAuthorizedToSign(_ binding: Binding) -> Bool {
        !Task.isCancelled && clock() < authorization.signingDeadline &&
            state.withLock { $0.resources.binding != nil } &&
            binding.operation.permit.isSigningAttemptCurrent(for: sessionID)
    }

    private nonisolated func finishSigningAttempt(_ binding: Binding) {
        let access = state.withLock { state in
            if case .available = state.resources { state.resources = .spent }
            let access = state.access
            state.access = nil
            return access
        }
        binding.operation.permit.finishSigningAttempt(for: sessionID)
        access?.invalidate()
    }

    func takeCommitLease() async -> WalletExecutionLease? {
        guard let acquireCommitLease else { return nil }
        let retired = state.withLock { state -> (Binding?, (any OwnedWalletSigningAccess)?)? in
            guard state.resources.permitsCommit else { return nil }
            let binding = state.resources.binding
            state.resources = .acquiringCommitLease
            let access = state.access
            state.access = nil
            return (binding, access)
        }
        guard let (binding, access) = retired else { return nil }
        binding?.operation.permit.finishSigningAttempt(for: sessionID)
        access?.invalidate()
        return await withTaskCancellationHandler {
            let lease = await acquireCommitLease()
            let canTransfer = state.withLock { state in
                guard case .acquiringCommitLease = state.resources else { return false }
                state.resources = .leaseTransferred
                return !Task.isCancelled
            }
            guard canTransfer else {
                lease?.release()
                return nil
            }
            return lease
        } onCancel: {
            self.invalidate()
        }
    }

    nonisolated func invalidate() {
        let (binding, access) = state.withLock { state in
            let binding = state.resources.binding
            state.resources = .invalidated
            let access = state.access
            state.access = nil
            return (binding, access)
        }
        binding?.operation.permit.finishSigningAttempt(for: sessionID)
        access?.invalidate()
    }

    deinit {
        invalidate()
    }
}
