// ∅ 2026 lil org

import CryptoKit
import Foundation
import XCTest
import Synchronization
@testable import Big_Wallet

private let alchemyURL = URL(string: "https://eth-mainnet.g.alchemy.com/v2")!

final class AlchemyJWTProviderTests: XCTestCase {

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
            expiresAt: 2_000_021_600
        )
        XCTAssertFalse(ordinary.isTimeUsable(at: Int64.max))
        XCTAssertFalse(ordinary.shouldRefresh(at: Int64.min))
    }

    func testJWTLifetimeAcceptsOneThroughSixHoursOnly() {
        let now: Int64 = 2_000_000_000

        for lifetime in [3_600, 21_600] {
            XCTAssertTrue(
                makeRecord(
                    issuedAt: now,
                    expiresAt: now + Int64(lifetime)
                ).isStructurallyValid(at: now)
            )
        }
        for lifetime in [3_599, 21_601] {
            XCTAssertFalse(
                makeRecord(
                    issuedAt: now,
                    expiresAt: now + Int64(lifetime)
                ).isStructurallyValid(at: now)
            )
        }
    }

    func testProofKeyLoaderRequiresCanonical32ByteBase64URL() throws {
        let encodedKey =
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        try withProofKeyBundle(contents: Data(encodedKey.utf8)) { bundle in
            XCTAssertEqual(
                try AlchemyJWTRequestProofSigner.loadKeyData(in: bundle),
                Data((0...31).map(UInt8.init))
            )
        }

        var noncanonicalKey = encodedKey
        noncanonicalKey.removeLast()
        noncanonicalKey.append("9")
        let invalidResources = [
            Data(),
            Data(encodedKey.dropLast().utf8),
            Data((encodedKey + "=").utf8),
            Data((encodedKey + "\n").utf8),
            Data(noncanonicalKey.utf8),
            Data(("!" + encodedKey.dropFirst()).utf8),
            Data(repeating: 0x41, count: 1_048_576),
        ]
        for invalidResource in invalidResources {
            try withProofKeyBundle(contents: invalidResource) { bundle in
                XCTAssertThrowsError(
                    try AlchemyJWTRequestProofSigner.loadKeyData(in: bundle)
                ) { error in
                    XCTAssertEqual(
                        error as? AlchemyJWTRequestProofError,
                        .invalidKeyResource
                    )
                }
            }
        }

        try withProofKeyBundle(contents: nil) { bundle in
            XCTAssertThrowsError(
                try AlchemyJWTRequestProofSigner.loadKeyData(in: bundle)
            ) { error in
                XCTAssertEqual(
                    error as? AlchemyJWTRequestProofError,
                    .missingKeyResource
                )
            }
        }
    }

    func testProofSignerLazilyLoadsAndCachesBundledKey() throws {
        let encodedKey =
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        try withProofKeyBundle(contents: Data(encodedKey.utf8)) { bundle in
            let signer = AlchemyJWTRequestProofSigner(
                bundle: bundle,
                now: {
                    Date(timeIntervalSince1970: 1_784_558_400)
                },
                nonceSource: {
                    Data((0...15).map(UInt8.init))
                }
            )
            let first = try signer.signedRequest()
            let resourceURL = try XCTUnwrap(
                bundle.url(
                    forResource: AlchemyJWTRequestProofSigner.resourceName,
                    withExtension: nil
                )
            )
            try FileManager.default.removeItem(at: resourceURL)

            XCTAssertEqual(try signer.signedRequest(), first)
        }
    }

    func testJWTCompactEncodingRequiresCanonicalRSA2048Signature() throws {
        let now: Int64 = 2_000_000_000
        let valid = makeRecord(
            issuedAt: now,
            expiresAt: now + 21_600
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
        let record = makeRecord(issuedAt: now - 60, expiresAt: now + 21_540)
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
            expiresAt: now + 21_600
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
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: TestAlchemyJWTRefreshLock(isAvailable: false),
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let entered = expectation(description: "all prewarm callers entered")
        entered.expectedFulfillmentCount = 20
        let calls = Task {
            await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    entered.fulfill()
                    await provider.prewarmForImmediateUse()
                }
            }
        }
        }
        await fulfillment(of: [entered], timeout: 2)
        await firstFetchGate.waitUntilStarted()
        firstFetchGate.release()
        await calls.value

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
            expiresAt: now + 21_600
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
            records: [makeRecord(issuedAt: 2_000_000_000, expiresAt: 2_000_021_600)]
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
        let record = makeRecord(issuedAt: now, expiresAt: now + 21_600)
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        let entered = expectation(description: "all authorization callers entered")
        entered.expectedFulfillmentCount = 20
        let calls = Task {
            try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    entered.fulfill()
                    return try await provider.authorization(for: alchemyURL)?.token
                }
            }

            var values: [String?] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        }
        await fulfillment(of: [entered], timeout: 2)
        await firstFetchGate.waitUntilStarted()
        firstFetchGate.release()
        let tokens = try await calls.value

        XCTAssertEqual(Set(tokens.compactMap { $0 }), [record.token])
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testOverlappingImmediateUsePrewarmAndColdRPCShareBrokerFlight()
        async throws {
        let now: Int64 = 2_000_000_000
        let record = makeRecord(issuedAt: now, expiresAt: now + 21_600)
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let observeDemand = Mutex(false)
        let contended = expectation(description: "overlapping demand attempted held lock")
        contended.assertForOverFulfill = false
        let observedLock = ObservedAlchemyJWTRefreshLock(refreshLock) { acquired in
            if !acquired, observeDemand.withLock({ $0 }) { contended.fulfill() }
        }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: observedLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        observeDemand.withLock { $0 = true }
        let rpc = Task {
            try await provider.authorization(for: alchemyURL)?.token
        }
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()

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
        let record = makeRecord(issuedAt: now, expiresAt: now + 21_600)
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let contended = expectation(description: "second provider contended on shared lock")
        contended.assertForOverFulfill = false
        let sharedLock = TestAlchemyJWTRefreshLock()
        let observedLock = ObservedAlchemyJWTRefreshLock(sharedLock) { acquired in
            if !acquired { contended.fulfill() }
        }
        let first = makeProvider(
            store: store,
            broker: broker,
            refreshLock: observedLock,
            now: now
        )
        let second = makeProvider(
            store: store,
            broker: broker,
            refreshLock: observedLock,
            now: now
        )

        async let firstToken = first.authorization(for: alchemyURL)?.token
        async let secondToken = second.authorization(for: alchemyURL)?.token
        await firstFetchGate.waitUntilStarted()
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()
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
        let record = makeRecord(issuedAt: now, expiresAt: now + 21_600)
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
            expiresAt: now + 21_599
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: current)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            firstFetchGate: firstFetchGate
        )
        let provider = makeProvider(store: store, broker: broker, now: now)

        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, current.token)
        await firstFetchGate.waitUntilStarted()
        XCTAssertEqual(store.record, current)
        let refresh = provider.prewarm()
        firstFetchGate.release()
        await refresh.value
        XCTAssertEqual(store.record, replacement)
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
            expiresAt: now + 21_600
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }

        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(durations, [16_200_000_000_000])
        XCTAssertEqual(fetchCount, 0)
    }

    func testScheduledWakeRefreshesAndSchedulesTheReplacement()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-old",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "scheduled-new",
            issuedAt: now + 16_200,
            expiresAt: now + 37_800
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let broker = TestAlchemyJWTBroker(records: [replacement])
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }

        clock.advance(by: 16_200_000_000_000)
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 }
        let checkpointFetchCount2 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount2, 1)

        let refreshed = try await provider.authorization(for: alchemyURL)
        let durations = await sleeper.requestedDurations()
        XCTAssertEqual(refreshed?.token, replacement.token)
        XCTAssertEqual(
            durations,
            [
                16_200_000_000_000,
                16_200_000_000_000,
            ]
        )
    }

    func testScheduledRefreshStaysSingleFlightDuringRPCAndLifecyclePrewarm()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-in-flight-current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "scheduled-in-flight-replacement",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            firstFetchGate: firstFetchGate
        )
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        await sleeper.resumeNext()
        await firstFetchGate.waitUntilStarted()

        clock.advanceUptime(by: 2_000_000_000)
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

        let inFlightDurations = await sleeper.requestedDurations()
        let inFlightPendingCount = await sleeper.pendingCount()
        let inFlightFetchCount = await broker.fetchCount
        firstFetchGate.release()
        await lifecyclePrewarm.value
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 }
        let checkpointFetchCount4 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount4, 1)

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
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let unexpectedSecond = makeRecord(
            marker: "unexpected-second",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        await sleeper.resumeNext()
        await firstFetchGate.waitUntilStarted()

        let overlappingPrewarm = provider.prewarm()
        firstFetchGate.release()
        await overlappingPrewarm.value
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 }
        let checkpointFetchCount6 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount6, 1)

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
            expiresAt: now + 11_600
        )
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        clock.setDate(clock.date.addingTimeInterval(3_600))
        notificationCenter.post(
            name: .NSSystemClockDidChange,
            object: nil
        )
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 && pendingCount == 1 }
        clock.setDate(clock.date.addingTimeInterval(-7_200))
        notificationCenter.post(
            name: .NSSystemClockDidChange,
            object: nil
        )
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 3 && pendingCount == 1 }

        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(
            durations,
            [
                6_200_000_000_000,
                2_600_000_000_000,
                9_800_000_000_000,
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
            expiresAt: now + 21_600
        )
        let second = makeRecord(
            marker: "reload-second",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        store.record = second
        provider.reloadFromPersistence()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 && pendingCount == 1 }

        let authorization = try await provider.authorization(for: alchemyURL)
        let durations = await sleeper.requestedDurations()
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(authorization?.token, second.token)
        XCTAssertEqual(
            durations,
            [
                16_200_000_000_000,
                16_201_000_000_000,
            ]
        )
        XCTAssertEqual(fetchCount, 0)
    }

    func testFreshPersistenceReloadResetsOpportunisticBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "reload-backed-off-current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "reload-backed-off-replacement",
            issuedAt: now + 2,
            expiresAt: now + 21_602
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
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 }
        let checkpointFetchCount13 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount13, 1)
        clock.advance(by: 2_000_000_000)
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 3 }
        let checkpointFetchCount14 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount14, 2)

        store.record = replacement
        provider.reloadFromPersistence()
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 && durations.count == 4 }

        clock.advance(by: 16_200_000_000_000)
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 5 }
        let checkpointFetchCount16 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount16, 3)

        let durations = await sleeper.requestedDurations()
        XCTAssertGreaterThan(durations[1], 750_000_000)
        XCTAssertLessThanOrEqual(durations[1], 1_000_000_000)
        XCTAssertGreaterThan(durations[2], 1_750_000_000)
        XCTAssertLessThanOrEqual(durations[2], 2_000_000_000)
        XCTAssertGreaterThan(durations[3], 16_199_750_000_000)
        XCTAssertLessThanOrEqual(durations[3], 16_200_000_000_000)
        XCTAssertGreaterThan(durations[4], 750_000_000)
        XCTAssertLessThanOrEqual(durations[4], 1_000_000_000)
    }

    func testFreshPersistenceReloadResetsDemandBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "reload-demand-replacement",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let broker = TestAlchemyJWTBroker(
            errors: [
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
                TestBrokerError.unavailable,
            ]
        )
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        }

        store.record = replacement
        provider.reloadFromPersistence()
        clock.advance(by: 21_601_000_000_000)

        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the post-expiry demand failure")
        } catch {
        }
        clock.advance(by: 300_000_000)
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the retry demand failure")
        } catch {
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
            expiresAt: now + 21_600
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
        await waitForSleeper(rejectedSleeper) { durations, pendingCount in pendingCount == 1 }

        await rejectedProvider.invalidateAuthorization(
            afterUnauthorized: authorization,
            for: alchemyURL
        )
        await waitForSleeper(rejectedSleeper) { durations, pendingCount in pendingCount == 0 }
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
        await waitForSleeper(deinitSleeper) { durations, pendingCount in pendingCount == 1 }

        provider = nil
        await waitForSleeper(deinitSleeper) { _, pending in pending == 0 }
        XCTAssertNil(weakProvider)
    }

    func testRepeatedNoProgressWakesUseBoundedExponentialBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "no-progress-current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
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
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }

        for (index, expectedSeconds) in expectedBackoffs.enumerated() {
            await sleeper.resumeNext()
            await waitForSleeper(sleeper) { durations, _ in durations.count == index + 2 }
            let fetchCount = await broker.fetchCount
            XCTAssertEqual(fetchCount, index + 1)

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
            clock.advance(by: UInt64(expectedSeconds + 1) * 1_000_000_000)
        }
    }

    func testUsefulProactiveRefreshResetsNoProgressBackoff()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "no-progress-current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "no-progress-replacement",
            issuedAt: now + 10,
            expiresAt: now + 21_610
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
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }

        for (index, advance) in [0, 2, 3, 5].enumerated() {
            clock.advance(by: UInt64(advance) * 1_000_000_000)
            await sleeper.resumeNext()
            await waitForSleeper(sleeper) { durations, _ in durations.count == index + 2 }
            let fetchCount = await broker.fetchCount
            XCTAssertEqual(fetchCount, index + 1)
        }

        var durations = await sleeper.requestedDurations()
        XCTAssertEqual(durations.first, 0)
        XCTAssertGreaterThan(durations[1], 750_000_000)
        XCTAssertLessThanOrEqual(durations[1], 1_000_000_000)
        XCTAssertGreaterThan(durations[2], 1_750_000_000)
        XCTAssertLessThanOrEqual(durations[2], 2_000_000_000)
        XCTAssertGreaterThan(durations[3], 3_750_000_000)
        XCTAssertLessThanOrEqual(durations[3], 4_000_000_000)
        XCTAssertGreaterThan(durations[4], 16_199_750_000_000)
        XCTAssertLessThanOrEqual(durations[4], 16_200_000_000_000)

        clock.advance(by: 16_200_000_000_000)
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 6 }
        let checkpointFetchCount24 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount24, 5)

        durations = await sleeper.requestedDurations()
        XCTAssertGreaterThan(durations[5], 750_000_000)
        XCTAssertLessThanOrEqual(durations[5], 1_000_000_000)
    }

    func testScheduledRateLimitRearmsAtRetryAfter()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "scheduled-rate-limit-current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let replacement = makeRecord(
            marker: "scheduled-rate-limit-replacement",
            issuedAt: now + 61,
            expiresAt: now + 21_661
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
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        await waitForSleeper(sleeper) { durations, pendingCount in pendingCount == 1 }
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 2 }
        let checkpointFetchCount26 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount26, 1)

        let throttled = try await provider.authorization(for: alchemyURL)
        let throttledDurations = await sleeper.requestedDurations()
        let throttledFetchCount = await broker.fetchCount
        XCTAssertEqual(throttled?.token, current.token)
        XCTAssertEqual(throttledDurations.first, 0)
        XCTAssertEqual(throttledDurations[1], 60_000_000_000)
        XCTAssertEqual(throttledFetchCount, 1)

        clock.advance(by: 61_000_000_000)
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pendingCount in durations.count == 3 }
        let checkpointFetchCount27 = await broker.fetchCount
        XCTAssertEqual(checkpointFetchCount27, 2)
        let refreshed = try await provider.authorization(for: alchemyURL)
        XCTAssertEqual(refreshed?.token, replacement.token)
    }

    func testStaleOpportunisticFetchCannotDowngradeSharedPersistence()
        async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let staleFetch = makeRecord(
            marker: "stale-fetch",
            issuedAt: now - 16_201,
            expiresAt: now + 5_399
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
            expiresAt: now + 21_600
        )
        let second = makeRecord(
            marker: "second",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
        await waitForStoredRecord(newer, in: store)
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
            expiresAt: now + 21_600
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
        )
        let newer = makeRecord(
            marker: "blocked-save-newer",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
        let alchemyURL = alchemyURL

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
        let saveIsBlocked = await store.waitUntilSaveIsBlocked()
        XCTAssertTrue(saveIsBlocked)

        let replacementFinished = expectation(description: "replacement finished while save is blocked")
        let replacementTask = Task.detached {
            () -> Result<AlchemyAuthorization?, Error> in
            defer { replacementFinished.fulfill() }
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
        let completedBeforeSaveWasReleased = await XCTWaiter.fulfillment(of: [replacementFinished], timeout: 1) == .completed

        store.releaseBlockedSave()
        let replacement = try await replacementTask.value.get()
        await invalidationTask.value

        XCTAssertTrue(completedBeforeSaveWasReleased)
        XCTAssertEqual(replacement?.token, newer.token)
        let fetchCount = await broker.fetchCount
        XCTAssertEqual(fetchCount, 0)
        let rejectedDigest = tokenDigest(rejected.token)
        await waitForStoredState(in: store.store) { state in
            state.record == newer && state.tombstones.contains { $0.tokenDigest == rejectedDigest }
        }
    }

    func testUnauthorizedUsesNewerMemoryBeforeStaleKeychain() async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let newer = makeRecord(
            marker: "newer",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
        await waitForStoredRecord(newer, in: store)
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_590
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: rejected)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            firstFetchGate: firstFetchGate
        )
        let contended = expectation(description: "concurrent rejection reached held lock")
        contended.assertForOverFulfill = false
        let lock = ObservedAlchemyJWTRefreshLock(TestAlchemyJWTRefreshLock()) { acquired in
            if !acquired { contended.fulfill() }
        }
        let provider = makeProvider(store: store, broker: broker, refreshLock: lock, now: now)
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
        await firstFetchGate.waitUntilStarted()
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [rejected, replacement],
            firstFetchGate: firstFetchGate
        )
        let rejectionEntered = expectation(description: "rejection attempted persistence")
        rejectionEntered.assertForOverFulfill = false
        let refreshLock = ObservedAlchemyJWTRefreshLock(TestAlchemyJWTRefreshLock()) { acquired in
            if !acquired { rejectionEntered.fulfill() }
        }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let demand = Task {
            try await provider.authorization(for: alchemyURL)
        }
        await firstFetchGate.waitUntilStarted()

        let recovery = Task {
            try await provider.replacementAuthorization(
                afterUnauthorized: AlchemyAuthorization(token: rejected.token),
                for: alchemyURL
            )
        }
        await fulfillment(of: [rejectionEntered], timeout: 2)
        firstFetchGate.release()
        let authorization = try await recovery.value
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
            expiresAt: now + 21_600
        )
        let expired = makeRecord(
            marker: "expired",
            issuedAt: now - 21_600,
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
            expiresAt: now + 21_600
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
                expiresAt: now + 21_600
            )
            let store = TestEncodedAlchemyJWTStore(data: invalidState)
            let broker = TestAlchemyJWTBroker(records: [replacement])
            let provider = AlchemyJWTProvider(
                tokenStore: store,
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
            expiresAt: now + 21_599
        )
        let memoryOnly = makeRecord(
            marker: "memory-only",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(
            record: persisted,
            loadError: .transient
        )
        let cooldown = TestAlchemyJWTProactiveSleeper()
        let provider = makeProvider(
            store: store,
            broker: TestAlchemyJWTBroker(records: [memoryOnly]),
            now: now,
            persistenceRepairCooldownSleep: { try await cooldown.sleep($0) }
        )

        let authorization = try await provider.authorization(for: alchemyURL)
        await waitForSleeper(cooldown) { _, pending in pending == 1 }

        XCTAssertEqual(authorization?.token, memoryOnly.token)
        XCTAssertEqual(store.state?.record, persisted)
        XCTAssertEqual(store.saveCount, 0)
    }

    func testRefreshFailuresUseBoundedBackoffWithoutDiscardingValidToken() async throws {
        let now: Int64 = 2_000_000_000
        let current = makeRecord(
            marker: "current",
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
        )
        let store = TestAlchemyJWTStore(record: current)
        let broker = TestAlchemyJWTBroker(
            errors: [TestBrokerError.unavailable, TestBrokerError.unavailable]
        )
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now)))
        let sleeper = TestAlchemyJWTProactiveSleeper()
        let provider = makeProvider(
            store: store,
            broker: broker,
            clock: clock,
            proactiveRefreshSleep: { try await sleeper.sleep($0) }
        )

        let firstAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(firstAuthorization?.token, current.token)
        await waitForSleeper(sleeper) { durations, pending in durations.last == 0 && pending == 1 }
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pending in durations.last == 1_000_000_000 && pending == 1 }

        let backedOffAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(backedOffAuthorization?.token, current.token)
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advance(by: 2_000_000_000)
        let retryAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(retryAuthorization?.token, current.token)
        await waitForSleeper(sleeper) { durations, pending in durations.last == 0 && pending == 1 }
        await sleeper.resumeNext()
        await waitForSleeper(sleeper) { durations, pending in durations.last == 2_000_000_000 && pending == 1 }
        let retryFetchCount = await broker.fetchCount
        XCTAssertEqual(retryFetchCount, 2)
    }

    func testOpportunisticFailureDoesNotSuppressColdDemandAcquisition()
        async throws {
        let now: Int64 = 2_000_000_000
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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
            expiresAt: now + 21_600
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
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let fetched = expectation(description: "demand fetched without blocked opportunistic lock")
        let broker = TestAlchemyJWTBroker(records: [replacement], onFetch: { _ in fetched.fulfill() })
        let refreshLock = BlockingFirstAlchemyJWTRefreshLock()
        defer { refreshLock.unblockFirstAttempt() }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            refreshLockTimeoutNanoseconds: 0,
            now: now
        )

        let prewarm = provider.prewarm()
        let firstAttemptStarted = await refreshLock.waitForFirstAttempt()
        XCTAssertTrue(firstAttemptStarted)
        let demand = Task {
            try await provider.authorization(for: alchemyURL)
        }
        await fulfillment(of: [fetched], timeout: 2)
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
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            firstFetchGate: firstFetchGate
        )
        let contended = expectation(description: "cold demand reached the held lock")
        contended.assertForOverFulfill = false
        let refreshLock = ObservedAlchemyJWTRefreshLock(TestAlchemyJWTRefreshLock()) { acquired in
            if !acquired { contended.fulfill() }
        }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: refreshLock,
            now: now
        )

        let prewarm = provider.prewarm()
        await firstFetchGate.waitUntilStarted()
        let demand = Task { try await provider.authorization(for: alchemyURL) }
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()
        let authorization = try await demand.value
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
            expiresAt: now + 21_601
        )
        let prewarmRecord = makeRecord(
            marker: "delayed-prewarm",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let demandFetched = expectation(description: "real join timeout released demand")
        let broker = TestAlchemyJWTBroker(
            records: [demandRecord, prewarmRecord],
            firstFetchGate: firstFetchGate,
            onFetch: { count in if count == 2 { demandFetched.fulfill() } }
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
            try await provider.authorization(for: alchemyURL)
        }

        await fulfillment(of: [demandFetched], timeout: 2)
        let fetchCountBeforePrewarmRelease = await broker.fetchCount
        let authorization = try await demand.value
        firstFetchGate.release()
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
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [replacement],
            errors: [TestBrokerError.unavailable],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock(isAvailable: false)
        let observeDemand = Mutex(false)
        let contended = expectation(description: "overlapping demand attempted held lock")
        contended.assertForOverFulfill = false
        let observedLock = ObservedAlchemyJWTRefreshLock(refreshLock) { acquired in
            if !acquired, observeDemand.withLock({ $0 }) { contended.fulfill() }
        }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: observedLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        observeDemand.withLock { $0 = true }
        let demand = Task {
            try await provider.authorization(for: alchemyURL)
        }
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()

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
            expiresAt: now + 21_600
        )
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [sentinel],
            errors: [rateLimit],
            firstFetchGate: firstFetchGate
        )
        let refreshLock = TestAlchemyJWTRefreshLock()
        let observeDemand = Mutex(false)
        let contended = expectation(description: "overlapping demand attempted held lock")
        contended.assertForOverFulfill = false
        let observedLock = ObservedAlchemyJWTRefreshLock(refreshLock) { acquired in
            if !acquired, observeDemand.withLock({ $0 }) { contended.fulfill() }
        }
        let provider = makeProvider(
            store: store,
            broker: broker,
            refreshLock: observedLock,
            now: now
        )

        let prewarm = Task {
            await provider.prewarmForImmediateUse()
        }
        await firstFetchGate.waitUntilStarted()
        observeDemand.withLock { $0 = true }
        let demand = Task {
            try await provider.authorization(for: alchemyURL)
        }
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()

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
            expiresAt: now + 21_600
        )
        let fresh = makeRecord(
            marker: "fresh",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
        )
        let candidate = makeRecord(
            marker: "candidate",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_599
        )
        let current = makeRecord(
            marker: "current",
            issuedAt: now,
            expiresAt: now + 21_600
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_599
        )
        let replacement = makeRecord(
            marker: "repair-replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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
        await waitForSleeper(cooldownSleeper) { _, pending in pending == 1 }

        XCTAssertEqual(recovered?.token, replacement.token)
        XCTAssertEqual(store.record, rejected)
        XCTAssertEqual(store.saveCount, 0)

        contendedLock.makeAvailable()
        let laterAuthorization = try await provider.authorization(
            for: alchemyURL
        )
        XCTAssertEqual(laterAuthorization?.token, replacement.token)
        await waitForSleeper(cooldownSleeper) { durations, pendingCount in pendingCount == 1 }
        await cooldownSleeper.resumeNext()
        let rejectedDigest = tokenDigest(rejected.token)
        await waitForStoredState(in: store) { state in
            state.record == replacement && state.tombstones.contains { $0.tokenDigest == rejectedDigest }
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
            expiresAt: now + 21_599
        )
        let replacement = makeRecord(
            marker: "retry-replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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

        let registered = expectation(description: "repair sleep registered")
        await sleepGate.observeRegistration(registered)
        await fulfillment(of: [registered], timeout: 2)
        let url = alchemyURL
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await provider.authorization(for: url)
                }
            }
        }

        let pendingSleepCount = await sleepGate.pendingCount()
        let maximumPendingSleepCount =
            await sleepGate.maximumPendingCount()
        XCTAssertEqual(pendingSleepCount, 1)
        XCTAssertEqual(maximumPendingSleepCount, 1)
        XCTAssertEqual(store.saveCount, 0)

        contendedLock.makeAvailable()
        await sleepGate.resumeAll()
        let rejectedDigest = tokenDigest(rejected.token)
        await waitForStoredState(in: store) { state in
            state.record == replacement && state.tombstones.contains { $0.tokenDigest == rejectedDigest }
        }

        XCTAssertEqual(store.saveCount, 1)
        let finalMaximum = await sleepGate.maximumPendingCount()
        XCTAssertEqual(finalMaximum, 1)
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
            expiresAt: now + 21_599
        )
        let replacement = makeRecord(
            marker: "cooldown-replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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

        await waitForSleeper(cooldownSleeper) { durations, pendingCount in pendingCount == 1 }
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
            await waitForSleeper(cooldownSleeper) { durations, pending in durations.count == expectedCount && pending == 1 }
        }
        let observedCooldowns =
            await cooldownSleeper.requestedDurations()
        XCTAssertEqual(
            observedCooldowns,
            expectedCooldowns
        )

        let repairReleased = expectation(description: "repair released persistence lock")
        repairReleased.assertForOverFulfill = false
        contendedLock.onRelease = { repairReleased.fulfill() }
        contendedLock.makeAvailable()
        await cooldownSleeper.resumeNext()
        let rejectedDigest = tokenDigest(rejected.token)
        await waitForStoredState(in: store) { state in
            state.record == replacement && state.tombstones.contains { $0.tokenDigest == rejectedDigest }
        }
        XCTAssertEqual(store.saveCount, 1)
        let pendingAfterRecovery = await cooldownSleeper.pendingCount()
        XCTAssertEqual(pendingAfterRecovery, 0)

        await fulfillment(of: [repairReleased], timeout: 2)
        contendedLock.onRelease = nil
        let acquiredLock = try contendedLock.tryAcquire()
        XCTAssertTrue(acquiredLock)
        await provider.invalidateAuthorization(
            afterUnauthorized: try XCTUnwrap(recovered),
            for: alchemyURL
        )
        await waitForSleeper(cooldownSleeper) { durations, pendingCount in durations.count == expectedCooldowns.count + 1 }
        let resetCooldown =
            await cooldownSleeper.requestedDurations().last
        XCTAssertEqual(
            resetCooldown,
            30_000_000_000
        )
        contendedLock.release()
        await cooldownSleeper.resumeNext()
        await waitForSleeper(cooldownSleeper) { durations, pendingCount in pendingCount == 0 }
    }

    func testNewerPersistenceCannotEvictLocalRejectionAndResurrectRecord()
        async throws {
        let now: Int64 = 2_000_000_000
        let rejected = makeRecord(
            marker: "rejected",
            issuedAt: now,
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
                        expiresAt: now + 21_600
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 1,
            expiresAt: now + 21_601
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
            expiresAt: now + 21_600
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
                expiresAt: now + 21_590
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
            expiresAt: now + 21_590
        )
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
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
        clock.setDate(clock.date.addingTimeInterval(-1))
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
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 61,
            expiresAt: now + 21_661
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
        }
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("Expected the Retry-After deadline")
        } catch {
        }
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advance(by: 61_000_000_000)
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testCooldownUsesUptimeAcrossForwardAndBackwardWallClockJumps()
        async throws {
        let now: Int64 = 2_000_000_000
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "monotonic-cooldown",
            issuedAt: now - 3_600,
            expiresAt: now + 18_000
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
        }

        clock.setDate(clock.date.addingTimeInterval(3_600))
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("A forward wall-clock jump must not bypass cooldown")
        } catch {
        }

        clock.setDate(clock.date.addingTimeInterval(-7_200))
        do {
            _ = try await provider.authorization(for: alchemyURL)
            XCTFail("A backward wall-clock jump must not alter cooldown")
        } catch {
        }
        let backedOffFetchCount = await broker.fetchCount
        XCTAssertEqual(backedOffFetchCount, 1)

        clock.advanceUptime(by: 61_000_000_000)
        let authorization = try await provider.authorization(for: alchemyURL)

        XCTAssertEqual(authorization?.token, replacement.token)
        let finalFetchCount = await broker.fetchCount
        XCTAssertEqual(finalFetchCount, 2)
    }

    func testRateLimitDeadlineAlsoSuppressesOpportunisticRefresh()
        async throws {
        let now: Int64 = 2_000_000_000
        let clock = TestClock(date: Date(timeIntervalSince1970: TimeInterval(now))
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now + 61,
            expiresAt: now + 21_661
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

        clock.advance(by: 61_000_000_000)
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
            issuedAt: now - 16_200,
            expiresAt: now + 5_400
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
            expiresAt: now + 21_590
        )
        let replacement = makeRecord(
            marker: "replacement",
            issuedAt: now,
            expiresAt: now + 21_600
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
        }
        do {
            _ = try await provider.replacementAuthorization(
                afterUnauthorized: original,
                for: alchemyURL
            )
            XCTFail("Expected the shared Retry-After deadline")
        } catch {
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
            expiresAt: now + 21_600
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
            expiresAt: 2_000_021_600
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
        let first = CrossProcessFileLock(fileURL: fileURL)
        let second = CrossProcessFileLock(fileURL: fileURL)

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
            expiresAt: now + 21_600
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-provider-lock-\(UUID().uuidString)",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = TestAlchemyJWTStore(record: nil)
        let firstFetchGate = TestAlchemyJWTBrokerFirstFetchGate()
        defer { firstFetchGate.release() }
        let broker = TestAlchemyJWTBroker(
            records: [record],
            firstFetchGate: firstFetchGate
        )
        let contended = expectation(description: "second real lock contended")
        contended.assertForOverFulfill = false
        let first = makeProvider(
            store: store,
            broker: broker,
            refreshLock: ObservedAlchemyJWTRefreshLock(CrossProcessFileLock(fileURL: fileURL)) { acquired in
                if !acquired { contended.fulfill() }
            },
            now: now
        )
        let second = makeProvider(
            store: store,
            broker: broker,
            refreshLock: ObservedAlchemyJWTRefreshLock(CrossProcessFileLock(fileURL: fileURL)) { acquired in
                if !acquired { contended.fulfill() }
            },
            now: now
        )

        async let firstAuthorization = first.authorization(for: alchemyURL)
        async let secondAuthorization = second.authorization(for: alchemyURL)
        await firstFetchGate.waitUntilStarted()
        await fulfillment(of: [contended], timeout: 2)
        firstFetchGate.release()
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

#if os(macOS)
    func testRealFileLockContendsWithChildProcessLockf() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "alchemy-jwt-child-lock-\(UUID().uuidString)",
                isDirectory: false
            )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let lock = CrossProcessFileLock(fileURL: fileURL)
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

    private func withProofKeyBundle(
        contents: Data?,
        body: (Bundle) throws -> Void
    ) throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier":
                    "org.lil.wallet.proof-tests.\(UUID().uuidString)",
                "CFBundleName": "Alchemy JWT Proof Fixture",
                "CFBundlePackageType": "BNDL",
            ],
            format: .xml,
            options: 0
        )
        try infoData.write(
            to: bundleURL.appendingPathComponent("Info.plist")
        )
        if let contents {
            try contents.write(
                to: bundleURL.appendingPathComponent(
                    AlchemyJWTRequestProofSigner.resourceName
                )
            )
        }

        try body(try XCTUnwrap(Bundle(url: bundleURL)))
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
        return AlchemyJWTProvider(
            tokenStore: store,
            broker: broker,
            refreshLock: refreshLock,
            now: { Date(timeIntervalSince1970: TimeInterval(now)) },
            uptimeNanoseconds: { DispatchTime.now().uptimeNanoseconds },
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

    private func makeProvider(
        store: AlchemyJWTStoring,
        broker: TestAlchemyJWTBroker,
        refreshLock: AlchemyJWTRefreshLocking = TestAlchemyJWTRefreshLock(),
        refreshLockTimeoutNanoseconds: UInt64 = 500_000_000,
        refreshLockPollNanoseconds: UInt64 = 25_000_000,
        persistenceRepairWindowNanoseconds: UInt64 = 0,
        persistenceRepairInitialDelayNanoseconds: UInt64 = 1,
        persistenceRepairMaximumDelayNanoseconds: UInt64 = 2,
        clock: TestClock,
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

    private func waitForSleeper(
        _ sleeper: TestAlchemyJWTProactiveSleeper,
        _ condition: @escaping @Sendable ([UInt64], Int) -> Bool
    ) async {
        let observed = expectation(description: "scheduled sleep checkpoint")
        await sleeper.observe(condition, expectation: observed)
        await fulfillment(of: [observed], timeout: 2)
    }

    private func waitForStoredRecord(_ record: AlchemyJWTRecord, in store: TestAlchemyJWTStore) async {
        await waitForStoredState(in: store) { $0.record == record }
    }

    private func waitForStoredState(
        in store: TestAlchemyJWTStore,
        matching predicate: @escaping @Sendable (AlchemyJWTPersistedState) -> Bool
    ) async {
        let saved = expectation(description: "token state persisted")
        saved.assertForOverFulfill = false
        store.onSave = { state in if predicate(state) { saved.fulfill() } }
        defer { store.onSave = nil }
        if let state = store.state, predicate(state) { saved.fulfill() }
        await fulfillment(of: [saved], timeout: 2)
    }



}

private enum TestBrokerError: Error {
    case unavailable
}


private final class BlockingSaveAlchemyJWTStore: Sendable, AlchemyJWTStoring {
    private struct GateState {
        var shouldBlockNextSave = false
        var didReleaseBlockedSave = false
    }
    let store: TestAlchemyJWTStore
    private let gate = Mutex(GateState())
    private let saveRelease = DispatchSemaphore(value: 0)
    private let saveStarted = XCTestExpectation(description: "synchronous save blocked")

    init(record: AlchemyJWTRecord?) {
        store = TestAlchemyJWTStore(record: record)
    }

    var record: AlchemyJWTRecord? {
        get { store.record }
        set { store.record = newValue }
    }

    var state: AlchemyJWTPersistedState? { store.state }

    func blockNextSave() {
        gate.withLock { $0 = GateState(shouldBlockNextSave: true) }
    }

    func waitUntilSaveIsBlocked(timeout: TimeInterval = 2) async -> Bool {
        await XCTWaiter.fulfillment(of: [saveStarted], timeout: timeout) == .completed
    }

    func releaseBlockedSave() {
        let shouldRelease = gate.withLock { state in
            guard !state.didReleaseBlockedSave else { return false }
            state.didReleaseBlockedSave = true
            return true
        }
        if shouldRelease { saveRelease.signal() }
    }

    func load() throws -> AlchemyJWTPersistedState? { try store.load() }

    func save(_ state: AlchemyJWTPersistedState) throws {
        let shouldBlock = gate.withLock { gate in
            guard gate.shouldBlockNextSave else { return false }
            gate.shouldBlockNextSave = false
            return true
        }
        if shouldBlock { saveStarted.fulfill(); saveRelease.wait() }
        try store.save(state)
    }
}

private final class TestAlchemyJWTStore: Sendable, AlchemyJWTStoring {
    private struct State {
        var persisted: AlchemyJWTPersistedState?
        var loads = 0
        var saves = 0
        var loadError: AlchemyJWTStorageError?
        var saveError: AlchemyJWTStorageError?
    }
    private let storage: Mutex<State>
    private let saveObserver = Mutex<(@Sendable (AlchemyJWTPersistedState) -> Void)?>(nil)
    var onSave: (@Sendable (AlchemyJWTPersistedState) -> Void)? {
        get { saveObserver.withLock { $0 } }
        set { saveObserver.withLock { $0 = newValue } }
    }

    init(
        record: AlchemyJWTRecord?,
        loadError: AlchemyJWTStorageError? = nil,
        saveError: AlchemyJWTStorageError? = nil
    ) {
        storage = Mutex(State(
            persisted: record.map { AlchemyJWTPersistedState(revision: 1, record: $0, tombstones: []) },
            loadError: loadError,
            saveError: saveError
        ))
    }

    var record: AlchemyJWTRecord? {
        get { storage.withLock { $0.persisted?.record } }
        set {
            storage.withLock { state in
                state.persisted = AlchemyJWTPersistedState(
                    revision: (state.persisted?.revision ?? 0) + 1,
                    record: newValue,
                    tombstones: state.persisted?.tombstones ?? []
                )
            }
        }
    }

    var state: AlchemyJWTPersistedState? { storage.withLock { $0.persisted } }
    func replaceState(_ state: AlchemyJWTPersistedState?) { storage.withLock { $0.persisted = state } }

    var loadError: AlchemyJWTStorageError? {
        get { storage.withLock { $0.loadError } }
        set { storage.withLock { $0.loadError = newValue } }
    }

    var saveError: AlchemyJWTStorageError? {
        get { storage.withLock { $0.saveError } }
        set { storage.withLock { $0.saveError = newValue } }
    }

    var loadCount: Int { storage.withLock { $0.loads } }
    var saveCount: Int { storage.withLock { $0.saves } }

    func load() throws -> AlchemyJWTPersistedState? {
        try storage.withLock { state in
            state.loads += 1
            if let error = state.loadError { throw error }
            return state.persisted
        }
    }

    func save(_ value: AlchemyJWTPersistedState) throws {
        try storage.withLock { state in
            if let error = state.saveError { throw error }
            state.persisted = value
            state.saves += 1
        }
        onSave?(value)
    }

    func resetCounts() {
        storage.withLock { $0.loads = 0; $0.saves = 0 }
    }
}

private final class TestEncodedAlchemyJWTStore: Sendable, AlchemyJWTStoring {
    private struct State {
        var data: Data
        var saves = 0
    }
    private let storage: Mutex<State>

    init(data: Data) { storage = Mutex(State(data: data)) }
    var state: AlchemyJWTPersistedState? {
        storage.withLock { AlchemyJWTPersistedState.decodePersistenceData($0.data) }
    }
    var saveCount: Int { storage.withLock { $0.saves } }

    func load() throws -> AlchemyJWTPersistedState? {
        try storage.withLock { value in
            guard let decoded = AlchemyJWTPersistedState.decodePersistenceData(value.data) else {
                throw AlchemyJWTStorageError.invalidData
            }
            return decoded
        }
    }

    func save(_ state: AlchemyJWTPersistedState) throws {
        let encoded = try JSONEncoder().encode(state)
        storage.withLock { $0.data = encoded; $0.saves += 1 }
    }
}

private final class ObservedAlchemyJWTRefreshLock: AlchemyJWTRefreshLocking {
    private let base: any AlchemyJWTRefreshLocking
    private let attempted: @Sendable (Bool) -> Void

    init(_ base: any AlchemyJWTRefreshLocking, attempted: @escaping @Sendable (Bool) -> Void) {
        self.base = base
        self.attempted = attempted
    }
    func tryAcquire() throws -> Bool {
        let acquired = try base.tryAcquire()
        attempted(acquired)
        return acquired
    }
    func release() { base.release() }
}

private final class TestAlchemyJWTRefreshLock: Sendable, AlchemyJWTRefreshLocking {
    private struct Counts {
        var acquisitions = 0
        var attempts = 0
    }
    private let semaphore: DispatchSemaphore
    private let counts = Mutex(Counts())
    private let releaseObserver = Mutex<(@Sendable () -> Void)?>(nil)
    var onRelease: (@Sendable () -> Void)? {
        get { releaseObserver.withLock { $0 } }
        set { releaseObserver.withLock { $0 = newValue } }
    }

    init(isAvailable: Bool = true) {
        semaphore = DispatchSemaphore(value: isAvailable ? 1 : 0)
    }

    var acquireCount: Int { counts.withLock { $0.acquisitions } }
    var attemptCount: Int { counts.withLock { $0.attempts } }

    func tryAcquire() throws -> Bool {
        counts.withLock { $0.attempts += 1 }
        guard semaphore.wait(timeout: .now()) == .success else { return false }
        counts.withLock { $0.acquisitions += 1 }
        return true
    }

    func release() {
        semaphore.signal()
        onRelease?()
    }
    func makeAvailable() { semaphore.signal() }
}

private final class BlockingFirstAlchemyJWTRefreshLock: Sendable, AlchemyJWTRefreshLocking {
    private let firstAttemptRelease = DispatchSemaphore(value: 0)
    private let firstAttemptStarted = XCTestExpectation(description: "first lock attempt entered")
    private let isFirstAttempt = Mutex(true)

    func tryAcquire() throws -> Bool {
        let shouldBlock = isFirstAttempt.withLock { value in
            defer { value = false }
            return value
        }
        if shouldBlock { firstAttemptStarted.fulfill(); firstAttemptRelease.wait() }
        return false
    }

    func release() {}

    func waitForFirstAttempt() async -> Bool {
        await XCTWaiter.fulfillment(of: [firstAttemptStarted], timeout: 2) == .completed
    }

    func unblockFirstAttempt() { firstAttemptRelease.signal() }
}

private final class TestAlchemyJWTSleeper: Sendable {
    private let recordedDurations = Mutex([UInt64]())
    var durations: [UInt64] { recordedDurations.withLock { $0 } }
    func sleep(_ nanoseconds: UInt64) async throws {
        recordedDurations.withLock { $0.append(nanoseconds) }
    }
}

private actor TestAlchemyJWTProactiveSleeper {
    private var nextIdentifier: UInt64 = 0
    private var requested = [UInt64]()
    private var pending = [UInt64: TestDeferred<Void>]()
    private var observers = [(condition: @Sendable ([UInt64], Int) -> Bool, XCTestExpectation)]()

    func sleep(_ nanoseconds: UInt64) async throws {
        nextIdentifier += 1
        let identifier = nextIdentifier
        let result = TestDeferred<Void>()
        requested.append(nanoseconds)
        pending[identifier] = result
        changed()
        defer { pending.removeValue(forKey: identifier); changed() }
        try await result.value()
    }
    func requestedDurations() -> [UInt64] { requested }
    func pendingCount() -> Int { pending.count }
    func resumeNext() {
        guard let identifier = pending.keys.min(), let result = pending.removeValue(forKey: identifier) else { return }
        result.resolve(.success(()))
        changed()
    }
    func observe(_ condition: @escaping @Sendable ([UInt64], Int) -> Bool, expectation: XCTestExpectation) {
        if condition(requested, pending.count) { expectation.fulfill() }
        else { observers.append((condition, expectation)) }
    }
    private func changed() {
        let ready = observers.filter { $0.condition(requested, pending.count) }
        observers.removeAll { $0.condition(requested, pending.count) }
        ready.forEach { $0.1.fulfill() }
    }
}

private actor TestAlchemyJWTBroker: AlchemyJWTBrokerFetching {

    private var records: [AlchemyJWTRecord]
    private var errors: [Error]
    private let firstFetchGate: TestAlchemyJWTBrokerFirstFetchGate?
    private let onFetch: (@Sendable (Int) -> Void)?
    private(set) var fetchCount = 0

    init(
        records: [AlchemyJWTRecord] = [],
        errors: [Error] = [],
        firstFetchGate: TestAlchemyJWTBrokerFirstFetchGate? = nil,
        onFetch: (@Sendable (Int) -> Void)? = nil
    ) {
        self.records = records
        self.errors = errors
        self.firstFetchGate = firstFetchGate
        self.onFetch = onFetch
    }

    func fetchToken() async throws -> AlchemyJWTRecord {
        fetchCount += 1
        onFetch?(fetchCount)
        if fetchCount == 1, let firstFetchGate {
            await firstFetchGate.pause()
        }
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
        guard !records.isEmpty else { throw TestBrokerError.unavailable }
        return records.removeFirst()
    }

}

private final class TestAlchemyJWTBrokerFirstFetchGate: Sendable {
    private let entered = XCTestExpectation(description: "broker fetch entered")
    private let released = TestGate<Void>()

    func pause() async {
        entered.fulfill()
        await released.wait()
    }
    func waitUntilStarted() async {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
    func release() { released.resolve(()) }
}


private actor TestAlchemyJWTSleepGate {
    private var gates = [TestGate<Void>]()
    private var maximumPending = 0
    private var waitingForRegistration = [XCTestExpectation]()

    func sleep() async throws {
        let gate = TestGate<Void>()
        gates.append(gate)
        maximumPending = max(maximumPending, gates.count)
        let observers = waitingForRegistration
        waitingForRegistration.removeAll()
        observers.forEach { $0.fulfill() }
        await gate.wait()
    }
    func observeRegistration(_ expectation: XCTestExpectation) {
        if gates.isEmpty { waitingForRegistration.append(expectation) }
        else { expectation.fulfill() }
    }
    func pendingCount() -> Int { gates.count }
    func maximumPendingCount() -> Int { maximumPending }
    func resumeAll() {
        let pending = gates
        gates.removeAll()
        pending.forEach { $0.resolve(()) }
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
