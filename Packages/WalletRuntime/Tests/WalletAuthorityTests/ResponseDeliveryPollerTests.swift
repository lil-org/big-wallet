import WalletDomain
import Foundation
import XCTest
@testable import WalletAuthority
@testable import WalletFlows
import WalletRuntimeTestSupport

@MainActor
final class ResponseDeliveryPollerTests: XCTestCase {
    private let modes: [ResponseMaintenance] = [.none, .quiet, .interactive]
    private nonisolated let configurationKey = "https://wallet.example"

    func testEachModeForwardsTheExactIdentityAndPreparesOnlyAfterReadiness() async {
        let expectedConfigurationKey = configurationKey
        let access = NativeRequestContext.ResponseAccess.document(.init(tabID: 7, frameID: 0,
            documentID: nil, documentSession: String(repeating: "a", count: 32)))
        for mode in modes {
            let handle = makeHandle()
            let expected = delivery(handle)
            let calls = LockedTestValue([String]())
            let poller = ResponseDeliveryPoller(
                authorize: { receivedHandle, key, receivedAccess in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("authorize") }
                    return .authorized
                },
                responseStatus: { receivedHandle, key, receivedAccess in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("status") }
                    return .ready
                },
                maintain: { receivedHandle, key, receivedMode, receivedAccess in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    XCTAssertEqual(receivedMode, mode)
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                    return .ready
                },
                prepareDelivery: { receivedHandle, key, receivedAccess in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("prepare") }
                    return .response(expected)
                }
            )

            let result = await poller.poll(
                handle: handle, configurationKey: configurationKey, maintenance: mode, access: access
            )

            assertResult(result, equals: .response(expected))
            XCTAssertEqual(calls.value, (mode == .none ? [] : ["authorize"]) + [statusCall(mode), "prepare"])
        }
    }

    func testNonreadyStatusesNeverPrepareDeliveryInAnyMode() async {
        let statuses: [(ExtensionBridge.ResponseStatusResult, ExtensionBridge.ResponseReadResult)] = [
            (.pending, .pending), (.missing, .missing), (.unavailable, .unavailable),
        ]
        for mode in modes {
            for (status, expected) in statuses {
                let calls = LockedTestValue([String]())
                let poller = ResponseDeliveryPoller(
                    authorize: { _, _, _ in .authorized },
                    responseStatus: { _, _, _ in
                        calls.withValue { $0.append("status") }
                        return status
                    },
                    maintain: { _, _, receivedMode, _ in
                        calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                        return status
                    },
                    prepareDelivery: { _, _, _ in
                        XCTFail("A nonready request must not prepare delivery")
                        return .unavailable
                    }
                )

                let result = await poller.poll(
                    handle: makeHandle(), configurationKey: configurationKey, maintenance: mode, access: .worker
                )

                assertResult(result, equals: expected)
                XCTAssertEqual(calls.value, [statusCall(mode)])
            }
        }
    }

    func testDocumentAccessIsCheckedBeforeEveryPollingSideEffect() async {
        let access = NativeRequestContext.ResponseAccess.document(.init(tabID: 7, frameID: 0,
            documentID: nil, documentSession: String(repeating: "a", count: 32)))
        for mode in modes {
            let calls = LockedTestValue([String]())
            let poller = ResponseDeliveryPoller(
                authorize: { _, _, receivedAccess in
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("authorize") }
                    return .missing
                },
                responseStatus: { _, _, receivedAccess in
                    XCTAssertEqual(receivedAccess, access)
                    calls.withValue { $0.append("status") }
                    return .missing
                },
                maintain: { _, _, _, _ in XCTFail("Unauthorized access must not maintain or launch approvals"); return .ready },
                prepareDelivery: { _, _, _ in XCTFail("Unauthorized access must not prepare delivery"); return .unavailable }
            )
            let result = await poller.poll(handle: makeHandle(), configurationKey: configurationKey,
                maintenance: mode, access: access)
            assertResult(result, equals: .missing)
            XCTAssertEqual(calls.value, [mode == .none ? "status" : "authorize"])
        }
    }

    func testPreparationCanDowngradeAnObservedReadyStatusInAnyMode() async {
        for mode in modes {
            for prepared in [ExtensionBridge.ResponseReadResult.pending, .missing, .unavailable] {
                let preparations = LockedTestValue(0)
                let poller = ResponseDeliveryPoller(
                    authorize: { _, _, _ in .authorized },
                    responseStatus: { _, _, _ in .ready },
                    maintain: { _, _, _, _ in .ready },
                    prepareDelivery: { _, _, _ in
                        preparations.withValue { $0 += 1 }
                        return prepared
                    }
                )

                let result = await poller.poll(
                    handle: makeHandle(), configurationKey: configurationKey, maintenance: mode, access: .worker
                )

                assertResult(result, equals: prepared)
                XCTAssertEqual(preparations.value, 1)
            }
        }
    }

    func testCancellationBeforePollingDoesNotStartAnyOperation() async {
        for mode in modes {
            let gate = TestGate<Void>()
            let poller = ResponseDeliveryPoller(
                authorize: { _, _, _ in .authorized },
                responseStatus: { _, _, _ in
                    XCTFail("Canceled polling must not read status")
                    return .ready
                },
                maintain: { _, _, _, _ in
                    XCTFail("Canceled polling must not maintain requests")
                    return .ready
                },
                prepareDelivery: { _, _, _ in
                    XCTFail("Canceled polling must not prepare delivery")
                    return .pending
                }
            )
            var result: ExtensionBridge.ResponseReadResult?
            let task = Task { @MainActor in
                await gate.wait()
                result = await poller.poll(
                    handle: self.makeHandle(), configurationKey: self.configurationKey, maintenance: mode, access: .worker
                )
            }
            task.cancel()
            gate.resolve(())
            await task.value

            guard let result else { return XCTFail("Expected canceled poll result") }
            assertResult(result, equals: .unavailable)
        }
    }

    func testCancellationDuringStatusOrMaintenanceDiscardsItsResultAndSkipsPreparation() async {
        for mode in modes {
            for status in [ExtensionBridge.ResponseStatusResult.ready, .pending, .missing] {
                let started = expectation(description: "status operation started")
                let gate = TestGate<Void>()
                let calls = LockedTestValue([String]())
                let poller = ResponseDeliveryPoller(
                    authorize: { _, _, _ in .authorized },
                    responseStatus: { _, _, _ in
                        calls.withValue { $0.append("status") }
                        started.fulfill()
                        await gate.wait()
                        return status
                    },
                    maintain: { _, _, receivedMode, _ in
                        calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                        started.fulfill()
                        await gate.wait()
                        return status
                    },
                    prepareDelivery: { _, _, _ in
                        XCTFail("Cancellation must prevent subsequent preparation")
                        return .pending
                    }
                )
                var result: ExtensionBridge.ResponseReadResult?
                let task = Task { @MainActor in
                    result = await poller.poll(
                        handle: self.makeHandle(), configurationKey: self.configurationKey, maintenance: mode, access: .worker
                    )
                }
                await fulfillment(of: [started], timeout: 1)
                task.cancel()
                gate.resolve(())
                await task.value

                guard let result else { return XCTFail("Expected canceled poll result") }
                assertResult(result, equals: .unavailable)
                XCTAssertEqual(calls.value, [statusCall(mode)])
            }
        }
    }

    func testCancellationDuringPreparationDiscardsTheLateDelivery() async {
        for mode in modes {
            let handle = makeHandle()
            let expected = delivery(handle)
            let started = expectation(description: "delivery preparation started")
            let gate = TestGate<Void>()
            let preparations = LockedTestValue(0)
            let poller = ResponseDeliveryPoller(
                authorize: { _, _, _ in .authorized },
                responseStatus: { _, _, _ in .ready },
                maintain: { _, _, _, _ in .ready },
                prepareDelivery: { _, _, _ in
                    preparations.withValue { $0 += 1 }
                    started.fulfill()
                    await gate.wait()
                    return .response(expected)
                }
            )
            var result: ExtensionBridge.ResponseReadResult?
            let task = Task { @MainActor in
                result = await poller.poll(
                    handle: handle, configurationKey: self.configurationKey, maintenance: mode, access: .worker
                )
            }
            await fulfillment(of: [started], timeout: 1)
            task.cancel()
            gate.resolve(())
            await task.value

            guard let result else { return XCTFail("Expected canceled poll result") }
            assertResult(result, equals: .unavailable)
            XCTAssertEqual(preparations.value, 1)
        }
    }

    func testPendingPollDoesNotRecoverExpiredStorageOrWriteOrSynchronize() async throws {
        let now = LockedTestValue(Date(timeIntervalSince1970: 1_800_000_000))
        let reads = LockedTestValue([URL]())
        let writes = LockedTestValue(0)
        let synchronizations = LockedTestValue(0)
        let (root, store) = try makeStore(clock: { now.value }) { io in
            let baseIO = io
            io.readSnapshot = { url, maximumBytes in
                reads.withValue { $0.append(url) }
                return baseIO.readSnapshot(url, maximumBytes)
            }
            io.replace = { data, url in
                writes.withValue { $0 += 1 }
                try baseIO.replace(data, url)
            }
            io.synchronizePublishedFile = { url in
                synchronizations.withValue { $0 += 1 }
                try baseIO.synchronizePublishedFile(url)
            }
        }
        let handle = try enqueue(store: store, now: now.value)
        now.withValue { $0.addTimeInterval(151) }
        let profileURL = root.appendingPathComponent("profiles-v9/default.state")
        let originalData = try Data(contentsOf: profileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        reads.value = []
        writes.value = 0
        synchronizations.value = 0
        let poller = storePoller(store)

        let result = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none, access: .worker
        )

        assertResult(result, equals: .pending)
        XCTAssertEqual(reads.value, [profileURL])
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(synchronizations.value, 0)
        XCTAssertEqual(try Data(contentsOf: profileURL), originalData)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), originalPaths)
    }

    func testCompletedPollRequiresDurabilityAndLeavesAcknowledgementExplicit() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failSynchronization = LockedTestValue(false)
        let synchronizations = LockedTestValue(0)
        let (_, store) = try makeStore(clock: { now }) { io in
            let baseIO = io
            io.synchronizePublishedFile = { url in
                synchronizations.withValue { $0 += 1 }
                if failSynchronization.value { throw CocoaError(.fileWriteUnknown) }
                try baseIO.synchronizePublishedFile(url)
            }
        }
        let handle = try enqueue(store: store, now: now)
        XCTAssertEqual(store.completeImmediate(handle: handle, resolution: .failure(.userRejected)), .persisted)
        let poller = storePoller(store)
        synchronizations.value = 0
        failSynchronization.value = true

        let unavailable = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none, access: .worker
        )

        assertResult(unavailable, equals: .unavailable)
        XCTAssertEqual(synchronizations.value, 1)
        failSynchronization.value = false
        let delivered = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none, access: .worker
        )
        guard case .response(let response) = delivered else { return XCTFail("Expected durable response") }
        XCTAssertEqual(synchronizations.value, 2)
        XCTAssertEqual((response["response"] as? [String: Any])?["kind"] as? String, "error")
        guard case .available(let unacknowledged) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected response listing")
        }
        XCTAssertNotNil(unacknowledged[handle])

        XCTAssertEqual(store.acknowledgeResponse(handle: handle, configurationKey: configurationKey, access: .worker), .persisted)
        guard case .available(let acknowledged) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected acknowledged response listing")
        }
        XCTAssertNil(acknowledged[handle])
        let replay = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none, access: .worker
        )
        assertResult(replay, equals: delivered)
    }

    func testCompletedDocumentOwnerSurvivesRestartAcknowledgementAndPermissionRepair() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (root, store) = try makeStore(clock: { now })
        let handle = try enqueue(store: store, now: now)
        XCTAssertEqual(store.completeImmediate(handle: handle, resolution: .failure(.userRejected)), .persisted)
        let profileURL = root.appendingPathComponent("profiles-v9/default.state")
        var profile = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: profileURL), format: nil
        ) as? [String: Any])
        profile["origins"] = "corrupt permissions"
        let damaged = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
        try damaged.write(to: profileURL)
        let restarted = ExtensionRequestFileStore(rootURL: root, directoryBoundary: root, dependencies: .init(clock: { now }))
        guard case .document(let document) = testDocumentResponseOwner else { return XCTFail("Expected document fixture") }
        let original = NativeRequestContext.ResponseAccess.document(document)
        let foreign = NativeRequestContext.ResponseAccess.document(.init(tabID: document.tabID, frameID: 0,
            documentID: document.documentID, documentSession: String(repeating: "f", count: 32)))
        XCTAssertEqual(restarted.authorizeResponseAccess(handle: handle, configurationKey: configurationKey, access: foreign), .missing)
        assertResult(restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: foreign), equals: .missing)
        XCTAssertEqual(restarted.acknowledgeResponse(handle: handle, configurationKey: configurationKey, access: foreign), .ownershipLost)
        XCTAssertEqual(try Data(contentsOf: profileURL), damaged)
        XCTAssertEqual(restarted.authorizeResponseAccess(handle: handle, configurationKey: configurationKey, access: original), .authorized)
        XCTAssertEqual(try Data(contentsOf: profileURL), damaged)
        let delivered = restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: original)
        guard case .response = delivered else { return XCTFail("Matching owner must still repair permissions and receive completion") }
        XCTAssertNotEqual(try Data(contentsOf: profileURL), damaged)
        XCTAssertEqual(restarted.acknowledgeResponse(handle: handle, configurationKey: configurationKey, access: original), .persisted)
        assertResult(restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: original), equals: delivered)
        assertResult(restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: foreign), equals: .missing)
        for access in [NativeRequestContext.ResponseAccess.worker, .popup] {
            assertResult(restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: access), equals: delivered)
        }
    }

    func testForeignDocumentReplayDoesNotRecoverExpiredRequests() throws {
        let now = LockedTestValue(Date(timeIntervalSince1970: 1_800_000_000))
        let (root, store) = try makeStore(clock: { now.value })
        let ingress = try makeIngress(store: store, now: now.value)
        guard case .accepted = store.enqueue(ingress: ingress, profileIdentifier: nil) else { return XCTFail("Expected admission") }
        now.withValue { $0.addTimeInterval(151) }
        let profileURL = root.appendingPathComponent("profiles-v9/default.state")
        let before = try Data(contentsOf: profileURL)
        let foreign = ExtensionBridge.Ingress(request: ingress.request, canonicalData: ingress.canonicalData,
            fingerprint: ingress.fingerprint, authority: ingress.authority, replayOnly: ingress.replayOnly,
            responseOwner: .document(.init(tabID: 1, frameID: 0, documentID: nil, documentSession: String(repeating: "f", count: 32))))
        guard case .rejected = store.enqueue(ingress: foreign, profileIdentifier: nil) else { return XCTFail("Foreign replay must be rejected") }
        XCTAssertEqual(try Data(contentsOf: profileURL), before)
    }

    func testMissingResponseOwnerCannotBecomeTrustedDuringRecovery() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (root, store) = try makeStore(clock: { now })
        let handle = try enqueue(store: store, now: now)
        XCTAssertEqual(store.completeImmediate(handle: handle, resolution: .failure(.userRejected)), .persisted)
        let profileURL = root.appendingPathComponent("profiles-v9/default.state")
        var profile = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: profileURL), format: nil
        ) as? [String: Any])
        var records = try XCTUnwrap(profile["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "responseOwner")
        profile["records"] = records
        let damaged = try PropertyListSerialization.data(fromPropertyList: profile, format: .binary, options: 0)
        try damaged.write(to: profileURL)
        let restarted = ExtensionRequestFileStore(rootURL: root, directoryBoundary: root, dependencies: .init(clock: { now }))
        XCTAssertEqual(restarted.authorizeResponseAccess(handle: handle, configurationKey: configurationKey, access: .worker), .unavailable)
        assertResult(restarted.prepareResponseDelivery(handle: handle, configurationKey: configurationKey, access: .worker), equals: .unavailable)
        XCTAssertEqual(restarted.acknowledgeResponse(handle: handle, configurationKey: configurationKey, access: .worker), .retryablePersistenceFailure)
        XCTAssertEqual(try Data(contentsOf: profileURL), damaged)
    }

    func testRevocationBetweenReadinessAndPreparationReturnsFreshAuthorityWithoutRestoringGrant() async throws {
        let fixture = try ApprovedExecutionTestFixture()
        let account = WalletAccountDescriptor(
            walletID: "poll-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let network = try XCTUnwrap(AuthorityTestNetworks.ethereum)
        let snapshot = try fixture.enqueue(
            id: 42, name: "requestAccounts", provider: .ethereum,
            body: ["address": "", "chainId": "0x1"], configurationKey: configurationKey
        )
        let permit = try fixture.authorize(
            snapshot: snapshot,
            action: .selectAccount(.init(
                coinType: .ethereum, selectedAccounts: [], initiallyConnectedProviders: [], network: network
            )),
            decision: .accountSelection(.init(accounts: [account], ethereumChainID: "0x1")),
            accounts: [account.specificAccount]
        )
        XCTAssertTrue(permit.consumeExecution())
        let completion = try XCTUnwrap(ApprovedCompletion.accountSelection(permit: permit, fallbackNetwork: { network }))
        XCTAssertEqual(fixture.store.complete(permit: permit, result: completion), .persisted)
        let revokedRevision = LockedTestValue<Int?>(nil)
        let poller = ResponseDeliveryPoller(
            authorize: { fixture.store.authorizeResponseAccess(handle: $0, configurationKey: $1, access: $2) },
            responseStatus: { handle, key, _ in
                let status = fixture.store.responseStatus(handle: handle, configurationKey: key, access: .worker)
                XCTAssertEqual(status, .ready)
                guard case .snapshot(let current) = fixture.store.configurationSnapshot(
                    configurationKey: key, profileIdentifier: handle.profileIdentifier
                ), case .revoked(let revoked) = fixture.store.revoke(
                    configurationKey: key, provider: .ethereum,
                    attempt: String(repeating: "c", count: 32), expected: current.version,
                    profileIdentifier: handle.profileIdentifier
                ) else {
                    XCTFail("Expected revocation between status and preparation")
                    return .unavailable
                }
                revokedRevision.value = revoked.version.revisions.ethereum
                return status
            },
            maintain: { _, _, _, _ in
                XCTFail("Ordinary polling must not maintain requests")
                return .unavailable
            },
            prepareDelivery: { handle, key, _ in
                fixture.store.prepareResponseDelivery(handle: handle, configurationKey: key, access: .worker)
            }
        )

        let result = await poller.poll(
            handle: snapshot.handle, configurationKey: configurationKey, maintenance: .none, access: .worker
        )

        guard case .response(let envelope) = result else { return XCTFail("Expected completed grant response") }
        let response = try XCTUnwrap(envelope["response"] as? [String: Any])
        let state = try XCTUnwrap(envelope["state"] as? [String: Any])
        XCTAssertEqual(response["result"] as? [String], [account.normalizedAddress])
        XCTAssertEqual(response["approvalCommitted"] as? Bool, true)
        XCTAssertEqual((state["ethereum"] as? [String: String])?["address"], "")
        XCTAssertEqual((state["revisions"] as? [String: Int])?["ethereum"], revokedRevision.value)
        guard case .snapshot(let current) = fixture.store.configurationSnapshot(
            configurationKey: configurationKey, profileIdentifier: nil
        ) else { return XCTFail("Expected current authority") }
        XCTAssertNil(current.ethereumAccount)
        XCTAssertEqual(current.version.revisions.ethereum, revokedRevision.value)
    }

    private func makeHandle() -> RequestHandle {
        .init(id: 42, token: .init(value: UUID()), profileIdentifier: UUID())
    }

    private func statusCall(_ mode: ResponseMaintenance) -> String {
        mode == .none ? "status" : "maintain:\(mode.rawValue)"
    }

    private func delivery(_ handle: RequestHandle) -> WireProtocol.JSONObject {
        WireProtocol.JSONObject([
            "id": handle.id,
            "response": ["id": handle.id, "result": ["signed"], "approvalCommitted": true],
            "state": ["context": String(repeating: "a", count: 64), "revisions": ["ethereum": 3, "solana": 2]],
        ])!
    }

    private func assertResult(
        _ actual: ExtensionBridge.ResponseReadResult,
        equals expected: ExtensionBridge.ResponseReadResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.pending, .pending), (.missing, .missing), (.unavailable, .unavailable):
            break
        case (.response(let actual), .response(let expected)):
            XCTAssertEqual(actual.json as NSDictionary, expected.json as NSDictionary, file: file, line: line)
        default:
            XCTFail("Unexpected poll result", file: file, line: line)
        }
    }

    private func makeStore(
        clock: @escaping @Sendable () -> Date,
        configureIO: (inout ExtensionRequestStoreFiles.IO) -> Void = { _ in }
    ) throws -> (URL, ExtensionRequestFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "response-poll-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (
            root,
            ExtensionRequestFileStore(
                rootURL: root, directoryBoundary: root,
                dependencies: .init(
                    clock: clock, fileIO: approvalStoreIO(directoryBoundary: root, configure: configureIO)
                ))
        )
    }

    private func enqueue(store: ExtensionRequestFileStore, now: Date) throws -> RequestHandle {
        let ingress = try makeIngress(store: store, now: now)
        guard case .accepted(let handle, _, _, _, _) = store.enqueue(ingress: ingress, profileIdentifier: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return handle
    }

    private func makeIngress(store: ExtensionRequestFileStore, now: Date) throws -> ExtensionBridge.Ingress {
        guard case .snapshot(let authority) = store.configurationSnapshot(
            configurationKey: configurationKey, profileIdentifier: nil
        ) else { throw CocoaError(.fileReadUnknown) }
        let raw: [String: Any] = [
            "id": 42, "name": "requestAccounts", "provider": "ethereum",
            "body": ["address": "", "chainId": "0x1"], "host": "wallet.example",
            "configurationKey": configurationKey, "workflowVersion": ExtensionBridge.workflowVersion,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(now.addingTimeInterval(150).timeIntervalSince1970 * 1_000),
            "authority": authority.version.json,
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw, responseOwner: testDocumentResponseOwner) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return ingress
    }

    private func storePoller(_ store: ExtensionRequestFileStore) -> ResponseDeliveryPoller {
        ResponseDeliveryPoller(
            authorize: { store.authorizeResponseAccess(handle: $0, configurationKey: $1, access: $2) },
            responseStatus: { store.responseStatus(handle: $0, configurationKey: $1, access: $2) },
            maintain: { _, _, _, _ in
                XCTFail("Ordinary polling must not maintain requests")
                return .unavailable
            },
            prepareDelivery: { store.prepareResponseDelivery(handle: $0, configurationKey: $1, access: $2) }
        )
    }
}
