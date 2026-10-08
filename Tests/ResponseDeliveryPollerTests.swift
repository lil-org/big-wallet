import Foundation
import XCTest
@testable import Big_Wallet

@MainActor
final class ResponseDeliveryPollerTests: XCTestCase {
    private let modes: [ResponseDeliveryPoller.Maintenance] = [.none, .quiet, .interactive]
    private nonisolated let configurationKey = "https://wallet.example"

    func testEachModeForwardsTheExactIdentityAndPreparesOnlyAfterReadiness() async {
        let expectedConfigurationKey = configurationKey
        for mode in modes {
            let handle = makeHandle()
            let expected = delivery(handle)
            let calls = LockedTestValue([String]())
            let poller = ResponseDeliveryPoller(
                responseStatus: { receivedHandle, key in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    calls.withValue { $0.append("status") }
                    return .ready
                },
                maintain: { receivedHandle, key, receivedMode in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    XCTAssertEqual(receivedMode, mode)
                    calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                    return .ready
                },
                prepareDelivery: { receivedHandle, key in
                    XCTAssertEqual(receivedHandle, handle)
                    XCTAssertEqual(key, expectedConfigurationKey)
                    calls.withValue { $0.append("prepare") }
                    return .response(expected)
                }
            )

            let result = await poller.poll(
                handle: handle, configurationKey: configurationKey, maintenance: mode
            )

            assertResult(result, equals: .response(expected))
            XCTAssertEqual(calls.value, [statusCall(mode), "prepare"])
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
                    responseStatus: { _, _ in
                        calls.withValue { $0.append("status") }
                        return status
                    },
                    maintain: { _, _, receivedMode in
                        calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                        return status
                    },
                    prepareDelivery: { _, _ in
                        XCTFail("A nonready request must not prepare delivery")
                        return .unavailable
                    }
                )

                let result = await poller.poll(
                    handle: makeHandle(), configurationKey: configurationKey, maintenance: mode
                )

                assertResult(result, equals: expected)
                XCTAssertEqual(calls.value, [statusCall(mode)])
            }
        }
    }

    func testPreparationCanDowngradeAnObservedReadyStatusInAnyMode() async {
        for mode in modes {
            for prepared in [ExtensionBridge.ResponseReadResult.pending, .missing, .unavailable] {
                let preparations = LockedTestValue(0)
                let poller = ResponseDeliveryPoller(
                    responseStatus: { _, _ in .ready },
                    maintain: { _, _, _ in .ready },
                    prepareDelivery: { _, _ in
                        preparations.withValue { $0 += 1 }
                        return prepared
                    }
                )

                let result = await poller.poll(
                    handle: makeHandle(), configurationKey: configurationKey, maintenance: mode
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
                responseStatus: { _, _ in
                    XCTFail("Canceled polling must not read status")
                    return .ready
                },
                maintain: { _, _, _ in
                    XCTFail("Canceled polling must not maintain requests")
                    return .ready
                },
                prepareDelivery: { _, _ in
                    XCTFail("Canceled polling must not prepare delivery")
                    return .pending
                }
            )
            var result: ExtensionBridge.ResponseReadResult?
            let task = Task { @MainActor in
                await gate.wait()
                result = await poller.poll(
                    handle: self.makeHandle(), configurationKey: self.configurationKey, maintenance: mode
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
                    responseStatus: { _, _ in
                        calls.withValue { $0.append("status") }
                        started.fulfill()
                        await gate.wait()
                        return status
                    },
                    maintain: { _, _, receivedMode in
                        calls.withValue { $0.append("maintain:\(receivedMode.rawValue)") }
                        started.fulfill()
                        await gate.wait()
                        return status
                    },
                    prepareDelivery: { _, _ in
                        XCTFail("Cancellation must prevent subsequent preparation")
                        return .pending
                    }
                )
                var result: ExtensionBridge.ResponseReadResult?
                let task = Task { @MainActor in
                    result = await poller.poll(
                        handle: self.makeHandle(), configurationKey: self.configurationKey, maintenance: mode
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
                responseStatus: { _, _ in .ready },
                maintain: { _, _, _ in .ready },
                prepareDelivery: { _, _ in
                    preparations.withValue { $0 += 1 }
                    started.fulfill()
                    await gate.wait()
                    return .response(expected)
                }
            )
            var result: ExtensionBridge.ResponseReadResult?
            let task = Task { @MainActor in
                result = await poller.poll(
                    handle: handle, configurationKey: self.configurationKey, maintenance: mode
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
        let writes = LockedTestValue(0)
        let synchronizations = LockedTestValue(0)
        let (root, store) = try makeStore(dependencies: .init(
            clock: { now.value },
            atomicWrite: { data, url in
                writes.withValue { $0 += 1 }
                try ApprovalStoreTestPersistence.write(data, url)
            },
            synchronizePublishedFile: { url in
                synchronizations.withValue { $0 += 1 }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        ))
        let handle = try enqueue(store: store, now: now.value)
        now.withValue { $0.addTimeInterval(151) }
        let profileURL = root.appendingPathComponent("profiles-v9/default.state")
        let originalData = try Data(contentsOf: profileURL)
        let originalPaths = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        writes.value = 0
        synchronizations.value = 0
        let poller = storePoller(store)

        let result = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none
        )

        assertResult(result, equals: .pending)
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(synchronizations.value, 0)
        XCTAssertEqual(try Data(contentsOf: profileURL), originalData)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), originalPaths)
    }

    func testCompletedPollRequiresDurabilityAndLeavesAcknowledgementExplicit() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failSynchronization = LockedTestValue(false)
        let synchronizations = LockedTestValue(0)
        let (_, store) = try makeStore(dependencies: .init(
            clock: { now },
            atomicWrite: ApprovalStoreTestPersistence.write,
            synchronizePublishedFile: { url in
                synchronizations.withValue { $0 += 1 }
                if failSynchronization.value { throw CocoaError(.fileWriteUnknown) }
                try ApprovalStoreTestPersistence.synchronize(url)
            }
        ))
        let handle = try enqueue(store: store, now: now)
        XCTAssertEqual(store.completeImmediate(handle: handle, resolution: .failure(.userRejected)), .persisted)
        let poller = storePoller(store)
        synchronizations.value = 0
        failSynchronization.value = true

        let unavailable = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none
        )

        assertResult(unavailable, equals: .unavailable)
        XCTAssertEqual(synchronizations.value, 1)
        failSynchronization.value = false
        let delivered = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none
        )
        guard case .response(let response) = delivered else { return XCTFail("Expected durable response") }
        XCTAssertEqual(synchronizations.value, 2)
        XCTAssertEqual((response["response"] as? [String: Any])?["kind"] as? String, "error")
        guard case .available(let unacknowledged) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected response listing")
        }
        XCTAssertNotNil(unacknowledged[handle])

        XCTAssertEqual(store.acknowledgeResponse(handle: handle, configurationKey: configurationKey), .persisted)
        guard case .available(let acknowledged) = store.list(profileIdentifier: nil) else {
            return XCTFail("Expected acknowledged response listing")
        }
        XCTAssertNil(acknowledged[handle])
        let replay = await poller.poll(
            handle: handle, configurationKey: configurationKey, maintenance: .none
        )
        assertResult(replay, equals: delivered)
    }

    func testRevocationBetweenReadinessAndPreparationReturnsFreshAuthorityWithoutRestoringGrant() async throws {
        let fixture = try ApprovedExecutionTestFixture()
        let account = WalletAccountDescriptor(
            walletID: "poll-wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.sequentialEthereumAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        let network = try XCTUnwrap(Networks.ethereum)
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
        let completion = try XCTUnwrap(ApprovedCompletion.accountSelection(permit: permit))
        XCTAssertEqual(fixture.store.complete(permit: permit, result: completion), .persisted)
        let revokedRevision = LockedTestValue<Int?>(nil)
        let poller = ResponseDeliveryPoller(
            responseStatus: { handle, key in
                let status = fixture.store.responseStatus(handle: handle, configurationKey: key)
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
            maintain: { _, _, _ in
                XCTFail("Ordinary polling must not maintain requests")
                return .unavailable
            },
            prepareDelivery: { handle, key in
                fixture.store.prepareResponseDelivery(handle: handle, configurationKey: key)
            }
        )

        let result = await poller.poll(
            handle: snapshot.handle, configurationKey: configurationKey, maintenance: .none
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

    private func makeHandle() -> ExtensionBridge.Handle {
        .init(id: 42, token: .init(value: UUID()), profileIdentifier: UUID())
    }

    private func statusCall(_ mode: ResponseDeliveryPoller.Maintenance) -> String {
        mode == .none ? "status" : "maintain:\(mode.rawValue)"
    }

    private func delivery(_ handle: ExtensionBridge.Handle) -> WireProtocol.JSONObject {
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
        dependencies: ExtensionRequestFileStore.Dependencies
    ) throws -> (URL, ExtensionRequestFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "response-poll-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, ExtensionRequestFileStore(rootURL: root, directoryBoundary: root, dependencies: dependencies))
    }

    private func enqueue(store: ExtensionRequestFileStore, now: Date) throws -> ExtensionBridge.Handle {
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
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(request: request, rawObject: raw),
              case .accepted(let handle, _, _, _, _) = store.enqueue(ingress: ingress, profileIdentifier: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return handle
    }

    private func storePoller(_ store: ExtensionRequestFileStore) -> ResponseDeliveryPoller {
        ResponseDeliveryPoller(
            responseStatus: { store.responseStatus(handle: $0, configurationKey: $1) },
            maintain: { _, _, _ in
                XCTFail("Ordinary polling must not maintain requests")
                return .unavailable
            },
            prepareDelivery: { store.prepareResponseDelivery(handle: $0, configurationKey: $1) }
        )
    }
}
