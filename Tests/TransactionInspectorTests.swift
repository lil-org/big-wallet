// ∅ 2026 lil org

import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

@MainActor
final class TransactionInspectorTests: XCTestCase {

    func testInterpretationSharesRequestAndRemovesCancelledSubscriber() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let subscribersRegistered = expectation(description: "both subscribers registered")
        subscribersRegistered.expectedFulfillmentCount = 2
        MethodSignatureURLProtocol.configure(onStart: { requestStarted.fulfill() }, onStop: {})
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(urlSession: session, onSubscriberRegistered: {
            subscribersRegistered.fulfill()
        })
        let data = "0x12345678" + abiWord("1")
        defer {
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }
        let first = Task { try await inspector.interpret(data: data) }
        let second = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [requestStarted, subscribersRegistered], timeout: 2)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected canceled subscriber to throw")
        } catch is CancellationError {
        }
        XCTAssertEqual(MethodSignatureURLProtocol.stopLoadingCount, 0)
        MethodSignatureURLProtocol.complete(data: Data("set(uint256)".utf8))
        let result = try await second.value
        XCTAssertEqual(result, "set(uint256)\n\n1")
        let cached = try await inspector.interpret(data: data)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(MethodSignatureURLProtocol.requestCount, 1)
    }

    func testInterpretationCancellationStopsLastSubscriberRequest() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let requestStopped = expectation(description: "method-signature request stopped")
        MethodSignatureURLProtocol.configure(
            onStart: { requestStarted.fulfill() }, onStop: { requestStopped.fulfill() })
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(urlSession: session)
        let data = "0x87654321" + abiWord("1")
        defer {
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }
        let task = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [requestStarted], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected canceled interpretation to throw")
        } catch is CancellationError {
        }
        await fulfillment(of: [requestStopped], timeout: 2)
        XCTAssertEqual(MethodSignatureURLProtocol.requestCount, 1)
        XCTAssertEqual(MethodSignatureURLProtocol.stopLoadingCount, 1)
    }

    func testCancellationDoesNotWaitForDecodingAndSuppressesCompletion() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let decoderStarted = expectation(description: "decoder started")
        let decoderFinished = expectation(description: "decoder finished")
        let releaseDecoder = DispatchSemaphore(value: 0)
        MethodSignatureURLProtocol.configure(onStart: { requestStarted.fulfill() }, onStop: {})
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(urlSession: session, decoder: { _, _, _ in
            decoderStarted.fulfill()
            releaseDecoder.wait()
            decoderFinished.fulfill()
            return "decoded"
        })
        let data = "0x12345678" + abiWord("1")
        defer {
            releaseDecoder.signal()
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }
        let task = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [requestStarted], timeout: 2)
        MethodSignatureURLProtocol.complete(data: Data("set(uint256)".utf8))
        await fulfillment(of: [decoderStarted], timeout: 2)
        task.cancel()
        XCTAssertTrue(task.isCancelled)
        releaseDecoder.signal()
        do {
            _ = try await task.value
            XCTFail("Canceled decoding must not publish its result")
        } catch is CancellationError {
        }
        await fulfillment(of: [decoderFinished], timeout: 2)
    }

    func testEthereumPreparationDoesNotInspectContractCreationInitcode() {
        let contractCreation = Transaction(from: "0x0000000000000000000000000000000000000001",
                                           to: "",
                                           nonce: nil,
                                           gasPrice: "0x1",
                                           gas: "0x5208",
                                           value: "0x",
                                           data: "0x6001600055")
        let contractCall = Transaction(from: "0x0000000000000000000000000000000000000001",
                                       to: "0x0000000000000000000000000000000000000002",
                                       nonce: nil,
                                       gasPrice: "0x1",
                                       gas: "0x5208",
                                       value: "0x",
                                       data: "0x6001600055")

        XCTAssertFalse(Ethereum.shouldInspect(contractCreation))
        XCTAssertTrue(Ethereum.shouldInspect(contractCall))
    }

    func testMint() {
        let a = TransactionInspector.shared.decode(data: "0x94bf804d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0021fb3f", nameHex: "94bf804d", signature: "mint(uint256,address)")
        XCTAssert(a?.lowercased() == "mint(uint256,address)\n\n1\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe")
    }
    
    func testClaim() {
        let b = TransactionInspector.shared.decode(data: "0x84bb1e42000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000080ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000009184e72a000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021fb3f", nameHex: "84bb1e42", signature: "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)")
        XCTAssertEqual(b?.lowercased(), "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe\n\n1\n\n0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n\n10000000000000\n\n([0x0000000000000000000000000000000000000000000000000000000000000000], 115792089237316195423570985008687907853269984665640564039457584007913129639935, 10000000000000, 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)\n\n0x")
    }

    func testBoolAndArrayValues() {
        let boolDecoded = TransactionInspector.shared.decode(data: WalletCrypto.hexString(Vectors.abiStaticAndDynamicBytesCall),
                                                             nameHex: "12345678",
                                                             signature: "setPayload(bool,bytes4,bytes32,bytes)")
        XCTAssertEqual(boolDecoded?.lowercased(), "setpayload(bool,bytes4,bytes32,bytes)\n\ntrue\n\n0xdeadbeef\n\n0x1111111111111111111111111111111111111111111111111111111111111111\n\n0x000102ff")

        let arrayDecoded = TransactionInspector.shared.decode(data: WalletCrypto.hexString(Vectors.abiArrayCall),
                                                              nameHex: "abcdef01",
                                                              signature: "batch(uint256[],address[2])")
        XCTAssertEqual(arrayDecoded?.lowercased(), "batch(uint256[],address[2])\n\n[1, 2, 1000]\n\n[0x1111111111111111111111111111111111111111, 0x2222222222222222222222222222222222222222]")
    }

    func testEmptyArrayValues() {
        let emptyArrayCall = "0xeeeeeeee" +
            abiWord("20") +
            abiWord("0")
        let arrayDecoded = TransactionInspector.shared.decode(data: emptyArrayCall,
                                                              nameHex: "eeeeeeee",
                                                              signature: "batch(uint256[])")
        XCTAssertEqual(arrayDecoded?.lowercased(), "batch(uint256[])\n\n[]")

        let emptyTupleArrayCall = "0xfeedbabe" +
            abiWord("20") +
            abiWord("40") +
            abiWord("7") +
            abiWord("0")
        let tupleDecoded = TransactionInspector.shared.decode(data: emptyTupleArrayCall,
                                                              nameHex: "feedbabe",
                                                              signature: "submit((bytes32[],uint256))")
        XCTAssertEqual(tupleDecoded?.lowercased(), "submit((bytes32[],uint256))\n\n([], 7)")
    }
    
    func testTupleArrayValues() {
        let tupleArrayCall = "0xaaaaaaaa" +
            abiWord("20") +
            abiWord("2") +
            abiWord("1") +
            abiWord("1111111111111111111111111111111111111111") +
            abiWord("2") +
            abiWord("2222222222222222222222222222222222222222")
        let decoded = TransactionInspector.shared.decode(data: tupleArrayCall,
                                                          nameHex: "aaaaaaaa",
                                                          signature: "submit((uint256,address)[])")
        XCTAssertEqual(decoded?.lowercased(), "submit((uint256,address)[])\n\n[(1, 0x1111111111111111111111111111111111111111), (2, 0x2222222222222222222222222222222222222222)]")
    }

    func testStringArrayValuesKeepElementBoundaries() {
        let stringArrayCall = "0xbbbbbbbb" +
            abiWord("20") +
            abiWord("2") +
            abiWord("40") +
            abiWord("60") +
            abiWord("0") +
            abiWord("3") +
            abiBytes("612c62")
        let decoded = TransactionInspector.shared.decode(data: stringArrayCall,
                                                          nameHex: "bbbbbbbb",
                                                          signature: "labels(string[])")
        XCTAssertEqual(decoded, "labels(string[])\n\n[\"\", \"a,b\"]")
    }

    func testMintPublic() {
        let c = TransactionInspector.shared.decode(data: "0x161ac21f0000000000000000000000003539ac68bc96fc1f470d7739a49bbbf3d321fd5d0000000000000000000000000000a26b00c1f0df003000390027140000faa719000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010021fb3f", nameHex: "161ac21f", signature: "mintPublic(address,address,address,uint256)")
        XCTAssert(c?.lowercased() == "mintpublic(address,address,address,uint256)\n\n0x3539ac68bc96fc1f470d7739a49bbbf3d321fd5d\n\n0x0000a26b00c1f0df003000390027140000faa719\n\n0x0000000000000000000000000000000000000000\n\n1")
        
    }
    
    func testEmptyData() {
        let d = TransactionInspector.shared.decode(data: "0x", nameHex: "", signature: "mint(uint256,address)")
        XCTAssert(d == nil)
    }

}

