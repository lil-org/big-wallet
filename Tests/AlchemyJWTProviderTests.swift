// ∅ 2026 lil org

import CryptoKit
import Foundation
import XCTest
@testable import Big_Wallet

final class AlchemyJWTProviderTests: XCTestCase {

    private let alchemyURL = URL(
        string: "https://eth-mainnet.g.alchemy.com/v2"
    )!
    private let installationID = UUID(
        uuidString: "123e4567-e89b-12d3-a456-426614174000"
    )!

    func testStrictAlchemyEndpointPredicate() throws {
        let accepted = [
            "https://eth-mainnet.g.alchemy.com/v2",
            "https://solana-mainnet.g.alchemy.com:443/v2",
            "https://a.g.alchemy.com/v2",
            "https://\(String(repeating: "a", count: 63)).g.alchemy.com/v2",
        ]
        for value in accepted {
            XCTAssertTrue(
                AlchemyJWTProvider.isAlchemyRPCURL(try XCTUnwrap(URL(string: value))),
                value
            )
        }

        let rejected = [
            "http://eth-mainnet.g.alchemy.com/v2",
            "https://g.alchemy.com/v2",
            "https://foo.bar.g.alchemy.com/v2",
            "https://FOO.g.alchemy.com/v2",
            "https://-foo.g.alchemy.com/v2",
            "https://foo-.g.alchemy.com/v2",
            "https://-.g.alchemy.com/v2",
            "https://\(String(repeating: "a", count: 64)).g.alchemy.com/v2",
            "https://foo.g.alchemy.com:8443/v2",
            "https://foo.g.alchemy.com/v2/",
            "https://foo.g.alchemy.com/v2/key",
            "https://foo.g.alchemy.com/v2?key=value",
            "https://foo.g.alchemy.com/v2#fragment",
            "https://user@foo.g.alchemy.com/v2",
            "https://foo.g.alchemy.com.evil.test/v2",
            "https://rpc.example/v2",
        ]
        for value in rejected {
            XCTAssertFalse(
                AlchemyJWTProvider.isAlchemyRPCURL(try XCTUnwrap(URL(string: value))),
                value
            )
        }
    }

    func testExtremeTimestampsAreRejectedWithoutOverflowing() {
        let extreme = AlchemyJWTRecord(
            token: "a.b.c",
            issuedAt: Int64.min,
            expiresAt: Int64.max
        )
        XCTAssertFalse(extreme.isStructurallyValid(at: 0))
        XCTAssertFalse(extreme.isUsable(at: 0))
        XCTAssertFalse(extreme.shouldRefresh(at: 0))

        let ordinary = makeRecord(
            issuedAt: 2_000_000_000,
            expiresAt: 2_000_086_400
        )
        XCTAssertFalse(ordinary.isTimeUsable(at: Int64.max))
        XCTAssertFalse(ordinary.shouldRefresh(at: Int64.min))
    }

    func testJWTCompactEncodingRequiresCanonicalRSA2048Signature() throws {
        let now: Int64 = 2_000_000_000
        let valid = makeRecord(
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let segments = valid.token.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).map(String.init)
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(valid.isStructurallyValid(at: now))

        func record(
            header: String? = nil,
            payload: String? = nil,
            signature: String
        ) -> AlchemyJWTRecord {
            return AlchemyJWTRecord(
                token: [
                    header ?? segments[0],
                    payload ?? segments[1],
                    signature,
                ].joined(separator: "."),
                issuedAt: valid.issuedAt,
                expiresAt: valid.expiresAt
            )
        }

        let wrongWidthSignatures = [
            Data(repeating: 0, count: 255).base64URLEncodedString,
            Data(repeating: 0, count: 257).base64URLEncodedString,
        ]
        for signature in wrongWidthSignatures {
            XCTAssertFalse(
                record(signature: signature).isStructurallyValid(at: now)
            )
        }

        XCTAssertFalse(
            record(signature: "!").isStructurallyValid(at: now)
        )
        XCTAssertFalse(
            record(signature: "A").isStructurallyValid(at: now)
        )
        XCTAssertFalse(
            record(
                signature: segments[2] + "="
            ).isStructurallyValid(at: now)
        )

        var noncanonicalSignature = segments[2]
        let canonicalLastCharacter = try XCTUnwrap(
            noncanonicalSignature.last
        )
        noncanonicalSignature.removeLast()
        let noncanonicalLastCharacter: Character
        switch canonicalLastCharacter {
        case "A":
            noncanonicalLastCharacter = "B"
        case "Q":
            noncanonicalLastCharacter = "R"
        case "g":
            noncanonicalLastCharacter = "h"
        case "w":
            noncanonicalLastCharacter = "x"
        default:
            XCTFail("Unexpected canonical base64url trailing character")
            noncanonicalLastCharacter = "B"
        }
        noncanonicalSignature.append(noncanonicalLastCharacter)
        XCTAssertFalse(
            record(
                signature: noncanonicalSignature
            ).isStructurallyValid(at: now)
        )
        XCTAssertFalse(
            record(
                header: segments[0] + "=",
                signature: segments[2]
            ).isStructurallyValid(at: now)
        )
    }

