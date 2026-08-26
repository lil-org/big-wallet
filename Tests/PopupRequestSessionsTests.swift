// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private let popupRequestAdmissionDeadline = 2_000_000_900_000

private enum PopupRequestSessionsTestError: Error {
    case timedOut
}

@MainActor
final class PopupRequestSessionsTests: XCTestCase {

    func testSessionUsesFourDisposablePhasesAndOneReviewToken() throws {
        let session = try makeSession()
        let initialToken = session.reviewToken

        let token = try XCTUnwrap(session.beginApproval())
        XCTAssertEqual(session.state, .working)
        XCTAssertNotEqual(token, initialToken)

        let claim = ExtensionBridge.ApprovalClaim(
            handle: session.handle,
            value: UUID()
        )
        XCTAssertTrue(session.acceptClaim(claim, token: token))
        XCTAssertTrue(session.beginAuthentication(claim: claim, token: token))
        XCTAssertEqual(session.state, .authenticating)
        XCTAssertTrue(session.finishAuthentication(claim: claim, token: token))
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.returnToReview(token: token))
        XCTAssertEqual(session.state, .review)

        session.fail("Unavailable")
        XCTAssertEqual(session.state, .error)
        session.retry()
        XCTAssertEqual(session.state, .review)
        XCTAssertNotEqual(session.reviewToken, token)
    }

    func testStaleReviewTokenCannotMutateSession() throws {
        let session = try makeSession()
        let token = try XCTUnwrap(session.beginApproval())
        let stale = UUID()
        let claim = ExtensionBridge.ApprovalClaim(
            handle: session.handle,
            value: UUID()
        )

        XCTAssertFalse(session.acceptClaim(claim, token: stale))
        XCTAssertTrue(session.acceptClaim(claim, token: token))
        XCTAssertFalse(session.beginAuthentication(claim: claim, token: stale))
        session.fail("stale", token: stale)
        XCTAssertEqual(session.state, .working)
    }

    func testMaterialReviewChangesRotateTheSingleReviewToken() throws {
        let session = try makeSession()
        let first = session.reviewToken
        let firstRevision = session.presentationRevision
        session.rotateReviewToken()
        XCTAssertNotEqual(session.reviewToken, first)
        XCTAssertEqual(session.presentationRevision, firstRevision + 1)

        let active = try XCTUnwrap(session.beginApproval())
        session.rotateReviewToken()
        XCTAssertEqual(session.reviewToken, active)
        XCTAssertEqual(session.presentationRevision, firstRevision + 2)
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertTrue(source.contains("case .snapshot, .verifiedFeeEstimate, .editorRequest:"))
        XCTAssertTrue(source.contains("case .alert:"))
    }

    func testNativeControllerHasNoDurableCoordinatorOrRetryEngine() throws {
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertFalse(source.contains("PopupDurableApprovalCoordinator"))
        XCTAssertFalse(source.contains("DeferredReply"))
        XCTAssertFalse(source.contains("watchdog"))
        XCTAssertFalse(source.contains("retryScheduler"))
    }

    func testTransactionBroadcastIsCheckpointedBeforeSend() throws {
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        let checkpoint = try XCTUnwrap(source.range(of: "store.prepareBroadcast"))
        let send = try XCTUnwrap(source.range(of: "prepared.send()"))
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: checkpoint.lowerBound),
            source.distance(from: source.startIndex, to: send.lowerBound)
        )
    }

    func testExtensionHandlerAwaitsPopupDispatchBeforeResponding() throws {
        let source = try source(named: "Safari Shared/SafariWebExtensionHandler.swift")
        XCTAssertTrue(source.contains("response = await PopupRequestSessions.dispatch("))
        XCTAssertTrue(source.contains("response = await PopupRequestSessions.dispatchPrivateBrowsing("))
    }

    func testCancelledTransactionSpeedLeavesFeeAndSelectionUnchanged() throws {
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        let network = EthereumNetwork(
            chainId: EthereumNetwork.ethMainnetChainId,
            name: "Ethereum",
            symbol: "ETH",
            rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
            isTestnet: false,
            mightShowPrice: true,
            explorer: nil
        )
        let action = SendTransactionAction(
            transaction: transaction,
            resolvedNetwork: ResolvedEthereumNetwork(
                network: network,
                source: .custom
            ),
            walletId: "wallet",
            account: popupTestAccount(),
            resolve: { _ -> DappExecutionResult in fatalError() }
        )
        var preparationCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { _, _, _, _, _, _ in
                preparationCount += 1
                return EthereumRequestCancellation()
            },
            preflight: { _, _, _ in EthereumRequestCancellation() }
        )
        let session = PopupTransactionSession(
            action: action,
            operations: operations
        )
        session.start()
        let fee = session.snapshot.transaction.preparedFee
        let position = session.gasSliderPosition(for: session.snapshot.transaction)
        let payloadData = try JSONSerialization.data(withJSONObject: [
            "interaction": "cancelled",
            "value": 200,
        ])
        let payload = try JSONDecoder().decode(
            InternalSafariRequest.TransactionSpeedPayload.self,
            from: payloadData
        )

        session.setSpeed(payload)

        XCTAssertEqual(session.snapshot.transaction.preparedFee, fee)
        XCTAssertEqual(
            session.gasSliderPosition(for: session.snapshot.transaction),
            position
        )
        XCTAssertEqual(preparationCount, 1)
    }

    func testQueueSortingRemainsFIFO() throws {
        let source = try source(named: "Safari Shared/PopupRequestSessions.swift")
        XCTAssertTrue(source.contains("$0.sequence < $1.sequence"))
    }

    private func makeSession() throws -> PopupRequestSession {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": 42,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "wallet.example",
            "configurationKey": "wallet.example",
            "enqueueAttempt": String(repeating: "a", count: 32),
            "admissionDeadline": popupRequestAdmissionDeadline,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["latestConfigurations": []],
        ])
        let request = try XCTUnwrap(SafariRequest(data: data))
        let handle = ExtensionBridge.Handle(
            id: request.id,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
        return PopupRequestSession(
            handle: handle,
            request: request,
            purpose: .immediateResponsePersistence
        )
    }

    private func source(named relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}

