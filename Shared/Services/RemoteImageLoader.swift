// ∅ 2026 lil org

import Foundation
import ObjectiveC

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif

final class RemoteImageLoader {
    
    static let shared = RemoteImageLoader()
    
    private let cache = NSCache<NSURL, PlatformSpecificImage>()
    private let session = URLSession(configuration: .default)
    
    private init() {}
    
    @discardableResult
    func loadImage(from url: URL, completion: @escaping (PlatformSpecificImage?) -> Void) -> URLSessionDataTask? {
        let key = url as NSURL
        if let cachedImage = cache.object(forKey: key) {
            DispatchQueue.main.async {
                completion(cachedImage)
            }
            return nil
        }
        
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard error == nil,
                  Self.isValidResponse(response),
                  let data = data,
                  let image = PlatformSpecificImage(data: data)
            else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            self?.cache.setObject(image, forKey: key)
            DispatchQueue.main.async {
                completion(image)
            }
        }
        task.resume()
        return task
    }
    
    private static func isValidResponse(_ response: URLResponse?) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return true }
        return (200...299).contains(httpResponse.statusCode)
    }
    
}

private var remoteImageTaskKey: UInt8 = 0
private var remoteImageURLKey: UInt8 = 0

private protocol RemoteImageLoadable: AnyObject {
    
    var remoteImageLoadTask: URLSessionDataTask? { get set }
    var remoteImageLoadURL: URL? { get set }
    
}

extension RemoteImageLoadable {
    
    var remoteImageLoadTask: URLSessionDataTask? {
        get {
            objc_getAssociatedObject(self, &remoteImageTaskKey) as? URLSessionDataTask
        }
        set {
            objc_setAssociatedObject(self, &remoteImageTaskKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    var remoteImageLoadURL: URL? {
        get {
            objc_getAssociatedObject(self, &remoteImageURLKey) as? URL
        }
        set {
            objc_setAssociatedObject(self, &remoteImageURLKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    func cancelCurrentRemoteImageLoad() {
        remoteImageLoadTask?.cancel()
        remoteImageLoadTask = nil
        remoteImageLoadURL = nil
    }
    
}

#if os(iOS) || os(visionOS)
extension UIImageView: RemoteImageLoadable {
    
    func cancelRemoteImageLoad() {
        cancelCurrentRemoteImageLoad()
    }
    
    func setRemoteImage(with url: URL, completion: ((Bool) -> Void)? = nil) {
        cancelCurrentRemoteImageLoad()
        remoteImageLoadURL = url
        remoteImageLoadTask = RemoteImageLoader.shared.loadImage(from: url) { [weak self] image in
            guard let self, remoteImageLoadURL == url else { return }
            if let image {
                self.image = image
                completion?(true)
            } else {
                completion?(false)
            }
            remoteImageLoadTask = nil
        }
    }
    
}
#elseif os(macOS)
extension NSImageView: RemoteImageLoadable {
    
    func cancelRemoteImageLoad() {
        cancelCurrentRemoteImageLoad()
    }
    
    func setRemoteImage(with url: URL, completion: ((Bool) -> Void)? = nil) {
        cancelCurrentRemoteImageLoad()
        remoteImageLoadURL = url
        remoteImageLoadTask = RemoteImageLoader.shared.loadImage(from: url) { [weak self] image in
            guard let self, remoteImageLoadURL == url else { return }
            if let image {
                self.image = image
                completion?(true)
            } else {
                completion?(false)
            }
            remoteImageLoadTask = nil
        }
    }
    
}
#endif
