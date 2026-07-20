// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class TransactionInspectorTests: XCTestCase {

    func testInterpretationSharesRequestAndRemovesCancelledSubscriber() {
        let requestStarted = expectation(
            description: "method-signature request started"
        )
        let firstCompletion = expectation(
            description: "cancelled subscriber did not complete"
        )
        firstCompletion.isInverted = true
        let secondCompletion = expectation(
            description: "active subscriber completed"
        )
        let cachedCompletion = expectation(
            description: "cached signature completed"
        )
        MethodSignatureURLProtocol.configure(
            onStart: {
                requestStarted.fulfill()
            },
            onStop: {}
        )
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(urlSession: session)
        let firstCancellation = EthereumRequestCancellation()
        let secondCancellation = EthereumRequestCancellation()
        let data = "0x12345678" + abiWord("1")
        defer {
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }

        inspector.interpret(
            data: data,
            cancellation: firstCancellation
        ) { _ in
            firstCompletion.fulfill()
        }
        inspector.interpret(
            data: data,
            cancellation: secondCancellation
        ) { result in
            XCTAssertEqual(result, "set(uint256)\n\n1")
            secondCompletion.fulfill()
        }

        wait(for: [requestStarted], timeout: 2)
        firstCancellation.cancel()
        XCTAssertEqual(MethodSignatureURLProtocol.stopLoadingCount, 0)
        MethodSignatureURLProtocol.complete(
            data: Data("set(uint256)".utf8)
        )

        wait(
            for: [secondCompletion, firstCompletion],
            timeout: 0.5
        )

        let cachedCancellation = EthereumRequestCancellation()
        inspector.interpret(
            data: data,
            cancellation: cachedCancellation
        ) { result in
            XCTAssertEqual(result, "set(uint256)\n\n1")
            cachedCompletion.fulfill()
        }
        wait(for: [cachedCompletion], timeout: 0.5)
        XCTAssertEqual(MethodSignatureURLProtocol.requestCount, 1)
    }

    func testInterpretationCancellationStopsLastSubscriberRequest() {
        let requestStarted = expectation(
            description: "method-signature request started"
        )
        let requestStopped = expectation(
            description: "method-signature request stopped"
        )
        let unexpectedCompletion = expectation(
            description: "cancelled interpretation did not complete"
        )
        unexpectedCompletion.isInverted = true
        MethodSignatureURLProtocol.configure(
            onStart: {
                requestStarted.fulfill()
            },
            onStop: {
                requestStopped.fulfill()
            }
        )
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(urlSession: session)
        let cancellation = EthereumRequestCancellation()
        defer {
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }

        inspector.interpret(
            data: "0x87654321" + abiWord("1"),
            cancellation: cancellation
        ) { _ in
            unexpectedCompletion.fulfill()
        }

        wait(for: [requestStarted], timeout: 2)
        cancellation.cancel()
        wait(
            for: [requestStopped, unexpectedCompletion],
            timeout: 0.5
        )
        XCTAssertEqual(MethodSignatureURLProtocol.requestCount, 1)
        XCTAssertEqual(MethodSignatureURLProtocol.stopLoadingCount, 1)
    }

    func testCancellationDoesNotWaitForDecodingAndSuppressesCompletion() {
        let requestStarted = expectation(
            description: "method-signature request started"
        )
        let decoderStarted = expectation(
            description: "decoder started"
        )
        let decoderFinished = expectation(
            description: "decoder finished"
        )
        let cancellationStarted = expectation(
            description: "cancellation started"
        )
        let cancellationFinished = expectation(
            description: "cancellation finished before decoder"
        )
        let unexpectedCompletion = expectation(
            description: "cancelled interpretation did not complete"
        )
        unexpectedCompletion.isInverted = true
        let releaseDecoder = DispatchSemaphore(value: 0)
        MethodSignatureURLProtocol.configure(
            onStart: {
                requestStarted.fulfill()
            },
            onStop: {}
        )
        let session = makeMethodSignatureSession()
        let inspector = TransactionInspector(
            urlSession: session
        ) { _, _, _ in
            decoderStarted.fulfill()
            releaseDecoder.wait()
            decoderFinished.fulfill()
            return "decoded"
        }
        let cancellation = EthereumRequestCancellation()
        defer {
            releaseDecoder.signal()
            session.invalidateAndCancel()
            MethodSignatureURLProtocol.reset()
        }

        inspector.interpret(
            data: "0x12345678" + abiWord("1"),
            cancellation: cancellation
        ) { _ in
            unexpectedCompletion.fulfill()
        }

        wait(for: [requestStarted], timeout: 2)
        MethodSignatureURLProtocol.complete(
            data: Data("set(uint256)".utf8)
        )
        wait(for: [decoderStarted], timeout: 2)

        DispatchQueue.global(qos: .userInitiated).async {
            cancellationStarted.fulfill()
            cancellation.cancel()
            cancellationFinished.fulfill()
        }
        wait(for: [cancellationStarted], timeout: 2)
        wait(for: [cancellationFinished], timeout: 2)

        releaseDecoder.signal()
        wait(
            for: [decoderFinished, unexpectedCompletion],
            timeout: 0.5
        )
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

    private static let lock = NSLock()
    private static var activeRequests =
        [ObjectIdentifier: MethodSignatureURLProtocol]()
    private static var onStart: (() -> Void)?
    private static var onStop: (() -> Void)?
    private static var storedRequestCount = 0
    private static var storedStopLoadingCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static var stopLoadingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopLoadingCount
    }

    static func configure(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        lock.lock()
        activeRequests.removeAll()
        self.onStart = onStart
        self.onStop = onStop
        storedRequestCount = 0
        storedStopLoadingCount = 0
        lock.unlock()
    }

    static func complete(data: Data) {
        lock.lock()
        let requests = Array(activeRequests.values)
        activeRequests.removeAll()
        lock.unlock()

        for request in requests {
            guard let url = request.request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                  ) else {
                continue
            }
            request.client?.urlProtocol(
                request,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }

    static func reset() {
        lock.lock()
        activeRequests.removeAll()
        onStart = nil
        onStop = nil
        storedRequestCount = 0
        storedStopLoadingCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.activeRequests[ObjectIdentifier(self)] = self
        Self.storedRequestCount += 1
        let onStart = Self.onStart
        Self.lock.unlock()
        onStart?()
    }

    override func stopLoading() {
        Self.lock.lock()
        let didRemove =
            Self.activeRequests.removeValue(
                forKey: ObjectIdentifier(self)
            ) != nil
        if didRemove {
            Self.storedStopLoadingCount += 1
        }
        let onStop = didRemove ? Self.onStop : nil
        Self.lock.unlock()
        onStop?()
    }

}