@MainActor
extension PopupRequestSessionsTests {

    func testPendingResponseIsFIFO() async throws {
        let store = CompactPopupStore()
        let receivedAt = Date(timeIntervalSince1970: 1)
        let first = try popupSnapshot(
            id: 1,
            createdAt: receivedAt,
            provider: .ethereum
        )
        let second = try popupSnapshot(id: 2, createdAt: receivedAt)
        await store.insert(second)
        await store.insert(first)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(response["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertEqual(
            requests.compactMap { $0["configurationKey"] as? String },
            ["wallet.example", "wallet.example"]
        )
        XCTAssertEqual(
            requests.compactMap { $0["provider"] as? String },
            ["ethereum", "unknown"]
        )
        XCTAssertEqual(
            requests.compactMap {
                ExtensionBridge.ProviderRevisions(rawValue: $0["revisions"])
            },
            [first.revisions, second.revisions]
        )
    }

    func testPendingResponseCarriesCompletedIdentitiesBeforeQueuedRequests() async throws {
        let store = CompactPopupStore()
        let completed = try popupSnapshot(
            id: 10,
            createdAt: Date(timeIntervalSince1970: 1),
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 2, solana: 3),
            phase: .responded
        )
        let pending = try popupSnapshot(
            id: 11,
            createdAt: Date(timeIntervalSince1970: 2),
            provider: .solana
        )
        await store.insert(pending)
        await store.insert(completed)
        let controller = popupController(store: store)
        let request = try popupCommand(subject: "getPendingRequests", id: 99)

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(response["requests"] as? [[String: Any]])
        let completedResponses = try XCTUnwrap(
            response["completedResponses"] as? [[String: Any]]
        )
        XCTAssertEqual(requests.compactMap { $0["id"] as? Int }, [pending.handle.id])
        XCTAssertEqual(completedResponses.count, 1)
        XCTAssertEqual(completedResponses[0]["id"] as? Int, completed.handle.id)
        XCTAssertEqual(completedResponses[0]["host"] as? String, completed.host)
        XCTAssertEqual(
            completedResponses[0]["configurationKey"] as? String,
            completed.configurationKey
        )
        XCTAssertEqual(
            completedResponses[0]["requestToken"] as? String,
            completed.handle.requestToken
        )
        XCTAssertEqual(
            ExtensionBridge.ProviderRevisions(
                rawValue: completedResponses[0]["revisions"]
            ),
            completed.revisions
        )
    }