    func testInitializationDoesNotLoadAndPrewarmCreatesWarmMemoryCache()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now - 60, expiresAt: now + 86_340)
        let store = TestAlchemyJWTStore(record: record)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now
        )

        XCTAssertEqual(store.loadCount, 0)
        await provider.prewarm().value
        XCTAssertEqual(store.loadCount, 1)
        store.resetCounts()

        for _ in 0..<100 {
            let authorization = try await provider.authorization(
                for: alchemyURL
            )
            XCTAssertEqual(authorization?.token, record.token)
        }
        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testApplicationLifecyclePrewarmSkipsTestsAndPreviews() async {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(
            marker: "lifecycle",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(records: [record])
        let provider = makeProvider(store: store, broker: broker, now: now)
        var providerAccessCount = 0
        let providerFactory = {
            providerAccessCount += 1
            return provider
        }

        XCTAssertNil(
            AlchemyJWTProvider.prewarmForApplicationLifecycle(
                environment: [
                    "XCTestConfigurationFilePath": "tests.xctest",
                ],
                provider: providerFactory
            )
        )
        XCTAssertNil(
            AlchemyJWTProvider.prewarmForApplicationLifecycle(
                environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
                provider: providerFactory
            )
        )
        try? await Task.sleep(nanoseconds: 25_000_000)

        XCTAssertEqual(providerAccessCount, 0)
        XCTAssertEqual(store.loadCount, 0)
        let skippedFetchCount = await broker.fetchCount
        XCTAssertEqual(skippedFetchCount, 0)

        let lifecyclePrewarm = AlchemyJWTProvider
            .prewarmForApplicationLifecycle(
                environment: [:],
                provider: providerFactory
            )
        XCTAssertNotNil(lifecyclePrewarm)
        await lifecyclePrewarm?.value

        XCTAssertEqual(providerAccessCount, 1)
        XCTAssertEqual(store.record, record)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 1)
    }

    func testImmediateUsePrewarmUsesCoalescedDemandAcquisition()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(
            marker: "immediate-demand",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [record],
            delayNanoseconds: 75_000_000
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await provider.prewarmForImmediateUse()
                }
            }
        }

        let prewarmFetchCount = await broker.fetchCount
        XCTAssertEqual(prewarmFetchCount, 1)
        XCTAssertNil(store.record)

        let authorization = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(authorization?.token, record.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 1)
    }

    func testFailedImmediateUsePrewarmDoesNotBackOffColdDemand()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [TestBrokerError.unavailable]
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        await provider.prewarmForImmediateUse()
        await provider.prewarmForImmediateUse()

        let prewarmFetchCount = await broker.fetchCount
        XCTAssertEqual(prewarmFetchCount, 1)

        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testNonAlchemyURLNeverLoadsTokenOrCallsBroker() async throws {
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [makeRecord(issuedAt: 2_000_000_000, expiresAt: 2_000_086_400)]
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: 2_000_000_000
        )
        store.resetCounts()

        let authorization = try await provider.authorization(
            for: URL(string: "https://rpc.example/v2")!
        )

        XCTAssertNil(authorization)
        XCTAssertEqual(store.loadCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testConcurrentColdAuthorizationIsSingleFlight() async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now, expiresAt: now + 86_400)
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [record],
            delayNanoseconds: 50_000_000
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        let tokens = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await provider.authorization(for: self.alchemyURL)?.token
                }
            }

            var values: [String?] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(Set(tokens.compactMap { $0 }), [record.token])
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testOverlappingImmediateUsePrewarmAndColdRPCShareBrokerFlight()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now, expiresAt: now + 86_400)
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        let rpc = Task {
            try await provider.authorization(for: self.alchemyURL)?.token
        }
        await waitUntil { refreshLock.attemptCount >= 2 }
        await firstFetchGate.release()

        let resolvedRPCToken = try await rpc.value
        await prewarm.value

        XCTAssertEqual(resolvedRPCToken, record.token)
        XCTAssertGreaterThanOrEqual(refreshLock.attemptCount, 2)
        XCTAssertEqual(store.saveCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testTwoProvidersCoalesceRefreshThroughSharedAdvisoryLock() async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now, expiresAt: now + 86_400)
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [record],
            delayNanoseconds: 75_000_000
        )
        let sharedLock = TestAlchemyJWTRefreshLock()
        let first = makeProvider(
            store: store,
            broker: broker,
            refreshLock: sharedLock,
            now: now
        )
        let second = makeProvider(
            store: store,
            broker: broker,
            refreshLock: sharedLock,
            now: now
        )

        async let firstToken = first.authorization(for: alchemyURL)?.token
        async let secondToken = second.authorization(for: alchemyURL)?.token
        let resolvedTokens = try await (firstToken, secondToken)
        let values = [resolvedTokens.0, resolvedTokens.1]

        XCTAssertEqual(Set(values.compactMap { $0 }), [record.token])
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(sharedLock.acquireCount, 2)
    }

    func testColdDemandFallsBackWhenCrossProcessLockStaysContended()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now, expiresAt: now + 86_400)
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(records: [record])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, record.token)
        XCTAssertEqual(contendedLock.acquireCount, 0)
        XCTAssertGreaterThanOrEqual(contendedLock.attemptCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(store.record)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testUnauthorizedLockTimeoutFallsBackWithoutSecondLockWait()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )
        let loadedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let current = try XCTUnwrap(loadedAuthorization)
        store.resetCounts()

        let authorization = try await provider.replacementAuthorization(
            afterUnauthorized: current,
            for: alchemyURL
        )

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertGreaterThanOrEqual(contendedLock.attemptCount, 1)
        XCTAssertEqual(contendedLock.acquireCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(store.record, rejected)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testOpportunisticRefreshDoesNotFetchWithoutCrossProcessLock()
        async {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        await provider.prewarm().value

        XCTAssertEqual(contendedLock.acquireCount, 0)
        XCTAssertEqual(contendedLock.attemptCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(store.record, current)
    }

    func testFinalQuarterReturnsCurrentTokenWhileRefreshingInBackground() async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            delayNanoseconds: 75_000_000
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, current.token)
        await waitUntil {
            let authorization = try? await provider.authorization(
                for: self.alchemyURL
            )
            return authorization?.token == replacement.token
        }
        let refreshedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(refreshedAuthorization?.token, replacement.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testFreshTokenSchedulesOneRefreshAtThreeQuarterLifetime()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-current",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            now: now,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        for _ in 0..<20 {
            let authorization = try await provider.authorization(
                for: alchemyURL
            )
            XCTAssertEqual(authorization?.token, current.token)
        }
        await waitUntil {
            await sleeper.pendingCount() == 1
        }

        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(durations, [64_800_000_000_000])
        XCTAssertEqual(fetchCount, 0)
    }

    func testScheduledWakeRefreshesAndSchedulesTheReplacement()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-old",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "scheduled-new",
            issuedAt: now + 64_800,
            expiresAt: now + 151_200
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        let original = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(original?.token, current.token)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }

        clock.advance(by: 64_800)
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 1 && durations.count == 2
        }

        let refreshed = try await provider.authorization(for: alchemyURL)
        let durations = await sleeper.requestedDurations()
        XCTAssertEqual(refreshed?.token, replacement.token)
        XCTAssertEqual(
            durations,
            [
                64_800_000_000_000,
                64_800_000_000_000,
            ]
        )
    }

    func testScheduledRefreshStaysSingleFlightDuringRPCAndLifecyclePrewarm()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-in-flight-current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "scheduled-in-flight-replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            firstFetchGate: firstFetchGate
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        let initial = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(initial?.token, current.token)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeNext()
        await firstFetchGate.waitUntilStarted()

        // Moving uptime past the no-op tolerance used to make hot-path calls
        // replace and cancel the task that was already refreshing.
        clock.advanceUptime(by: 2)
        let lifecyclePrewarm = provider.prewarm()
        var concurrentTokens: [String?] = []
        for _ in 0..<20 {
            do {
                let authorization = try await provider.authorization(
                    for: alchemyURL
                )
                concurrentTokens.append(authorization?.token)
            } catch {
                XCTFail("Authorization failed while refresh was in flight")
                concurrentTokens.append(nil)
            }
        }
        for _ in 0..<10 {
            await Task.yield()
        }

        let inFlightDurations = await sleeper.requestedDurations()
        let inFlightPendingCount = await sleeper.pendingCount()
        let inFlightFetchCount = await broker.fetchCount
        await firstFetchGate.release()
        await lifecyclePrewarm.value
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 1 && durations.count == 2
        }

        XCTAssertEqual(
            Set(concurrentTokens.compactMap { $0 }),
            [current.token]
        )
        XCTAssertEqual(inFlightDurations, [0])
        XCTAssertEqual(inFlightPendingCount, 0)
        XCTAssertEqual(inFlightFetchCount, 1)
        let refreshed = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(refreshed?.token, replacement.token)
    }

    func testLifecyclePrewarmCannotRefetchStillDueScheduledResult()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-still-due",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let unexpectedSecond = makeRecord(
            marker: "unexpected-second",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [current, unexpectedSecond],
            firstFetchGate: firstFetchGate
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            now: now,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeNext()
        await firstFetchGate.waitUntilStarted()

        let overlappingPrewarm = provider.prewarm()
        await firstFetchGate.release()
        await overlappingPrewarm.value
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 1 && durations.count == 2
        }

        // A lifecycle event immediately after the shared fetch must observe
        // the no-progress cooldown instead of issuing another request.
        await provider.prewarm().value
        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(durations.first, 0)
        XCTAssertGreaterThan(durations[1], 750_000_000)
        XCTAssertLessThanOrEqual(durations[1], 1_000_000_000)
    }

    func testClockChangeNotificationReschedulesWithoutRPCOrLifecycleEvent()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "clock-jump",
            issuedAt: now - 10_000,
            expiresAt: now + 76_400
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let notificationCenter = NotificationCenter()
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            },
            notificationCenter: notificationCenter
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        clock.adjustWallTime(by: 3_600)
        notificationCenter.post(
            name: .NSSystemClockDidChange,
            object: nil
        )
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            let pendingCount = await sleeper.pendingCount()
            return durations.count == 2 && pendingCount == 1
        }
        clock.adjustWallTime(by: -7_200)
        notificationCenter.post(
            name: .NSSystemClockDidChange,
            object: nil
        )
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            let pendingCount = await sleeper.pendingCount()
            return durations.count == 3 && pendingCount == 1
        }

        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(
            durations,
            [
                54_800_000_000_000,
                51_200_000_000_000,
                58_400_000_000_000,
            ]
        )
        XCTAssertEqual(fetchCount, 0)
    }

    func testPersistenceReloadReplacesAndCancelsTheOldTokenWake()
        async throws {
        let now: Int64 = 2_000_000_000
        let first = makeRecord(
            marker: "reload-first",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let second = makeRecord(
            marker: "reload-second",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: first)
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        store.record = second
        provider.reloadFromPersistence()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            let pendingCount = await sleeper.pendingCount()
            return durations.count == 2 && pendingCount == 1
        }

        let authorization = try await provider.authorization(for: alchemyURL)
        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(authorization?.token, second.token)
        XCTAssertEqual(
            durations,
            [
                64_800_000_000_000,
                64_801_000_000_000,
            ]
        )
        XCTAssertEqual(fetchCount, 0)
    }

    func testFreshPersistenceReloadResetsOpportunisticBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "reload-backed-off-current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "reload-backed-off-replacement",
            issuedAt: now + 2,
            expiresAt: now + 86_402
        )
        let store = TestAlchemyJWTStore(record: current)
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(
            errors: [
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
            ]
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 1 && durations.count == 2
        }
        clock.advance(by: 2)
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 2 && durations.count == 3
        }

        store.record = replacement
        provider.reloadFromPersistence()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await sleeper.pendingCount() == 1
                && durations.count == 4
        }

        clock.advance(by: 64_800)
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 3 && durations.count == 5
        }

        let durations = await sleeper.requestedDurations()
        XCTAssertGreaterThan(durations[1], 750_000_000)
        XCTAssertLessThanOrEqual(durations[1], 1_000_000_000)
        XCTAssertGreaterThan(durations[2], 1_750_000_000)
        XCTAssertLessThanOrEqual(durations[2], 2_000_000_000)
        XCTAssertGreaterThan(durations[3], 64_799_750_000_000)
        XCTAssertLessThanOrEqual(durations[3], 64_800_000_000_000)
        XCTAssertGreaterThan(durations[4], 750_000_000)
        XCTAssertLessThanOrEqual(durations[4], 1_000_000_000)
    }

    func testFreshPersistenceReloadResetsDemandBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "reload-demand-replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            errors: [
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
            ]
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock
        )

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the initial demand failure")
        } catch {
            // Expected.
        }

        store.record = replacement
        provider.reloadFromPersistence()
        clock.advance(by: 86_401)

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the post-expiry demand failure")
        } catch {
            // Expected.
        }
        clock.advance(by: 0.3)
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the retry demand failure")
        } catch {
            // Expected.
        }

        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 3)
    }

    func testRejectedTokenAndProviderDeinitCancelScheduledWake()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "cancel-current",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let rejectedSleeper = TestAlchemyJWTProactiveSleeper()
        let rejectedBroker = TestAlchemyJWTBroker(records: [])
        let rejectedProvider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: rejectedBroker,
            now: now,
            proactiveRefreshSleep: {
                try await rejectedSleeper.sleep($0)
            }
        )
        let loadedAuthorization = try await rejectedProvider.authorization(
            for: alchemyURL
        )
        let authorization = try XCTUnwrap(loadedAuthorization)
        await waitUntil {
            await rejectedSleeper.pendingCount() == 1
        }

        await rejectedProvider.invalidateAuthorization(
            afterUnauthorized: authorization,
            for: alchemyURL
        )
        await waitUntil {
            await rejectedSleeper.pendingCount() == 0
        }
        let rejectedFetchCount = await rejectedBroker.fetchCount
        XCTAssertEqual(rejectedFetchCount, 0)

        let deinitSleeper = TestAlchemyJWTProactiveSleeper()
        weak var weakProvider: AlchemyJWTProvider?
        var provider: AlchemyJWTProvider? = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: TestAlchemyJWTBroker(records: []),
            now: now,
            proactiveRefreshSleep: {
                try await deinitSleeper.sleep($0)
            }
        )
        weakProvider = provider
        _ = try await provider?.authorization(for: alchemyURL)
        await waitUntil {
            await deinitSleeper.pendingCount() == 1
        }

        provider = nil
        await waitUntil {
            let pendingCount = await deinitSleeper.pendingCount()
            return weakProvider == nil && pendingCount == 0
        }
    }

    func testRepeatedNoProgressWakesUseBoundedExponentialBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "no-progress-current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let expectedBackoffs: [UInt64] = [
            1, 2, 4, 8, 16, 32, 64, 128, 256, 300, 300,
        ]
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(
            records: Array(
                repeating: current,
                count: expectedBackoffs.count
            )
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        let authorization = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(authorization?.token, current.token)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }

        for (index, expectedSeconds) in expectedBackoffs.enumerated() {
            await sleeper.resumeNext()
            await waitUntil {
                let durations = await sleeper.requestedDurations()
                return await broker.fetchCount == index + 1
                    && durations.count == index + 2
            }

            let durations = await sleeper.requestedDurations()
            XCTAssertEqual(durations.first, 0)
            let expectedNanoseconds = expectedSeconds * 1_000_000_000
            XCTAssertGreaterThan(
                durations[index + 1],
                expectedNanoseconds - 250_000_000
            )
            XCTAssertLessThanOrEqual(
                durations[index + 1],
                expectedNanoseconds
            )
            clock.advance(by: TimeInterval(expectedSeconds + 1))
        }
    }

    func testUsefulProactiveRefreshResetsNoProgressBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "no-progress-current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "no-progress-replacement",
            issuedAt: now + 10,
            expiresAt: now + 86_410
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(
            records: [
                current,
                current,
                current,
                replacement,
                replacement,
            ]
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }

        for (index, advance) in [0, 2, 3, 5].enumerated() {
            clock.advance(by: TimeInterval(advance))
            await sleeper.resumeNext()
            await waitUntil {
                let durations = await sleeper.requestedDurations()
                return await broker.fetchCount == index + 1
                    && durations.count == index + 2
            }
        }

        var durations = await sleeper.requestedDurations()
        XCTAssertEqual(durations.first, 0)
        XCTAssertGreaterThan(durations[1], 750_000_000)
        XCTAssertLessThanOrEqual(durations[1], 1_000_000_000)
        XCTAssertGreaterThan(durations[2], 1_750_000_000)
        XCTAssertLessThanOrEqual(durations[2], 2_000_000_000)
        XCTAssertGreaterThan(durations[3], 3_750_000_000)
        XCTAssertLessThanOrEqual(durations[3], 4_000_000_000)
        XCTAssertGreaterThan(durations[4], 64_799_750_000_000)
        XCTAssertLessThanOrEqual(durations[4], 64_800_000_000_000)

        clock.advance(by: 64_800)
        await sleeper.resumeNext()
        await waitUntil {
            let values = await sleeper.requestedDurations()
            return await broker.fetchCount == 5 && values.count == 6
        }

        durations = await sleeper.requestedDurations()
        XCTAssertGreaterThan(durations[5], 750_000_000)
        XCTAssertLessThanOrEqual(durations[5], 1_000_000_000)
    }

    func testScheduledRateLimitRearmsAtRetryAfter()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-rate-limit-current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "scheduled-rate-limit-replacement",
            issuedAt: now + 61,
            expiresAt: now + 86_461
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now)),
            advancesWithRealTime: false
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: current),
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: {
                try await sleeper.sleep($0)
            }
        )

        _ = try await provider.authorization(for: alchemyURL)
        await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 1 && durations.count == 2
        }

        let throttled = try await provider.authorization(for: alchemyURL)
        let throttledDurations = await sleeper.requestedDurations()
        let throttledFetchCount = await broker.fetchCount
        XCTAssertEqual(throttled?.token, current.token)
        XCTAssertEqual(throttledDurations.first, 0)
        XCTAssertEqual(throttledDurations[1], 60_000_000_000)
        XCTAssertEqual(throttledFetchCount, 1)

        clock.advance(by: 61)
        await sleeper.resumeNext()
        await waitUntil {
            let durations = await sleeper.requestedDurations()
            return await broker.fetchCount == 2 && durations.count == 3
        }
        let refreshed = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(refreshed?.token, replacement.token)
    }

    func testStaleOpportunisticFetchCannotDowngradeSharedPersistence()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let staleFetch = makeRecord(
            marker: "stale-fetch",
            issuedAt: now - 64_801,
            expiresAt: now + 21_599
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(records: [staleFetch])
        let provider = makeProvider(store: store, broker: broker, now: now)

        await provider.prewarm().value
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, current.token)
        XCTAssertEqual(store.record, current)
        XCTAssertEqual(store.saveCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testPersistenceReloadMakesCrossProcessTokenImmediatelyVisible() async throws {
        let now: Int64 = 2_000_000_000
        let first = makeRecord(
            marker: "first",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let second = makeRecord(
            marker: "second",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: first)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)

        store.record = second
        provider.reloadFromPersistence()

        let authorization = try await provider.authorization(for: alchemyURL)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(authorization?.token, second.token)
        XCTAssertEqual(fetchCount, 0)
    }

    func testUnauthorizedUsesNewerCrossProcessTokenWithoutInvalidatingIt() async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)
        store.record = newer

        let replacement = try await provider.replacementAuthorization(
            afterUnauthorized: AlchemyAuthorization(token: rejected.token),
            for: alchemyURL
        )

        XCTAssertEqual(replacement?.token, newer.token)
        await waitUntil { store.record == newer }
        XCTAssertEqual(store.record, newer)
        XCTAssertEqual(store.saveCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testUnauthorizedReturnsNewerMemoryBeforeWaitingForPersistenceLock()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: newer)
        let broker = TestAlchemyJWTBroker(records: [])
        let sleeper = TestAlchemyJWTSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 5_000_000,
            now: now,
            sleep: { nanoseconds in
                try await sleeper.sleep(nanoseconds)
            }
        )

        let current = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(current?.token, newer.token)
        store.record = rejected
        store.resetCounts()

        let replacement = try await provider.replacementAuthorization(
            afterUnauthorized: AlchemyAuthorization(token: rejected.token),
            for: alchemyURL
        )

        XCTAssertEqual(replacement?.token, newer.token)
        XCTAssertTrue(sleeper.durations.isEmpty)
        XCTAssertEqual(store.record, rejected)
        XCTAssertEqual(store.saveCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testUnauthorizedReturnsNewerMemoryWhilePersistenceSaveIsBlocked()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "blocked-save-rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let newer = makeRecord(
            marker: "blocked-save-newer",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = BlockingSaveAlchemyJWTStore(record: newer)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(
            store: store,
            broker: broker,
            persistenceRepairWindowNanoseconds: 2_000_000_000,
            persistenceRepairInitialDelayNanoseconds: 10_000_000,
            persistenceRepairMaximumDelayNanoseconds: 50_000_000,
            now: now
        )
        let alchemyURL = self.alchemyURL

        let current = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(current?.token, newer.token)
        store.record = rejected
        store.blockNextSave()
        defer { store.releaseBlockedSave() }

        let invalidationTask = Task.detached {
            await provider.invalidateAuthorization(
                afterUnauthorized: AlchemyAuthorization(
                    token: "unrelated-rejected-token"
                ),
                for: alchemyURL
            )
        }
        XCTAssertTrue(store.waitUntilSaveIsBlocked())

        let completionFlag = TestAlchemyJWTCompletionFlag()
        let replacementTask = Task.detached {
            () -> Result<AlchemyAuthorization?, Error> in
            defer { completionFlag.markCompleted() }
            do {
                return .success(
                    try await provider.replacementAuthorization(
                        afterUnauthorized: AlchemyAuthorization(
                            token: rejected.token
                        ),
                        for: alchemyURL
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        let fastPathDeadline = Date().addingTimeInterval(1)
        while !completionFlag.isCompleted, Date() < fastPathDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let completedBeforeSaveWasReleased = completionFlag.isCompleted

        store.releaseBlockedSave()
        let replacement = try await replacementTask.value.get()
        await invalidationTask.value

        XCTAssertTrue(completedBeforeSaveWasReleased)
        XCTAssertEqual(replacement?.token, newer.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
        await waitUntil {
            store.state?.record == newer
                && store.state?.tombstones.contains {
                    $0.tokenDigest == self.tokenDigest(rejected.token)
                } == true
        }
    }

    func testUnauthorizedUsesNewerMemoryBeforeStaleKeychain() async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: newer)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)

        let current = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(current?.token, newer.token)
        store.record = rejected
        store.resetCounts()

        let replacement = try await provider.replacementAuthorization(
            afterUnauthorized: AlchemyAuthorization(token: rejected.token),
            for: alchemyURL
        )

        XCTAssertEqual(replacement?.token, newer.token)
        await waitUntil { store.record == newer }
        XCTAssertEqual(store.record, newer)
        XCTAssertEqual(store.saveCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testUnauthorizedTombstonesOnlyMatchingTokenAndFetchesOnce()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let provider = makeProvider(store: store, broker: broker, now: now)

        let authorization = try await provider.replacementAuthorization(
            afterUnauthorized: AlchemyAuthorization(token: rejected.token),
            for: alchemyURL
        )

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.record, replacement)
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testConcurrentUnauthorizedRecoveryForSameTokenCoalesces()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now - 10,
            expiresAt: now + 86_390
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            delayNanoseconds: 75_000_000
        )
        let provider = makeProvider(store: store, broker: broker, now: now)
        let currentAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(currentAuthorization)

        async let first = provider.replacementAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )
        async let second = provider.replacementAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )
        let resolvedAuthorizations = try await (first, second)
        let authorizations = [
            resolvedAuthorizations.0,
            resolvedAuthorizations.1,
        ]

        XCTAssertEqual(
            Set(authorizations.compactMap { $0?.token }),
            [replacement.token]
        )
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.record, replacement)
    }

    func testUnauthorizedNeverPersistsSameSecondRejectedTokenAndRetriesOnce()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [rejected, replacement])
        let sleeper = TestAlchemyJWTSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now,
            sleep: { nanoseconds in
                try await sleeper.sleep(nanoseconds)
            }
        )

        let original = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(original?.token, rejected.token)
        store.resetCounts()

        let authorization = try await provider.replacementAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.record, replacement)
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(sleeper.durations.count, 2)
        XCTAssertTrue(
            sleeper.durations.allSatisfy { $0 > 1_000_000_000 }
        )
    }

    func testUnauthorizedFailsCleanlyWhenSecondIssuedTokenIsStillRejected()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [rejected, rejected])
        let sleeper = TestAlchemyJWTSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now,
            sleep: { nanoseconds in
                try await sleeper.sleep(nanoseconds)
            }
        )

        let original = try await provider.authorization(for: alchemyURL)
        store.resetCounts()

        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: try XCTUnwrap(original),
                for: alchemyURL
            )
            XCTFail("Expected repeated rejected issuance to fail")
        } catch {
            XCTAssertNil(store.record)
            XCTAssertEqual(store.saveCount, 1)
            XCTAssertEqual(store.state?.tombstones.count, 1)
        }
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(sleeper.durations.count, 2)
    }

    func testUnauthorizedRetriesWhenJoiningDemandThatReturnsRejectedToken()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [rejected, replacement],
            delayNanoseconds: 50_000_000
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now
        )

        let demand = Task {
            try await provider.authorization(for: self.alchemyURL)
        }
        await waitUntil { await broker.fetchCount == 1 }

        let authorization = try await provider.replacementAuthorization(
            afterUnauthorized: AlchemyAuthorization(token: rejected.token),
            for: alchemyURL
        )
        let demandResult = await demand.result

        if case .success = demandResult {
            XCTFail("The concurrently rejected token must not be installed")
        }
        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.record, replacement)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testMalformedAndExpiredBrokerResponsesAreRejectedAndNotPersisted() async {
        let now: Int64 = 2_000_000_000
        let malformed = AlchemyJWTRecord(
            token: "not-a-jwt",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let expired = makeRecord(
            marker: "expired",
            issuedAt: now - 86_400,
            expiresAt: now - 1
        )

        for record in [malformed, expired] {
            let store = TestAlchemyJWTStore(record: nil)
            let broker = TestAlchemyJWTBroker(records: [record])
            let provider = makeProvider(store: store, broker: broker, now: now)

            do {
                _ = try await provider.authorization(for: alchemyURL)
                XCTFail("Expected the invalid broker response to fail")
            } catch {
                XCTAssertNil(store.record)
                XCTAssertEqual(store.saveCount, 0)
            }
        }
    }

    func testInvalidAndUnsupportedPersistenceIsReplacedAndReloadable()
        async throws {
        let now: Int64 = 2_000_000_000
        let legacyLookingRecord = makeRecord(
            marker: "must-not-fall-back-to-legacy",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let unsupportedState = try JSONSerialization.data(
            withJSONObject: [
                "version": AlchemyJWTPersistedState.currentVersion + 1,
                "revision": 41,
                "record": NSNull(),
                "tombstones": [],
            ],
            options: [.sortedKeys]
        )
        let unsupportedLegacyHybrid = try JSONSerialization.data(
            withJSONObject: [
                "version": AlchemyJWTPersistedState.currentVersion + 1,
                "revision": 42,
                "record": NSNull(),
                "tombstones": [],
                "token": legacyLookingRecord.token,
                "issuedAt": legacyLookingRecord.issuedAt,
                "expiresAt": legacyLookingRecord.expiresAt,
            ],
            options: [.sortedKeys]
        )
        let malformedVersionedLegacyHybrid = try JSONSerialization.data(
            withJSONObject: [
                "version": AlchemyJWTPersistedState.currentVersion,
                "token": legacyLookingRecord.token,
                "issuedAt": legacyLookingRecord.issuedAt,
                "expiresAt": legacyLookingRecord.expiresAt,
            ],
            options: [.sortedKeys]
        )
        let invalidStates = [
            Data("not-json".utf8),
            unsupportedState,
            unsupportedLegacyHybrid,
            malformedVersionedLegacyHybrid,
        ]

        for (index, invalidState) in invalidStates.enumerated() {
            XCTAssertNil(
                AlchemyJWTPersistedState.decodePersistenceData(invalidState)
            )
            let replacement = makeRecord(
                marker: "repaired-persistence-\(index)",
                issuedAt: now,
                expiresAt: now + 86_400
            )
            let store = TestEncodedAlchemyJWTStore(data: invalidState)
            let broker = TestAlchemyJWTBroker(records: [replacement])
            let provider = AlchemyJWTProvider(
                tokenStore: store,
                installationIDProvider: TestInstallationIDProvider(
                    installationID: installationID
                ),
                broker: broker,
                refreshLock: TestAlchemyJWTRefreshLock(),
                now: {
                    Date(timeIntervalSince1970: TimeInterval(now))
                },
                persistenceRepairWindowNanoseconds: 0
            )

            let authorization = try await provider.authorization(
                for: alchemyURL
            )

            XCTAssertEqual(authorization?.token, replacement.token)
            XCTAssertEqual(store.state?.record, replacement)
            XCTAssertEqual(store.saveCount, 1)

            let recreatedBroker = TestAlchemyJWTBroker(records: [])
            let recreatedProvider = AlchemyJWTProvider(
                tokenStore: store,
                installationIDProvider: TestInstallationIDProvider(
                    installationID: installationID
                ),
                broker: recreatedBroker,
                refreshLock: TestAlchemyJWTRefreshLock(),
                now: {
                    Date(timeIntervalSince1970: TimeInterval(now))
                },
                persistenceRepairWindowNanoseconds: 0
            )
            let reloaded = try await recreatedProvider.authorization(
                for: alchemyURL
            )

            XCTAssertEqual(reloaded?.token, replacement.token)
            let recreatedFetchCount = await recreatedBroker.fetchCount
            XCTAssertEqual(recreatedFetchCount, 0)
        }
    }

    func testTransientPersistenceReadFailureDoesNotOverwriteSharedState()
        async throws {
        let now: Int64 = 2_000_000_000
        let persisted = makeRecord(
            marker: "persisted",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let memoryOnly = makeRecord(
            marker: "memory-only",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(
            record: persisted,
            loadError: .transient
        )
        let provider = makeProvider(
            store: store,
            broker: TestAlchemyJWTBroker(records: [memoryOnly]),
            now: now
        )

        let authorization = try await provider.authorization(for: alchemyURL)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(authorization?.token, memoryOnly.token)
        XCTAssertEqual(store.state?.record, persisted)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testRefreshFailuresUseBoundedBackoffWithoutDiscardingValidToken() async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(
            errors: [TestBrokerError.unavailable, TestBrokerError.unavailable]
        )
        let clock = TestAlchemyJWTClock(now: Date(timeIntervalSince1970: TimeInterval(now)))
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock
        )

        let firstAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(firstAuthorization?.token, current.token)
        await waitUntil { await broker.fetchCount == 1 }

        let backedOffAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(backedOffAuthorization?.token, current.token)
        try? await Task.sleep(nanoseconds: 25_000_000)
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advance(by: 2)
        let retryAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(retryAuthorization?.token, current.token)
        await waitUntil { await broker.fetchCount == 2 }
    }

    func testOpportunisticFailureDoesNotSuppressColdDemandAcquisition()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [TestBrokerError.unavailable]
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        await provider.prewarm().value
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 2)
    }

    func testDemandBackoffStillRechecksNewCrossProcessToken() async throws {
        let now: Int64 = 2_000_000_000
        let crossProcessRecord = makeRecord(
            marker: "cross-process",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            errors: [TestBrokerError.unavailable]
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the first demand acquisition to fail")
        } catch {
            // Expected.
        }
        store.record = crossProcessRecord

        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, crossProcessRecord.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testColdDemandDoesNotJoinBlockedOpportunisticRefresh() async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let refreshLock = BlockingFirstAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let prewarm = provider.prewarm()
        XCTAssertTrue(refreshLock.waitForFirstAttempt())
        let demand = Task {
            try await provider.authorization(for: self.alchemyURL)
        }
        await waitUntil { await broker.fetchCount == 1 }
        refreshLock.unblockFirstAttempt()

        let authorization = try await demand.value
        await prewarm.value

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.saveCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testColdDemandJoinsActiveOpportunisticBrokerFetch() async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "shared-prewarm",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            delayNanoseconds: 75_000_000
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let prewarm = provider.prewarm()
        await waitUntil { await broker.fetchCount == 1 }
        let authorization = try await provider.authorization(for: alchemyURL)
        await prewarm.value

        XCTAssertEqual(authorization?.token, replacement.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.record, replacement)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testColdDemandBoundsJoinOnHungOpportunisticBrokerFetch()
        async throws {
        let now: Int64 = 2_000_000_000
        let demandRecord = makeRecord(
            marker: "independent-demand",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let prewarmRecord = makeRecord(
            marker: "delayed-prewarm",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [demandRecord, prewarmRecord],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            refreshLockTimeoutNanoseconds: 50_000_000,
            refreshLockPollNanoseconds: 5_000_000,
            now: now
        )

        let prewarm = provider.prewarm()
        await firstFetchGate.waitUntilStarted()
        let demand = Task {
            try await provider.authorization(for: self.alchemyURL)
        }

        await waitUntil(timeout: 1) {
            await broker.fetchCount == 2
        }
        let fetchCountBeforePrewarmRelease = await broker.fetchCount
        let authorization = try await demand.value
        await firstFetchGate.release()
        await prewarm.value

        XCTAssertEqual(fetchCountBeforePrewarmRelease, 2)
        XCTAssertEqual(authorization?.token, demandRecord.token)
        let finalAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(finalAuthorization?.token, demandRecord.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testDemandRetriesAfterOverlappingImmediatePrewarmFailure()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "demand-retry",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [TestBrokerError.unavailable],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        let demand = Task {
            try await provider.authorization(for: self.alchemyURL)
        }
        await waitUntil { refreshLock.attemptCount >= 2 }
        await Task.yield()
        await firstFetchGate.release()

        let authorization = try await demand.value
        await prewarm.value

        XCTAssertEqual(authorization?.token, replacement.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertNil(store.record)
    }

    func testDemandPropagatesOverlappingImmediatePrewarmRateLimit()
        async throws {
        let now: Int64 = 2_000_000_000
        let rateLimit = AlchemyJWTBrokerError.rateLimited(
            retryAfterSeconds: 60
        )
        let sentinel = makeRecord(
            marker: "must-not-fetch",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        let broker = TestAlchemyJWTBroker(
            records: [sentinel],
            errors: [rateLimit],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        let demand = Task {
            try await provider.authorization(for: self.alchemyURL)
        }
        await waitUntil { refreshLock.attemptCount >= 2 }
        await Task.yield()
        await firstFetchGate.release()

        do {
            _ = try await demand.value
            XCTFail("Expected the overlapping broker rate limit")
        } catch let error as AlchemyJWTBrokerError {
            XCTAssertEqual(error, rateLimit)
        } catch {
            XCTFail("Unexpected demand error: \(error)")
        }
        await prewarm.value

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the shared Retry-After backoff")
        } catch {
            // Expected.
        }

        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(store.record)
    }

    func testReloadNeverDowngradesOrClearsFreshMemoryOnlyToken()
        async throws {
        let now: Int64 = 2_000_000_000
        let older = makeRecord(
            marker: "older",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let fresh = makeRecord(
            marker: "fresh",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(records: [fresh])
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let acquired = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(acquired?.token, fresh.token)

        store.record = older
        provider.reloadFromPersistence()
        let authorizationAfterOlderReload = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(authorizationAfterOlderReload?.token, fresh.token)

        store.record = nil
        provider.reloadFromPersistence()
        let authorizationAfterNilReload = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(authorizationAfterNilReload?.token, fresh.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testPersistedRevisionMustAdvanceBeforeReplacingWarmRecord()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let candidate = makeRecord(
            marker: "candidate",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: nil)
        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 10,
                record: current,
                tombstones: []
            )
        )
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)

        let initialAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(initialAuthorization?.token, current.token)

        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 9,
                record: candidate,
                tombstones: []
            )
        )
        provider.reloadFromPersistence()
        let authorizationAfterOlderRevision = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(authorizationAfterOlderRevision?.token, current.token)

        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 11,
                record: candidate,
                tombstones: []
            )
        )
        provider.reloadFromPersistence()
        let authorizationAfterNewerRevision = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(authorizationAfterNewerRevision?.token, candidate.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testOlderOrReusedRevisionCannotRejectOrPromoteStaleState()
        async throws {
        let now: Int64 = 2_000_000_000
        let stale = makeRecord(
            marker: "stale",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let current = makeRecord(
            marker: "current",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: nil)
        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 10,
                record: current,
                tombstones: []
            )
        )
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)
        let initial = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(initial?.token, current.token)

        let staleTombstone = AlchemyJWTRejectionTombstone(
            tokenDigest: Data(
                SHA256.hash(data: Data(current.token.utf8))
            ),
            rejectedAt: now,
            expiresAt: current.expiresAt
        )
        for revision: UInt64 in [9, 10] {
            store.replaceState(
                AlchemyJWTPersistedState(
                    revision: revision,
                    record: stale,
                    tombstones: [staleTombstone]
                )
            )
            provider.reloadFromPersistence()
            let authorization = try await provider.authorization(
                for: alchemyURL
            )
            XCTAssertEqual(authorization?.token, current.token)
        }

        await provider.invalidateAuthorization(
            afterUnauthorized: AlchemyAuthorization(
                token: "unrelated-rejected-token"
            ),
            for: alchemyURL
        )

        XCTAssertEqual(store.state?.revision, 11)
        XCTAssertEqual(store.record, current)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        let authorization = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(authorization?.token, current.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testContendedInvalidationCannotResurrectRejectedKeychainToken()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let original = try await provider.authorization(for: alchemyURL)
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.record, rejected)
        XCTAssertEqual(store.saveCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testLaterAuthorizationRepairsContendedRejectionAndReplacement()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "repair-rejected",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let replacement = makeRecord(
            marker: "repair-replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let cooldownSleeper = TestAlchemyJWTProactiveSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            persistenceRepairWindowNanoseconds: 0,
            now: now,
            persistenceRepairCooldownSleep: {
                try await cooldownSleeper.sleep($0)
            }
        )
        let loadedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(loadedAuthorization)

        let recovered = try await provider.replacementAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recovered?.token, replacement.token)
        XCTAssertEqual(store.record, rejected)
        XCTAssertEqual(store.saveCount, 0)

        contendedLock.makeAvailable()
        let laterAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(laterAuthorization?.token, replacement.token)
        await waitUntil {
            await cooldownSleeper.pendingCount() == 1
        }
        await cooldownSleeper.resumeNext()
        await waitUntil {
            store.record == replacement
                && store.state?.tombstones.contains {
                    $0.tokenDigest == self.tokenDigest(rejected.token)
                } == true
        }

        XCTAssertEqual(store.record, replacement)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        XCTAssertEqual(store.saveCount, 1)

        let recreatedBroker = TestAlchemyJWTBroker(records: [])
        let recreatedProvider = makeProvider(
            store: store,
            broker: recreatedBroker,
            refreshLock: contendedLock,
            now: now
        )
        let recreatedAuthorization = try await recreatedProvider.authorization(
            for: alchemyURL
        )

        XCTAssertEqual(recreatedAuthorization?.token, replacement.token)
        let recreatedFetchCount = await recreatedBroker.fetchCount
        XCTAssertEqual(recreatedFetchCount, 0)
    }

    func testPersistenceRepairRetriesWithinWindowAndCoalescesRequests()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "retry-rejected",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let replacement = makeRecord(
            marker: "retry-replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let sleepGate = TestAlchemyJWTSleepGate()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            persistenceRepairWindowNanoseconds: 1_000_000_000,
            persistenceRepairInitialDelayNanoseconds: 1,
            persistenceRepairMaximumDelayNanoseconds: 2,
            now: now,
            sleep: { _ in
                try await sleepGate.sleep()
            }
        )
        let loadedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(loadedAuthorization)
        let recovered = try await provider.replacementAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )
        XCTAssertEqual(recovered?.token, replacement.token)

        await waitUntil {
            await sleepGate.pendingCount() == 1
        }
        let url = alchemyURL
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await provider.authorization(for: url)
                }
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        let pendingSleepCount = await sleepGate.pendingCount()
        let maximumPendingSleepCount =
            await sleepGate.maximumPendingCount()
        XCTAssertEqual(pendingSleepCount, 1)
        XCTAssertEqual(maximumPendingSleepCount, 1)
        XCTAssertEqual(store.saveCount, 0)

        contendedLock.makeAvailable()
        await sleepGate.resumeAll()
        await waitUntil {
            store.record == replacement
                && store.state?.tombstones.contains {
                    $0.tokenDigest == self.tokenDigest(rejected.token)
                } == true
        }

        XCTAssertEqual(store.saveCount, 1)
        let finalMaximumPendingSleepCount =
            await sleepGate.maximumPendingCount()
        XCTAssertEqual(finalMaximumPendingSleepCount, 1)
    }

    func testPersistenceRepairCooldownIsExponentialAndCannotBeRearmedByTraffic()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "cooldown-rejected",
            issuedAt: now - 1,
            expiresAt: now + 86_399
        )
        let replacement = makeRecord(
            marker: "cooldown-replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let contendedLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let cooldownSleeper = TestAlchemyJWTProactiveSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: contendedLock,
            refreshLockTimeoutNanoseconds: 0,
            persistenceRepairWindowNanoseconds: 0,
            now: now,
            persistenceRepairCooldownSleep: {
                try await cooldownSleeper.sleep($0)
            }
        )
        let loadedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let recovered = try await provider.replacementAuthorization(
            afterUnauthorized: try XCTUnwrap(loadedAuthorization),
            for: alchemyURL
        )
        XCTAssertEqual(recovered?.token, replacement.token)

        await waitUntil {
            await cooldownSleeper.pendingCount() == 1
        }
        let initialCooldowns =
            await cooldownSleeper.requestedDurations()
        XCTAssertEqual(
            initialCooldowns,
            [30_000_000_000]
        )
        let attemptsDuringFirstCooldown = contendedLock.attemptCount

        let url = alchemyURL
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await provider.authorization(for: url)
                }
            }
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        let pendingDuringTraffic = await cooldownSleeper.pendingCount()
        let cooldownsDuringTraffic =
            await cooldownSleeper.requestedDurations()
        XCTAssertEqual(pendingDuringTraffic, 1)
        XCTAssertEqual(
            cooldownsDuringTraffic,
            [30_000_000_000]
        )
        XCTAssertEqual(
            contendedLock.attemptCount,
            attemptsDuringFirstCooldown
        )

        let expectedCooldowns: [UInt64] = [
            30_000_000_000,
            60_000_000_000,
            120_000_000_000,
            240_000_000_000,
            300_000_000_000,
            300_000_000_000,
        ]
        for expectedCount in 2...expectedCooldowns.count {
            await cooldownSleeper.resumeNext()
            await waitUntil {
                let durations = await cooldownSleeper.requestedDurations()
                guard durations.count == expectedCount else {
                    return false
                }
                return await cooldownSleeper.pendingCount() == 1
            }
        }
        let observedCooldowns =
            await cooldownSleeper.requestedDurations()
        XCTAssertEqual(
            observedCooldowns,
            expectedCooldowns
        )

        contendedLock.makeAvailable()
        await cooldownSleeper.resumeNext()
        await waitUntil {
            store.record == replacement
                && store.state?.tombstones.contains {
                    $0.tokenDigest == self.tokenDigest(rejected.token)
                } == true
        }
        XCTAssertEqual(store.saveCount, 1)
        let pendingAfterRecovery = await cooldownSleeper.pendingCount()
        XCTAssertEqual(pendingAfterRecovery, 0)

        XCTAssertTrue(try contendedLock.tryAcquire())
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(recovered),
            for: alchemyURL
        )
        await waitUntil {
            await cooldownSleeper.requestedDurations().count
                == expectedCooldowns.count + 1
        }
        let resetCooldown =
            await cooldownSleeper.requestedDurations().last
        XCTAssertEqual(
            resetCooldown,
            30_000_000_000
        )
        contendedLock.release()
        await cooldownSleeper.resumeNext()
        await waitUntil {
            await cooldownSleeper.pendingCount() == 0
        }
    }

    func testNewerPersistenceCannotEvictLocalRejectionAndResurrectRecord()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let original = try await provider.authorization(for: alchemyURL)
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )
        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 2,
                record: rejected,
                tombstones: (0..<16).map {
                    AlchemyJWTRejectionTombstone(
                        tokenDigest: tokenDigest("newer-rejection-\($0)"),
                        rejectedAt: now + 1,
                        expiresAt: now + 86_400
                    )
                }
            )
        )

        provider.reloadFromPersistence()
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertNotEqual(authorization?.token, rejected.token)
        XCTAssertEqual(store.record, rejected)
        XCTAssertEqual(store.saveCount, 0)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testReloadedTombstoneInvalidatesMatchingWarmToken() async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let provider = makeProvider(store: store, broker: broker, now: now)

        let warm = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(warm?.token, rejected.token)
        store.replaceState(
            AlchemyJWTPersistedState(
                revision: 2,
                record: rejected,
                tombstones: [
                    AlchemyJWTRejectionTombstone(
                        tokenDigest: Data(
                            SHA256.hash(
                                data: Data(rejected.token.utf8)
                            )
                        ),
                        rejectedAt: now,
                        expiresAt: rejected.expiresAt
                    ),
                ]
            )
        )

        provider.reloadFromPersistence()
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testPersistedTombstoneSurvivesProviderRecreation() async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 86_401
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let firstProvider = makeProvider(
            store: store,
            broker: TestAlchemyJWTBroker(records: []),
            now: now
        )
        let currentAuthorization = try await firstProvider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(currentAuthorization)
        await firstProvider.invalidateAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )
        let rejectedState = try XCTUnwrap(store.state)
        store.replaceState(
            AlchemyJWTPersistedState(
                revision: rejectedState.revision + 1,
                record: rejected,
                tombstones: rejectedState.tombstones
            )
        )

        let broker = TestAlchemyJWTBroker(records: [replacement])
        let recreatedProvider = makeProvider(
            store: store,
            broker: broker,
            now: now
        )
        let authorization = try await recreatedProvider.authorization(
            for: alchemyURL
        )

        XCTAssertEqual(authorization?.token, replacement.token)
        XCTAssertEqual(store.record, replacement)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testInvalidationPersistsTombstoneWithoutBrokerRequest()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)
        let original = try await provider.authorization(for: alchemyURL)

        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )

        XCTAssertNil(store.record)
        XCTAssertEqual(store.state?.tombstones.count, 1)
        XCTAssertEqual(store.saveCount, 1)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testPersistedTombstonesAreBounded() async {
        let now: Int64 = 2_000_000_000
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(records: [])
        let provider = makeProvider(store: store, broker: broker, now: now)

        for index in 0..<24 {
            await provider.invalidateAuthorization(
                afterUnauthorized: AlchemyAuthorization(
                    token: "rejected-\(index)"
                ),
                for: alchemyURL
            )
        }

        XCTAssertEqual(store.state?.tombstones.count, 16)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testSameSecondCapacityPreservesJustRejectedCurrentToken()
        async throws {
        let now: Int64 = 2_000_000_000
        let candidates = (0..<32).map {
            makeRecord(
                marker: "capacity-\($0)",
                issuedAt: now - 10,
                expiresAt: now + 86_400
            )
        }.sorted {
            tokenDigest($0.token).lexicographicallyPrecedes(
                tokenDigest($1.token)
            )
        }
        let rejected = try XCTUnwrap(candidates.last)
        let fillers = candidates.prefix(16)
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [rejected])
        let provider = makeProvider(store: store, broker: broker, now: now)

        let original = try await provider.authorization(for: alchemyURL)
        for filler in fillers {
            await provider.invalidateAuthorization(
                afterUnauthorized: AlchemyAuthorization(
                    token: filler.token
                ),
                for: alchemyURL
            )
        }
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )

        let persistedState = try XCTUnwrap(store.state)
        XCTAssertNil(persistedState.record)
        XCTAssertEqual(persistedState.tombstones.count, 16)
        XCTAssertTrue(
            persistedState.tombstones.contains {
                $0.tokenDigest == tokenDigest(rejected.token)
            }
        )

        let returnedToken: String?
        do {
            returnedToken = try await provider.authorization(
                for: alchemyURL
            )?.token
        } catch {
            returnedToken = nil
        }
        XCTAssertNotEqual(returnedToken, rejected.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testBackwardClockCapacityPreservesJustRejectedCurrentToken()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "backward-current",
            issuedAt: now - 10,
            expiresAt: now + 86_400
        )
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(records: [rejected])
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock
        )

        let original = try await provider.authorization(for: alchemyURL)
        for index in 0..<16 {
            await provider.invalidateAuthorization(
                afterUnauthorized: AlchemyAuthorization(
                    token: "backward-filler-\(index)"
                ),
                for: alchemyURL
            )
        }
        clock.advance(by: -1)
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(original),
            for: alchemyURL
        )

        let persistedState = try XCTUnwrap(store.state)
        XCTAssertNil(persistedState.record)
        XCTAssertEqual(persistedState.tombstones.count, 16)
        XCTAssertTrue(
            persistedState.tombstones.contains {
                $0.tokenDigest == tokenDigest(rejected.token)
            }
        )

        let returnedToken: String?
        do {
            returnedToken = try await provider.authorization(
                for: alchemyURL
            )?.token
        } catch {
            returnedToken = nil
        }
        XCTAssertNotEqual(returnedToken, rejected.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testRateLimitDeadlineSuppressesBrokerUntilRetryAfter()
        async throws {
        let now: Int64 = 2_000_000_000
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 61,
            expiresAt: now + 86_461
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock
        )

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the broker rate limit")
        } catch {
            // Expected.
        }
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the Retry-After deadline")
        } catch {
            // Expected.
        }
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advance(by: 61)
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testCooldownUsesUptimeAcrossForwardAndBackwardWallClockJumps()
        async throws {
        let now: Int64 = 2_000_000_000
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "monotonic-cooldown",
            issuedAt: now - 3_600,
            expiresAt: now + 82_800
        )
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let provider = makeProvider(
            store: TestAlchemyJWTStore(record: nil),
            broker: broker,
            clock: clock
        )

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the broker rate limit")
        } catch {
            // Expected.
        }

        clock.adjustWallTime(by: 3_600)
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("A forward wall-clock jump must not bypass cooldown")
        } catch {
            // Expected.
        }

        clock.adjustWallTime(by: -7_200)
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("A backward wall-clock jump must not alter cooldown")
        } catch {
            // Expected.
        }
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advanceUptime(by: 61)
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testRateLimitDeadlineAlsoSuppressesOpportunisticRefresh()
        async throws {
        let now: Int64 = 2_000_000_000
        let clock = TestAlchemyJWTClock(
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 61,
            expiresAt: now + 86_461
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock
        )

        await provider.prewarm().value
        await provider.prewarm().value
        let throttledFetchCount = await broker.fetchCount
        XCTAssertEqual(throttledFetchCount, 1)

        clock.advance(by: 61)
        await provider.prewarm().value

        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
        let authorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(authorization?.token, replacement.token)
    }

    func testRateLimitDeadlineDoesNotScheduleWarmBackgroundReloads()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 64_800,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        await provider.prewarm().value
        store.resetCounts()
        let lockAttempts = refreshLock.attemptCount

        for _ in 0..<5 {
            let authorization = try await provider.authorization(
                for: alchemyURL
            )
            XCTAssertEqual(authorization?.token, current.token)
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.loadCount, 0)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(refreshLock.attemptCount, lockAttempts)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testRateLimitRecoveryRechecksCrossProcessTokenBeforeDeadline()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now - 10,
            expiresAt: now + 86_390
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let provider = makeProvider(store: store, broker: broker, now: now)
        let currentAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(currentAuthorization)

        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: original,
                for: alchemyURL
            )
            XCTFail("Expected the broker rate limit")
        } catch {
            // Expected.
        }
        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: original,
                for: alchemyURL
            )
            XCTFail("Expected the shared Retry-After deadline")
        } catch {
            // Expected.
        }
        let throttledFetchCount = await broker.fetchCount
        XCTAssertEqual(throttledFetchCount, 1)

        store.record = replacement
        let authorization = try await provider.replacementAuthorization(
            afterUnauthorized: original,
            for: alchemyURL
        )

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 1)
    }

    func testRateLimitedUnauthorizedRecoveryFailsBeforeIssuanceWait()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let broker = TestAlchemyJWTBroker(
            errors: [
                AlchemyJWTBrokerError.rateLimited(
                    retryAfterSeconds: 60
                ),
            ]
        )
        let sleeper = TestAlchemyJWTSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            now: now,
            sleep: { nanoseconds in
                try await sleeper.sleep(nanoseconds)
            }
        )
        let loadedAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        let original = try XCTUnwrap(loadedAuthorization)

        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: original,
                for: alchemyURL
            )
            XCTFail("Expected the broker rate limit")
        } catch {
            // Expected.
        }
        XCTAssertEqual(
            sleeper.durations,
            [1_050_000_000]
        )

        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: original,
                for: alchemyURL
            )
            XCTFail("Expected the active Retry-After deadline")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            sleeper.durations,
            [1_050_000_000]
        )
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testRetryAfterParsingIsIntegerBoundedAndDefaultsSafely() {
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds(nil), 60)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds(""), 60)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds("1.5"), 60)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds("-10"), 60)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds("+10"), 60)
        XCTAssertEqual(
            AlchemyJWTBrokerClient.retryAfterSeconds(
                "Sun, 19 Jul 2026 10:00:00 GMT"
            ),
            60
        )
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds("0"), 1)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds(" 42 "), 42)
        XCTAssertEqual(AlchemyJWTBrokerClient.retryAfterSeconds("301"), 300)
        XCTAssertEqual(
            AlchemyJWTBrokerClient.retryAfterSeconds(
                String(repeating: "9", count: 100)
            ),
            300
        )
    }

    func testLegacyRecordPersistenceDecodesIntoVersionedEnvelope()
        throws {
        let record = makeRecord(
            issuedAt: 2_000_000_000,
            expiresAt: 2_000_086_400
        )
        let data = try JSONEncoder().encode(record)

        let state = try XCTUnwrap(
            AlchemyJWTPersistedState.decodePersistenceData(data)
        )

        XCTAssertEqual(state.version, AlchemyJWTPersistedState.currentVersion)
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(state.record, record)
        XCTAssertTrue(state.tombstones.isEmpty)
    }

    func testRealFileLockExcludesSameProcessOpenDescriptions() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-lock-\(UUID().uuidString)",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let first = AlchemyJWTFileLock(fileURL: fileURL)
        let second = AlchemyJWTFileLock(fileURL: fileURL)

        XCTAssertTrue(try first.tryAcquire())
        XCTAssertFalse(try first.tryAcquire())
        XCTAssertFalse(try second.tryAcquire())
        first.release()
        XCTAssertTrue(try second.tryAcquire())
        second.release()
    }

    func testProvidersWithSeparateRealLocksSerializeSharedPersistence()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(
            issuedAt: now,
            expiresAt: now + 86_400
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-provider-lock-\(UUID().uuidString)",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            records: [record],
            delayNanoseconds: 75_000_000
        )
        let first = makeProvider(
            store: store,
            broker: broker,
            refreshLock: AlchemyJWTFileLock(fileURL: fileURL),
            now: now
        )
        let second = makeProvider(
            store: store,
            broker: broker,
            refreshLock: AlchemyJWTFileLock(fileURL: fileURL),
            now: now
        )

        async let firstAuthorization = first.authorization(for: alchemyURL)
        async let secondAuthorization = second.authorization(for: alchemyURL)
        let resolvedAuthorizations = try await (
            firstAuthorization,
            secondAuthorization
        )
        let authorizations = [
            resolvedAuthorizations.0,
            resolvedAuthorizations.1,
        ]

        XCTAssertEqual(
            Set(authorizations.compactMap { $0?.token }),
            [record.token]
        )
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testRacingInstallationIDProvidersCreateOneCanonicalUUID()
        async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-installation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let first = AlchemyAppGroupInstallationIDProvider(
            containerURL: directoryURL
        )
        let second = AlchemyAppGroupInstallationIDProvider(
            containerURL: directoryURL
        )

        let identifiers = try await withThrowingTaskGroup(
            of: UUID.self
        ) { group in
            for index in 0..<20 {
                group.addTask {
                    try (index.isMultiple(of: 2) ? first : second)
                        .installationID()
                }
            }
            var values = [UUID]()
            for try await identifier in group {
                values.append(identifier)
            }
            return values
        }

        XCTAssertEqual(Set(identifiers).count, 1)
        let identifier = try XCTUnwrap(identifiers.first)
        let storedValue = try String(
            contentsOf: directoryURL.appendingPathComponent(
                "alchemy-jwt-installation-id",
                isDirectory: false
            ),
            encoding: .utf8
        )
        XCTAssertEqual(storedValue, identifier.uuidString.lowercased())
    }

