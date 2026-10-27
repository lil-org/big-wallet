import Foundation
import XCTest
@testable import WalletNetworking

final class WalletHTTPSessionTests: XCTestCase {
    func testDefaultSessionDisablesCookiesCredentialsAndCaching() {
        let session = WalletHTTPSession.make()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration

        XCTAssertNil(session.delegate)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 604_800)
    }

    func testSessionUsesRequestedTimeouts() {
        let session = WalletHTTPSession.make(timeoutIntervalForRequest: 12, timeoutIntervalForResource: 45)
        defer { session.invalidateAndCancel() }

        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 12)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 45)
    }

    @MainActor
    func testSessionConfigurationPreservesExplicitAuthorization() async throws {
        let factorySession = WalletHTTPSession.make()
        defer { factorySession.invalidateAndCancel() }
        let configuration = factorySession.configuration
        configuration.protocolClasses = [AuthorizationEchoURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://session-test.invalid/authorization")))
        request.setValue("Bearer explicit-token", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "Bearer explicit-token")
    }
}

private final class AuthorizationEchoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "session-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