    func testUnavailableSessionReturnsCompactRefreshOnlyError() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 20)
        await store.insert(snapshot)
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor(),
            managesWallets: true,
            walletManagerStart: { false }
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 20,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.keys), ["id", "state", "host", "error"])
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil(response["reviewToken"])
        XCTAssertNil(response["canReject"])
    }

    func testNonemptySwitchMaterializesImmediateResponseAfterWalletReload() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSwitchSnapshot(
            id: 24,
            address: "0x0000000000000000000000000000000000000001"
        )
        await store.insert(snapshot)
        var walletStarts = 0
        var preparations = 0
        let processor = CompactPopupProcessor { request in
            preparations += 1
            return .response(ResponseToExtension(
                for: request,
                payload: .body(.ethereum(.init(
                    results: ["0x0000000000000000000000000000000000000001"],
                    chainId: "0x1"
                )))
            ))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            managesWallets: true,
            walletManagerStart: {
                walletStarts += 1
                return true
            }
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle
        )

        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(walletStarts, 1)
        XCTAssertEqual(preparations, 1)
        let loadCount = await store.loadCount()
        XCTAssertEqual(loadCount, 1)
        let events = await store.events()
        XCTAssertEqual(events, ["complete"])
    }

    func testUnknownNonemptySwitchPersistsWithoutStartingWallets() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSwitchSnapshot(
            id: 26,
            address: "0x0000000000000000000000000000000000000001",
            requestedChainId: "0x7fffffffffffffff"
        )
        await store.insert(snapshot)
        var walletStarts = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: ProductionPopupRequestProcessor(),
            managesWallets: true,
            walletManagerStart: {
                walletStarts += 1
                return false
            }
        )

        let disposition = await controller.materializeAfterAdmission(
            handle: snapshot.handle
        )

        XCTAssertEqual(disposition, .responseReady)
        XCTAssertEqual(walletStarts, 0)
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)
        XCTAssertEqual(errorCode, 4902)
    }

    func testImmediateResponsePersistenceShowsWorkingUntilReconciled() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 28)
        await store.insert(snapshot)
        await store.suspendNextCompletion()
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                .response(request.response(error: .userRejected))
            },
            managesWallets: false
        )
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(state.keys), ["id", "state", "host"])
        XCTAssertEqual(state["id"] as? Int, snapshot.handle.id)
        XCTAssertEqual(state["state"] as? String, "working")
        XCTAssertEqual(state["host"] as? String, snapshot.host)

        try await waitForEvent("completeStarted", store: store)
        await store.resumeCompletion()
        try await waitForEvent("complete", store: store)
        let pendingRequest = try popupCommand(subject: "getPendingRequests", id: 99)
        let pending = await controller.dispatch(
            try popupCommandValue(pendingRequest),
            request: pendingRequest,
            profileIdentifier: nil
        )
        let requests = try XCTUnwrap(pending["requests"] as? [[String: Any]])
        let completed = try XCTUnwrap(
            pending["completedResponses"] as? [[String: Any]]
        )
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0]["id"] as? Int, snapshot.handle.id)
        XCTAssertEqual(
            completed[0]["requestToken"] as? String,
            snapshot.handle.requestToken
        )
    }

    func testColdControllerShowsWorkingForApprovingSnapshot() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 22, phase: .approving)
        await store.insert(snapshot)
        var preparationCount = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparationCount += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            managesWallets: false
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil(response["reviewToken"])
        XCTAssertEqual(preparationCount, 0)
    }

    func testCachedControllerShowsWorkingAfterForeignClaim() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 23)
        await store.insert(snapshot)
        let controller = popupController(store: store)
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let initial = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        XCTAssertNotNil(initial["reviewToken"])
        guard case .claimed = await store.claim(handle: snapshot.handle) else {
            return XCTFail("Expected foreign claim")
        }

        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["state"] as? String, "working")
        XCTAssertEqual(response["host"] as? String, snapshot.host)
        XCTAssertNil(response["reviewToken"])
    }

    func testSelectionRefreshFailureReturnsCompactError() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 21)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.switchAccount(SelectAccountAction(
                coinType: nil,
                selectedAccounts: [],
                initiallyConnectedProviders: [.ethereum],
                network: nil,
                resolve: { _, _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            managesWallets: false,
            selectionStateRefresh: { false }
        )
        let request = try popupCommand(
            subject: "getApprovalState",
            id: 21,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        _ = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        let response = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )

        XCTAssertEqual(Set(response.keys), ["id", "state", "host", "error"])
        XCTAssertEqual(response["state"] as? String, "error")
        XCTAssertNil(response["reviewToken"])
    }

    func testAccountSelectionRejectsDuplicateSameCoinAndWrongCoinAccountsBeforeClaim() async throws {
        let firstAccount = WalletAccount(
            address: "solana-public-key-1",
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/0'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
        let secondAccount = WalletAccount(
            address: "solana-public-key-2",
            coin: .solana,
            derivation: .solanaSolana,
            derivationPath: "m/44'/501'/1'/0'",
            publicKey: "",
            extendedPublicKey: ""
        )
        let wrongCoinAccount = popupTestAccount()
        let accountsByAddress = [
            firstAccount.address: firstAccount,
            secondAccount.address: secondAccount,
            wrongCoinAccount.address: wrongCoinAccount,
        ]

        for (index, selectedAccounts) in [
            [firstAccount, firstAccount],
            [firstAccount, secondAccount],
            [wrongCoinAccount],
        ].enumerated() {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 40 + index, provider: .solana)
            await store.insert(snapshot)
            var resolveCount = 0
            let processor = CompactPopupProcessor { request in
                .approval(.selectAccount(SelectAccountAction(
                    coinType: .solana,
                    selectedAccounts: [],
                    initiallyConnectedProviders: [],
                    network: nil,
                    resolve: { _, _ in
                        resolveCount += 1
                        return request.response(error: .userRejected)
                    }
                )))
            }
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: processor,
                managesWallets: false,
                selectionStateRefresh: { true },
                selectionAccountResolver: { item in
                    guard let account = accountsByAddress[item.address] else {
                        return nil
                    }
                    return SpecificWalletAccount(
                        walletId: item.walletId,
                        account: account
                    )
                }
            )
            let token = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            let approve = try popupCommand(
                subject: "approveRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken,
                reviewToken: token,
                payload: [
                    "selectedAccounts": selectedAccounts.map { account in
                        [
                            "walletId": "wallet",
                            "address": account.address,
                            "coin": account.coin.correspondingInpageProvider.rawValue,
                        ]
                    },
                    "revisions": snapshot.revisions.json,
                ]
            )

            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            let events = await store.events()

            XCTAssertEqual(response["status"] as? String, "ok")
            XCTAssertEqual(resolveCount, 0)
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testStaleReviewTokenRejectsApproveAndMutation() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 3)
        await store.insert(snapshot)
        let controller = popupController(store: store)
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: 3,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertNotNil(state["reviewToken"] as? String)

        for subject in ["approveRequest", "applyTransactionEdits"] {
            let payload: [String: Any] = subject == "approveRequest"
                ? [:]
                : ["mode": "suggested"]
            let request = try popupCommand(
                subject: subject,
                id: 3,
                requestToken: snapshot.handle.requestToken,
                reviewToken: UUID().uuidString.lowercased(),
                payload: payload
            )
            let response = await controller.dispatch(
                try popupCommandValue(request),
                request: request,
                profileIdentifier: nil
            )
            XCTAssertEqual(response["status"] as? String, "ignored")
        }
        let staleEvents = await store.events()
        XCTAssertTrue(staleEvents.isEmpty)
    }

    func testAddChainApprovalSkipsRevisionsAndRejectUsesSingleActionPath() async throws {
        let store = CompactPopupStore()
        let approved = try popupSnapshot(id: 4)
        await store.insert(approved)
        let controller = popupController(store: store)
        let reviewToken = try await materializeToken(
            controller: controller,
            snapshot: approved
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 4,
            requestToken: approved.handle.requestToken,
            reviewToken: reviewToken,
            payload: [:]
        )
        let approvalResponse = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let approvalEvents = await store.events()
        XCTAssertEqual(approvalResponse["status"] as? String, "ok")
        XCTAssertEqual(approvalEvents, ["claim", "begin", "complete"])
        let approvalWasCommitted = await store.completedApprovalWasCommitted(
            handle: approved.handle
        )
        XCTAssertTrue(approvalWasCommitted)

        let rejected = try popupSnapshot(id: 5)
        await store.insert(rejected)
        _ = try await materializeToken(
            controller: controller,
            snapshot: rejected
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: 5,
            requestToken: rejected.handle.requestToken
        )
        _ = await controller.dispatch(
            try popupCommandValue(reject),
            request: reject,
            profileIdentifier: nil
        )
        let rejectionEvents = await store.events()
        XCTAssertEqual(rejectionEvents.last, "reject")

        XCTAssertThrowsError(try popupCommand(
            subject: "rejectRequest",
            id: 6,
            requestToken: rejected.handle.requestToken,
            reviewToken: UUID().uuidString.lowercased()
        ))
    }

    func testColdControllerRejectsQueuedHandleWithoutMaterializingSession() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 25)
        await store.insert(snapshot)
        var preparations = 0
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor { request in
                preparations += 1
                return .approval(.addEthereumChain(AddEthereumChainAction(
                    chainToAdd: popupTestNetwork(),
                    resolve: { _ in request.response(error: .userRejected) }
                )))
            },
            managesWallets: false
        )
        let reject = try popupCommand(
            subject: "rejectRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken
        )

        let response = await controller.dispatch(
            try popupCommandValue(reject),
            request: reject,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(preparations, 0)
        let events = await store.events()
        XCTAssertEqual(events, ["reject"])
    }

    func testFailedRejectPreservesCachedReviewSession() async throws {
        for (result, expectedStatus) in [
            (ExtensionBridge.StoreMutationResult.ownershipLost, "ignored"),
            (.retryablePersistenceFailure, "unavailable"),
        ] {
            let store = CompactPopupStore()
            let snapshot = try popupSnapshot(id: 27)
            await store.insert(snapshot)
            var preparations = 0
            let controller = PopupRequestSessions(
                store: store,
                requestProcessor: CompactPopupProcessor { request in
                    preparations += 1
                    return .approval(.addEthereumChain(AddEthereumChainAction(
                        chainToAdd: popupTestNetwork(),
                        resolve: { _ in request.response(error: .userRejected) }
                    )))
                },
                managesWallets: false
            )
            let originalToken = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )
            await store.forceNextRejectResult(result)
            let reject = try popupCommand(
                subject: "rejectRequest",
                id: snapshot.handle.id,
                requestToken: snapshot.handle.requestToken
            )

            let response = await controller.dispatch(
                try popupCommandValue(reject),
                request: reject,
                profileIdentifier: nil
            )
            let retainedToken = try await materializeToken(
                controller: controller,
                snapshot: snapshot
            )

            XCTAssertEqual(response["status"] as? String, expectedStatus)
            XCTAssertEqual(retainedToken, originalToken)
            XCTAssertEqual(preparations, 1)
        }
    }

    func testAuthenticationFailureReleasesClaimAndReturnsToReview() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 6)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(false) },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 6,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let releaseEvents = await store.events()
        XCTAssertEqual(releaseEvents, ["claim", "release"])
        let refreshed = try popupCommand(
            subject: "getApprovalState",
            id: 6,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(refreshed),
            request: refreshed,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "review")
    }

    func testApprovalDispatchAwaitsAuthenticationAndFinalPersistence() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 30)
        await store.insert(snapshot)
        await store.suspendNextCompletion()
        var authenticationCompletion: ((Bool) -> Void)?
        var dispatchCompleted = false
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in
                authenticationCompletion = completion
            },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationCompletion != nil }
        XCTAssertFalse(dispatchCompleted)
        let authenticationEvents = await store.events()
        XCTAssertEqual(authenticationEvents, ["claim"])

        authenticationCompletion?(true)
        try await waitForEvent("completeStarted", store: store)
        XCTAssertFalse(dispatchCompleted)

        await store.resumeCompletion()
        let response = try await dispatch.value
        let completionEvents = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            completionEvents,
            ["claim", "begin", "completeStarted", "complete"]
        )
    }

    func testExecutionPersistsAfterReviewTokenBecomesStale() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 31)
        await store.insert(snapshot)
        let executionGate = CompactPopupGate()
        var approvalSession: PopupRequestSession?
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    await executionGate.wait()
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { session, _, _, completion in
                approvalSession = session
                completion(true)
            },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForEvent("begin", store: store)
        try XCTUnwrap(approvalSession).retry()
        await executionGate.open()
        let response = try await dispatch.value
        let events = await store.events()
        let approvalWasCommitted = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "begin", "complete"])
        XCTAssertTrue(approvalWasCommitted)
    }

    func testBroadcastCheckpointsBeforeSendAndCompletion() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 7)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("send")
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(true) },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 7,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let broadcastEvents = await store.events()
        XCTAssertEqual(
            broadcastEvents,
            ["claim", "begin", "checkpoint", "send", "complete"]
        )
    }

    func testApprovalDispatchAwaitsBroadcastSend() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 32)
        await store.insert(snapshot)
        let sendGate = CompactPopupGate()
        var dispatchCompleted = false
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("sendStarted")
                            await sendGate.wait()
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(true) },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForEvent("sendStarted", store: store)
        XCTAssertFalse(dispatchCompleted)
        let pendingEvents = await store.events()
        XCTAssertEqual(
            pendingEvents,
            ["claim", "begin", "checkpoint", "sendStarted"]
        )

        await sendGate.open()
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(
            events,
            ["claim", "begin", "checkpoint", "sendStarted", "complete"]
        )
    }

    func testTransactionApprovalAwaitsSynchronousAuthenticationOutputAndPreflight() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 33, provider: .ethereum)
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var authenticationCompletion: ((Bool) -> Void)?
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        var dispatchCompleted = false
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, completion in
                preflightCompletion = completion
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { transaction in
                    XCTAssertNotNil(transaction)
                    await store.record("resolve")
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in
                authenticationCompletion = completion
            },
            transactionApprovalOperations: operations,
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            let response = await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
            dispatchCompleted = true
            return response
        }

        try await waitForCondition { authenticationCompletion != nil }
        XCTAssertFalse(dispatchCompleted)
        authenticationCompletion?(true)
        try await waitForCondition { preflightCompletion != nil }
        XCTAssertFalse(dispatchCompleted)

        preflightCompletion?(.safe(transaction, popupTransactionEstimate()))
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertTrue(dispatchCompleted)
        XCTAssertEqual(events, ["claim", "begin", "resolve", "complete"])
    }

    func testTransactionPresentationChangeWhileClaimingReturnsToReview() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 35, provider: .ethereum)
        await store.insert(snapshot)
        await store.suspendNextClaim()
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preparationUpdate: ((Transaction) -> Void)?
        var authenticationCount = 0
        var preflightCount = 0
        var resolveCount = 0
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, onUpdate, _, completion in
                preparationUpdate = onUpdate
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, _ in
                preflightCount += 1
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in
                authenticationCount += 1
                completion(true)
            },
            transactionApprovalOperations: operations,
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForEvent("claimStarted", store: store)
        var lateTransaction = transaction
        lateTransaction.interpretation = "Late interpretation"
        preparationUpdate?(lateTransaction)
        await store.resumeClaim()

        let response = try await dispatch.value
        let events = await store.events()
        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )

        XCTAssertEqual(response["status"] as? String, "ignored")
        XCTAssertEqual(events, ["claimStarted", "claim", "release"])
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertEqual(state["dataInterpretation"] as? String, "Late interpretation")
        XCTAssertNotEqual(state["reviewToken"] as? String, token)
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(preflightCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testTransactionAlertReleasesClaimBeforeApprovalReturns() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 34, provider: .ethereum)
        await store.insert(snapshot)
        let transaction = popupReadyTransaction()
        let network = popupTransactionNetwork()
        var preflightCompletion: ((TransactionFeePreflightResult) -> Void)?
        let operations = TransactionApprovalOperations(
            prepare: { transaction, _, _, _, _, completion in
                completion(.success(transaction))
                return EthereumRequestCancellation()
            },
            preflight: { _, _, completion in
                preflightCompletion = completion
                return EthereumRequestCancellation()
            }
        )
        let processor = CompactPopupProcessor { request in
            .approval(.approveTransaction(SendTransactionAction(
                transaction: transaction,
                resolvedNetwork: ResolvedEthereumNetwork(
                    network: network,
                    source: .custom
                ),
                walletId: "wallet",
                account: popupTestAccount(),
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(true) },
            transactionApprovalOperations: operations,
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        let dispatch = Task { @MainActor in
            await controller.dispatch(
                try popupCommandValue(approve),
                request: approve,
                profileIdentifier: nil
            )
        }

        try await waitForCondition { preflightCompletion != nil }
        preflightCompletion?(.unavailable(transaction, popupTransactionEstimate()))
        let response = try await dispatch.value
        let events = await store.events()
        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "release"])

        let stateRequest = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(stateRequest),
            request: stateRequest,
            profileIdentifier: nil
        )
        XCTAssertEqual(state["state"] as? String, "review")
        XCTAssertNotNil(state["alert"])
    }

    func testHungBroadcastTimesOutToRecoveryAndInvokesSendOnce() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 8)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    .broadcast(PreparedBroadcast(
                        recoveryResponse: request.response(error: .internalError),
                        send: {
                            await store.record("send")
                            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                            await store.record("late")
                            return request.response(error: .userRejected)
                        }
                    ))
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(true) },
            managesWallets: false,
            broadcastTimeoutNanoseconds: 1_000_000
        )
        let token = try await materializeToken(
            controller: controller,
            snapshot: snapshot
        )
        let approve = try popupCommand(
            subject: "approveRequest",
            id: 8,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: ["revisions": snapshot.revisions.json]
        )
        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        XCTAssertEqual(events.filter { $0 == "send" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "complete" }.count, 1)
        let completedErrorCode = await store.completedErrorCode(
            handle: snapshot.handle
        )
        XCTAssertEqual(completedErrorCode, ProviderResponseError.internalErrorCode)
        let checkpointWasCommitted = await store.checkpointApprovalWasCommitted(
            handle: snapshot.handle
        )
        let completionWasCommitted = await store.completedApprovalWasCommitted(
            handle: snapshot.handle
        )
        XCTAssertTrue(checkpointWasCommitted)
        XCTAssertTrue(completionWasCommitted)
    }

    func testEthereumRevisionMismatchCompletesBeforeAuthenticationOrResolve() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 9,
            provider: .ethereum,
            revisions: popupRevisions(ethereum: 3, solana: 4)
        )
        await store.insert(snapshot)
        var authenticationCount = 0
        var resolveCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in
                authenticationCount += 1
                completion(true)
            },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 4, solana: 4).json,
            ]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(authenticationCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testUnrelatedEthereumDriftDoesNotBlockSolanaApproval() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 10,
            provider: .solana,
            revisions: popupRevisions(ethereum: 1, solana: 7)
        )
        await store.insert(snapshot)
        var resolveCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in
                    resolveCount += 1
                    return request.response(error: .userRejected)
                }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in completion(true) },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 99, solana: 7).json,
            ]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["claim", "begin", "complete"])
        XCTAssertEqual(resolveCount, 1)
    }

    func testUnknownProviderRequiresBothRevisions() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(
            id: 11,
            revisions: popupRevisions(ethereum: 2, solana: 8)
        )
        await store.insert(snapshot)
        var authenticationCount = 0
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, completion in
                authenticationCount += 1
                completion(true)
            },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [
                "revisions": popupRevisions(ethereum: 2, solana: 9).json,
            ]
        )

        _ = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
        XCTAssertEqual(authenticationCount, 0)
    }

    func testMissingRevisionsCompletesNonAddApprovalAsStale() async throws {
        let store = CompactPopupStore()
        let snapshot = try popupSnapshot(id: 12, provider: .ethereum)
        await store.insert(snapshot)
        let processor = CompactPopupProcessor { request in
            .approval(.approveMessage(SignMessageAction(
                subject: .signMessage,
                walletId: "wallet",
                account: popupTestAccount(),
                meta: "message",
                resolve: { _ in request.response(error: .userRejected) }
            )))
        }
        let controller = PopupRequestSessions(
            store: store,
            requestProcessor: processor,
            authenticationOverride: { _, _, _, _ in
                XCTFail("Stale approval must not authenticate")
            },
            managesWallets: false
        )
        let token = try await materializeToken(controller: controller, snapshot: snapshot)
        let approve = try popupCommand(
            subject: "approveRequest",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            reviewToken: token,
            payload: [:]
        )

        let response = await controller.dispatch(
            try popupCommandValue(approve),
            request: approve,
            profileIdentifier: nil
        )
        let events = await store.events()
        let errorCode = await store.completedErrorCode(handle: snapshot.handle)

        XCTAssertEqual(response["status"] as? String, "ok")
        XCTAssertEqual(events, ["complete"])
        XCTAssertEqual(errorCode, 4100)
    }

    private func popupController(store: CompactPopupStore) -> PopupRequestSessions {
        return PopupRequestSessions(
            store: store,
            requestProcessor: CompactPopupProcessor(),
            managesWallets: false
        )
    }

    private func materializeToken(
        controller: PopupRequestSessions,
        snapshot: ExtensionBridge.Snapshot
    ) async throws -> String {
        let request = try popupCommand(
            subject: "getApprovalState",
            id: snapshot.handle.id,
            requestToken: snapshot.handle.requestToken,
            payload: ["mode": "full"]
        )
        let state = await controller.dispatch(
            try popupCommandValue(request),
            request: request,
            profileIdentifier: nil
        )
        return try XCTUnwrap(state["reviewToken"] as? String)
    }

    private func waitForEvent(
        _ event: String,
        store: CompactPopupStore
    ) async throws {
        for _ in 0..<100 {
            if await store.events().contains(event) { return }
            await Task.yield()
        }
        throw PopupRequestSessionsTestError.timedOut
    }

    private func waitForCondition(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        throw PopupRequestSessionsTestError.timedOut
    }
}

