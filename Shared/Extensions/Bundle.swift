// ∅ 2024 lil org

import Foundation

extension Bundle {
    
    var identifier: String {
        return infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    }
    
    var name: String {
        return infoDictionary?["CFBundleName"] as? String ?? ""
    }
    
    var shortVersionString: String {
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
    
}
