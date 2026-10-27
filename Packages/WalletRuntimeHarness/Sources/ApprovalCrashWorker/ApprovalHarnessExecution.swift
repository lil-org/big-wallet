import Foundation
import Synchronization
import WalletDomain
@testable import WalletAuthority
@testable import WalletNetworking

func harnessHandle(_ handle: RequestHandle) -> HarnessValue {
    .object(["id": .number(Double(handle.id)), "token": .string(handle.requestToken),
        "profileIdentifier": handle.profileIdentifier.map { .string($0.uuidString.lowercased()) } ?? .null])
}

func harnessDecodeHandle(_ value: HarnessValue) throws -> RequestHandle {
    guard let id = value["id"].int,
          let token = value["token"].string ?? value["requestToken"].string,
          let handle = RequestHandle(id: id, requestToken: token,
            profileIdentifier: value["profileIdentifier"].string.flatMap(UUID.init(uuidString:))) else {
        throw HarnessError.invalid("Invalid request handle")
    }
    return handle
}

final class HarnessObservedStore: NativeApprovalStore, NativeDeliveryStore, NativeImmediateCompleting, NativeMessageBridge {
    let bridge: ExtensionBridge
    let ipc: HarnessIPC

    init(bridge: ExtensionBridge, ipc: HarnessIPC) {
        self.bridge = bridge
        self.ipc = ipc
    }

    private func perform<Value: Sendable>(
        _ name: String,
        handle: RequestHandle,
        after: String? = nil,
        extra: HarnessValue = .object([:]),
        successful: @Sendable (Value) -> Bool = { _ in true },
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await HarnessOperation.$name.withValue(name) {
            try await HarnessOperation.$identity.withValue(harnessHandle(handle)) {
                let details = extra.merging(["handle": harnessHandle(handle)])
                try await ipc.checkpoint(name + ".before", details: details)
                let value = try await operation()
                if successful(value) { try await ipc.checkpoint(after ?? name + ".after", details: details) }
                return value
            }
        }
    }

    func authorityIsCurrent(handle: RequestHandle) async -> Bool { await bridge.authorityIsCurrent(handle: handle) }
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult { await bridge.list(profileIdentifier: profileIdentifier) }
    func load(handle: RequestHandle) async -> ExtensionBridge.SnapshotResult { await bridge.load(handle: handle) }

    func claim(handle: RequestHandle) async -> ExtensionBridge.ApprovalClaimResult {
        do { return try await perform("claim", handle: handle, successful: { if case .claimed = $0 { true } else { false } }) {
            let result = await self.bridge.claim(handle: handle)
            if case .claimed = result { try self.ipc.bindCurrentTask(to: handle) }
            return result
        } }
        catch { return .unavailable }
    }

    func claimNativeExecution(consent: ReviewConsent) async -> ExtensionBridge.NativeExecutionClaimResult {
        do { return try await perform("claim", handle: consent.binding.handle,
            successful: { if case .claimed = $0 { true } else { false } }) {
            let result = await self.bridge.claimNativeExecution(consent: consent)
            if case .claimed = result { try self.ipc.bindCurrentTask(to: consent.binding.handle) }
            return result
        } }
        catch { return .unavailable }
    }

    func authorize(claim: ExtensionBridge.ApprovalClaim, approval: ResolvedDappApproval) async -> ExtensionBridge.AuthorizeExecutionResult {
        do {
            return try await HarnessOperation.$name.withValue("authorize") {
                try await HarnessOperation.$identity.withValue(harnessHandle(claim.handle)) {
                    let details = HarnessValue.object(["handle": harnessHandle(claim.handle)])
                    try await ipc.checkpoint("authorize.before", details: details)
                    let result = await bridge.authorize(claim: claim, approval: approval)
                    if case .authorized(let permit) = result {
                        let details = details.merging(["executionID": .string(permit.executionID.uuidString.lowercased())])
                        if case .ordinary = claim.authority {
                            ipc.event("consent", details: details.merging(["label": .string("popup-" + permit.executionID.uuidString.lowercased())]))
                        }
                        try await ipc.checkpoint("authorize.after", details: details)
                    }
                    return result
                }
            }
        } catch { return .retryablePersistenceFailure }
    }

