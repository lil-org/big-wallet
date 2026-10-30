// ∅ 2026 lil org

import Foundation
import Synchronization
import XCTest
import WalletDomain
import WalletRuntimeTestSupport
@testable import WalletNetworking

private typealias Vectors = NetworkTestVectors

@MainActor
final class TransactionInspectorTests: XCTestCase {

    func testInterpretationSharesRequestAndRemovesCancelledSubscriber() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let subscribersRegistered = expectation(description: "both subscribers registered")
        subscribersRegistered.expectedFulfillmentCount = 2
        MetadataURLProtocol.configure(onStart: { requestStarted.fulfill() }, onStop: {})
        let session = makeMetadataSession()
        let inspector = TransactionInspector(urlSession: session, onSubscriberRegistered: {
            subscribersRegistered.fulfill()
        })
        let data = "0x12345678" + abiWord("1")
        defer {
            session.invalidateAndCancel()
            MetadataURLProtocol.reset()
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
        XCTAssertEqual(MetadataURLProtocol.stopLoadingCount, 0)
        MetadataURLProtocol.complete(data: Data("set(uint256)".utf8))
        let result = try await second.value
        XCTAssertEqual(result, "set(uint256)\n\n1")
        let cached = try await inspector.interpret(data: data)
        XCTAssertEqual(cached, result)
        XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
    }

    func testInterpretationCancellationStopsLastSubscriberRequest() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let requestStopped = expectation(description: "method-signature request stopped")
        MetadataURLProtocol.configure(
            onStart: { requestStarted.fulfill() }, onStop: { requestStopped.fulfill() })
        let session = makeMetadataSession()
        let inspector = TransactionInspector(urlSession: session)
        let data = "0x87654321" + abiWord("1")
        defer {
            session.invalidateAndCancel()
            MetadataURLProtocol.reset()
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
        XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
        XCTAssertEqual(MetadataURLProtocol.stopLoadingCount, 1)
    }