#if os(macOS)
    func testRealFileLockContendsWithChildProcessLockf() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-child-lock-\(UUID().uuidString)",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let lock = AlchemyJWTFileLock(fileURL: fileURL)
        XCTAssertTrue(try lock.tryAcquire())

        func runLockf() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            process.arguments = [
                "-t",
                "0",
                fileURL.path,
                "/usr/bin/true",
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        XCTAssertNotEqual(try runLockf(), 0)
        lock.release()
        XCTAssertEqual(try runLockf(), 0)
    }
#endif

    private func makeProvider(
        store: AlchemyJWTStoring,
        broker: TestAlchemyJWTBroker,
        refreshLock: AlchemyJWTRefreshLocking = TestAlchemyJWTRefreshLock(),
        refreshLockTimeoutNanoseconds: UInt64 = 500_000_000,
        refreshLockPollNanoseconds: UInt64 = 25_000_000,
        persistenceRepairWindowNanoseconds: UInt64 = 0,
        persistenceRepairInitialDelayNanoseconds: UInt64 = 1,
        persistenceRepairMaximumDelayNanoseconds: UInt64 = 2,
        now: Int64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        proactiveRefreshSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        persistenceRepairCooldownSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        notificationCenter: NotificationCenter = .default
    ) -> AlchemyJWTProvider {
        return makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            refreshLockTimeoutNanoseconds: refreshLockTimeoutNanoseconds,
            refreshLockPollNanoseconds: refreshLockPollNanoseconds,
            persistenceRepairWindowNanoseconds:
                persistenceRepairWindowNanoseconds,
            persistenceRepairInitialDelayNanoseconds:
                persistenceRepairInitialDelayNanoseconds,
            persistenceRepairMaximumDelayNanoseconds:
                persistenceRepairMaximumDelayNanoseconds,
            clock: TestAlchemyJWTClock(
                now: Date(timeIntervalSince1970: TimeInterval(now))
            ),
            sleep: sleep,
            proactiveRefreshSleep: proactiveRefreshSleep,
            persistenceRepairCooldownSleep:
                persistenceRepairCooldownSleep,
            notificationCenter: notificationCenter
        )
    }

    private func makeProvider(
        store: AlchemyJWTStoring,
        broker: TestAlchemyJWTBroker,
        refreshLock: AlchemyJWTRefreshLocking = TestAlchemyJWTRefreshLock(),
        refreshLockTimeoutNanoseconds: UInt64 = 500_000_000,
        refreshLockPollNanoseconds: UInt64 = 25_000_000,
        persistenceRepairWindowNanoseconds: UInt64 = 0,
        persistenceRepairInitialDelayNanoseconds: UInt64 = 1,
        persistenceRepairMaximumDelayNanoseconds: UInt64 = 2,
        clock: TestAlchemyJWTClock,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        proactiveRefreshSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        persistenceRepairCooldownSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        notificationCenter: NotificationCenter = .default
    ) -> AlchemyJWTProvider {
        return AlchemyJWTProvider(
            tokenStore: store,
            installationIDProvider: TestInstallationIDProvider(
                installationID: installationID
            ),
            broker: broker,
            refreshLock: refreshLock,
            now: { clock.date },
            uptimeNanoseconds: { clock.uptimeNanoseconds },
            refreshLockTimeoutNanoseconds: refreshLockTimeoutNanoseconds,
            refreshLockPollNanoseconds: refreshLockPollNanoseconds,
            persistenceRepairWindowNanoseconds:
                persistenceRepairWindowNanoseconds,
            persistenceRepairInitialDelayNanoseconds:
                persistenceRepairInitialDelayNanoseconds,
            persistenceRepairMaximumDelayNanoseconds:
                persistenceRepairMaximumDelayNanoseconds,
            sleep: sleep,
            proactiveRefreshSleep: proactiveRefreshSleep,
            persistenceRepairCooldownSleep:
                persistenceRepairCooldownSleep,
            notificationCenter: notificationCenter
        )
    }

    private func makeRecord(
        marker: String = "token",
        issuedAt: Int64,
        expiresAt: Int64
    ) -> AlchemyJWTRecord {
        let header: [String: Any] = [
            "alg": "RS256",
            "typ": "JWT",
            "kid": "test-key",
        ]
        let payload: [String: Any] = [
            "iat": issuedAt,
            "exp": expiresAt,
        ]
        let markerBytes = Array(marker.utf8)
        let signature = Data((0..<256).map { index in
            guard !markerBytes.isEmpty else { return UInt8(0) }
            return markerBytes[index % markerBytes.count]
                ^ UInt8(truncatingIfNeeded: index)
        })
        let token = [
            base64URL(header),
            base64URL(payload),
            signature.base64URLEncodedString,
        ].joined(separator: ".")
        return AlchemyJWTRecord(
            token: token,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    private func tokenDigest(_ token: String) -> Data {
        return Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return data.base64URLEncodedString
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for asynchronous state")
    }

}

private enum TestBrokerError: Error {
    case unavailable
}

private final class TestAlchemyJWTCompletionFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var storedIsCompleted = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedIsCompleted
    }

    func markCompleted() {
        lock.lock()
        storedIsCompleted = true
        lock.unlock()
    }

}

