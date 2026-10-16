import Foundation

func harnessHandle(_ handle: ExtensionBridge.Handle) -> HarnessValue {
    .object(["id": .number(Double(handle.id)), "token": .string(handle.requestToken),
        "profileIdentifier": handle.profileIdentifier.map { .string($0.uuidString.lowercased()) } ?? .null])
}

func harnessDecodeHandle(_ value: HarnessValue) throws -> ExtensionBridge.Handle {
    guard let id = value["id"].int,
          let token = value["token"].string ?? value["requestToken"].string,
          let handle = ExtensionBridge.Handle(id: id, requestToken: token,
            profileIdentifier: value["profileIdentifier"].string.flatMap(UUID.init(uuidString:))) else {
        throw HarnessError.invalid("Invalid request handle")
    }
    return handle
}

final class HarnessObservedStore: NativeApprovalStore, NativeDeliveryStore, NativeMessageBridge {
    let bridge: ExtensionBridge
    let ipc: HarnessIPC

    init(bridge: ExtensionBridge, ipc: HarnessIPC) {
        self.bridge = bridge
        self.ipc = ipc
    }

    private func perform<Value: Sendable>(
        _ name: String,
        handle: ExtensionBridge.Handle,
        after: String? = nil,
        extra: HarnessValue = .object([:]),
        successful: @Sendable (Value) -> Bool = { _ in true },
        _ operation: @Sendable () async -> Value
    ) async throws -> Value {
        try await HarnessOperation.$name.withValue(name) {
            try await HarnessOperation.$identity.withValue(harnessHandle(handle)) {
                let details = extra.merging(["handle": harnessHandle(handle)])
                try await ipc.checkpoint(name + ".before", details: details)
                let value = await operation()
                if successful(value) { try await ipc.checkpoint(after ?? name + ".after", details: details) }
                return value
            }
        }
    }

    func authorityIsCurrent(handle: ExtensionBridge.Handle) async -> Bool { await bridge.authorityIsCurrent(handle: handle) }
    func list(profileIdentifier: UUID?) async -> ExtensionBridge.SnapshotsResult { await bridge.list(profileIdentifier: profileIdentifier) }
    func load(handle: ExtensionBridge.Handle) async -> ExtensionBridge.SnapshotResult { await bridge.load(handle: handle) }

    func claim(handle: ExtensionBridge.Handle) async -> ExtensionBridge.ApprovalClaimResult {
        do { return try await perform("claim", handle: handle, successful: { if case .claimed = $0 { true } else { false } }) {
            await self.bridge.claim(handle: handle)
        } }
        catch { return .unavailable }
    }

    func claimNativeExecution(consent: ReviewConsent) async -> ExtensionBridge.NativeExecutionClaimResult {
        do { return try await perform("claim", handle: consent.binding.handle,
            successful: { if case .claimed = $0 { true } else { false } }) {
            await self.bridge.claimNativeExecution(consent: consent)
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

    func completeImmediate(handle: ExtensionBridge.Handle, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.completeImmediate(handle: handle, resolution: resolution)
        } }
        catch { return .retryablePersistenceFailure }
    }

    func reject(handle: ExtensionBridge.Handle) async -> ExtensionBridge.StoreMutationResult {
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

    func recordNativeDeliveryReceipt(handle: ExtensionBridge.Handle, nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        owner: ExtensionBridge.NativeDeliveryOwner) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("receipt", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.recordNativeDeliveryReceipt(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce, owner: owner)
        } } catch { return .retryablePersistenceFailure }
    }

    func interruptNativeApproval(handle: ExtensionBridge.Handle, nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID) async -> ExtensionBridge.NativeInterruptionResult {
        do { return try await perform("interrupt", handle: handle) {
            await self.bridge.interruptNativeApproval(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier)
        } } catch { return .retryablePersistenceFailure }
    }

