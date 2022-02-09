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
        
        case accounts
        case settings
        
        var id: String { return rawValue }
        
        var title: String {
            switch self {
            case .accounts: return Texts.Wallet.wallets
            case .settings: return Texts.Settings.title
            }
        }
        
        var image: UIImage {
            switch self {
            case .accounts: return UIImage(SPSafeSymbol.person.fill)
            case .settings: return UIImage(SPSafeSymbol.gear)
            }
        }
        
        var controller: UIViewController {
            switch self {
            case .accounts: return Controllers.Crypto.accounts
            case .settings: return Controllers.App.Settings.list
            }
        }
    }
}