    func completeImmediate(handle: RequestHandle, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.completeImmediate(handle: handle, resolution: resolution)
        } }
        catch { return .retryablePersistenceFailure }
    }

    func reject(handle: RequestHandle) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("reject", handle: handle) { await self.bridge.reject(handle: handle) } }
        catch { return .retryablePersistenceFailure }
    }

    func abandon(claim: ExtensionBridge.ApprovalClaim) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("abandon", handle: claim.handle) { await self.bridge.abandon(claim: claim) } }
        catch { return .retryablePersistenceFailure }
    }

    func returnToReview(claim: ExtensionBridge.ApprovalClaim, consent: ReviewConsent) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("returnToReview", handle: claim.handle) { await self.bridge.returnToReview(claim: claim, consent: consent) } }
        catch { return .retryablePersistenceFailure }
    }

    func complete(claim: ExtensionBridge.ApprovalClaim, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: claim.handle, successful: { $0 == .persisted }) {
            await self.bridge.complete(claim: claim, resolution: resolution)
        } }
        catch { return .retryablePersistenceFailure }
    }

    func prepareBroadcast(permit: ExtensionBridge.ApprovedExecutionPermit, broadcast: PreparedBroadcast) async -> ExtensionBridge.BroadcastPreparationResult {
        do { return try await perform("broadcast.prepare", handle: permit.handle, after: "broadcast.prepared",
            extra: .object(["executionID": .string(permit.executionID.uuidString.lowercased())]),
            successful: { if case .prepared = $0 { true } else { false } }) {
            await self.bridge.prepareBroadcast(permit: permit, broadcast: broadcast)
        } } catch { return .retryablePersistenceFailure }
    }

    func complete(permit: ExtensionBridge.ApprovedExecutionPermit, result: ApprovedCompletion) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: permit.handle,
            extra: .object(["executionID": .string(permit.executionID.uuidString.lowercased())]), successful: { $0 == .persisted }) {
            await self.bridge.complete(permit: permit, result: result)
        } }
        catch { return .retryablePersistenceFailure }
    }

    func abandon(permit: ExtensionBridge.ApprovedExecutionPermit) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("abandon", handle: permit.handle) { await self.bridge.abandon(permit: permit) } }
        catch { return .retryablePersistenceFailure }
    }

    func recordNativeDeliveryReceipt(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce,
        owner: NativeDeliveryOwner) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("receipt", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.recordNativeDeliveryReceipt(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce, owner: owner)
        } } catch { return .retryablePersistenceFailure }
    }

    func interruptNativeApproval(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID) async -> ExtensionBridge.NativeInterruptionResult {
        do { return try await perform("interrupt", handle: handle) {
            await self.bridge.interruptNativeApproval(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier)
        } } catch { return .retryablePersistenceFailure }
    }

    func completeNativeImmediate(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.completeNativeImmediate(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier, resolution: resolution)
        } } catch { return .retryablePersistenceFailure }
    }

    func rejectNativeDelivery(handle: RequestHandle, nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("reject", handle: handle) {
            await self.bridge.rejectNativeDelivery(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier)
        } } catch { return .retryablePersistenceFailure }
    }

    func enqueue(ingress: ExtensionBridge.Ingress, profileIdentifier: UUID?, privateBrowsing: Bool) async -> ExtensionBridge.EnqueueResult {
        await HarnessOperation.$name.withValue("enqueue") {
            let result = await bridge.enqueue(ingress: ingress, profileIdentifier: profileIdentifier, privateBrowsing: privateBrowsing)
            if case .accepted(let handle, _, _, _, _) = result {
                ipc.event("admission", details: .object(["handle": harnessHandle(handle),
                    "enqueueAttempt": .string(ingress.request.enqueueAttempt), "configurationKey": .string(ingress.request.configurationKey),
                    "provider": .string(ingress.request.provider.rawValue), "name": .string(ingress.request.name),
                    "payloadDigest": .string(WalletCrypto.hexString(data: ingress.fingerprint))]))
                do { try await ipc.checkpoint("admission.after", details: .object(["handle": harnessHandle(handle)])) }
                catch { return .unavailable }
            }
            return result
        }
    }

    func configurationSnapshot(configurationKey: String, profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityReadResult {
        await bridge.configurationSnapshot(configurationKey: configurationKey, profileIdentifier: profileIdentifier)
    }

    func revoke(configurationKey: String, provider: InpageProvider, attempt: String, expected: RequestAuthorityVersion,
        profileIdentifier: UUID?) async -> ExtensionBridge.AuthorityMutationResult {
        await HarnessOperation.$name.withValue("revoke") {
            let result = await bridge.revoke(configurationKey: configurationKey, provider: provider, attempt: attempt, expected: expected,
                profileIdentifier: profileIdentifier)
            if case .revoked(let snapshot) = result {
                do { try await ipc.checkpoint("revocation.after", details: .object(["configurationKey": .string(configurationKey),
                    "provider": .string(provider.rawValue), "attempt": .string(attempt), "state": try HarnessValue.convert(snapshot.json),
                    "profileIdentifier": profileIdentifier.map { .string($0.uuidString.lowercased()) } ?? .null])) }
                catch { return .unavailable }
            }
            return result
        }
    }

    func listRecoveryRequests(profileIdentifier: UUID?) async -> ExtensionBridge.RecoveryRequestsResult {
        await bridge.listRecoveryRequests(profileIdentifier: profileIdentifier)
    }

    func acknowledgeResponse(handle: RequestHandle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("acknowledgement", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.acknowledgeResponse(handle: handle, configurationKey: configurationKey)
        } } catch { return .retryablePersistenceFailure }
    }

    func prepareDelivery(handle: RequestHandle, configurationKey: String) async -> ExtensionBridge.ResponseReadResult {
        do { return try await perform("delivery", handle: handle, successful: { if case .response = $0 { true } else { false } }) {
            await self.bridge.prepareResponseDelivery(id: handle.id, configurationKey: configurationKey,
                requestToken: handle.requestToken, profileIdentifier: handle.profileIdentifier)
        } } catch { return .unavailable }
    }
}