    func completeNativeImmediate(handle: ExtensionBridge.Handle, nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID, resolution: ImmediateResolution) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("completion", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.completeNativeImmediate(handle: handle, nativeDeliveryNonce: nativeDeliveryNonce,
                runtimeInstanceIdentifier: runtimeInstanceIdentifier, resolution: resolution)
        } } catch { return .retryablePersistenceFailure }
    }

    func rejectNativeDelivery(handle: ExtensionBridge.Handle, nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce,
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

    func revoke(configurationKey: String, provider: InpageProvider, attempt: String, expected: ExtensionBridge.AuthorityVersion,
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

    func acknowledgeResponse(handle: ExtensionBridge.Handle, configurationKey: String) async -> ExtensionBridge.StoreMutationResult {
        do { return try await perform("acknowledgement", handle: handle, successful: { $0 == .persisted }) {
            await self.bridge.acknowledgeResponse(handle: handle, configurationKey: configurationKey)
        } } catch { return .retryablePersistenceFailure }
    }

    func prepareDelivery(handle: ExtensionBridge.Handle, configurationKey: String) async -> ExtensionBridge.ResponseReadResult {
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
        do {
            try await ipc.checkpoint("signer.before", details: details)
            let result = await base.sign()
            var outcome: [String: HarnessValue] = ["succeeded": .bool(false)]
            if case .success(let output) = result {
                outcome["succeeded"] = .bool(true)
                switch output {
                case .broadcast(let broadcast):
                    switch broadcast.transaction {
                    case .ethereum(let signed, let hash, _):
                        outcome["transactionID"] = .string(hash)
                        outcome["signedTransaction"] = .string(signed)
                        outcome["encoding"] = .string("hex")
                    case .solana(let signed, let signature, _, _):
                        outcome["transactionID"] = .string(signature)
                        outcome["signedTransaction"] = .string(signed)
                        outcome["encoding"] = .string("base64")
                    }
                case .response(let completion):
                    guard let response = completion.response(for: permit) else {
                        return .failure(.authorizationUnavailable)
                    }
                    outcome["response"] = try HarnessValue.convert(response.json)
                }
            }
            try await ipc.checkpoint("signer.after", details: details.merging(outcome))
            return result
        } catch { return .failure(.authorizationUnavailable) }
    }

    func invalidate() { base.invalidate() }
}

struct HarnessBroadcastSender: ApprovedBroadcastSending {
    let ipc: HarnessIPC
    let identity: HarnessValue
    let clock: HarnessClock

    func sendEthereum(signedTransaction: String, network: ResolvedEthereumNetwork) async -> Result<String, EthereumSendFailure> {
        let details = identity.merging([
            "transactionHash": Ethereum.transactionHash(signedTransaction: signedTransaction).map(HarnessValue.string) ?? .null,
        ])
        let transport = HarnessRPCTransport(ipc: ipc, identity: details, endpoints: [network.rpcEndpoint.url])
        defer { transport.close() }
        let rpc = EthereumRPC(urlSession: transport.session, authorizationProvider: HarnessRejectAuthorization(),
            waitForRetry: { [clock] in try await clock.sleep(for: 500_000_000) })
        let ethereum = Ethereum(rpc: rpc, interpretTransaction: { _ in
            throw HarnessError.invalid("Unexpected transaction interpretation during broadcast")
        })
        let sender = DappBroadcastSender(ethereum: ethereum)
        do {
            try await ipc.checkpoint("broadcast.dispatch", details: details)
            return await sender.sendEthereum(signedTransaction: signedTransaction, network: network)
        } catch { return .failure(.transport) }
    }

    func sendSolana(signedTransaction: String, cluster: Solana.Cluster,
        options: Solana.PreparedSendOptions) async -> Result<String, Solana.SendTransactionError> {
        let configuration = Solana.RPCConfiguration(trustsAlchemyURLBuilderOutput: false,
            urlBuilder: { URL(string: "https://solana.fixture.invalid/" + $0) })
        guard let endpoint = configuration.endpoint(for: cluster) else { return .failure(.rpcUnavailable) }
        let details = identity.merging([
            "cluster": .string(cluster.rawValue),
            "transactionSignature": Solana.transactionSignature(signedTransaction: signedTransaction).map(HarnessValue.string) ?? .null,
            "confirmationCommitment": options.confirmationCommitment.map { .string($0.rawValue) } ?? .null,
        ])
        let transport = HarnessRPCTransport(ipc: ipc, identity: details, endpoints: [endpoint.url])
        defer { transport.close() }
        let solana = Solana(urlSession: transport.session, rpcConfiguration: configuration,
            authorizationProvider: HarnessRejectAuthorization(), timing: .init(now: clock.now,
                sleep: { [clock] duration in try await clock.sleep(until: clock.now().addingTimeInterval(duration)) }))
        let sender = DappBroadcastSender(solana: solana)
        do {
            try await ipc.checkpoint("broadcast.dispatch", details: details)
            return await sender.sendSolana(signedTransaction: signedTransaction, cluster: cluster, options: options)
        } catch { return .failure(.unknown) }
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