private final class BlockingSaveAlchemyJWTStore:
    @unchecked Sendable,
    AlchemyJWTStoring {

    private let store: TestAlchemyJWTStore
    private let gateLock = NSLock()
    private let saveStarted = DispatchSemaphore(value: 0)
    private let saveRelease = DispatchSemaphore(value: 0)
    private var shouldBlockNextSave = false
    private var didReleaseBlockedSave = false

    init(record: AlchemyJWTRecord?) {
        self.store = TestAlchemyJWTStore(record: record)
    }

    var record: AlchemyJWTRecord? {
        get { store.record }
        set { store.record = newValue }
    }

    var state: AlchemyJWTPersistedState? {
        return store.state
    }

    func blockNextSave() {
        gateLock.lock()
        shouldBlockNextSave = true
        didReleaseBlockedSave = false
        gateLock.unlock()
    }

    func waitUntilSaveIsBlocked(
        timeout: TimeInterval = 2
    ) -> Bool {
        return saveStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseBlockedSave() {
        gateLock.lock()
        guard !didReleaseBlockedSave else {
            gateLock.unlock()
            return
        }
        didReleaseBlockedSave = true
        gateLock.unlock()
        saveRelease.signal()
    }

    func load() throws -> AlchemyJWTPersistedState? {
        return try store.load()
    }

    func save(_ state: AlchemyJWTPersistedState) throws {
        gateLock.lock()
        let shouldBlock = shouldBlockNextSave
        shouldBlockNextSave = false
        gateLock.unlock()

        if shouldBlock {
            saveStarted.signal()
            saveRelease.wait()
        }
        try store.save(state)
    }

}

private final class TestAlchemyJWTStore:
    @unchecked Sendable,
    AlchemyJWTStoring {

    private let lock = NSLock()
    private var storedState: AlchemyJWTPersistedState?
    private var loads = 0
    private var saves = 0
    private var configuredLoadError: AlchemyJWTStorageError?
    private var configuredSaveError: AlchemyJWTStorageError?

    init(
        record: AlchemyJWTRecord?,
        loadError: AlchemyJWTStorageError? = nil,
        saveError: AlchemyJWTStorageError? = nil
    ) {
        self.storedState = record.map {
            AlchemyJWTPersistedState(
                revision: 1,
                record: $0,
                tombstones: []
            )
        }
        self.configuredLoadError = loadError
        self.configuredSaveError = saveError
    }

    var record: AlchemyJWTRecord? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedState?.record
        }
        set {
            lock.lock()
            let nextRevision = (storedState?.revision ?? 0) + 1
            storedState = AlchemyJWTPersistedState(
                revision: nextRevision,
                record: newValue,
                tombstones: storedState?.tombstones ?? []
            )
            lock.unlock()
        }
    }

    var state: AlchemyJWTPersistedState? {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    func replaceState(_ state: AlchemyJWTPersistedState?) {
        lock.lock()
        storedState = state
        lock.unlock()
    }

    var loadError: AlchemyJWTStorageError? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredLoadError
        }
        set {
            lock.lock()
            configuredLoadError = newValue
            lock.unlock()
        }
    }

    var saveError: AlchemyJWTStorageError? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return configuredSaveError
        }
        set {
            lock.lock()
            configuredSaveError = newValue
            lock.unlock()
        }
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() throws -> AlchemyJWTPersistedState? {
        lock.lock()
        defer { lock.unlock() }
        loads += 1
        if let configuredLoadError {
            throw configuredLoadError
        }
        return storedState
    }

    func save(_ state: AlchemyJWTPersistedState) throws {
        lock.lock()
        if let configuredSaveError {
            lock.unlock()
            throw configuredSaveError
        }
        storedState = state
        saves += 1
        lock.unlock()
    }

    func resetCounts() {
        lock.lock()
        loads = 0
        saves = 0
        lock.unlock()
    }

}