@MainActor
private final class CompactPopupProcessor: PopupRequestProcessing {
    let handler: (SafariRequest) -> DappRequestPreparation

    init(handler: @escaping (SafariRequest) -> DappRequestPreparation = { request in
        .approval(.addEthereumChain(AddEthereumChainAction(
            chainToAdd: popupTestNetwork(),
            resolve: { _ in request.response(error: .userRejected) }
        )))
    }) {
        self.handler = handler
    }

    func prepare(_ request: SafariRequest) -> DappRequestPreparation {
        return handler(request)
    }
}

private actor CompactPopupGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor CompactPopupStore: PopupRequestStore {
    private var records = [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
    private var eventValues = [String]()
    private var claims = [ExtensionBridge.Handle: ExtensionBridge.ApprovalClaim]()
    private var permits = [ExtensionBridge.Handle: ExtensionBridge.ExecutionPermit]()
    private var completedErrorCodes = [ExtensionBridge.Handle: Int]()
    private var committedCompletions = Set<ExtensionBridge.Handle>()
    private var committedCheckpoints = Set<ExtensionBridge.Handle>()
    private var nextRejectResult: ExtensionBridge.StoreMutationResult?
    private var suspendClaim = false
    private var claimContinuation: CheckedContinuation<Void, Never>?
    private var suspendCompletion = false
    private var completionContinuation: CheckedContinuation<Void, Never>?
    private var loadCountValue = 0

    func insert(_ snapshot: ExtensionBridge.Snapshot) { records[snapshot.handle] = snapshot }
    func events() -> [String] { eventValues }
    func loadCount() -> Int { loadCountValue }
    func record(_ event: String) { eventValues.append(event) }
    func completedErrorCode(handle: ExtensionBridge.Handle) -> Int? {
        return completedErrorCodes[handle]
    }
    func completedApprovalWasCommitted(
        handle: ExtensionBridge.Handle
    ) -> Bool {
        return committedCompletions.contains(handle)
    }
    func checkpointApprovalWasCommitted(
        handle: ExtensionBridge.Handle
    ) -> Bool {
        return committedCheckpoints.contains(handle)
    }
    func forceNextRejectResult(_ result: ExtensionBridge.StoreMutationResult) {
        nextRejectResult = result
    }
    func suspendNextClaim() { suspendClaim = true }
    func resumeClaim() {
        let continuation = claimContinuation
        claimContinuation = nil
        continuation?.resume()
    }
    func suspendNextCompletion() { suspendCompletion = true }
    func resumeCompletion() {
        let continuation = completionContinuation
        completionContinuation = nil
        continuation?.resume()
    }

    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult {
        .available(records.filter { $0.key.profileIdentifier == profileIdentifier })
    }

    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult {
        loadCountValue += 1
        return records[handle].map(ExtensionBridge.SnapshotResult.found) ?? .missing
    }

    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult {
        if suspendClaim {
            suspendClaim = false
            await withCheckedContinuation { continuation in
                eventValues.append("claimStarted")
                claimContinuation = continuation
            }
        }
        guard let snapshot = records[handle], snapshot.phase == .queued else { return .missing }
        eventValues.append("claim")
        let claim = ExtensionBridge.ApprovalClaim(handle: handle, value: UUID())
        claims[handle] = claim
        records[handle] = replacing(snapshot, phase: .approving, request: snapshot.request)
        return .claimed(claim)
    }

    func complete(handle: ExtensionBridge.Handle, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult {
        completedErrorCodes[handle] = response.json["errorCode"] as? Int
        return await complete(handle: handle)
    }

    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult {
        eventValues.append("reject")
        if let result = nextRejectResult {
            nextRejectResult = nil
            return result
        }
        return await complete(handle: handle, recordsEvent: false)
    }

    func release(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult {
        guard claims[claim.handle] == claim, let snapshot = records[claim.handle] else {
            return .ownershipLost
        }
        eventValues.append("release")
        claims[claim.handle] = nil
        records[claim.handle] = replacing(snapshot, phase: .queued, request: snapshot.request)
        return .persisted
    }

    func begin(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.BeginExecutionResult {
        guard claims[claim.handle] == claim, let snapshot = records[claim.handle] else {
            return .ownershipLost
        }
        eventValues.append("begin")
        let permit = ExtensionBridge.ExecutionPermit(handle: claim.handle, value: UUID())
        claims[claim.handle] = nil
        permits[claim.handle] = permit
        records[claim.handle] = replacing(snapshot, phase: .approving, request: nil)
        return .began(permit)
    }

    func complete(permit: ExtensionBridge.ExecutionPermit, response: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult {
        guard permits[permit.handle] == permit else { return .ownershipLost }
        permits[permit.handle] = nil
        completedErrorCodes[permit.handle] = response.json["errorCode"] as? Int
        if response.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
            committedCompletions.insert(permit.handle)
        }
        return await complete(handle: permit.handle)
    }

    func prepareBroadcast(permit: ExtensionBridge.ExecutionPermit, recoveryResponse: ResponseToExtension) async -> ExtensionBridge.StoreMutationResult {
        guard permits[permit.handle] == permit else { return .ownershipLost }
        if recoveryResponse.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
            committedCheckpoints.insert(permit.handle)
        }
        eventValues.append("checkpoint")
        return .persisted
    }

    private func complete(
        handle: ExtensionBridge.Handle,
        recordsEvent: Bool = true
    ) async -> ExtensionBridge.StoreMutationResult {
        guard let snapshot = records[handle] else { return .ownershipLost }
        if suspendCompletion {
            suspendCompletion = false
            await withCheckedContinuation { continuation in
                eventValues.append("completeStarted")
                completionContinuation = continuation
            }
        }
        if recordsEvent { eventValues.append("complete") }
        records[handle] = replacing(snapshot, phase: .responded, request: nil)
        return .persisted
    }

    private func replacing(
        _ snapshot: ExtensionBridge.Snapshot,
        phase: ExtensionBridge.Phase,
        request: SafariRequest?
    ) -> ExtensionBridge.Snapshot {
        ExtensionBridge.Snapshot(
            handle: snapshot.handle,
            phase: phase,
            request: request,
            host: snapshot.host,
            configurationKey: snapshot.configurationKey,
            revisions: snapshot.revisions,
            createdAt: snapshot.createdAt,
            enqueueAttempt: snapshot.enqueueAttempt,
            sequence: snapshot.sequence
        )
    }
}

private extension SafariRequest {
    func response(error: ProviderResponseError) -> ResponseToExtension {
        ResponseToExtension(for: self, payload: .error(error))
    }
}

private func popupTestNetwork() -> EthereumNetworkFromDapp {
    EthereumNetworkFromDapp(
        chainId: "0x1234",
        rpcUrls: ["https://rpc.example"],
        blockExplorerUrls: [],
        nativeCurrency: .init(decimals: 18, name: "Test Ether", symbol: "TETH"),
        chainName: "Test Network"
    )
}

private func popupTestAccount() -> WalletAccount {
    WalletAccount(
        address: "0x0000000000000000000000000000000000000042",
        coin: .ethereum,
        derivation: .default,
        derivationPath: "m/44'/60'/0'/0/0",
        publicKey: "",
        extendedPublicKey: ""
    )
}

private func popupReadyTransaction() -> Transaction {
    Transaction(
        from: "0x0000000000000000000000000000000000000001",
        to: "0x0000000000000000000000000000000000000002",
        nonce: "0x0",
        gas: "0x5208",
        value: "0x0",
        data: "0x",
        feeIntent: .legacy(gasPrice: 10),
        preparedFee: .legacy(gasPrice: 10),
        feeSource: .automatic
    )
}

private func popupTransactionNetwork() -> EthereumNetwork {
    EthereumNetwork(
        chainId: 10,
        name: "Test",
        symbol: "ETH",
        rpcEndpoint: .unauthenticated(URL(string: "https://rpc.example")!),
        isTestnet: true,
        mightShowPrice: false,
        explorer: nil
    )
}

private func popupTransactionEstimate() -> GasService.Estimate {
    GasService.Estimate(
        info: nil,
        nextBaseFee: nil,
        currentBaseFee: nil,
        support: .legacy,
        gasPrice: 10,
        endpointChainID: 10
    )
}

private func popupSwitchSnapshot(
    id: Int,
    address: String,
    requestedChainId: String = "0x1"
) throws -> ExtensionBridge.Snapshot {
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "name": "switchEthereumChain",
        "provider": "ethereum",
        "host": "wallet.example",
        "configurationKey": "wallet.example",
        "enqueueAttempt": String(format: "%032x", id),
        "admissionDeadline": popupRequestAdmissionDeadline,
        "workflowVersion": ExtensionBridge.workflowVersion,
        "body": [
            "address": address,
            "chainId": "0x1",
            "object": ["chainId": requestedChainId],
        ],
    ])
    let request = try XCTUnwrap(SafariRequest(data: data))
    let handle = ExtensionBridge.Handle(
        id: id,
        token: .init(value: UUID()),
        profileIdentifier: nil
    )
    return ExtensionBridge.Snapshot(
        handle: handle,
        phase: .queued,
        request: request,
        host: request.host,
        configurationKey: request.configurationKey,
        revisions: popupRevisions(),
        createdAt: Date(),
        enqueueAttempt: request.enqueueAttempt,
        sequence: id
    )
}

private func popupSnapshot(
    id: Int,
    createdAt: Date = Date(),
    provider: InpageProvider = .unknown,
    revisions: ExtensionBridge.ProviderRevisions = popupRevisions(),
    phase: ExtensionBridge.Phase = .queued
) throws -> ExtensionBridge.Snapshot {
    let name: String
    let body: [String: Any]
    switch provider {
    case .ethereum:
        name = "requestAccounts"
        body = ["address": popupTestAccount().address]
    case .solana:
        name = "connect"
        body = ["publicKey": "solana-public-key"]
    case .unknown:
        name = "switchAccount"
        body = ["latestConfigurations": []]
    case .multiple:
        throw CocoaError(.coderInvalidValue)
    }
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "name": name,
        "provider": provider.rawValue,
        "host": "wallet.example",
        "configurationKey": "wallet.example",
        "enqueueAttempt": String(format: "%032x", id),
        "admissionDeadline": popupRequestAdmissionDeadline,
        "workflowVersion": ExtensionBridge.workflowVersion,
        "body": body,
    ])
    let request = try XCTUnwrap(SafariRequest(data: data))
    let handle = ExtensionBridge.Handle(
        id: id,
        token: .init(value: UUID()),
        profileIdentifier: nil
    )
    return ExtensionBridge.Snapshot(
        handle: handle,
        phase: phase,
        request: phase == .responded ? nil : request,
        host: request.host,
        configurationKey: request.configurationKey,
        revisions: revisions,
        createdAt: createdAt,
        enqueueAttempt: request.enqueueAttempt,
        sequence: id
    )
}

private func popupRevisions(
    ethereum: Int = 0,
    solana: Int = 0
) -> ExtensionBridge.ProviderRevisions {
    guard let revisions = ExtensionBridge.ProviderRevisions(rawValue: [
        "ethereum": ethereum,
        "solana": solana,
    ]) else {
        preconditionFailure("Invalid test revisions")
    }
    return revisions
}

private func popupCommand(
    subject: String,
    id: Int,
    requestToken: String? = nil,
    reviewToken: String? = nil,
    payload: [String: Any]? = nil
) throws -> InternalSafariRequest {
    var value: [String: Any] = [
        "subject": subject,
        "id": id,
        "workflowVersion": ExtensionBridge.workflowVersion,
    ]
    value["requestToken"] = requestToken
    value["reviewToken"] = reviewToken
    value["payload"] = payload
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(InternalSafariRequest.self, from: data)
}

private func popupCommandValue(
    _ request: InternalSafariRequest
) throws -> InternalSafariRequest.PopupCommand {
    guard case .popup(let command) = request.command else {
        throw CocoaError(.coderInvalidValue)
    }
    return command
}
