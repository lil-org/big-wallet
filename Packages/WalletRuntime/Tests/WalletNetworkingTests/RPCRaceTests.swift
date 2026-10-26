import Foundation
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletNetworking

@MainActor
final class RPCRaceTests: XCTestCase {
    func testEveryCancellationSerializationAndDispatchOrderingKeepsCapacityUntilExit() async throws {
        let schedules = twoActorInterleavings(first: 3, second: 3)
        XCTAssertEqual(schedules.count, 20)
        for schedule in schedules {
            let clock = TestClock()
            let serialized = TestGate<Void>()
            let serializeRelease = TestGate<Void>()
            let dispatchRelease = TestGate<Void>()
            let responseRelease = TestGate<Void>()
            let state = Mutex((operationEntered: false, dispatches: 0, dispatchAttempted: false))
            let serializationCount = Mutex(0)
            let service = makeService(clock: clock, active: 2, perOrigin: 1, outstandingPerOrigin: 1) { prepared in
                if serializationCount.withLock({ count in count += 1; return count == 1 }) {
                    serialized.resolve(())
                    await serializeRelease.wait()
                }
                return try prepared.serialize()
            }
            let request = Task {
                await service.perform(id: 1, body: Self.body(1), scope: scope("same")) { request, execution in
                    state.withLock { $0.operationEntered = true }
                    await dispatchRelease.wait()
                    do {
                        try execution.markDispatched()
                        state.withLock { $0.dispatches += 1; $0.dispatchAttempted = true }
                    } catch {
                        state.withLock { $0.dispatchAttempted = true }
                        throw error
                    }
                    await responseRelease.wait()
                    return Self.response(request.id)
                }
            }
            defer { request.cancel(); serializeRelease.resolve(()); dispatchRelease.resolve(()); responseRelease.resolve(()) }
            await serialized.wait()
            var response: RPCResponseToExtension?
            var ownerFinished = false
            var cancelRequested = false
            for step in schedule {
                switch (step.actor, step.index) {
                case (.first, 0):
                    serializeRelease.resolve(())
                    await expectEventually {
                        if state.withLock({ $0.operationEntered }) { return true }
                        return await service.statistics.activeRequests == 0
                    }
                    if cancelRequested { await expectEventually { await service.statistics.activeRequests == 0 } }
                case (.first, 1):
                    dispatchRelease.resolve(())
                    await expectEventually {
                        if state.withLock({ $0.dispatchAttempted }) { return true }
                        return await service.statistics.activeRequests == 0
                    }
                    if cancelRequested { await expectEventually { await service.statistics.activeRequests == 0 } }
                case (.first, 2):
                    responseRelease.resolve(())
                    response = await request.value
                    await expectEventually { await service.statistics.activeRequests == 0 }
                    ownerFinished = true
                case (.second, 0):
                    cancelRequested = true
                    request.cancel()
                    response = await request.value
                    if !ownerFinished {
                        let error = response?.json["error"] as? [String: Any]
                        let data = error?["data"] as? [String: Any]
                        XCTAssertEqual(data?["reason"] as? String, "cancelled", "Schedule: \(schedule)")
                        XCTAssertEqual(data?["dispatched"] as? Bool, state.withLock { $0.dispatches > 0 })
                        let retained = await service.statistics
                        XCTAssertEqual(retained.activeRequests, 1)
                        XCTAssertEqual(retained.outstandingRequests, 1)
                        XCTAssertGreaterThan(retained.retainedRequestBytes, 0)
                    }
                case (.second, 1):
                    let occupied = await service.statistics.activeRequests > 0
                    let replacement = await service.perform(id: 2, body: Self.body(2), scope: scope("same")) { request, _ in Self.response(request.id) }
                    if occupied {
                        let error = replacement.json["error"] as? [String: Any]
                        XCTAssertEqual((error?["data"] as? [String: Any])?["reason"] as? String, "busy")
                    } else { XCTAssertEqual(replacement.json["result"] as? String, "result-2") }
                case (.second, 2):
                    let independent = await service.perform(id: 3, body: Self.body(3), scope: scope("other", profile: UUID())) { request, _ in Self.response(request.id) }
                    XCTAssertEqual(independent.json["result"] as? String, "result-3")
                default: XCTFail("Unexpected schedule step")
                }
            }
            XCTAssertNotNil(response)
            XCTAssertLessThanOrEqual(state.withLock { $0.dispatches }, 1)
            let empty = await service.statistics
            XCTAssertEqual(empty.activeRequests, 0)
            XCTAssertEqual(empty.outstandingRequests, 0)
            XCTAssertEqual(empty.retainedRequestBytes, 0)
            XCTAssertEqual(empty.scopeCount, 0)
        }
    }

