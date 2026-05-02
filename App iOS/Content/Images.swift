// ∅ 2026 lil org

import UIKit

struct Images {
    
    static var noData: UIImage { systemName("wind") }
    static var failedToLoad: UIImage { systemName("xmark.octagon") }
    static var preferences: UIImage { systemName("gearshape") }
    static var circleFill: UIImage { systemName("circle.fill") }
    static var network: UIImage { systemName("network") }
    static var solana: UIImage { named("solana") }
    
    private static func named(_ name: String) -> UIImage {
        return UIImage(named: name)!
    }
    
    private static func systemName(_ systemName: String, configuration: UIImage.Configuration? = nil) -> UIImage {
        return UIImage(systemName: systemName, withConfiguration: configuration)!
    }
    
}