    func testCancellationDoesNotWaitForDecodingAndSuppressesCompletion() async throws {
        let requestStarted = expectation(description: "method-signature request started")
        let decoderStarted = expectation(description: "decoder started")
        let decoderFinished = expectation(description: "decoder finished")
        let releaseDecoder = DispatchSemaphore(value: 0)
        MetadataURLProtocol.configure(onStart: { requestStarted.fulfill() }, onStop: {})
        let session = makeMetadataSession()
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
            MetadataURLProtocol.reset()
        }
        let task = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [requestStarted], timeout: 2)
        MetadataURLProtocol.complete(data: Data("set(uint256)".utf8))
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

    func testSignatureResponseAcceptsExactByteBudgetAndRejectsOneExtraByte() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let suffix = "(uint256)"
        let exact = String(repeating: "a", count: 16_384 - suffix.utf8.count) + suffix
        let inspector = TransactionInspector(urlSession: session, decoder: { _, _, signature in signature })
        do {
            _ = try await lookup(inspector, data: Data(("a" + exact).utf8))
            XCTFail("Expected an oversized signature to fail")
        } catch {
            XCTAssertEqual(error as? HTTPResponsePolicyError, .responseTooLarge)
        }
        let result = try await lookup(inspector, data: Data(exact.utf8))
        XCTAssertEqual(result, exact)
        let cached = try await inspector.interpret(data: "0x12345678" + abiWord("1"))
        XCTAssertEqual(cached, exact)
        XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
    }

    func testSignatureBudgetAcceptsExactTupleArrayAndNodeBoundaries() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let signatures = [
            "f(" + String(repeating: "(", count: 32) + "uint256" + String(repeating: ")", count: 32) + ")",
            "f(uint256" + String(repeating: "[]", count: 32) + ")",
            "f((uint256" + String(repeating: "[]", count: 15) + ")" + String(repeating: "[]", count: 16) + ")",
            "f(" + Array(repeating: "uint256", count: 1_024).joined(separator: ",") + ")",
            "f(" + Array(repeating: "(uint256)", count: 512).joined(separator: ",") + ")",
            "f(" + Array(repeating: "uint256[]", count: 512).joined(separator: ",") + ")",
        ]
        for signature in signatures {
            let inspector = TransactionInspector(urlSession: session, decoder: { _, _, signature in signature })
            let result = try await lookup(inspector, data: Data(signature.utf8))
            XCTAssertEqual(result, signature)
            let cached = try await inspector.interpret(data: "0x12345678" + abiWord("1"))
            XCTAssertEqual(cached, signature)
            XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
        }
    }

    func testSignatureBudgetFailuresAreNotDecodedOrCached() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let signatures = [
            "f(" + String(repeating: "(", count: 33) + "uint256" + String(repeating: ")", count: 33) + ")",
            "f(uint256" + String(repeating: "[]", count: 33) + ")",
            "f((uint256" + String(repeating: "[]", count: 16) + ")" + String(repeating: "[]", count: 16) + ")",
            "f(" + Array(repeating: "uint256", count: 1_025).joined(separator: ",") + ")",
            "f(" + Array(repeating: "(uint256)", count: 512).joined(separator: ",") + ",uint256)",
            "f(" + Array(repeating: "uint256[]", count: 512).joined(separator: ",") + ",uint256)",
        ]
        for signature in signatures {
            let decoderCalls = Mutex(0)
            let inspector = TransactionInspector(urlSession: session, decoder: { _, _, _ in
                decoderCalls.withLock { $0 += 1 }
                return "decoded"
            })
            let rejected = try await lookup(inspector, data: Data(signature.utf8))
            XCTAssertNil(rejected)
            XCTAssertEqual(decoderCalls.withLock { $0 }, 0)
            let retry = try await lookup(inspector, data: Data("set(uint256)".utf8))
            XCTAssertEqual(retry, "decoded")
            XCTAssertEqual(decoderCalls.withLock { $0 }, 1)
        }
    }

    func testPublicDecodeEnforcesSignatureResourceBoundaries() {
        let inspector = TransactionInspector()
        let data = "0x12345678" + abiWord("1")
        let tuple32 = "f(" + String(repeating: "(", count: 32) + "uint256" + String(repeating: ")", count: 32) + ")"
        XCTAssertEqual(inspector.decode(data: data, nameHex: "12345678", signature: tuple32),
                       tuple32 + "\n\n" + String(repeating: "(", count: 32) + "1" + String(repeating: ")", count: 32))
        let tuple33 = "f(" + String(repeating: "(", count: 33) + "uint256" + String(repeating: ")", count: 33) + ")"
        XCTAssertNil(inspector.decode(data: data, nameHex: "12345678", signature: tuple33))
        let arrays32 = "f(uint256" + String(repeating: "[1]", count: 32) + ")"
        XCTAssertEqual(inspector.decode(data: data, nameHex: "12345678", signature: arrays32),
                       arrays32 + "\n\n" + String(repeating: "[", count: 32) + "1" + String(repeating: "]", count: 32))
        XCTAssertNil(inspector.decode(data: data, nameHex: "12345678",
                                     signature: "f(uint256" + String(repeating: "[1]", count: 33) + ")"))
        let mixed32 = "f((uint256" + String(repeating: "[1]", count: 15) + ")" + String(repeating: "[1]", count: 16) + ")"
        XCTAssertNotNil(inspector.decode(data: data, nameHex: "12345678", signature: mixed32))
        let mixed33 = "f((uint256" + String(repeating: "[1]", count: 16) + ")" + String(repeating: "[1]", count: 16) + ")"
        XCTAssertNil(inspector.decode(data: data, nameHex: "12345678", signature: mixed33))
        let nodes1_024 = "f(" + Array(repeating: "uint256", count: 1_024).joined(separator: ",") + ")"
        let largeData = "0x12345678" + String(repeating: abiWord("1"), count: 1_024)
        XCTAssertNotNil(inspector.decode(data: largeData, nameHex: "12345678", signature: nodes1_024))
        XCTAssertNil(inspector.decode(data: largeData + abiWord("1"), nameHex: "12345678",
                                     signature: "f(" + Array(repeating: "uint256", count: 1_025).joined(separator: ",") + ")"))
        let exact = String(repeating: "a", count: 16_384 - "(uint256)".utf8.count) + "(uint256)"
        XCTAssertNotNil(inspector.decode(data: data, nameHex: "12345678", signature: exact))
        XCTAssertNil(inspector.decode(data: data, nameHex: "12345678", signature: "a" + exact))
    }

    func testSignatureFailuresAndMalformedUTF8PermitRetry() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let inspector = TransactionInspector(urlSession: session)
        for status in [302, 404, 503] {
            let result = try await lookup(inspector, data: Data("set(uint256)".utf8), status: status)
            XCTAssertNil(result)
        }
        let malformed = try await lookup(inspector, data: Data("set(uint256)".utf8) + Data([0xFF]))
        XCTAssertNil(malformed)
        do {
            _ = try await lookup(inspector, data: Data("set(uint256)".utf8), error: URLError(.networkConnectionLost))
            XCTFail("Expected a transport failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        let retry = try await lookup(inspector, data: Data("set(uint256)".utf8))
        XCTAssertEqual(retry, "set(uint256)\n\n1")
    }

    func testSignatureWithinBudgetPreservesUndecodableFallback() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        for signature in ["set(unknown)", "set((uint256)", "not a signature"] {
            let inspector = TransactionInspector(urlSession: session)
            let result = try await lookup(inspector, data: Data(signature.utf8))
            XCTAssertEqual(result, signature + "\n\n0x12345678" + abiWord("1"))
        }
    }

    func testSignatureSubscribersKeepOriginalDeadlineAndRetryAfterTimeout() async throws {
        let requestStarted = expectation(description: "signature request started")
        let deadlineScheduled = expectation(description: "signature deadline scheduled")
        let requestStopped = expectation(description: "signature request stopped")
        let subscribers = expectation(description: "signature subscribers registered")
        subscribers.expectedFulfillmentCount = 2
        let sleepCount = Mutex(0)
        let subscriberCount = Mutex(0)
        let clock = MetadataTestClock {
            if sleepCount.withLock({ $0 += 1; return $0 }) == 1 { deadlineScheduled.fulfill() }
        }
        MetadataURLProtocol.configure(onStart: { requestStarted.fulfill() }, onStop: { requestStopped.fulfill() })
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let inspector = TransactionInspector(urlSession: session, responsePolicy: TransactionInspector.responsePolicy, timing: clock.timing,
                                             onSubscriberRegistered: {
            if subscriberCount.withLock({ $0 += 1; return $0 }) <= 2 { subscribers.fulfill() }
        })
        let data = "0x12345678" + abiWord("1")
        let first = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [requestStarted, deadlineScheduled], timeout: 2)
        clock.advance(by: .seconds(4))
        let second = Task { try await inspector.interpret(data: data) }
        await fulfillment(of: [subscribers], timeout: 2)
        XCTAssertEqual(clock.deadlines.count, 1)
        XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
        clock.advance(by: .seconds(1))
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Expected the original request deadline to expire")
            } catch {
                XCTAssertEqual(error as? HTTPResponsePolicyError, .deadlineExceeded)
            }
        }
        await fulfillment(of: [requestStopped], timeout: 2)
        let retry = try await lookup(inspector, data: Data("set(uint256)".utf8))
        XCTAssertEqual(retry, "set(uint256)\n\n1")
    }

    private func lookup(_ inspector: TransactionInspector, data: Data, status: Int = 200, error: URLError? = nil) async throws -> String? {
        let started = expectation(description: "signature response requested")
        MetadataURLProtocol.configure(onStart: { started.fulfill() })
        let task = Task { try await inspector.interpret(data: "0x12345678" + abiWord("1")) }
        await fulfillment(of: [started], timeout: 2)
        MetadataURLProtocol.complete(data: data, status: status, error: error)
        return try await task.value
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

        XCTAssertFalse(EthereumTransactionPreparation.shouldInspect(contractCreation))
        XCTAssertTrue(EthereumTransactionPreparation.shouldInspect(contractCall))
    }

    func testMint() {
        let a = TransactionInspector().decode(data: "0x94bf804d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0021fb3f", nameHex: "94bf804d", signature: "mint(uint256,address)")
        XCTAssert(a?.lowercased() == "mint(uint256,address)\n\n1\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe")
    }
    
    func testClaim() {
        let b = TransactionInspector().decode(data: "0x84bb1e42000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000080ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000009184e72a000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021fb3f", nameHex: "84bb1e42", signature: "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)")
        XCTAssertEqual(b?.lowercased(), "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe\n\n1\n\n0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n\n10000000000000\n\n([0x0000000000000000000000000000000000000000000000000000000000000000], 115792089237316195423570985008687907853269984665640564039457584007913129639935, 10000000000000, 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)\n\n0x")
    }

    func testBoolAndArrayValues() {
        let boolDecoded = TransactionInspector().decode(data: WalletEncoding.hexString(Vectors.abiStaticAndDynamicBytesCall),
                                                             nameHex: "12345678",
                                                             signature: "setPayload(bool,bytes4,bytes32,bytes)")
        XCTAssertEqual(boolDecoded?.lowercased(), "setpayload(bool,bytes4,bytes32,bytes)\n\ntrue\n\n0xdeadbeef\n\n0x1111111111111111111111111111111111111111111111111111111111111111\n\n0x000102ff")

        let arrayDecoded = TransactionInspector().decode(data: WalletEncoding.hexString(Vectors.abiArrayCall),
                                                              nameHex: "abcdef01",
                                                              signature: "batch(uint256[],address[2])")
        XCTAssertEqual(arrayDecoded?.lowercased(), "batch(uint256[],address[2])\n\n[1, 2, 1000]\n\n[0x1111111111111111111111111111111111111111, 0x2222222222222222222222222222222222222222]")
    }

    func testEmptyArrayValues() {
        let emptyArrayCall = "0xeeeeeeee" +
            abiWord("20") +
            abiWord("0")
        let arrayDecoded = TransactionInspector().decode(data: emptyArrayCall,
                                                              nameHex: "eeeeeeee",
                                                              signature: "batch(uint256[])")
        XCTAssertEqual(arrayDecoded?.lowercased(), "batch(uint256[])\n\n[]")

        let emptyTupleArrayCall = "0xfeedbabe" +
            abiWord("20") +
            abiWord("40") +
            abiWord("7") +
            abiWord("0")
        let tupleDecoded = TransactionInspector().decode(data: emptyTupleArrayCall,
                                                              nameHex: "feedbabe",
                                                              signature: "submit((bytes32[],uint256))")
        XCTAssertEqual(tupleDecoded?.lowercased(), "submit((bytes32[],uint256))\n\n([], 7)")
    }

    func testDecodedArrayExpansionIsBoundedAfterSignatureValidation() {
        let inspector = TransactionInspector()
        for signature in ["f(()[1000000000])", "f(()[4096][4096])"] {
            XCTAssertNil(inspector.decode(data: "0x12345678", nameHex: "12345678", signature: signature))
        }
        let dynamic = "0x12345678" + abiWord("20") + abiWord(String(1_000_000_000, radix: 16))
        XCTAssertNil(inspector.decode(data: dynamic, nameHex: "12345678", signature: "f(()[])"))
        let aliases = "0x12345678" + abiWord("20") + abiWord("100") +
            String(repeating: abiWord("2000"), count: 256) + abiWord("100") +
            String(repeating: abiWord("1"), count: 256)
        XCTAssertNil(inspector.decode(data: aliases, nameHex: "12345678", signature: "f(uint256[][])"))
    }

    func testExcessiveDecodedOutputFallsBackToRawTransactionData() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let inspector = TransactionInspector(urlSession: session)
        let signature = "f(()[1000000000])"
        let result = try await lookup(inspector, data: Data(signature.utf8))
        XCTAssertEqual(result, signature + "\n\n0x12345678" + abiWord("1"))
    }
    
    func testTupleArrayValues() {
        let tupleArrayCall = "0xaaaaaaaa" +
            abiWord("20") +
            abiWord("2") +
            abiWord("1") +
            abiWord("1111111111111111111111111111111111111111") +
            abiWord("2") +
            abiWord("2222222222222222222222222222222222222222")
        let decoded = TransactionInspector().decode(data: tupleArrayCall,
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
        let decoded = TransactionInspector().decode(data: stringArrayCall,
                                                          nameHex: "bbbbbbbb",
                                                          signature: "labels(string[])")
        XCTAssertEqual(decoded, "labels(string[])\n\n[\"\", \"a,b\"]")
    }

    func testMintPublic() {
        let c = TransactionInspector().decode(data: "0x161ac21f0000000000000000000000003539ac68bc96fc1f470d7739a49bbbf3d321fd5d0000000000000000000000000000a26b00c1f0df003000390027140000faa719000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010021fb3f", nameHex: "161ac21f", signature: "mintPublic(address,address,address,uint256)")
        XCTAssert(c?.lowercased() == "mintpublic(address,address,address,uint256)\n\n0x3539ac68bc96fc1f470d7739a49bbbf3d321fd5d\n\n0x0000a26b00c1f0df003000390027140000faa719\n\n0x0000000000000000000000000000000000000000\n\n1")
        
    }
    
    func testEmptyData() {
        let d = TransactionInspector().decode(data: "0x", nameHex: "", signature: "mint(uint256,address)")
        XCTAssert(d == nil)
    }

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
