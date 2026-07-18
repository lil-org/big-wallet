// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class SolanaOptionsTests: XCTestCase {

    func testSolanaSendOptionsAcceptClusterHintAliases() {
        let aliases: [(String, Solana.Cluster)] = [
            ("mainnet", .mainnetBeta),
            ("mainnet-beta", .mainnetBeta),
            ("mainnetBeta", .mainnetBeta),
            ("solana:mainnet", .mainnetBeta),
            ("devnet", .devnet),
            ("solana:devnet", .devnet),
            ("testnet", .testnet),
            ("solana:testnet", .testnet),
        ]

        for (alias, expectedCluster) in aliases {
            switch Solana.preparedSendOptions(from: ["cluster": alias]) {
            case .success(let options):
                XCTAssertEqual(options.clusterHint, expectedCluster)
            case .failure(let error):
                XCTFail("Expected \(alias) to parse, got \(error)")
            }
        }
    }

    func testSolanaSendOptionsRejectInvalidAndConflictingClusterHints() {
        switch Solana.preparedSendOptions(from: ["cluster": "localnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected invalid cluster hint to fail")
        }

        switch Solana.preparedSendOptions(from: ["cluster": "mainnet", "bigWalletCluster": "devnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected conflicting cluster hints to fail")
        }
    }

    func testSolanaSendOptionsSanitizeRPCOptions() {
        switch Solana.preparedSendOptions(from: [
            "cluster": "devnet",
            "bigWalletCluster": "solana:devnet",
            "encoding": "base58",
            "skipPreflight": false,
            "commitment": "finalized",
            "preflightCommitment": "confirmed",
            "mode": "serial",
            "maxRetries": 2,
            "minContextSlot": 123,
            "rpcURL": "https://example.com",
        ]) {
        case .success(let options):
            XCTAssertEqual(options.clusterHint, .devnet)
            XCTAssertEqual(options.confirmationCommitment, .finalized)
            XCTAssertEqual(options.rpcOptions["encoding"] as? String, "base64")
            XCTAssertEqual(options.rpcOptions["skipPreflight"] as? Bool, false)
            XCTAssertEqual(options.rpcOptions["preflightCommitment"] as? String, "confirmed")
            XCTAssertEqual(options.rpcOptions["maxRetries"] as? Int, 2)
            XCTAssertEqual(options.rpcOptions["minContextSlot"] as? Int, 123)
            XCTAssertNil(options.rpcOptions["commitment"])
            XCTAssertNil(options.rpcOptions["mode"])
            XCTAssertNil(options.rpcOptions["rpcURL"])
            XCTAssertNil(options.rpcOptions["cluster"])
            XCTAssertNil(options.rpcOptions["bigWalletCluster"])
        case .failure(let error):
            XCTFail("Expected sanitized options, got \(error)")
        }
    }

    func testSolanaSendOptionsRejectUnsafeValues() {
        let invalidOptions: [[String: Any]] = [
            ["skipPreflight": true],
            ["preflightCommitment": "unsafe"],
            ["commitment": "unsafe"],
            ["mode": "parallel"],
            ["mode": "unsafe"],
            ["maxRetries": -1],
            ["minContextSlot": 1.5],
        ]

        for options in invalidOptions {
            switch Solana.preparedSendOptions(from: options) {
            case .failure(.invalidSendOptions):
                break
            default:
                XCTFail("Expected invalid options to fail: \(options)")
            }
        }
    }

    func testSolanaRPCConfigurationUsesAndCachesAlchemyForSupportedClusters() throws {
        var builtNetworks: [String] = []
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: "unit-test-key") { network, _ in
            builtNetworks.append(network)
            return URL(string: "https://\(network).g.alchemy.com/v2/unit-test-key")
        }

        XCTAssertEqual(builtNetworks, ["solana-mainnet", "solana-devnet"])

        let mainnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .mainnetBeta))
        XCTAssertEqual(mainnetEndpoint.scheme, "https")
        XCTAssertEqual(mainnetEndpoint.host, "solana-mainnet.g.alchemy.com")
        XCTAssertEqual(mainnetEndpoint.pathComponents.dropLast().last, "v2")

        let devnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .devnet))
        XCTAssertEqual(devnetEndpoint.scheme, "https")
        XCTAssertEqual(devnetEndpoint.host, "solana-devnet.g.alchemy.com")
        XCTAssertEqual(devnetEndpoint.pathComponents.dropLast().last, "v2")

        _ = configuration.endpoint(for: .mainnetBeta)
        _ = configuration.endpoint(for: .devnet)
        XCTAssertEqual(builtNetworks, ["solana-mainnet", "solana-devnet"])
    }

    func testSolanaRPCConfigurationFailsClosedWithoutAlchemyKey() throws {
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: nil)

        XCTAssertNil(configuration.endpoint(for: .mainnetBeta))
        XCTAssertNil(configuration.endpoint(for: .devnet))

        let testnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .testnet))
        XCTAssertEqual(testnetEndpoint.absoluteString, "https://api.testnet.solana.com")
    }

    func testSolanaRPCConfigurationRejectsInvalidAlchemyKey() {
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: "invalid key")

        XCTAssertNil(configuration.endpoint(for: .mainnetBeta))
        XCTAssertNil(configuration.endpoint(for: .devnet))
    }

    func testSolanaTestnetAlwaysUsesPublicEndpoint() throws {
        var urlBuilderCallCount = 0
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: "unit-test-key") { network, _ in
            urlBuilderCallCount += 1
            return URL(string: "https://\(network).g.alchemy.com/v2/unit-test-key")
        }

        let testnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .testnet))
        XCTAssertEqual(testnetEndpoint.absoluteString, "https://api.testnet.solana.com")
        XCTAssertEqual(urlBuilderCallCount, 2)
    }

    func testSolanaRPCSourcesUseAccurateDisplayNames() {
        XCTAssertEqual(Solana.Cluster.mainnetBeta.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.devnet.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.testnet.rpcSource, .publicFallback)
        XCTAssertEqual(Solana.RPCSource.alchemy.displayName, Strings.alchemyRPC)
        XCTAssertEqual(Solana.RPCSource.publicFallback.displayName, Strings.publicRPC)
    }

    func testSolanaDevnetSubmissionAndConfirmationReuseResolvedEndpoint() throws {
        let sentinelURL = try XCTUnwrap(URL(string: "https://sentinel.example/devnet"))
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: "unit-test-key") { network, _ in
            if network == "solana-devnet" {
                return sentinelURL
            }
            return URL(string: "https://unused.example/mainnet")
        }
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let responseBody: String
            switch method {
            case "sendTransaction":
                responseBody = #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#
            case "getSignatureStatuses":
                responseBody = #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"slot":1,"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#
            default:
                throw SolanaRPCStubError.unexpectedMethod
            }
            return (try Self.httpResponse(for: request), Data(responseBody.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let solana = Solana(urlSession: session, rpcConfiguration: configuration)
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(description: "Solana transaction confirmed")

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .devnet,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .devnet,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), ["sendTransaction", "getSignatureStatuses"])
        XCTAssertEqual(requests.map(\.url), [sentinelURL, sentinelURL])
    }

    func testSolanaMainnetFailsWithoutAlchemyBeforeMakingRequest() throws {
        let configuration = Solana.RPCConfiguration(alchemyAPIKey: nil)
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            throw SolanaRPCStubError.unexpectedRequest
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let solana = Solana(urlSession: session, rpcConfiguration: configuration)
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(description: "Unavailable RPC reported")

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .failure(.rpcUnavailable))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    private func preparedTransaction(using solana: Solana,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws -> Solana.PreparedSerializedTransaction {
        switch solana.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: Vectors.solanaPreparedSerializedTransaction,
            publicKey: Vectors.solanaPreparedSignerPublicKey
        ) {
        case .success(let prepared):
            return prepared
        case .failure(let error):
            XCTFail("Expected valid prepared transaction, got \(error)", file: file, line: line)
            throw SolanaRPCStubError.invalidFixture
        }
    }

    private func makeRPCSession(
        requestHandler: @escaping SolanaOptionsURLProtocol.RequestHandler
    ) -> URLSession {
        SolanaOptionsURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SolanaOptionsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(for request: URLRequest) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            throw SolanaRPCStubError.invalidRequest
        }
        return response
    }

}