private final class TestEncodedAlchemyJWTStore:
    @unchecked Sendable,
    AlchemyJWTStoring {

    private let lock = NSLock()
    private var data: Data
    private var saves = 0

    init(data: Data) {
        self.data = data
    }

    var state: AlchemyJWTPersistedState? {
        lock.lock()
        defer { lock.unlock() }
        return AlchemyJWTPersistedState.decodePersistenceData(data)
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() throws -> AlchemyJWTPersistedState? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = AlchemyJWTPersistedState
            .decodePersistenceData(data) else {
            throw AlchemyJWTStorageError.invalidData
        }
        return state
    }

    func save(_ state: AlchemyJWTPersistedState) throws {
        let encoded = try JSONEncoder().encode(state)
        lock.lock()
        data = encoded
        saves += 1
        lock.unlock()
    }

}

private final class TestInstallationIDProvider:
    @unchecked Sendable,
    AlchemyInstallationIDProviding {

    private let id: UUID

    init(installationID: UUID) {
        self.id = installationID
    }

    func installationID() throws -> UUID {
        return id
    }

}

private final class TestAlchemyJWTRefreshLock:
    @unchecked Sendable,
    AlchemyJWTRefreshLocking {

    private let semaphore: DispatchSemaphore
    private let countLock = NSLock()
    private var acquisitions = 0
    private var attempts = 0

    init(isAvailable: Bool = true) {
        self.semaphore = DispatchSemaphore(value: isAvailable ? 1 : 0)
    }

    var acquireCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return acquisitions
    }

    var attemptCount: Int {
        countLock.lock()
        defer { countLock.unlock() }
        return attempts
    }

    func tryAcquire() throws -> Bool {
        countLock.lock()
        attempts += 1
        countLock.unlock()

        guard semaphore.wait(timeout: .now()) == .success else {
            return false
        }
        countLock.lock()
        acquisitions += 1
        countLock.unlock()
        return true
    }

    func release() {
        semaphore.signal()
    }

    func makeAvailable() {
        semaphore.signal()
    }

}

