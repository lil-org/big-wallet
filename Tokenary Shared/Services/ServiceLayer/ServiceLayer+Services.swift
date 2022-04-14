// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension ServiceLayer.Services {
    static let networkMonitor: NetworkMonitor = {
        NetworkMonitor.shared
    }()
    
    static let images: ImagesService = {
        ImagesServiceImp(
            operationsQueue: DispatchQueue(label: "io.Tokenary.image_service"),
            cache: imagesCache
        )
    }()
    
    static let imagesCache: ImageCacheService = {
        ImageCacheServiceImp(
            diskOperationsQueue: DispatchQueue(label: "io.Tokenary.image_disk_cache"),
            dataCachePath: NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0] + "/image",
            softLimit: 15 * 1024 * 1024,
            hardLimit: 20 * 1024 * 1024
        )
    }()
    
}