struct HarnessObservedProcessor: DappRequestProcessing {
    let base: DappRequestProcessor
    let ipc: HarnessIPC

    func prepare(_ binding: ExtensionBridge.RequestBinding, catalog: WalletReviewCatalog?) -> DappRequestPreparation {
        base.prepare(binding, catalog: catalog)
    }

    func execute(permit: ExtensionBridge.ApprovedExecutionPermit, signer: (any WalletSigning)?) async -> ApprovedExecutionResult {
        await HarnessOperation.$name.withValue("execute") {
            await HarnessOperation.$identity.withValue(harnessHandle(permit.handle)) {
                let observed = signer.map { HarnessObservedSigner(base: $0, permit: permit, ipc: ipc) }
                return await base.execute(permit: permit, signer: observed)
            }
        }
    }
}

final class HarnessObservedSigner: WalletSigning {
    let base: any WalletSigning
    let permit: ExtensionBridge.ApprovedExecutionPermit
    let ipc: HarnessIPC

    init(base: any WalletSigning, permit: ExtensionBridge.ApprovedExecutionPermit, ipc: HarnessIPC) {
        self.base = base
        self.permit = permit
        self.ipc = ipc
    }

    @MainActor
    func sign() async -> Result<WalletSigningOutput, WalletSigningFailure> {
        let account = permit.request.authorizedAccount.flatMap {
            try? JSONDecoder().decode(HarnessValue.self, from: JSONEncoder().encode($0))
        } ?? .null
        let details = HarnessValue.object(["handle": harnessHandle(permit.handle),
            "executionID": .string(permit.executionID.uuidString.lowercased()),
            "enqueueAttempt": .string(permit.request.enqueueAttempt), "provider": .string(permit.request.provider.rawValue),
            "requestName": .string(permit.request.name),
            "account": account, "approvedAccount": account])
        defer { ipc.event("observation", details: details.merging(["boundary": .string("signer.terminal")])) }
        let observed = Mutex((before: false, after: false, outcome: ["succeeded": HarnessValue.bool(false)]))
        let inherited = AuthorityExecutionHooks.current
        let ipc = ipc
        let permit = permit
        let hooks = AuthorityExecutionHooks(checkpoint: { point, context in
            switch point {
            case .beforeSigning:
                observed.withLock { $0.before = true }
                try await ipc.checkpoint("signer.before", details: details)
            case .afterSigning:
                let outcome = observed.withLock { state in state.after = true; return state.outcome }
                try await ipc.checkpoint("signer.after", details: details.merging(outcome))
            default:
                try await inherited.checkpoint(point, context)
            }
        }, event: { event in
            if event.kind == .signingFinished {
                let outcome = Self.signingDetails(event.signingOutput, permit: permit)
                observed.withLock { $0.outcome = outcome }
            }
            inherited.event(event)
        })
        let result = await AuthorityExecutionHooks.$current.withValue(hooks) { await base.sign() }
        let remaining = observed.withLock { state -> [String: HarnessValue]? in
            guard state.before, !state.after else { return nil }
            state.after = true
            return state.outcome
        }
        if let remaining {
            do { try await ipc.checkpoint("signer.after", details: details.merging(remaining)) }
            catch { return .failure(.authorizationUnavailable) }
        }
        return result
    }

