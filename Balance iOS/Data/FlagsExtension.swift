import Foundation
import Constants

extension Flags {
    
    static var seen_tutorial: Bool {
        get { UserDefaults.shared.bool(forKey: "main_app_seen_tutorial") }
        set { UserDefaults.shared.set(newValue, forKey: "main_app_seen_tutorial") }
    }
}