private final class SolanaRPCRequestRecorder {

    struct RecordedRequest: Equatable {
        let method: String
        let url: URL
    }

    private let lock = NSLock()
    private var requests = [RecordedRequest]()

    func record(_ request: URLRequest) throws -> String {
        guard let url = request.url,
              let body = try Self.bodyData(from: request),
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            throw SolanaRPCStubError.invalidRequest
        }

        lock.lock()
        requests.append(RecordedRequest(method: method, url: url))
        lock.unlock()
        return method
    }

    func snapshot() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private static func bodyData(from request: URLRequest) throws -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? SolanaRPCStubError.invalidRequest
            }
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private enum SolanaRPCStubError: Error {
    case invalidFixture
    case invalidRequest
    case unexpectedMethod
    case unexpectedRequest
}

private final class SolanaOptionsURLProtocol: URLProtocol {

    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let requestHandlerLock = NSLock()
    private static var requestHandler: RequestHandler?

    static func setRequestHandler(_ handler: @escaping RequestHandler) {
        requestHandlerLock.lock()
        requestHandler = handler
        requestHandlerLock.unlock()
    }

    static func removeRequestHandler() {
        requestHandlerLock.lock()
        requestHandler = nil
        requestHandlerLock.unlock()
    }

    private static func currentRequestHandler() -> RequestHandler? {
        requestHandlerLock.lock()
        defer { requestHandlerLock.unlock() }
        return requestHandler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.currentRequestHandler() else {
            client?.urlProtocol(self, didFailWithError: SolanaRPCStubError.unexpectedRequest)
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
