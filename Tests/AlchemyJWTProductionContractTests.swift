// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class AlchemyJWTProductionContractTests: XCTestCase {

    private let installationID = UUID(
        uuidString: "123E4567-E89B-12D3-A456-426614174000"
    )!

    func testProductionBrokerRequestAndSuccessfulResponseContract()
        async throws {
        let session = makeSession { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.lil.org/v1/alchemy/jwt"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            XCTAssertEqual(
                try Self.bodyData(from: request),
                Data(
                    """
                    {"installationId":"123e4567-e89b-12d3-a456-426614174000"}
                    """.utf8
                )
            )

            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "token": "test-token",
                      "issuedAt": 2000000000,
                      "expiresAt": 2000086400
                    }
                    """.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: session
        )

        let record = try await client.fetchToken(
            installationID: installationID
        )

        XCTAssertEqual(record.token, "test-token")
        XCTAssertEqual(record.issuedAt, 2_000_000_000)
        XCTAssertEqual(record.expiresAt, 2_000_086_400)
    }

    func testProductionBrokerMapsRateLimitAndRetryAfter() async throws {
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 429,
                    headers: ["Retry-After": "42"]
                ),
                Data(repeating: 0, count: 16_385)
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: session
        )

        do {
            _ = try await client.fetchToken(
                installationID: installationID
            )
            XCTFail("Expected rate limit error")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .rateLimited(retryAfterSeconds: 42)
            )
        }
    }

    func testProductionBrokerDefaultsMissingAndMalformedRetryAfter()
        async throws {
        let retryAfterHeaders: [[String: String]] = [
            [:],
            ["Retry-After": "not-a-delay"],
        ]

        for headers in retryAfterHeaders {
            let session = makeSession { request in
                return (
                    try Self.httpResponse(
                        for: request,
                        statusCode: 429,
                        headers: headers
                    ),
                    Data()
                )
            }
            let client = Big_Wallet.AlchemyJWTBrokerClient(
                urlSession: session
            )

            do {
                _ = try await client.fetchToken(
                    installationID: installationID
                )
                XCTFail("Expected rate limit error")
            } catch {
                XCTAssertEqual(
                    error as? Big_Wallet.AlchemyJWTBrokerError,
                    .rateLimited(retryAfterSeconds: 60)
                )
            }

            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
    }

    func testProductionBrokerRejectsNonSuccessMalformedAndOversizedResponses()
        async throws {
        let invalidResponses: [(statusCode: Int, data: Data)] = [
            (
                500,
                Data(
                    """
                    {"token":"ignored","issuedAt":1,"expiresAt":61}
                    """.utf8
                )
            ),
            (200, Data("{".utf8)),
            (200, Data(repeating: 0, count: 16_385)),
        ]

        for invalidResponse in invalidResponses {
            let session = makeSession { request in
                return (
                    try Self.httpResponse(
                        for: request,
                        statusCode: invalidResponse.statusCode
                    ),
                    invalidResponse.data
                )
            }
            let client = Big_Wallet.AlchemyJWTBrokerClient(
                urlSession: session
            )

            do {
                _ = try await client.fetchToken(
                    installationID: installationID
                )
                XCTFail(
                    "Expected invalid response for status "
                        + "\(invalidResponse.statusCode)"
                )
            } catch {
                XCTAssertEqual(
                    error as? Big_Wallet.AlchemyJWTBrokerError,
                    .invalidResponse
                )
            }

            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
    }

    func testProductionBrokerAllowsExactlyMaximumResponseSize()
        async throws {
        var body = Data(
            """
            {"token":"test-token","issuedAt":2000000000,"expiresAt":2000086400}
            """.utf8
        )
        body.append(
            Data(repeating: 0x20, count: 16_384 - body.count)
        )
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 200,
                    headers: ["Content-Length": "16384"]
                ),
                body
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: session
        )

        let record = try await client.fetchToken(
            installationID: installationID
        )

        XCTAssertEqual(record.token, "test-token")
    }

    func testProductionBrokerRejectsDeclaredOversizeBeforeDecoding()
        async throws {
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 200,
                    headers: ["Content-Length": "16385"]
                ),
                Data(
                    """
                    {"token":"ignored","issuedAt":1,"expiresAt":61}
                    """.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: session
        )

        do {
            _ = try await client.fetchToken(
                installationID: installationID
            )
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .invalidResponse
            )
        }
    }

    func testProductionBrokerRejectsNonHTTPResponse() async throws {
        let session = makeSession { request in
            return (
                URLResponse(
                    url: try XCTUnwrap(request.url),
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: session
        )

        do {
            _ = try await client.fetchToken(
                installationID: installationID
            )
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .invalidResponse
            )
        }
    }

    private func makeSession(
        requestHandler:
            @escaping ProductionAlchemyJWTURLProtocol.RequestHandler
    ) -> URLSession {
        ProductionAlchemyJWTURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ProductionAlchemyJWTURLProtocol.self,
        ]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 {
                return body
            }
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            body.append(buffer, count: count)
        }
    }

    private static func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        return try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        )
    }

}

private final class ProductionAlchemyJWTURLProtocol: URLProtocol {

    typealias RequestHandler =
        (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    private static var requestHandler: RequestHandler?

    static func setRequestHandler(_ requestHandler: @escaping RequestHandler) {
        lock.lock()
        self.requestHandler = requestHandler
        lock.unlock()
    }

    static func removeRequestHandler() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        let requestHandler = Self.requestHandler
        Self.lock.unlock()

        guard let requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

}
