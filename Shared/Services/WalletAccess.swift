// ∅ 2026 lil org

import Foundation

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

enum WalletUnlockResult {
    case unlocked(catalog: WalletReviewCatalog, session: WalletSigningSession)
    case canceled
    case unavailable
}

final class WalletExecutionLease: @unchecked Sendable {

    private let lock = NSLock()
    private var releaseOperation: (() -> Void)?

    init(release: @escaping () -> Void) {
        releaseOperation = release
    }

    func release() {
        lock.lock()
        let operation = releaseOperation
        releaseOperation = nil
        lock.unlock()
        operation?()
    }

    deinit {
        release()
    }
}

protocol WalletSigning: AnyObject {
    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure>
    func invalidate()
}

protocol OwnedWalletSigningAccess: AnyObject {
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
        transactionHash: String,
        network: ResolvedEthereumNetwork
    )
    case solanaTransaction(
        signedTransaction: String,
        signature: String,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    )
}

struct WalletSigningAuthorization: Equatable, Sendable {
    let handle: ExtensionBridge.Handle
    let approvedAccount: WalletAccountDescriptor
    let signingDeadline: Date
}

private final class WalletSigningOperationUse: @unchecked Sendable {
    private let lock = NSLock()
    private var bound = false
    private var signed = false

    func bind() -> Bool {
        lock.withLock {
            guard !bound, !signed else { return false }
            bound = true
            return true
        }
    }

    func sign() -> Bool {
        lock.withLock {
            guard !signed else { return false }
            signed = true
            return true
        }
    }
}

struct ApprovedWalletSigningOperation: Sendable {

    enum Payload: Sendable {
        case ethereumMessage(Data)
        case ethereumPersonalMessage(Data)
        case ethereumTypedData(String)
        case ethereumTransaction(Transaction, ResolvedEthereumNetwork)
        case solanaMessage(Data)
        case solanaTransaction(SolanaPreparedTransactionMessage)
        case solanaTransactions([SolanaPreparedTransactionMessage])
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
            case .ethereumMessage, .ethereumPersonalMessage, .ethereumTypedData,
                 .ethereumTransaction:
                return .ethereum
            case .solanaMessage, .solanaTransaction, .solanaTransactions,
                 .solanaLegacyBroadcast, .solanaSerializedBroadcast:
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
    private let permit: ExtensionBridge.ApprovedExecutionPermit
    private let use = WalletSigningOperationUse()

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

    fileprivate func consumeBinding() -> Bool {
        use.bind()
    }