private func makeMethodSignatureSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MethodSignatureURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func abiWord(_ hex: String) -> String {
    precondition(hex.count <= 64)
    return String(repeating: "0", count: 64 - hex.count) + hex
}

private func abiBytes(_ hex: String) -> String {
    precondition(hex.count.isMultiple(of: 2))
    let padding = (64 - hex.count % 64) % 64
    return hex + String(repeating: "0", count: padding)
}

private final class MethodSignatureURLProtocol: URLProtocol {
    // Foundation owns each loader; response and cancellation use its one-shot completion gate.
    private final class ResponseEndpoint: @unchecked Sendable {
        private weak var owner: MethodSignatureURLProtocol?
        init(_ owner: MethodSignatureURLProtocol) { self.owner = owner }
        func complete(data: Data) { owner?.completeResponse(data: data) }
    }

    private struct State: Sendable {
        var activeRequests = [ObjectIdentifier: ResponseEndpoint]()
        var onStart: (@Sendable () -> Void)?
        var onStop: (@Sendable () -> Void)?
        var requestCount = 0
        var stopLoadingCount = 0
    }

    private static let state = Mutex(State())

    static var requestCount: Int { state.withLock { $0.requestCount } }
    static var stopLoadingCount: Int { state.withLock { $0.stopLoadingCount } }

    static func configure(onStart: @escaping @Sendable () -> Void, onStop: @escaping @Sendable () -> Void) {
        state.withLock { $0 = State(onStart: onStart, onStop: onStop) }
    }

    static func complete(data: Data) {
        let requests = state.withLock { value in
            let requests = Array(value.activeRequests.values)
            value.activeRequests.removeAll()
            return requests
        }
        for endpoint in requests { endpoint.complete(data: data) }
    }

    private let responseFinished = Mutex(false)

    private func completeResponse(data: Data) {
        let canFinish = responseFinished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard canFinish, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let identifier = ObjectIdentifier(self)
        let endpoint = ResponseEndpoint(self)
        let onStart = Self.state.withLock { state in
            state.activeRequests[identifier] = endpoint
            state.requestCount += 1
            return state.onStart
        }
        onStart?()
    }

    override func stopLoading() {
        responseFinished.withLock { $0 = true }
        let identifier = ObjectIdentifier(self)
        let onStop = Self.state.withLock { state in
            guard state.activeRequests.removeValue(forKey: identifier) != nil else {
                return Optional<@Sendable () -> Void>.none
            }
            state.stopLoadingCount += 1
            return state.onStop
        }
        onStop?()
    }
}
