import Foundation
import Constants

extension Flags {
    
    static var seen_tutorial: Bool {
        get {  UserDefaults.shared.bool(forKey: "main_app_seen_tutorial2") }
        set { UserDefaults.shared.set(newValue, forKey: "main_app_seen_tutorial2") }
    }
    
    static var show_safari_extension_advice: Bool {
        get { UserDefaults.standard.value(forKey: "show_safari_extension_advice") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "show_safari_extension_advice") }
    }
    
    static var last_selected_ethereum_chain: EthereumChain {
        get {
            guard let id = UserDefaults.standard.value(forKey: "last_selected_ethereum_chain") as? Int else { return EthereumChain.ethereum }
            return EthereumChain(rawValue: id) ?? .ethereum
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "last_selected_ethereum_chain") }
    }
}
