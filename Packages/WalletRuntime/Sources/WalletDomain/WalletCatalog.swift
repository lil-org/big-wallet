import Foundation

public struct WalletAccountDescriptor: Codable, Equatable, Hashable, Sendable {

    public let walletID: String
    public let coin: WalletCoin
    public let normalizedAddress: String
    public let derivationPath: String

    private enum CodingKeys: String, CodingKey {
        case walletID
        case coin
        case normalizedAddress
        case derivationPath
    }

    public init(
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

    public init(walletID: String, account: WalletAccount) {
        self.init(
            walletID: walletID,
            coin: account.coin,
            normalizedAddress: account.coin.normalizedAddress(account.address),
            derivationPath: account.derivationPath
        )
    }

    public func matches(walletID: String, account: WalletAccount) -> Bool {
        isValid && self == Self(walletID: walletID, account: account)
    }

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(walletID, forKey: .walletID)
        try container.encode(coin.rawValue, forKey: .coin)
        try container.encode(normalizedAddress, forKey: .normalizedAddress)
        try container.encode(derivationPath, forKey: .derivationPath)
    }

    public var account: WalletAccount {
        WalletAccount(
            address: normalizedAddress,
            coin: coin,
            derivation: .custom,
            derivationPath: derivationPath,
            publicKey: "",
            extendedPublicKey: ""
        )
    }

    public var specificAccount: SpecificWalletAccount {
        SpecificWalletAccount(walletId: walletID, account: account)
    }

    public var isValid: Bool {
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
            return WalletEncoding.base58Decode(string: normalizedAddress)?.count == 32
        }
    }
}

public struct WalletAccountCatalog: Codable, Equatable, Sendable {

    public let accounts: [WalletAccountDescriptor]

    public init(accounts: [WalletAccountDescriptor]) {
        self.accounts = accounts
    }

    public init(snapshots: [WalletSnapshot]) {
        accounts = snapshots.flatMap { wallet in
            wallet.accounts.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) }
        }
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public var isValid: Bool {
        accounts.count <= 16_384 && hasValidAccounts
    }

    public var hasValidAccounts: Bool {
        accounts.allSatisfy(\.isValid) && Set(accounts).count == accounts.count
    }
}

public struct ValidatedWalletAccountCatalog: Sendable {

    public let catalog: WalletAccountCatalog
    public let data: Data

    public init?(data: Data) {
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

public struct WalletCatalogIdentity: Equatable, Sendable {
    public let generation: UUID?
    public let catalogData: Data

    public init(generation: UUID?, catalogData: Data) {
        self.generation = generation
        self.catalogData = catalogData
    }
}

public struct WalletReviewCatalog: Sendable {

    public enum AccountAvailability: Equatable, Sendable {
        case available
        case unavailable
        case removed
    }

    public let identity: WalletCatalogIdentity
    public let orderedAccounts: [SpecificWalletAccount]
    public let knownAccounts: Set<WalletAccountDescriptor>

    public init(
        identity: WalletCatalogIdentity,
        orderedAccounts: [SpecificWalletAccount],
        knownAccounts: Set<WalletAccountDescriptor>? = nil
    ) {
        self.identity = identity
        self.orderedAccounts = orderedAccounts
        self.knownAccounts = knownAccounts ?? Set(orderedAccounts.map {
            WalletAccountDescriptor(walletID: $0.walletId, account: $0.account)
        })
    }

    public func availability(of descriptor: WalletAccountDescriptor) -> AccountAvailability {
        if specificAccount(descriptor: descriptor) != nil { return .available }
        return knownAccounts.contains(descriptor) ? .unavailable : .removed
    }

    public func specificAccount(
        coin: WalletCoin,
        address: String
    ) -> SpecificWalletAccount? {
        let normalized = coin.normalizedAddress(address)
        return orderedAccounts.first { candidate in
            candidate.account.coin == coin &&
                coin.normalizedAddress(candidate.account.address) == normalized
        }
    }

    public func specificAccount(descriptor: WalletAccountDescriptor) -> SpecificWalletAccount? {
        orderedAccounts.first {
            descriptor.matches(walletID: $0.walletId, account: $0.account)
        }
    }

    public func suggestedAccounts(coin: WalletCoin? = nil) -> [SpecificWalletAccount] {
        guard let account = orderedAccounts.first(where: {
            $0.account.coin == (coin ?? .ethereum)
        }) else { return [] }
        return [account]
    }
}

