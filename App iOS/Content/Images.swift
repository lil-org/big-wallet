// ∅ 2025 lil org

import UIKit
import WalletCore

struct Images {
    
    static var noData: UIImage { systemName("wind") }
    static var failedToLoad: UIImage { systemName("xmark.octagon") }
    static var preferences: UIImage { systemName("gearshape") }
    static var circleFill: UIImage { systemName("circle.fill") }
    static var network: UIImage { systemName("network") }
    
    private static func named(_ name: String) -> UIImage {
        return UIImage(named: name)!
    }
    
    private static func systemName(_ systemName: String, configuration: UIImage.Configuration? = nil) -> UIImage {
        return UIImage(systemName: systemName, withConfiguration: configuration)!
    }
    
}