    private static func signingDetails(_ output: WalletSigningOutput?, permit: ExtensionBridge.ApprovedExecutionPermit) -> [String: HarnessValue] {
        guard let output else { return ["succeeded": .bool(false)] }
        var outcome: [String: HarnessValue] = ["succeeded": .bool(true)]
        switch output {
        case .broadcast(let broadcast):
            switch broadcast.transaction {
            case .ethereum(let signed, let hash, _):
                outcome["transactionID"] = .string(hash)
                outcome["signedTransaction"] = .string(signed)
                outcome["encoding"] = .string("hex")
            case .solana(let signed, let signature, _, _, _):
                outcome["transactionID"] = .string(signature)
                outcome["signedTransaction"] = .string(signed)
                outcome["encoding"] = .string("base64")
            }
        case .response(let completion):
            guard let response = completion.response(for: permit), let value = try? HarnessValue.convert(response.json) else {
                preconditionFailure("Signing observation could not read its execution-bound response")
            }
            outcome["response"] = value
        }
        return outcome
    }

    func invalidate() { base.invalidate() }
}

struct HarnessBroadcastSender: SignedTransactionBroadcasting {
    let ipc: HarnessIPC
    let clock: HarnessClock

    func broadcast(_ request: BroadcastRequest) async -> BroadcastResult {
        guard let context = AuthorityExecutionContext.current, let executionID = context.executionID else {
            preconditionFailure("Broadcast dispatch has no authority execution context")
        }
        let identity = HarnessValue.object([
            "handle": harnessHandle(context.handle),
            "executionID": .string(executionID.uuidString.lowercased()),
            "enqueueAttempt": .string(context.enqueueAttempt),
        ])
        let details: HarnessValue
        let endpoint: URL
        switch request {
        case .ethereum(_, let hash, let network):
            details = identity.merging(["transactionHash": .string(hash)])
            endpoint = network.rpcEndpoint.url
        case .solana(_, let signature, let cluster, let frozenEndpoint, let options):
            endpoint = frozenEndpoint.url
            details = identity.merging([
                "cluster": .string(cluster.rawValue),
                "transactionSignature": .string(signature),
                "confirmationCommitment": options.confirmationCommitment.map { .string($0.rawValue) } ?? .null,
            ])
        }
        let transport = HarnessRPCTransport(ipc: ipc, identity: details, endpoints: [endpoint])
        defer { transport.close() }
        let rpc = EthereumRPC(urlSession: transport.session, authorizationProvider: HarnessRejectAuthorization(),
            waitForRetry: { [clock] in try await clock.sleep(for: 500_000_000) })
        let ethereum = EthereumBroadcastClient(rpc: rpc)
        let solana = SolanaRPCClient(urlSession: transport.session,
            authorizationProvider: HarnessRejectAuthorization(), timing: .init(now: clock.now,
                sleep: { [clock] duration in try await clock.sleep(until: clock.now().addingTimeInterval(duration)) }),
            messages: .init(failedToSend: AuthorityMessages.testingEnglish[.failedToSend],
                blockhashNotFound: AuthorityMessages.testingEnglish[.solanaBlockhashNotFound]))
        let sender = SignedBroadcastClient(ethereum: ethereum, solana: solana)
        do {
            try await ipc.checkpoint("broadcast.dispatch", details: details)
            return await sender.broadcast(request)
        } catch {
            switch request {
            case .ethereum: return .submissionUnknown(.ethereum(.transport))
            case .solana: return .submissionUnknown(.solana(.unknown))
            }
        }
    }
}

struct HarnessWalletMutator: WalletSourceMutating {
    let store: ExtensionRequestFileStore
    let ipc: HarnessIPC

    func perform<Payload, Result>(preparing: () throws -> PreparedWalletSourceMutation<Payload>,
        beforeCommit: () throws -> Void, commit: (Payload) throws -> Result) throws -> Result {
        try store.perform(preparing: {
            let prepared = try preparing()
            return PreparedWalletSourceMutation(payload: (prepared.payload, prepared.authorityRemovals),
                authorityRemovals: prepared.authorityRemovals)
        }, beforeCommit: beforeCommit) { payload, removals in
            if !removals.isEmpty {
                let values = removals.map { removal -> HarnessValue in
                    switch removal {
                    case .wallet(let id): return .object(["kind": .string("wallet"), "walletID": .string(id)])
                    case .accounts(let accounts):
                        return .object(["kind": .string("accounts"), "accounts": .array(accounts.map { account in
                            .object(["walletID": .string(account.walletID), "coin": .string(account.coin.correspondingInpageProvider.rawValue),
                                "address": .string(account.normalizedAddress), "path": .string(account.derivationPath)])
                        })])
                    }
                }
                try ipc.checkpointSync("revocation.after", details: .object(["allProfiles": .bool(true), "removals": .array(values)]))
            }
            return try commit(payload)
        }
    }
}
