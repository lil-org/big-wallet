#if os(macOS)
import AppKit
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers

final class RemoteImageLoader {
    
    static let shared = RemoteImageLoader()
    static let maximumResponseBytes = 1_048_576
    static let maximumPixelDimension = 1_024
    static let maximumDuration: TimeInterval = 3
    
    private let configuration: URLSessionConfiguration
    private let duration: TimeInterval
    
    init(
        configuration: URLSessionConfiguration = .ephemeral,
        duration: TimeInterval = RemoteImageLoader.maximumDuration
    ) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.duration = min(duration, Self.maximumDuration)
    }
    
    func loadImage(
        from url: URL,
        completion: @escaping (NSImage?) -> Void
    ) -> RemoteImageLoadTask {
        let request = RemoteImageRequest(completion: completion)
        let task = RemoteImageLoadTask(request: request)
        request.start(url: url, configuration: configuration, duration: duration)
        return task
    }
    
    fileprivate static func allows(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    fileprivate static func decode(_ data: Data) -> NSImage? {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...Double(maximumPixelDimension)).contains(width.doubleValue),
              (1...Double(maximumPixelDimension)).contains(height.doubleValue),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    
}

final class RemoteImageLoadTask {

    private let request: RemoteImageRequest
    
    fileprivate init(request: RemoteImageRequest) {
        self.request = request
    }

    func cancel() {
        request.cancel()
    }

    deinit {
        cancel()
    }
    
}

private final class RemoteImageRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    
    private let lock = NSLock()
    private var completion: ((NSImage?) -> Void)?
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var data = Data()
    private var finished = false
    private var cancelled = false

    init(completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
    }

    func start(url: URL, configuration: URLSessionConfiguration, duration: TimeInterval) {
        guard RemoteImageLoader.allows(url) else {
            finish(image: nil)
            return
        }

        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = duration
        configuration.timeoutIntervalForResource = duration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: url)
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { [weak self] in
            self?.finish(image: nil)
        }
        self.session = session
        self.timer = timer
        timer.resume()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(image: nil)
    }

    private func finish(image: NSImage?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let completion = completion
        self.completion = nil
        let session = session
        self.session = nil
        let timer = timer
        self.timer = nil
        data.removeAll()
        lock.unlock()

        timer?.cancel()
        session?.invalidateAndCancel()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let shouldDeliver = !cancelled
            lock.unlock()
            if shouldDeliver {
                completion?(image)
            }
        }
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard RemoteImageLoader.allows(request.url) else {
            completionHandler(nil)
            finish(image: nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              RemoteImageLoader.allows(response.url),
              (200...299).contains(response.statusCode),
              response.expectedContentLength <= RemoteImageLoader.maximumResponseBytes,
              let mime = response.mimeType?.lowercased(),
              mime.hasPrefix("image/"),
              UTType(mimeType: mime)?.conforms(to: .image) == true
        else {
            completionHandler(.cancel)
            finish(image: nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        guard chunk.count <= RemoteImageLoader.maximumResponseBytes - data.count else {
            lock.unlock()
            finish(image: nil)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let received = finished ? nil : data
        lock.unlock()
        guard let received else { return }
        finish(image: error == nil ? RemoteImageLoader.decode(received) : nil)
    }

}

private var remoteImageLoadKey: UInt8 = 0

private final class RemoteImageViewLoad {
    var task: RemoteImageLoadTask?
}

extension NSImageView {

    private var remoteImageLoad: RemoteImageViewLoad? {
        get { objc_getAssociatedObject(self, &remoteImageLoadKey) as? RemoteImageViewLoad }
        set { objc_setAssociatedObject(self, &remoteImageLoadKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func cancelRemoteImageLoad() {
        remoteImageLoad?.task?.cancel()
        remoteImageLoad = nil
    }

    func setRemoteImage(
        with urlString: String?,
        loader: RemoteImageLoader = .shared,
        completion: ((NSImage?) -> Void)? = nil
    ) {
        cancelRemoteImageLoad()
        image = nil
        guard let urlString, let url = URL(string: urlString) else {
            completion?(nil)
            return
        }
        let load = RemoteImageViewLoad()
        remoteImageLoad = load
        load.task = loader.loadImage(from: url) { [weak self, weak load] image in
            guard let self, let load, self.remoteImageLoad === load else { return }
            self.image = image
            self.remoteImageLoad = nil
            completion?(image)
        }
    }
    
}
#endif
