import Foundation

public struct WalletPreviewAccountKey: Hashable, Sendable {
    public let coin: WalletCoin
    public let derivationPath: String

    public init(coin: WalletCoin, derivationPath: String) {
        self.coin = coin
        self.derivationPath = derivationPath
    }
}


extension WalletAccount {
    public var previewAccountKey: WalletPreviewAccountKey {
        return WalletPreviewAccountKey(coin: coin, derivationPath: derivationPath)
    }

    public var previewDerivationIndex: Int {
        return WalletEncoding.previewDerivationIndex(derivationPath: derivationPath, coin: coin)
    }

    public var croppedAddress: String {
        let dropFirstCount: Int
        switch coin {
        case .ethereum:
            dropFirstCount = 2
        case .solana:
            dropFirstCount = 0
        }
        let withoutCommonPart = String(address.dropFirst(dropFirstCount))
        return withoutCommonPart.prefix(4) + "..." + withoutCommonPart.suffix(4)
    }
    
}

extension WalletCoin {
    public var name: String {
        switch self {
        case .solana:
            return "Solana"
        case .ethereum:
            return "Ethereum"
        }
    }
    
}
