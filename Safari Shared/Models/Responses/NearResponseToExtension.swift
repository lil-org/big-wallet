// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ResponseToExtension {
    
    struct Near: Codable {
        
        let account: String?
        
        init(account: String? = nil) {
            self.account = account
        }
        
    }

}
