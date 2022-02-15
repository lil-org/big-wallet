import UIKit
import SPSafeSymbols

struct BarRowModel {
    
    let id: String
    let title: String
    let image: UIImage
    
    var getController: (() -> UIViewController)
    
    init(id: String, title: String, image: UIImage, getController: @escaping (() -> UIViewController)) {
        self.id = id
        self.title = title
        self.image = image
        self.getController = getController
    }
    
    enum Item: String, CaseIterable {
        
        case wallets
        case nft
        case settings
        
        var id: String { return rawValue }
        
        var title: String {
            switch self {
            case .wallets: return Texts.Wallet.wallets
            case .nft: return Texts.NFT.title
            case .settings: return Texts.Settings.title
            }
        }
        
        var image: UIImage {
            switch self {
            case .wallets: return UIImage(SPSafeSymbol.mail.stackFill)
            case .nft: return UIImage(SPSafeSymbol.square.stack_3dDownRightFill)
            case .settings: return UIImage(SPSafeSymbol.gear)
            }
        }
        
        var controller: UIViewController {
            switch self {
            case .wallets: return Controllers.Crypto.accounts
            case .nft: return Controllers.Crypto.NFT.list
            case .settings: return Controllers.App.Settings.list
            }
        }
    }
}
