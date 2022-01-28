import UIKit

enum InterfaceAppearance: String {
    
    case light
    case dark
    case system
    
    var id: String { rawValue }
    
    var system: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return .unspecified
        }
    }
}

