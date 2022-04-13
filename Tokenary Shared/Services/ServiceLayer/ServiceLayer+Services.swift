// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ServiceLayer.Services {
    static let networkMonitor: NetworkMonitor = {
        NetworkMonitor.shared
    }()
    
    static let cachedImaged: CachedImages = {
        CachedImagesService.shared
    }()
}
