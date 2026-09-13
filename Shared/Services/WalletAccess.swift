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

    var isValid: Bool {
        accounts.count <= 16_384 &&
            accounts.allSatisfy(\.isValid) &&
            Set(accounts).count == accounts.count
    }
}

struct WalletCatalogIdentity: Equatable, Sendable {
    let generation: UUID?
    let sourceRevision: UInt64?
    let catalogData: Data
}

enum WalletUnlockResult {
    case unlocked(RequestScopedWalletAccess)
    case canceled
    case unavailable
}

final class WalletExecutionLease: @unchecked Sendable {

    private let lock = NSLock()
    private var releaseOperation: (() -> Void)?

    init(release: @escaping () -> Void = {}) {
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

protocol WalletAccess: AnyObject {
    var catalogIdentity: WalletCatalogIdentity { get }
    var orderedAccounts: [SpecificWalletAccount] { get }
    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey?
}

extension WalletAccess {

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

final class SourceWalletAccess: WalletAccess {

    static let shared = SourceWalletAccess()

    private let walletsManager: WalletsManager

    init(walletsManager: WalletsManager = .shared) {
        self.walletsManager = walletsManager
    }

    var orderedAccounts: [SpecificWalletAccount] {
        walletsManager.wallets.flatMap { wallet in
            wallet.accounts.map {
                SpecificWalletAccount(walletId: wallet.id, account: $0)
            }
        }
    }

    var catalogIdentity: WalletCatalogIdentity {
        let catalog = WalletAccountCatalog(
            accounts: Self.descriptors(for: walletsManager.wallets)
        )
        return WalletCatalogIdentity(
            generation: nil,
            sourceRevision: nil,
            catalogData: (try? Self.encodeCatalog(catalog)) ?? Data()
        )
    }

    func specificAccount(
        coin: WalletCoin,
        address: String
    ) -> SpecificWalletAccount? {
        walletsManager.getSpecificAccount(coin: coin, address: address)
    }

    func suggestedAccounts(coin: WalletCoin? = nil) -> [SpecificWalletAccount] {
        walletsManager.suggestedAccounts(coin: coin)
    }

    func suggestedAccounts(providers: Set<InpageProvider>) -> [SpecificWalletAccount] {
        walletsManager.suggestedAccounts(providers: providers)
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        walletsManager.getPrivateKey(walletId: walletID, account: account)
    }

    static func descriptors(
        for wallets: [WalletContainer]
    ) -> [WalletAccountDescriptor] {
        wallets.flatMap { wallet in
            wallet.accounts.map { account in
                WalletAccountDescriptor(
                    walletID: wallet.id,
                    coin: account.coin,
                    normalizedAddress: account.coin.normalizedAddress(
                        account.address
                    ),
                    derivationPath: account.derivationPath
                )
            }
        }
    }

    static func encodeCatalog(_ catalog: WalletAccountCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(catalog)
    }
}

final class CatalogWalletAccess: WalletAccess {

    let catalogIdentity: WalletCatalogIdentity
    let orderedAccounts: [SpecificWalletAccount]

    init?(
        catalog: WalletAccountCatalog,
        generation: UUID,
        sourceRevision: UInt64,
        catalogData: Data
    ) {
        guard catalog.isValid,
              (try? SourceWalletAccess.encodeCatalog(catalog)) == catalogData
        else { return nil }
        catalogIdentity = WalletCatalogIdentity(
            generation: generation,
            sourceRevision: sourceRevision,
            catalogData: catalogData
        )
        orderedAccounts = catalog.accounts.map(\.specificAccount)
    }

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        nil
    }
}

final class UnlockedWalletAccess: WalletAccess {

    let catalogIdentity: WalletCatalogIdentity
    private(set) var orderedAccounts: [SpecificWalletAccount]
    private var password: Data
    private var walletsByID: [String: WalletContainer]

    init?(
        catalog: WalletAccountCatalog,
        generation: UUID,
        sourceRevision: UInt64,
        catalogData: Data,
        password: Data,
        walletRecords: [(id: String, data: Data)]
    ) {
        guard !password.isEmpty,
              catalog.isValid,
              (try? SourceWalletAccess.encodeCatalog(catalog)) == catalogData
        else { return nil }

        var wallets = [WalletContainer]()
        wallets.reserveCapacity(walletRecords.count)
        guard Set(walletRecords.map(\.id)).count == walletRecords.count
        else { return nil }
        for record in walletRecords {
            guard let key = WalletStoredKey.importJSON(json: record.data)
            else { return nil }
            let wallet = WalletContainer(id: record.id, key: key)
            guard Self.ownsStoredAccounts(wallet, password: password) else {
                return nil
            }
            wallets.append(wallet)
        }
        guard SourceWalletAccess.descriptors(for: wallets) == catalog.accounts else {
            return nil
        }

        self.password = password
        walletsByID = Dictionary(
            uniqueKeysWithValues: wallets.map { ($0.id, $0) }
        )
        orderedAccounts = wallets.flatMap { wallet in
            wallet.accounts.map {
                SpecificWalletAccount(walletId: wallet.id, account: $0)
            }
        }
        catalogIdentity = WalletCatalogIdentity(
            generation: generation,
            sourceRevision: sourceRevision,
            catalogData: catalogData
        )
    }

    private static func ownsStoredAccounts(
        _ wallet: WalletContainer,
        password: Data
    ) -> Bool {
        let accounts = wallet.accounts
        guard accounts.count == wallet.key.accountCount,
              var secret = wallet.key.decryptPrivateKey(password: password)
        else { return false }
        defer { secret.resetBytes(in: 0..<secret.count) }

        if wallet.isMnemonic {
            return mnemonicAccountsMatch(accounts, secret: secret)
        }
        return privateKeyAccountsMatch(accounts, secret: secret)
    }

    private static func mnemonicAccountsMatch(
        _ accounts: [WalletAccount],
        secret: Data
    ) -> Bool {
        guard let mnemonic = String(data: secret, encoding: .utf8),
              let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: "")
        else { return false }
        return accounts.allSatisfy { account in
            guard let privateKey = wallet.privateKey(
                coin: account.coin,
                derivationPath: account.derivationPath
            ) else { return false }
            return accountMatches(account, privateKey: privateKey)
        }
    }

    private static func privateKeyAccountsMatch(
        _ accounts: [WalletAccount],
        secret: Data
    ) -> Bool {
        guard let privateKey = WalletPrivateKey(data: secret) else {
            return false
        }
        return accounts.allSatisfy { account in
            guard WalletCrypto.isValidPrivateKeyData(
                secret,
                coin: account.coin
            ) else { return false }
            return accountMatches(account, privateKey: privateKey)
        }
    }

    private static func accountMatches(
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

    func privateKey(
        walletID: String,
        account: WalletAccount
    ) -> WalletPrivateKey? {
        guard let wallet = walletsByID[walletID],
              wallet.hasAccountMatching(account) else { return nil }
        return try? wallet.privateKey(passwordData: password, account: account)
    }

    func invalidate() {
        password.resetBytes(in: 0..<password.count)
        password.removeAll(keepingCapacity: false)
        orderedAccounts.removeAll(keepingCapacity: false)
        walletsByID.removeAll(keepingCapacity: false)
    }

    deinit {
        invalidate()
    }
}

final class RequestScopedWalletAccess: WalletAccess {

    private let lock = NSLock()
    private var access: WalletAccess?
    private let isCurrent: () -> Bool
    private let acquireExecutionLease: () -> WalletExecutionLease?
    private var executionLeaseTaken = false

    init(
        _ access: WalletAccess,
        isCurrent: @escaping () -> Bool = { true },
        acquireExecutionLease: (() -> WalletExecutionLease?)? = nil
    ) {
        self.access = access
        self.isCurrent = isCurrent
        self.acquireExecutionLease = acquireExecutionLease ?? {
            isCurrent() ? WalletExecutionLease() : nil
        }
    }

    var catalogIdentity: WalletCatalogIdentity {
        guard isCurrent() else {
            invalidate()
            return WalletCatalogIdentity(
                generation: nil,
                sourceRevision: nil,
                catalogData: Data()
            )
        }
        lock.lock()
        defer { lock.unlock() }
        guard !executionLeaseTaken else {
            return WalletCatalogIdentity(
                generation: nil,
                sourceRevision: nil,
                catalogData: Data()
            )
        }
        return access?.catalogIdentity ?? WalletCatalogIdentity(
            generation: nil,
            sourceRevision: nil,
            catalogData: Data()
        )
    }

    var orderedAccounts: [SpecificWalletAccount] {
        guard isCurrent() else {
            invalidate()
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        guard !executionLeaseTaken else { return [] }
        return access?.orderedAccounts ?? []
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

    func takeExecutionLease() -> WalletExecutionLease? {
        lock.lock()
        guard access != nil, !executionLeaseTaken else {
            lock.unlock()
            return nil
        }
        executionLeaseTaken = true
        lock.unlock()
        let lease = acquireExecutionLease()
        invalidate()
        return lease
    }

    func invalidate() {
        lock.lock()
        let access = access
        self.access = nil
        lock.unlock()
        if let scoped = access as? RequestScopedWalletAccess {
            scoped.invalidate()
        } else {
            (access as? UnlockedWalletAccess)?.invalidate()
        }
    }

    deinit {
        invalidate()
    }
}
