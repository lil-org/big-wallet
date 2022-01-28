import UIKit
import SparrowKit
import SPAlert

enum Appearance {
    
    static func configure(rootWindow: UIWindow) {
        SPAlertView.appearance().cornerRadius = Corners.spalert
        if currentInterfaceAppearance != .system {
            rootWindow.overrideUserInterfaceStyle = currentInterfaceAppearance.system
        }
    }
    
    enum Scroll {
        
        static var height_for_change_appearance_navigation: CGFloat { 16 }
    }
    
    enum Corners {
        
        static var spalert: CGFloat { 15 }
        static var large_action_button: CGFloat { 15 }
        static var cell_image: CGFloat { 12 }
        static var readable_width_image: CGFloat { 15 }
    }
    
    enum Higlight {
        
        static var alpha: CGFloat { 0.6 }
    }
    
    // MARK: - Interface
    
    static var currentInterfaceAppearance: InterfaceAppearance {
        get {
            let id = UserDefaults.standard.string(forKey: "interface_style") ?? .space
            return InterfaceAppearance(rawValue: id) ?? .system
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: "interface_style")
            for window in UIApplication.shared.windows {
                window.overrideUserInterfaceStyle = newValue.system
            }
        }
    }
}