private final class BlockingFirstAlchemyJWTRefreshLock:
    @unchecked Sendable,
    AlchemyJWTRefreshLocking {

    private let stateLock = NSLock()
    private let firstAttemptEntered = DispatchSemaphore(value: 0)
    private let firstAttemptRelease = DispatchSemaphore(value: 0)
    private var isFirstAttempt = true

    func tryAcquire() throws -> Bool {
        stateLock.lock()
        let shouldBlock = isFirstAttempt
        isFirstAttempt = false
        stateLock.unlock()

        if shouldBlock {
            firstAttemptEntered.signal()
            firstAttemptRelease.wait()
        }
        return false
    }

    func release() {}

    func waitForFirstAttempt() -> Bool {
        return firstAttemptEntered.wait(timeout: .now() + 2) == .success
    }

    func unblockFirstAttempt() {
        firstAttemptRelease.signal()
    }

}

private final class TestAlchemyJWTSleeper: @unchecked Sendable {

    private let lock = NSLock()
    private var recordedDurations: [UInt64] = []

    var durations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedDurations
    }

    func sleep(_ nanoseconds: UInt64) async throws {
        record(nanoseconds)
    }

    private func record(_ nanoseconds: UInt64) {
        lock.lock()
        recordedDurations.append(nanoseconds)
        lock.unlock()
    }

}

