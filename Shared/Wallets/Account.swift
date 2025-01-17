// ∅ 2025 lil org

import WalletCore

extension Account {

    var croppedAddress: String {
        let dropFirstCount: Int
        switch coin {
        case .ethereum:
            dropFirstCount = 2
        case .near, .solana:
            dropFirstCount = 0
        default:
            fatalError(Strings.somethingWentWrong)
        }
        let withoutCommonPart = String(address.dropFirst(dropFirstCount))
        return withoutCommonPart.prefix(4) + "..." + withoutCommonPart.suffix(4)
    }
    
    var image: PlatformSpecificImage? {
        if coin == .ethereum {
            return Blockies(seed: address.lowercased()).createImage()
        } else {
            return Images.circleFill
        }
    }
    
    func nameOrCroppedAddress(walletId: String) -> String {
        return WalletsMetadataService.getAccountName(walletId: walletId, account: self) ?? croppedAddress
    }
    
    func name(walletId: String) -> String? {
        return WalletsMetadataService.getAccountName(walletId: walletId, account: self)
    }
    
}
