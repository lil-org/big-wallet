// Copyright © 2021 Tokenary. All rights reserved.

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