private actor TestAlchemyJWTProactiveSleeper {

    private struct PendingSleep {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nextIdentifier: UInt64 = 0
    private var requested: [UInt64] = []
    private var pendingOrder: [UInt64] = []
    private var pending: [UInt64: PendingSleep] = [:]
    private var cancelledBeforeRegistration: Set<UInt64> = []

    func sleep(_ nanoseconds: UInt64) async throws {
        nextIdentifier &+= 1
        let identifier = nextIdentifier
        requested.append(nanoseconds)

        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if cancelledBeforeRegistration.remove(identifier) != nil
                        || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingOrder.append(identifier)
                    pending[identifier] = PendingSleep(
                        continuation: continuation
                    )
                }
            },
            onCancel: {
                Task {
                    await self.cancel(identifier)
                }
            }
        )
    }

    func requestedDurations() -> [UInt64] {
        return requested
    }

    func pendingCount() -> Int {
        return pending.count
    }

    func resumeNext() {
        while !pendingOrder.isEmpty {
            let identifier = pendingOrder.removeFirst()
            guard let sleep = pending.removeValue(
                forKey: identifier
            ) else {
                continue
            }
            sleep.continuation.resume(returning: ())
            return
        }
    }

    private func cancel(_ identifier: UInt64) {
        guard let sleep = pending.removeValue(forKey: identifier) else {
            cancelledBeforeRegistration.insert(identifier)
            return
        }
        pendingOrder.removeAll { $0 == identifier }
        sleep.continuation.resume(throwing: CancellationError())
    }

}

