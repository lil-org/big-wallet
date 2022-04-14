// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import Kingfisher

struct CacheItemAvailability: OptionSet {
    let rawValue: Int
    
    init(rawValue: Int) { self.rawValue = rawValue }
    
    static let memory: CacheItemAvailability = .init(rawValue: 1 << 0)
    static let disk: CacheItemAvailability = .init(rawValue: 1 << 1)
    
    static let both: CacheItemAvailability = [.memory, .disk]
}

private struct ImageCacheItem {
    var image: UIImage
    var size: CGFloat
    var timestamp: CFAbsoluteTime
    
    init(image: UIImage, size: CGFloat) {
        self.image = image
        self.size = size
        self.timestamp = CFAbsoluteTimeGetCurrent()
    }
    
    init(updatingTimestamp record: ImageCacheItem) {
        self = .init(image: record.image, size: record.size)
    }
}

protocol ImageCacheService {
    func cache(image: UIImage, forKey key: String, having availability: CacheItemAvailability)
    func image(forKey key: String, having availability: CacheItemAvailability) -> UIImage?
    func move(from oldKey: String, to newKey: String)
    func remove(key: String)
    
    func diskCacheContains(key: String) -> Bool
    func removeImageOnDisk(forKey key: String)
    func removeImageInMemory(forKey key: String)
}

final class ImageCacheServiceImp: ImageCacheService {
    // MARK: - Lifecycle
    