    func testBroadcastTransportProgressesAtEveryPublicRPCCapacityBoundary() async throws {
        let schedules = twoActorInterleavings(first: 3, second: 1)
        XCTAssertEqual(schedules.count, 4)
        for schedule in schedules {
            let clock = TestClock()
            let service = makeService(clock: clock, active: 1, perOrigin: 1, outstandingPerOrigin: 1)
            let ready = TestGate<Void>()
            let release = TestGate<Void>()
            let rpc = BroadcastRPCProbe()
            let transport = EthereumBroadcastClient(rpc: rpc)
            var traffic: Task<RPCResponseToExtension, Never>?
            defer { traffic?.cancel(); release.resolve(()) }
            for step in schedule {
                switch (step.actor, step.index) {
                case (.first, 0):
                    traffic = Task {
                        await service.perform(id: 1, body: Self.body(1), scope: scope("busy")) { request, _ in
                            ready.resolve(())
                            await release.wait()
                            return Self.response(request.id)
                        }
                    }
                    await ready.wait()
                    let active = await service.statistics.activeRequests
                    XCTAssertEqual(active, 1)
                case (.first, 1):
                    traffic?.cancel()
                    _ = await traffic?.value
                    let active = await service.statistics.activeRequests
                    XCTAssertEqual(active, 1)
                case (.first, 2):
                    release.resolve(())
                    await expectEventually { await service.statistics.activeRequests == 0 }
                case (.second, 0):
                    let before = await service.statistics
                    let hash = try await transport.sendSignedTransaction(NetworkTestVectors.signedEthereumLegacyTransaction, network: network())
                    XCTAssertEqual(hash, "0xfixture")
                    let after = await service.statistics
                    XCTAssertEqual(after, before)
                default: XCTFail("Unexpected schedule step")
                }
            }
            XCTAssertEqual(rpc.sends, [NetworkTestVectors.signedEthereumLegacyTransaction])
            let outstanding = await service.statistics.outstandingRequests
            XCTAssertEqual(outstanding, 0)
        }
    }

    private func makeService(clock: TestClock, active: Int, perOrigin: Int, outstandingPerOrigin: Int,
        serialize: @escaping SafariRPCService.Serializer = { try $0.serialize() }
    ) -> SafariRPCService {
        let anchor = clock.instant
        let uptime = clock.uptimeNanoseconds
        return SafariRPCService(limits: .init(maximumActivePerOrigin: perOrigin, maximumActiveRequests: active,
            maximumOutstandingPerOrigin: outstandingPerOrigin, maximumOutstandingRequests: 4,
            maximumQueueWait: .seconds(500), maximumLifetime: .seconds(1_000)),
            clock: .init(now: { clock.instant }, sleepUntil: { deadline in
                let duration = anchor.duration(to: deadline).components
                let offset = UInt64(duration.seconds) * 1_000_000_000 + UInt64(duration.attoseconds / 1_000_000_000)
                try await clock.sleep(until: uptime + offset)
            }), serializeRequest: serialize)
    }

    private func scope(_ origin: String, profile: UUID? = nil) -> RPCScope {
        RPCScope(profileIdentifier: profile, origin: "https://\(origin).fixture.invalid")
    }

    private nonisolated static func body(_ id: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"eth_blockNumber\",\"params\":[]}"
    }

    private nonisolated static func response(_ id: Int) -> RPCResponseToExtension {
        RPCResponseToExtension(upstream: ["id": id, "result": "result-\(id)"], expectedResponseID: id)!
    }

    private func network() -> EthereumNetwork {
        EthereumNetwork(chainId: 1, name: "Fixture", symbol: "ETH", rpcEndpoint: .unauthenticated(URL(string: "https://rpc.fixture.invalid")!),
            isTestnet: true, mightShowPrice: false, explorer: nil)
    }
}

private final class BroadcastRPCProbe: EthereumRPCClient {
    private let sent = Mutex([String]())
    var sends: [String] { sent.withLock { $0 } }
    func getBalance(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String { throw ProbeError.unexpected }
    func fetchNonce(endpoint: EthereumRPCEndpoint, for address: String) async throws -> String { throw ProbeError.unexpected }
    func estimateGas(endpoint: EthereumRPCEndpoint, transaction: Transaction) async throws -> String { throw ProbeError.unexpected }
    func sendRawTransaction(endpoint: EthereumRPCEndpoint, signedTxData: String) async throws -> String {
        sent.withLock { $0.append(signedTxData) }
        return "0xfixture"
    }
    private enum ProbeError: Error { case unexpected }
}