    fileprivate func sign(with privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard isAuthorizedToSign, use.sign() else { return .failure(.authorizationUnavailable) }
        switch payload {
        case .ethereumMessage(let data):
            guard let signature = try? Ethereum.sign(data: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return .success(.ethereumSignature(signature))
        case .ethereumPersonalMessage(let data):
            guard let signature = try? Ethereum.signPersonalMessage(data: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return .success(.ethereumSignature(signature))
        case .ethereumTypedData(let data):
            guard let signature = try? Ethereum.sign(typedData: data, privateKey: privateKey)
            else { return .failure(.failedToSign) }
            return .success(.ethereumSignature(signature))
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
                    signedTransaction: signed, transactionHash: hash, network: network
                ))
            }
        case .solanaMessage(let data):
            return solanaSignature(data, privateKey: privateKey)
        case .solanaTransaction(let transaction):
            return solanaSignature(transaction.messageData, privateKey: privateKey)
        case .solanaTransactions(let transactions):
            guard let signatures = Solana.sign(
                messageDataList: transactions.map(\.messageData), privateKey: privateKey
            ), signatures.count == transactions.count else { return .failure(.failedToSign) }
            return .success(.solanaSignatures(signatures))
        case .solanaLegacyBroadcast(let transaction, let options, let cluster):
            return solanaTransactionOutput(
                Solana.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction, privateKey: privateKey
                ), cluster: cluster, options: options
            )
        case .solanaSerializedBroadcast(let transaction, let options, let cluster):
            return solanaTransactionOutput(
                Solana.signedTransactionForSignAndSend(
                    preparedSerializedTransaction: transaction, privateKey: privateKey
                ), cluster: cluster, options: options
            )
        }
    }

    private func solanaSignature(_ data: Data, privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signature = Solana.sign(messageData: data, privateKey: privateKey)
        else { return .failure(.failedToSign) }
        return .success(.solanaSignature(signature))
    }

    private func solanaTransactionOutput(
        _ signedTransaction: String?,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        guard let signedTransaction,
              let signature = Solana.transactionSignature(signedTransaction: signedTransaction)
        else { return .failure(.invalidTransaction) }
        return .success(.solanaTransaction(
            signedTransaction: signedTransaction, signature: signature, cluster: cluster, options: options
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

    private let approvedAccount: WalletAccountDescriptor
    private let walletsManager: WalletsManager

    init(approvedAccount: WalletAccountDescriptor, walletsManager: WalletsManager) {
        self.approvedAccount = approvedAccount
        self.walletsManager = walletsManager
    }

    var isCurrent: Bool {
        approvedAccount.isValid &&
            walletsManager.currentWallet(id: approvedAccount.walletID)?
                .hasAccountMatching(approvedAccount.account) == true
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount,
              operation.isAuthorizedToSign,
              !Task.isCancelled else {
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = walletsManager.getPrivateKey(
            walletId: approvedAccount.walletID,
            account: approvedAccount.account
        ), WalletSnapshotValidation.accountMatches(
            approvedAccount.account, privateKey: privateKey
        ) else { return .failure(.failedToSign) }
        guard let result = await awaitBackgroundOperation({
            operation.sign(with: privateKey)
        }), operation.isAuthorizedToSign else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {}
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

    static func ownsStoredAccounts(
        _ wallet: WalletContainer,
        password: Data,
        checkCancellation: () throws -> Void = {}
    ) throws -> Bool {
        try checkCancellation()
        let accounts = wallet.accounts
        guard accounts.count == wallet.key.accountCount,
              var secret = wallet.key.decryptPrivateKey(password: password)
        else { return false }
        defer { secret.resetBytes(in: 0..<secret.count) }
        try checkCancellation()

        if wallet.isMnemonic {
            return try mnemonicAccountsMatch(
                accounts,
                secret: secret,
                checkCancellation: checkCancellation
            )
        }
        return try privateKeyAccountsMatch(
            accounts,
            secret: secret,
            checkCancellation: checkCancellation
        )
    }

    private static func mnemonicAccountsMatch(
        _ accounts: [WalletAccount],
        secret: Data,
        checkCancellation: () throws -> Void
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
            return accountMatches(account, privateKey: privateKey)
        }
    }

    private static func privateKeyAccountsMatch(
        _ accounts: [WalletAccount],
        secret: Data,
        checkCancellation: () throws -> Void
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
            return accountMatches(account, privateKey: privateKey)
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

    private let lock = NSLock()
    private let approvedAccount: WalletAccountDescriptor
    private var privateKey: WalletPrivateKey?

    init?(approvedAccount: WalletAccountDescriptor, privateKey: WalletPrivateKey) {
        guard approvedAccount.isValid,
              WalletSnapshotValidation.accountMatches(
                  approvedAccount.account,
                  privateKey: privateKey
              ) else { return nil }
        self.approvedAccount = approvedAccount
        self.privateKey = privateKey
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount,
              operation.isAuthorizedToSign else {
            return .failure(.authorizationUnavailable)
        }
        guard !Task.isCancelled else {
            invalidate()
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = lock.withLock({
            let privateKey = self.privateKey
            self.privateKey = nil
            return privateKey
        }) else { return .failure(.authorizationUnavailable) }
        guard let result = await awaitBackgroundOperation({
            operation.sign(with: privateKey)
        }), operation.isAuthorizedToSign else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {
        lock.withLock { privateKey = nil }
    }

    deinit {
        invalidate()
    }
}

final class WalletSigningSession: WalletSigning, @unchecked Sendable {

    private struct Binding {
        let operation: ApprovedWalletSigningOperation
        let authorityIsCurrent: @MainActor (ExtensionBridge.Handle) async -> Bool
    }

    private enum State {
        case unbound
        case bound(Binding)
        case signing
        case attemptFinished
        case acquiringCommitLease
        case leaseTransferred
        case invalidated

        var permitsCommit: Bool {
            switch self {
            case .unbound, .bound, .signing, .attemptFinished: true
            case .acquiringCommitLease, .leaseTransferred, .invalidated: false
            }
        }
    }

    let authorization: WalletSigningAuthorization
    var approvedAccount: WalletAccountDescriptor { authorization.approvedAccount }
    var requiresCommitLease: Bool { acquireCommitLease != nil }

    private let lock = NSLock()
    private var state = State.unbound
    private var access: (any OwnedWalletSigningAccess)?
    private let isCurrent: () -> Bool
    private let acquireCommitLease: (() async -> WalletExecutionLease?)?
    private let clock: () -> Date

    init(
        _ access: any OwnedWalletSigningAccess,
        authorization: WalletSigningAuthorization,
        isCurrent: @escaping () -> Bool,
        acquireCommitLease: (() async -> WalletExecutionLease?)? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.access = access
        self.authorization = authorization
        self.isCurrent = isCurrent
        self.acquireCommitLease = acquireCommitLease
        self.clock = clock
    }

    static func fromSource(
        operation: ApprovedWalletSigningOperation,
        walletsManager: WalletsManager = .shared,
        authorityIsCurrent: @escaping @MainActor (ExtensionBridge.Handle) async -> Bool,
        clock: @escaping () -> Date = Date.init
    ) -> WalletSigningSession {
        let access = SourceWalletSigningAccess(
            approvedAccount: operation.approvedAccount,
            walletsManager: walletsManager
        )
        let session = WalletSigningSession(
            access,
            authorization: operation.authorization,
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
        return lock.withLock { state.permitsCommit }
    }

    func bind(
        operation: ApprovedWalletSigningOperation,
        authorityIsCurrent: @escaping @MainActor (ExtensionBridge.Handle) async -> Bool
    ) -> Bool {
        guard operation.authorization == authorization,
              clock() < authorization.signingDeadline,
              validateCurrent() else { return false }
        return lock.withLock {
            guard case .unbound = state, access != nil,
                  operation.consumeBinding() else { return false }
            state = .bound(Binding(
                operation: operation,
                authorityIsCurrent: authorityIsCurrent
            ))
            return true
        }
    }

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        let bound = lock.withLock { () -> (Binding, any OwnedWalletSigningAccess)? in
            guard case .bound(let binding) = state, let access else { return nil }
            state = .signing
            return (binding, access)
        }
        guard let (binding, access) = bound else {
            return .failure(.authorizationUnavailable)
        }
        defer { finishSigningAttempt() }
        return await withTaskCancellationHandler {
            guard isLocallyAuthorizedToSign, binding.operation.isAuthorizedToSign,
                  await binding.authorityIsCurrent(authorization.handle),
                  isLocallyAuthorizedToSign, binding.operation.isAuthorizedToSign,
                  isCurrent() else { return .failure(.authorizationUnavailable) }
            let result = await access.sign(binding.operation)
            guard isLocallyAuthorizedToSign, binding.operation.isAuthorizedToSign,
                  await binding.authorityIsCurrent(authorization.handle),
                  isLocallyAuthorizedToSign, binding.operation.isAuthorizedToSign,
                  isCurrent() else { return .failure(.authorizationUnavailable) }
            return result
        } onCancel: {
            self.invalidate()
        }
    }

    @MainActor
    private var isLocallyAuthorizedToSign: Bool {
        !Task.isCancelled && clock() < authorization.signingDeadline &&
            lock.withLock {
                if case .signing = state { return true }
                return false
            }
    }

    private func finishSigningAttempt() {
        let access = lock.withLock {
            if case .signing = state { state = .attemptFinished }
            let access = self.access
            self.access = nil
            return access
        }
        access?.invalidate()
    }

    func takeCommitLease() async -> WalletExecutionLease? {
        guard let acquireCommitLease else { return nil }
        let canAcquire = lock.withLock {
            guard state.permitsCommit else { return false }
            state = .acquiringCommitLease
            return true
        }
        guard canAcquire else { return nil }
        finishSigningAttempt()
        let lease = await acquireCommitLease()
        let canTransfer = lock.withLock {
            guard case .acquiringCommitLease = state else { return false }
            state = .leaseTransferred
            return !Task.isCancelled
        }
        guard canTransfer else {
            lease?.release()
            return nil
        }
        return lease
    }

    func invalidate() {
        let access = lock.withLock {
            state = .invalidated
            let access = self.access
            self.access = nil
            return access
        }
        access?.invalidate()
    }

    deinit {
        invalidate()
    }
}
