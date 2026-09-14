#if os(macOS)
import AppKit
import XCTest
@testable import Big_Wallet

final class RemoteImageLoaderTests: XCTestCase {

    private func loader(duration: TimeInterval = RemoteImageLoader.maximumDuration) -> RemoteImageLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageTestProtocol.self]
        return RemoteImageLoader(configuration: configuration, duration: duration)
    }

    private func endpoint(
        scheme: String = "https",
        stopped: (() -> Void)? = nil,
        start: @escaping (RemoteImageTestProtocol) -> Void
    ) -> URL {
        let url = URL(string: "\(scheme)://\(UUID().uuidString).favicon-tests.invalid/icon.png")!
        RemoteImageTestProtocol.install(url: url, start: start, stopped: stopped)
        addTeardownBlock { RemoteImageTestProtocol.remove(url: url) }
        return url
    }

    private func png(width: Int = 1, height: Int = 1) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func load(from url: URL, using loader: RemoteImageLoader? = nil) -> NSImage? {
        let completed = expectation(description: "favicon completed")
        var received: NSImage?
        let task = (loader ?? self.loader()).loadImage(from: url) { image in
            XCTAssertTrue(Thread.isMainThread)
            received = image
            completed.fulfill()
        }
        withExtendedLifetime(task) {
            wait(for: [completed], timeout: 2)
        }
        return received
    }

    func testLoadsHTTPAndHTTPSImagesAtDimensionLimit() throws {
        let data = try png(width: 1_024, height: 1_024)
        for scheme in ["http", "https"] {
            let url = endpoint(scheme: scheme) { request in
                request.respond(data: data)
            }
            let image = try XCTUnwrap(load(from: url))
            XCTAssertEqual(image.size, NSSize(width: 1_024, height: 1_024))
        }
    }

    func testRejectsNonHTTPURLWithoutStartingNetworkRequest() {
        XCTAssertNil(load(from: URL(fileURLWithPath: "/favicon.png")))
        XCTAssertNil(load(from: URL(string: "data:image/png;base64,AA==")!))
        XCTAssertNil(load(from: URL(string: "ftp://favicon-tests.invalid/icon.png")!))
    }

    func testRejectsInvalidStatusMIMEAndImageData() throws {
        let data = try png()
        for mime in ["text/html", "application/octet-stream", "image/not-a-real-type"] {
            let url = endpoint { request in
                request.respond(data: data, mime: mime)
            }
            XCTAssertNil(load(from: url), mime)
        }
        let failure = endpoint { request in
            request.respond(data: data, status: 500)
        }
        XCTAssertNil(load(from: failure))
        let malformed = endpoint { request in
            request.respond(data: Data("not an image".utf8))
        }
        XCTAssertNil(load(from: malformed))
    }

    func testRejectsImagesExceedingEitherDimension() throws {
        for size in [(1_025, 1), (1, 1_025)] {
            let data = try png(width: size.0, height: size.1)
            let url = endpoint { request in
                request.respond(data: data)
            }
            XCTAssertNil(load(from: url))
        }
    }

    func testAcceptsExactlyOneMiB() throws {
        var data = try png()
        data.append(Data(repeating: 0, count: 1_048_576 - data.count))
        let payload = data
        let url = endpoint { request in
            request.respond(data: payload)
        }
        XCTAssertNotNil(load(from: url))
    }

    func testRejectsDeclaredOversizeBeforeBodyCompletes() {
        let stopped = expectation(description: "oversized response cancelled")
        let url = endpoint(stopped: { stopped.fulfill() }) { request in
            request.sendResponse(contentLength: 1_048_577)
            request.client?.urlProtocol(request, didLoad: Data(repeating: 0, count: 1_024))
        }
        XCTAssertNil(load(from: url))
        wait(for: [stopped], timeout: 2)
    }

    func testCancelsAsSoonAsChunkedResponseExceedsOneMiB() {
        let stopped = expectation(description: "oversized stream cancelled")
        let url = endpoint(stopped: { stopped.fulfill() }) { request in
            request.sendResponse()
            request.client?.urlProtocol(request, didLoad: Data(repeating: 0, count: 524_288))
            request.client?.urlProtocol(request, didLoad: Data(repeating: 0, count: 524_288))
            request.client?.urlProtocol(request, didLoad: Data([0]))
        }
        XCTAssertNil(load(from: url))
        wait(for: [stopped], timeout: 2)
    }

    func testRedirectsAreRestrictedToHTTPAndHTTPS() throws {
        let data = try png()
        let target = endpoint(scheme: "http") { request in request.respond(data: data) }
        let safe = endpoint { request in request.redirect(to: target) }
        XCTAssertNotNil(load(from: safe))

        let unsafe = endpoint { request in
            request.redirect(to: URL(fileURLWithPath: "/favicon.png"))
        }
        XCTAssertNil(load(from: unsafe))
    }

    func testDeadlineCancelsAnUnfinishedResponse() {
        let stopped = expectation(description: "deadline cancelled transport")
        let url = endpoint(stopped: { stopped.fulfill() }) { request in
            request.sendResponse()
            request.client?.urlProtocol(request, didLoad: Data([0]))
        }
        XCTAssertNil(load(from: url, using: loader(duration: 0.05)))
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(RemoteImageLoader.maximumDuration, 3)
    }

    func testCancellationStopsTransportAndSuppressesCompletion() {
        let started = expectation(description: "transport started")
        let stopped = expectation(description: "transport cancelled")
        let completed = expectation(description: "cancelled load stays silent")
        completed.isInverted = true
        let url = endpoint(stopped: { stopped.fulfill() }) { _ in started.fulfill() }
        let task = loader().loadImage(from: url) { _ in completed.fulfill() }
        wait(for: [started], timeout: 2)
        task.cancel()
        task.cancel()
        wait(for: [stopped], timeout: 2)
        wait(for: [completed], timeout: 0.05)
    }

    @MainActor
    func testReusingImageViewSuppressesPreviousCompletion() throws {
        let first = try png()
        let second = try png(width: 2, height: 2)
        let oldURL = endpoint { request in request.respond(data: first) }
        let newURL = endpoint { request in request.respond(data: second) }
        let imageView = NSImageView()
        let completed = expectation(description: "replacement image loaded")
        var oldCompletions = 0
        let loader = loader()
        imageView.setRemoteImage(with: oldURL.absoluteString, loader: loader) { _ in
            oldCompletions += 1
        }
        imageView.setRemoteImage(with: newURL.absoluteString, loader: loader) { image in
            XCTAssertEqual(image?.size, NSSize(width: 2, height: 2))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(imageView.image?.size, NSSize(width: 2, height: 2))
        XCTAssertEqual(oldCompletions, 0)
    }

    @MainActor
    func testImageViewTeardownCancelsLoad() {
        let started = expectation(description: "image view transport started")
        let stopped = expectation(description: "image view teardown cancelled transport")
        let url = endpoint(stopped: { stopped.fulfill() }) { _ in started.fulfill() }
        var imageView: NSImageView? = NSImageView()
        weak var releasedView = imageView
        imageView?.setRemoteImage(with: url.absoluteString, loader: loader())
        wait(for: [started], timeout: 2)
        imageView = nil
        XCTAssertNil(releasedView)
        wait(for: [stopped], timeout: 2)
    }

}

private final class RemoteImageTestProtocol: URLProtocol {

    private struct Handler {
        let start: (RemoteImageTestProtocol) -> Void
        let stopped: (() -> Void)?
    }

    private static let lock = NSLock()
    private static var handlers: [URL: Handler] = [:]
    private var handler: Handler?

    static func install(
        url: URL,
        start: @escaping (RemoteImageTestProtocol) -> Void,
        stopped: (() -> Void)?
    ) {
        lock.lock()
        handlers[url] = Handler(start: start, stopped: stopped)
        lock.unlock()
    }

    static func remove(url: URL) {
        lock.lock()
        handlers[url] = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host?.hasSuffix(".favicon-tests.invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        handler = request.url.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        handler.start(self)
    }

    override func stopLoading() {
        handler?.stopped?()
    }

    func sendResponse(mime: String = "image/png", status: Int = 200, contentLength: Int? = nil) {
        var headers = ["Content-Type": mime]
        if let contentLength { headers["Content-Length"] = String(contentLength) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func respond(data: Data, mime: String = "image/png", status: Int = 200) {
        sendResponse(mime: mime, status: status, contentLength: data.count)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func redirect(to url: URL) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": url.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
    }

}
#endif