private actor TestAlchemyJWTBroker: AlchemyJWTBrokerFetching {

    private var records: [AlchemyJWTRecord]
    private var errors: [Error]
    private let delayNanoseconds: UInt64
    private let firstFetchGate: TestAlchemyJWTBrokerFirstFetchGate?
    private(set) var fetchCount = 0

    init(
        records: [AlchemyJWTRecord] = [],
        errors: [Error] = [],
        delayNanoseconds: UInt64 = 0,
        firstFetchGate: TestAlchemyJWTBrokerFirstFetchGate? = nil
    ) {
        self.records = records
        self.errors = errors
        self.delayNanoseconds = delayNanoseconds
        self.firstFetchGate = firstFetchGate
    }

    func fetchToken(installationID: UUID) async throws -> AlchemyJWTRecord {
        fetchCount += 1
        if fetchCount == 1, let firstFetchGate {
            await firstFetchGate.pause()
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        guard !records.isEmpty else { throw TestBrokerError.unavailable }
        return records.removeFirst()
    }

}

private actor TestAlchemyJWTBrokerFirstFetchGate {

    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

}

private final class TestAlchemyJWTClock: @unchecked Sendable {

    private let lock = NSLock()
    private var currentDate: Date
    private let baseUptimeNanoseconds: UInt64
    private let advancesWithRealTime: Bool
    private var uptimeOffsetNanoseconds: UInt64 = 0

    init(
        now: Date,
        advancesWithRealTime: Bool = true
    ) {
        self.currentDate = now
        self.baseUptimeNanoseconds =
            DispatchTime.now().uptimeNanoseconds
        self.advancesWithRealTime = advancesWithRealTime
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    var uptimeNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let current = advancesWithRealTime
            ? DispatchTime.now().uptimeNanoseconds
            : baseUptimeNanoseconds
        let (adjusted, overflow) = current.addingReportingOverflow(
            uptimeOffsetNanoseconds
        )
        return overflow ? UInt64.max : adjusted
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(interval)
        if interval > 0 {
            uptimeOffsetNanoseconds = addingNanoseconds(
                interval,
                to: uptimeOffsetNanoseconds
            )
        }
        lock.unlock()
    }

    func adjustWallTime(by interval: TimeInterval) {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(interval)
        lock.unlock()
    }

    func advanceUptime(by interval: TimeInterval) {
        lock.lock()
        uptimeOffsetNanoseconds = addingNanoseconds(
            interval,
            to: uptimeOffsetNanoseconds
        )
        lock.unlock()
    }

    private func addingNanoseconds(
        _ interval: TimeInterval,
        to value: UInt64
    ) -> UInt64 {
        guard interval > 0 else { return value }
        let maximumInterval = TimeInterval(
            UInt64.max / 1_000_000_000
        )
        guard interval < maximumInterval else { return UInt64.max }
        let nanoseconds = UInt64(interval * 1_000_000_000)
        let (result, overflow) = value.addingReportingOverflow(nanoseconds)
        return overflow ? UInt64.max : result
    }

}

private actor TestAlchemyJWTSleepGate {

    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var maximumPending = 0

    func sleep() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            continuations.append(continuation)
            maximumPending = max(maximumPending, continuations.count)
        }
    }

    func pendingCount() -> Int {
        return continuations.count
    }

    func maximumPendingCount() -> Int {
        return maximumPending
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: ())
        }
    }

}

private extension Data {

    var base64URLEncodedString: String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

}
