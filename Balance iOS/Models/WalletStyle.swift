import Foundation

enum WalletStyle: String, CaseIterable {
    
    case onlyName
    case onlyAddress
    case nameAndAddress
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .onlyName:
            return Texts.Settings.wallet_style_only_name
        case .onlyAddress:
            return Texts.Settings.wallet_style_only_address
        case .nameAndAddress:
            return Texts.Settings.wallet_style_name_address
        }
    }
    
    static var current: WalletStyle {
        get {
            let id = UserDefaults.standard.string(forKey: "wallet-style") ?? .empty
            return WalletStyle(rawValue: id) ?? .nameAndAddress
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: "wallet-style")
            NotificationCenter.default.post(name: .walletsUpdated)
        }
    }
}
