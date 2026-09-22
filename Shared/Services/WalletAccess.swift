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
    case unlocked(catalog: WalletReviewCatalog, signer: RequestScopedWalletAccess)
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
    case failedToSign
    case ethereum(EthereumSendFailure)
    case solana(Solana.SendTransactionError)
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
            Solana.Cluster,
            Solana.PreparedSendOptions
        )
        case solanaSerializedBroadcast(
            Solana.PreparedSerializedTransaction,
            Solana.Cluster,
            Solana.PreparedSendOptions
        )
    }

    let handle: ExtensionBridge.Handle
    let configurationKey: String
    let enqueueAttempt: String
    let approvedAccount: WalletAccountDescriptor
    let deadline: Date
    let payload: Payload

    init?(
        request: SafariRequest,
        approval: DappApprovalValidator.Approval,
        handle: ExtensionBridge.Handle,
        deadline: Date
    ) {
        guard request.id == handle.id,
              deadline.timeIntervalSince1970.isFinite,
              let approvedAccount = approval.signingAccount,
              approvedAccount.isValid,
              approvedAccount.coin.correspondingInpageProvider == request.provider
        else { return nil }
        self.handle = handle
        configurationKey = request.configurationKey
        enqueueAttempt = request.enqueueAttempt
        self.approvedAccount = approvedAccount
        self.deadline = deadline
        switch approval {
        case .message(let action, let cluster):
            switch action.payload {
            case .ethereumMessage(let data):
                guard approvedAccount.coin == .ethereum, cluster == nil else { return nil }
                payload = .ethereumMessage(data)
            case .ethereumPersonalMessage(let data):
                guard approvedAccount.coin == .ethereum, cluster == nil else { return nil }
                payload = .ethereumPersonalMessage(data)
            case .ethereumTypedData(let data):
                guard approvedAccount.coin == .ethereum, cluster == nil else { return nil }
                payload = .ethereumTypedData(data)
            case .solanaMessage(let data):
                guard approvedAccount.coin == .solana, cluster == nil else { return nil }
                payload = .solanaMessage(data)
            case .solanaTransaction(let transaction):
                guard approvedAccount.coin == .solana, cluster == nil else { return nil }
                payload = .solanaTransaction(transaction)
            case .solanaTransactions(let transactions):
                guard approvedAccount.coin == .solana, cluster == nil else { return nil }
                payload = .solanaTransactions(transactions)
            case .solanaLegacyBroadcast(let transaction, let options):
                guard approvedAccount.coin == .solana, let cluster else { return nil }
                payload = .solanaLegacyBroadcast(transaction, cluster, options)
            case .solanaSerializedBroadcast(let transaction, let options):
                guard approvedAccount.coin == .solana, let cluster else { return nil }
                payload = .solanaSerializedBroadcast(transaction, cluster, options)
            }
        case .transaction(let action, let transaction):
            guard approvedAccount.coin == .ethereum,
                  DappApprovalDecision.NetworkIdentity(action.resolvedNetwork) != nil,
                  transaction.isReadyForApproval(on: action.chain) else { return nil }
            payload = .ethereumTransaction(transaction, action.resolvedNetwork)
        case .accountSelection, .addEthereumChain:
            return nil
        }
    }

    fileprivate func sign(with privateKey: WalletPrivateKey) ->
        Result<WalletSigningOutput, WalletSigningFailure> {
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
            case .failure(let failure):
                return .failure(.ethereum(failure))
            case .success(let signed):
                guard let hash = Ethereum.transactionHash(signedTransaction: signed)
                else { return .failure(.ethereum(.invalidTransaction)) }
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
        case .solanaLegacyBroadcast(let transaction, let cluster, let options):
            return solanaBroadcast(
                Solana.signedTransactionForSignAndSend(
                    preparedLegacyTransaction: transaction, privateKey: privateKey
                ), cluster: cluster, options: options
            )
        case .solanaSerializedBroadcast(let transaction, let cluster, let options):
            return solanaBroadcast(
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

    private func solanaBroadcast(
        _ result: Result<String, Solana.SendTransactionError>,
        cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions
    ) -> Result<WalletSigningOutput, WalletSigningFailure> {
        switch result {
        case .failure(let failure):
            return .failure(.solana(failure))
        case .success(let signed):
            guard let signature = Solana.transactionSignature(signedTransaction: signed)
            else { return .failure(.solana(.invalidMessage)) }
            return .success(.solanaTransaction(
                signedTransaction: signed, signature: signature, cluster: cluster, options: options
            ))
        }
    }
}

final class BoundWalletSigner: WalletSigning, @unchecked Sendable {

    let operation: ApprovedWalletSigningOperation
    private let lock = NSLock()
    private var access: (any OwnedWalletSigningAccess)?
    private var consumed = false
    private var invalidated = false
    private let isCurrent: () -> Bool
    private let clock: () -> Date

    init(
        operation: ApprovedWalletSigningOperation,
        access: any OwnedWalletSigningAccess,
        isCurrent: @escaping () -> Bool,
        clock: @escaping () -> Date = Date.init
    ) {
        self.operation = operation
        self.access = access
        self.isCurrent = isCurrent
        self.clock = clock
    }

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        let access = lock.withLock { () -> (any OwnedWalletSigningAccess)? in
            guard !consumed, !invalidated else { return nil }
            consumed = true
            return self.access
        }
        guard let access else { return .failure(.authorizationUnavailable) }
        defer { invalidate() }
        guard isAuthorized else { return .failure(.authorizationUnavailable) }
        let result = await withTaskCancellationHandler {
            await access.sign(operation)
        } onCancel: {
            self.invalidate()
        }
        guard isAuthorized else { return .failure(.authorizationUnavailable) }
        return result
    }

    @MainActor
    private var isAuthorized: Bool {
        !Task.isCancelled && clock() < operation.deadline &&
            lock.withLock { !invalidated } && isCurrent()
    }

    func invalidate() {
        let access = lock.withLock {
            invalidated = true
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

struct WalletReviewCatalog {

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

    func suggestedAccounts(coin: WalletCoin? = nil) -> [SpecificWalletAccount] {
        suggestedAccounts(for: [coin ?? .ethereum])
    }

    func suggestedAccounts(providers: Set<InpageProvider>) -> [SpecificWalletAccount] {
        let coins = InpageProvider.allCases
            .filter(providers.contains)
            .compactMap(WalletCoin.correspondingToInpageProvider)
        return suggestedAccounts(for: coins)
    }

    private func suggestedAccounts(
        for coins: [WalletCoin]
    ) -> [SpecificWalletAccount] {
        var result = [SpecificWalletAccount]()
        var seen = Set<WalletCoin>()
        for coin in coins where seen.insert(coin).inserted {
            if let account = orderedAccounts.first(where: {
                $0.account.coin == coin
            }) {
                result.append(account)
            }
        }
        return result
    }
}

final class SourceWalletSigner: WalletSigning {

    private let signer: BoundWalletSigner

    init(
        operation: ApprovedWalletSigningOperation,
        walletsManager: WalletsManager = .shared,
        clock: @escaping () -> Date = Date.init
    ) {
        let access = SourceWalletSigningAccess(
            approvedAccount: operation.approvedAccount,
            walletsManager: walletsManager
        )
        signer = BoundWalletSigner(
            operation: operation, access: access,
            isCurrent: { access.isCurrent }, clock: clock
        )
    }

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        await signer.sign()
    }

    func invalidate() {
        signer.invalidate()
    }
}

private final class SourceWalletSigningAccess: OwnedWalletSigningAccess {

    private let approvedAccount: WalletAccountDescriptor
    private let walletsManager: WalletsManager
    private let lock = NSLock()
    private var active = true

    init(approvedAccount: WalletAccountDescriptor, walletsManager: WalletsManager) {
        self.approvedAccount = approvedAccount
        self.walletsManager = walletsManager
    }

    var isCurrent: Bool {
        approvedAccount.isValid && lock.withLock { active } &&
            walletsManager.currentWallet(id: approvedAccount.walletID)?
                .hasAccountMatching(approvedAccount.account) == true
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        guard operation.approvedAccount == approvedAccount,
              !Task.isCancelled, isCurrent else {
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = walletsManager.getPrivateKey(
            walletId: approvedAccount.walletID,
            account: approvedAccount.account
        ), WalletSnapshotValidation.accountMatches(
            approvedAccount.account, privateKey: privateKey
        ) else { return .failure(.failedToSign) }
        guard isCurrent else { return .failure(.authorizationUnavailable) }
        guard let result = await awaitBackgroundOperation({
            operation.sign(with: privateKey)
        }) else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {
        lock.withLock { active = false }
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

final class UnlockedWalletSigner: OwnedWalletSigningAccess {

    private let lock = NSLock()
    private var password: Data
    private var walletsByID: [String: WalletContainer]

    init?(password: Data, wallets: [WalletContainer]) {
        guard !password.isEmpty,
              Set(wallets.map(\.id)).count == wallets.count else { return nil }
        self.password = password
        walletsByID = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0) })
    }

    private func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let wallet = walletsByID[walletID],
              wallet.hasAccountMatching(account),
              let privateKey = try? wallet.privateKey(
                  passwordData: password,
                  account: account
              ),
              WalletSnapshotValidation.accountMatches(
                  account,
                  privateKey: privateKey
              ) else { return nil }
        return privateKey
    }

    @MainActor
    func sign(_ operation: ApprovedWalletSigningOperation) async ->
        Result<WalletSigningOutput, WalletSigningFailure> {
        let account = operation.approvedAccount
        guard account.isValid, !Task.isCancelled else {
            return .failure(.authorizationUnavailable)
        }
        guard let privateKey = privateKey(walletID: account.walletID, account: account.account)
        else { return .failure(.failedToSign) }
        guard let result = await awaitBackgroundOperation({
            operation.sign(with: privateKey)
        }) else { return .failure(.authorizationUnavailable) }
        return result
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        password.resetBytes(in: 0..<password.count)
        password.removeAll(keepingCapacity: false)
        walletsByID.removeAll(keepingCapacity: false)
    }

    deinit {
        invalidate()
    }
}

final class RequestScopedWalletAccess {

    let approvedAccount: WalletAccountDescriptor
    private let lock = NSLock()
    private var access: (any OwnedWalletSigningAccess)?
    private let isCurrent: () -> Bool
    private let acquireExecutionLease: () async -> WalletExecutionLease?
    private var executionLeaseTaken = false
    private var invalidated = false
    private var boundSigner: BoundWalletSigner?
    private let clock: () -> Date

    init(
        _ access: any OwnedWalletSigningAccess,
        approvedAccount: WalletAccountDescriptor,
        isCurrent: @escaping () -> Bool,
        acquireExecutionLease: @escaping () async -> WalletExecutionLease?,
        clock: @escaping () -> Date = Date.init
    ) {
        self.access = access
        self.approvedAccount = approvedAccount
        self.isCurrent = isCurrent
        self.acquireExecutionLease = acquireExecutionLease
        self.clock = clock
    }

    func validateCurrent() -> Bool {
        guard isCurrent() else {
            invalidate()
            return false
        }
        return lock.withLock { !invalidated && !executionLeaseTaken }
    }

    func bind(operation: ApprovedWalletSigningOperation) -> BoundWalletSigner? {
        guard operation.approvedAccount == approvedAccount,
              clock() < operation.deadline,
              validateCurrent() else { return nil }
        return lock.withLock {
            guard let access, !invalidated, !executionLeaseTaken, boundSigner == nil else { return nil }
            let signer = BoundWalletSigner(
                operation: operation,
                access: access,
                isCurrent: { [weak self] in self?.validateCurrent() == true },
                clock: clock
            )
            self.access = nil
            boundSigner = signer
            return signer
        }
    }

    func takeExecutionLease() async -> WalletExecutionLease? {
        let canAcquire = lock.withLock {
            guard !invalidated, !executionLeaseTaken else { return false }
            executionLeaseTaken = true
            return true
        }
        guard canAcquire else { return nil }
        defer { invalidate() }
        let lease = await acquireExecutionLease()
        guard !Task.isCancelled, lock.withLock({ !invalidated }) else {
            lease?.release()
            return nil
        }
        return lease
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        let access = access
        self.access = nil
        let signer = boundSigner
        lock.unlock()
        signer?.invalidate()
        access?.invalidate()
    }

    deinit {
        invalidate()
    }
}