    init(
        diskOperationsQueue: DispatchQueue, dataCachePath: String, softLimit: CGFloat, hardLimit: CGFloat
    ) {
        precondition(URL(fileURLWithPath: dataCachePath).isFileURL, "Cache path must resolve to path on disk!")
        self.diskOperationsQueue = diskOperationsQueue
        self.diskCachePath = dataCachePath
        
        self.inMemorySoftLimit = min(softLimit, hardLimit)
        self.inMemoryHardLimit = max(softLimit, hardLimit)
        self.memoryWarningBaseline = 0.2 * inMemorySoftLimit
        self.backgroundBaseline = 0.5 * inMemorySoftLimit
        
        if !fileManager.directoryExists(atPath: diskCachePath) {
            try? fileManager.removeItem(atPath: diskCachePath)
            try? fileManager.createDirectory(atPath: diskCachePath, withIntermediateDirectories: true, attributes: nil)
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning(notification:)),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEnterBackground(notification:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Private Properties
    
    private var memoryCache: [String: ImageCacheItem] = [:]
    private var occupiedMemory: CGFloat = .zero
    
    private let diskCachePath: String
    /// Absolute limit
    private let inMemoryHardLimit: CGFloat
    /// Purge up to limit
    private let inMemorySoftLimit: CGFloat
    private let memoryWarningBaseline: CGFloat
    private let backgroundBaseline: CGFloat
    
    private let diskOperationsQueue: DispatchQueue
    private let fileManager: FileManager = .default
    
    // MARK: - Public Methods
    
    func cache(image: UIImage, forKey key: String, having availability: CacheItemAvailability) {
        if availability.contains(.memory) {
            let actionClosure = {
                let size = image.size.width * image.size.height * image.scale * 4 // width * height * pixels * color
                if let cachedItem = self.memoryCache[key] {
                    self.occupiedMemory -= cachedItem.size
                }
                self.memoryCache[key] = ImageCacheItem(image: image, size: size)
                self.occupiedMemory += size
                
                if self.occupiedMemory >= self.inMemoryHardLimit {
                    self.freeInMemoryCache(upTo: self.inMemorySoftLimit)
                }
            }
            DispatchQueue.safeMainAsync(actionClosure)
        }
        
        if availability.contains(.disk) {
            diskOperationsQueue.async {
                try? image.pngData()?.write(to: self.diskCacheURL(having: key), options: .atomic)
            }
        }
    }
    
    func image(forKey key: String, having availability: CacheItemAvailability) -> UIImage? {
        var result: UIImage?
        
        if availability.contains(.memory) {
            var image: UIImage?
            DispatchQueue.safeMainSync {
                if let cachedItem = self.memoryCache[key] {
                    self.memoryCache[key] = ImageCacheItem(updatingTimestamp: cachedItem)
                    image = cachedItem.image
                }
            }
            result = image
        }
        if result != nil {
            return result
        }
        
        if availability.contains(.disk) {
            var image: UIImage?
            diskOperationsQueue.sync {
                let options = [
                    kCGImageSourceShouldCache: kCFBooleanTrue // decode immediately
                ] as CFDictionary
                if
                    let imageSource = CGImageSourceCreateWithURL(self.diskCacheURL(having: key) as CFURL, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(imageSource, .zero, options)
                {
                    image = UIImage(cgImage: cgImage)
                    if availability.contains(.memory) {
                        cache(image: image!, forKey: key, having: .memory)
                    }
                }
            }
            result = image
        }
        
        return result
    }
    
    func move(from oldKey: String, to newKey: String) {
        DispatchQueue.safeMainAsync {
            if let cachedItem = self.memoryCache[oldKey] {
                self.memoryCache[newKey] = ImageCacheItem(updatingTimestamp: cachedItem)
                self.memoryCache.removeValue(forKey: oldKey)
            }
        }
        diskOperationsQueue.async {
            try? self.fileManager.moveItem(
                at: self.diskCacheURL(having: oldKey), to: self.diskCacheURL(having: newKey)
            )
        }
    }
    
    func remove(key: String) {
        removeImageInMemory(forKey: key)
        removeImageOnDisk(forKey: key)
    }
    
    func diskCacheContains(key: String) -> Bool {
        var isPresent: Bool = false
        diskOperationsQueue.sync {
            isPresent = fileManager.fileExists(atPath: self.diskCacheURL(having: key).path)
        }
        return isPresent
    }
    
    func removeImageOnDisk(forKey key: String) {
        diskOperationsQueue.async {
            try? self.fileManager.removeItem(at: self.diskCacheURL(having: key))
        }
    }
    
    func removeImageInMemory(forKey key: String) {
        DispatchQueue.safeMainSync {
            let removedItem = self.memoryCache.removeValue(forKey: key)
            self.occupiedMemory -= removedItem?.size ?? .zero
            
            if self.occupiedMemory < .zero {
                self.occupiedMemory = .zero
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func diskCacheURL(having key: String) -> URL {
        URL(fileURLWithPath: diskCachePath).appendingPathComponent(key.md5())
    }
    
    private func freeInMemoryCache(upTo baselineSize: CGFloat) {
        let actionClosure = {
            let sortedKeys = self.memoryCache
                .sorted { $0.value.timestamp < $1.value.timestamp }
                .map { $0.key }
            for key in sortedKeys {
                guard self.occupiedMemory > baselineSize else { break }
                
                let removedItem = self.memoryCache.removeValue(forKey: key)
                self.occupiedMemory -= removedItem?.size ?? .zero
            }
            if self.occupiedMemory < .zero {
                self.occupiedMemory = .zero
            }
            if Constants.isDebug {
                let realOccupiedMemory: CGFloat = self.memoryCache.reduce(.zero) { $0 + $1.value.size }
                print("Cache size supposed: \(self.occupiedMemory) - Cache size real: \(realOccupiedMemory)")
            }
        }
        
        DispatchQueue.safeMainAsync(actionClosure)
    }
    
    @objc private func didReceiveMemoryWarning(notification: Notification) {
        freeInMemoryCache(upTo: memoryWarningBaseline)
    }
    
    @objc private func didEnterBackground(notification: Notification) {
        freeInMemoryCache(upTo: backgroundBaseline)
    }
    
    private func clearCache() {
        DispatchQueue.safeMainAsync {
            self.memoryCache.removeAll()
            self.occupiedMemory = .zero
        }
        diskOperationsQueue.async {
            if let allFilePaths = try? self.fileManager.contentsOfDirectory(atPath: self.diskCachePath) {
                for filePath in allFilePaths {
                    try? self.fileManager.removeItem(
                        at: URL(fileURLWithPath: self.diskCachePath).appendingPathComponent(filePath)
                    )
                }
            }
        }
    }
}
