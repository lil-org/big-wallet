import Foundation
import Synchronization
import XCTest
import WalletDomain
import WalletRuntimeTestSupport
@testable import WalletNetworking

@MainActor
final class PriceServiceTests: XCTestCase {
    func testPriceResponsesAcceptExactByteBudgetAndRejectOneExtraByte() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        let base = "{\"ethereum\":{\"usd\":123}}"
        let exact = Data((base + String(repeating: " ", count: 65_536 - base.utf8.count)).utf8)
        await update(service, data: exact)
        XCTAssertEqual(service.forNetwork(network), 123)
        let replacement = "{\"ethereum\":{\"usd\":456}}"
        await update(service, data: Data((replacement + String(repeating: " ", count: 65_537 - replacement.utf8.count)).utf8))
        XCTAssertEqual(service.forNetwork(network), 123)
    }

    func testPriceResponsesEnforceJSONDepthAndTokenBoundaries() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        func nested(_ count: Int, price: Int) -> Data {
            Data(("{\"ethereum\":{\"usd\":\(price)},\"ignored\":" + String(repeating: "[", count: count) + "0" + String(repeating: "]", count: count) + "}").utf8)
        }
        await update(service, data: nested(15, price: 123))
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: nested(16, price: 456))
        XCTAssertEqual(service.forNetwork(network), 123)
        func tokens(_ count: Int, price: Int) -> Data {
            Data("{\"ethereum\":{\"usd\":\(price)},\"ignored\":[\(Array(repeating: "0", count: count - 7).joined(separator: ","))]}".utf8)
        }
        await update(service, data: tokens(4_096, price: 789))
        XCTAssertEqual(service.forNetwork(network), 789)
        await update(service, data: tokens(4_097, price: 999))
        XCTAssertEqual(service.forNetwork(network), 789)
    }

    func testPriceResponsesEnforceNormalizedByteBudgetAndRejectMalformedEncoding() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        let base = "{\"ethereum\":{\"usd\":123},\"ignored\":\"\"}"
        let remaining = 65_536 - base.utf8.count
        let suffix = String(repeating: "漢", count: remaining / 3) + String(repeating: "a", count: remaining % 3)
        let exact = "{\"ethereum\":{\"usd\":123},\"ignored\":\"\(suffix)\"}"
        XCTAssertEqual(exact.utf8.count, 65_536)
        await update(service, data: try XCTUnwrap(exact.data(using: .utf16LittleEndian)))
        XCTAssertEqual(service.forNetwork(network), 123)
        let expanded = "{\"ethereum\":{\"usd\":456},\"ignored\":\"\(suffix)a\"}"
        let utf16 = try XCTUnwrap(expanded.data(using: .utf16LittleEndian))
        XCTAssertLessThan(utf16.count, 65_536)
        XCTAssertGreaterThan(expanded.utf8.count, 65_536)
        await update(service, data: utf16)
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: Data([0xFF, 0xFE, 0x7B, 0x00, 0x00, 0xD8]))
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: Data("{\"ethereum\":{\"usd\":321}}".utf8) + Data([0xFF]))
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: try XCTUnwrap("{\"ethereum\":{\"usd\":789}}".data(using: .utf16BigEndian)))
        XCTAssertEqual(service.forNetwork(network), 789)
    }

    func testPriceFailuresPreserveLastPriceAndPermitRetry() async throws {
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        await update(service, data: Data("{\"ethereum\":{\"usd\":123}}".utf8))
        for status in [302, 404, 503] {
            await update(service, data: Data("{\"ethereum\":{\"usd\":456}}".utf8), status: status)
            XCTAssertEqual(service.forNetwork(network), 123)
        }
        await update(service, data: Data("{\"ethereum\":{\"usd\":456}}".utf8), error: URLError(.networkConnectionLost))
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: Data("not JSON".utf8))
        XCTAssertEqual(service.forNetwork(network), 123)
        await update(service, data: Data("{\"ethereum\":{\"usd\":789}}".utf8))
        XCTAssertEqual(service.forNetwork(network), 789)
    }

    func testPriceUpdatesShareRequestWhenOneCallerIsCancelled() async throws {
        let started = expectation(description: "price request started")
        let secondEntered = expectation(description: "second update entered")
        MetadataURLProtocol.configure(onStart: { started.fulfill() })
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        let first = Task { await service.update() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { secondEntered.fulfill(); await service.update() }
        await fulfillment(of: [secondEntered], timeout: 2)
        first.cancel()
        MetadataURLProtocol.complete(data: Data("{\"ethereum\":{\"usd\":123}}".utf8))
        await first.value
        await second.value
        XCTAssertEqual(MetadataURLProtocol.requestCount, 1)
        XCTAssertEqual(MetadataURLProtocol.stopLoadingCount, 0)
        XCTAssertEqual(service.forNetwork(network), 123)
    }

    func testPriceDeadlineReleasesSharedRequestAndAllowsFreshUpdate() async throws {
        let started = expectation(description: "price request started")
        let scheduled = expectation(description: "price deadline scheduled")
        let stopped = expectation(description: "price request stopped")
        let secondEntered = expectation(description: "second update entered")
        let sleepCount = Mutex(0)
        let clock = MetadataTestClock {
            if sleepCount.withLock({ $0 += 1; return $0 }) == 1 { scheduled.fulfill() }
        }
        MetadataURLProtocol.configure(onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        let session = makeMetadataSession()
        defer { session.invalidateAndCancel(); MetadataURLProtocol.reset() }
        let service = PriceService(urlSession: session, responsePolicy: PriceService.responsePolicy, timing: clock.timing)
        let network = try XCTUnwrap(RuntimeTestCatalog.resolver().network(chainId: 1))
        let first = Task { await service.update() }
        await fulfillment(of: [started, scheduled], timeout: 2)
        clock.advance(by: .seconds(9))
        let second = Task { secondEntered.fulfill(); await service.update() }
        await fulfillment(of: [secondEntered], timeout: 2)
        XCTAssertEqual(clock.deadlines.count, 1)
        clock.advance(by: .seconds(1))
        await first.value
        await second.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(service.forNetwork(network))
        await update(service, data: Data("{\"ethereum\":{\"usd\":123}}".utf8))
        XCTAssertEqual(service.forNetwork(network), 123)
    }

    private func update(_ service: PriceService, data: Data, status: Int = 200, error: URLError? = nil) async {
        let started = expectation(description: "price response requested")
        MetadataURLProtocol.configure(onStart: { started.fulfill() })
        let task = Task { await service.update() }
        await fulfillment(of: [started], timeout: 2)
        MetadataURLProtocol.complete(data: data, status: status, error: error)
        await task.value
    }
}
