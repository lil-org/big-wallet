import Foundation

public enum WalletCoin: UInt32, Hashable, Sendable {
    case ethereum = 60
    case solana = 501

    public var slip44Id: UInt32 { rawValue }
}

public enum WalletDerivation: Hashable, Sendable {
    case `default`
    case solanaSolana
    case custom
}

public struct WalletAccount: Hashable, Sendable {
    public let address: String
    public let coin: WalletCoin
    public let derivation: WalletDerivation
    public let derivationPath: String
    public let publicKey: String
    public let extendedPublicKey: String

    public init(address: String,
         coin: WalletCoin,
         derivation: WalletDerivation,
         derivationPath: String,
         publicKey: String,
         extendedPublicKey: String) {
        self.address = address
        self.coin = coin
        self.derivation = derivation
        self.derivationPath = derivationPath
        self.publicKey = publicKey
        self.extendedPublicKey = extendedPublicKey
    }
}


public struct SpecificWalletAccount: Hashable, Sendable {
    public let walletId: String
    public let account: WalletAccount

    public init(walletId: String, account: WalletAccount) { self.walletId = walletId; self.account = account }
}
public struct WalletSnapshot: Hashable, Sendable {
    public let id: String
    public let isMnemonic: Bool
    public let accounts: [WalletAccount]

    public init(id: String, isMnemonic: Bool, accounts: [WalletAccount]) {
        self.id = id
        self.isMnemonic = isMnemonic
        self.accounts = accounts
    }

    public func hasAccountMatching(_ account: WalletAccount) -> Bool {
        let normalizedAddress = account.coin.normalizedAddress(account.address)
        return accounts.contains {
            $0.coin == account.coin &&
                $0.derivationPath == account.derivationPath &&
                account.coin.normalizedAddress($0.address) == normalizedAddress
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}


extension WalletCoin {
    public nonisolated var correspondingInpageProvider: InpageProvider {
        switch self {
        case .ethereum:
            return .ethereum
        case .solana:
            return .solana
        }
    }

    public nonisolated static func correspondingToInpageProvider(_ inpageProvider: InpageProvider) -> WalletCoin? {
        switch inpageProvider {
        case .ethereum:
            return .ethereum
        case .solana:
            return .solana
        case .unknown, .multiple:
            return nil
        }
    }

    public func normalizedAddress(_ address: String) -> String {
        switch self {
        case .ethereum:
            return address.lowercased()
        case .solana:
            return address
        }
    }
    
}
