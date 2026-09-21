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
                WalletAccountDescriptor(
                    walletID: wallet.id,
                    coin: account.coin,
                    normalizedAddress: account.coin.normalizedAddress(account.address),
                    derivationPath: account.derivationPath
                )
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
    case unlocked(catalog: WalletReviewCatalog, signer: RequestScopedWalletSigner)
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
    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey?
}

protocol OwnedWalletSigning: WalletSigning {
    func invalidate()
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

    static let shared = SourceWalletSigner()

    private let walletsManager: WalletsManager

    init(walletsManager: WalletsManager = .shared) {
        self.walletsManager = walletsManager
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        walletsManager.getPrivateKey(walletId: walletID, account: account)
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

final class UnlockedWalletSigner: OwnedWalletSigning {

    private var password: Data
    private var walletsByID: [String: WalletContainer]

    init?(password: Data, wallets: [WalletContainer]) {
        guard !password.isEmpty,
              Set(wallets.map(\.id)).count == wallets.count else { return nil }
        self.password = password
        walletsByID = Dictionary(uniqueKeysWithValues: wallets.map { ($0.id, $0) })
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
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

    func invalidate() {
        password.resetBytes(in: 0..<password.count)
        password.removeAll(keepingCapacity: false)
        walletsByID.removeAll(keepingCapacity: false)
    }

    deinit {
        invalidate()
    }
}

final class RequestScopedWalletSigner: WalletSigning {

    private let lock = NSLock()
    private var access: OwnedWalletSigning?
    private let isCurrent: () -> Bool
    private let acquireExecutionLease: () async -> WalletExecutionLease?
    private var executionLeaseTaken = false

    init(
        _ access: OwnedWalletSigning,
        isCurrent: @escaping () -> Bool,
        acquireExecutionLease: @escaping () async -> WalletExecutionLease?
    ) {
        self.access = access
        self.isCurrent = isCurrent
        self.acquireExecutionLease = acquireExecutionLease
    }

    func validateCurrent() -> Bool {
        guard isCurrent() else {
            invalidate()
            return false
        }
        return lock.withLock { access != nil && !executionLeaseTaken }
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        guard isCurrent() else {
            invalidate()
            return nil
        }
        lock.lock()
        guard !executionLeaseTaken else {
            lock.unlock()
            return nil
        }
        let privateKey = access?.privateKey(
            walletID: walletID,
            account: account
        )
        lock.unlock()
        guard isCurrent() else {
            invalidate()
            return nil
        }
        return privateKey
    }

    func takeExecutionLease() async -> WalletExecutionLease? {
        let canAcquire = lock.withLock {
            guard access != nil, !executionLeaseTaken else { return false }
            executionLeaseTaken = true
            return true
        }
        guard canAcquire else { return nil }
        defer { invalidate() }
        let lease = await acquireExecutionLease()
        guard !Task.isCancelled, lock.withLock({ access != nil }) else {
            lease?.release()
            return nil
        }
        return lease
    }

    func invalidate() {
        lock.lock()
        let access = access
        self.access = nil
        lock.unlock()
        access?.invalidate()
    }

    deinit {
        invalidate()
    }
}
