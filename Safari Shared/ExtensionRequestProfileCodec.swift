// ∅ 2026 lil org

import Foundation

struct ExtensionRequestProfileCodec {
    typealias ProfileState = ExtensionRequestProfile.State
    typealias OriginState = ExtensionRequestProfile.OriginState
    typealias ValidatedProfile = ExtensionRequestProfile

    func bind(_ request: SafariRequest, data: Data, authority: ExtensionBridge.AuthoritySnapshot) -> (request: SafariRequest, payload: ExtensionRequestProfile.ActiveRequestPayload)? {
        var raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        raw?["authority"] = authority.version.json
        if case .unknown = request.body {
            var configurations = [[String: Any]]()
            configurations.append([
                "provider": "ethereum",
                "results": authority.ethereumAccount.map { [$0.normalizedAddress] } ?? [],
                "chainId": authority.ethereumChainId,
            ])
            if let account = authority.solanaAccount {
                configurations.append(["provider": "solana", "publicKey": account.normalizedAddress])
            }
            raw?["body"] = ["latestConfigurations": configurations]
        }
        guard let raw, let data = ExtensionBridge.payloadData(raw, options: [.sortedKeys]),
              data.count <= ExtensionBridge.maximumPayloadBytes,
              var bound = SafariRequest(json: raw),
              let body = raw["body"] as? [String: Any] else { return nil }
        switch request.body {
        case .ethereum:
            bound.authorizedAccount = authority.ethereumAccount
        case .solana:
            bound.authorizedAccount = authority.solanaAccount
        case .unknown:
            bound.connectedAccounts = [authority.ethereumAccount, authority.solanaAccount].compactMap { $0 }
        }
        guard let payload = ExtensionRequestProfile.ActiveRequestPayload(request: bound, body: body, favicon: raw["favicon"] as? String) else { return nil }
        return (bound, payload)
    }

    static func interruptionResponseData(for request: SafariRequest?) -> Data? {
        guard let request else { return nil }
        return boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.approvalInterrupted)),
            request: request
        )
    }

    static func expirationResponseData(for request: SafariRequest) -> Data? {
        boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.userRejected)),
            request: request
        )
    }

    private func repairAuthority(
        _ stored: ProfileState,
        expectedIdentifier: UUID?,
        now: Date
    ) -> ValidatedProfile? {
        guard let repair = ExtensionRequestProfile.repairAuthorityState(stored, expectedIdentifier: expectedIdentifier),
              var profile = validate(repair.state, expectedIdentifier: expectedIdentifier) else { return nil }
        for key in repair.invalidOrigins {
            guard profile.invalidateStaleRequests(configurationKey: key, excluding: nil, now: now) else { return nil }
        }
        return profile
    }

    private func validate(
        _ profile: ProfileState,
        expectedIdentifier: UUID?
    ) -> ValidatedProfile? {
        let active = profile.records.filter(\.state.isActive)
        guard profile.schemaVersion == ExtensionRequestProfile.profileSchemaVersion,
              profile.workflowVersion == ExtensionBridge.workflowVersion,
              profile.profileIdentifier == expectedIdentifier,
              profile.invalidOrigins.isEmpty, !profile.invalidOriginsContainer,
              profile.authoritySequence >= 0, profile.authoritySequence <= ExtensionRequestProfile.maximumRevision,
              profile.origins.count <= ExtensionRequestProfile.maximumOrigins,
              (try? Self.encode(profile.origins).count).map({ $0 <= ExtensionRequestProfile.maximumAuthorityBytes }) == true,
              profile.mutationReceipts.count <= ExtensionRequestProfile.maximumMutationReceipts,
              Set(profile.mutationReceipts.map(\.attempt)).count == profile.mutationReceipts.count,
              profile.mutationReceipts.allSatisfy({ receipt in
                  ExtensionRequestProfile.validConfigurationKey(receipt.configurationKey) &&
                    (receipt.provider == .ethereum || receipt.provider == .solana) &&
                    ExtensionBridge.isValidEnqueueAttempt(receipt.attempt) &&
                    receipt.createdAt.timeIntervalSince1970.isFinite &&
                    receipt.expected.context == ExtensionRequestProfile.authoritySnapshot(profile, configurationKey: receipt.configurationKey).version.context &&
                    profile.origins[receipt.configurationKey] != nil
              }),
              (try? Self.encode(profile.mutationReceipts).count).map({ $0 <= ExtensionRequestProfile.maximumMutationReceiptBytes }) == true,
              profile.origins.allSatisfy({ key, origin in
                  ExtensionRequestProfile.validConfigurationKey(key) && ExtensionRequestProfile.validOrigin(origin, sequence: profile.authoritySequence)
              }),
              active.count <= ExtensionBridge.maximumRequests,
              Dictionary(grouping: active, by: \.configurationKey).values.allSatisfy({
                  $0.count <= ExtensionBridge.maximumRequestsPerHost
              }),
              Set(profile.records.map(\.requestToken)).count == profile.records.count,
              Set(profile.records.map(\.nativeDeliveryNonce)).count ==
                profile.records.count,
              Set(profile.records.flatMap {
                  [$0.requestToken, $0.nativeDeliveryNonce.value]
              }).count == profile.records.count * 2,
              Set(profile.records.map(\.enqueueAttempt)).count == profile.records.count else {
            return nil
        }
        for record in profile.records {
            guard record.profileIdentifier == expectedIdentifier,
                  !record.host.isEmpty,
                  record.authority.context == ExtensionRequestProfile.authoritySnapshot(profile, configurationKey: record.configurationKey).version.context,
                  record.authorizedAccount.map(\.isValid) ?? true,
                  record.revisions.ethereum <= profile.authoritySequence,
                  record.revisions.solana <= profile.authoritySequence,
                  (record.claimedApproval?.deadline).map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  profile.origins[record.configurationKey] != nil,
                  ExtensionBridge.isValidIdentity(
                      host: record.host,
                      configurationKey: record.configurationKey
                  ),
                  ExtensionBridge.isValidEnqueueAttempt(record.enqueueAttempt),
                  record.createdAt <= record.admissionCreatedAt,
                  record.nativeApproval.map({
                      $0.approvedAt.timeIntervalSince1970.isFinite &&
                        $0.approvedAt >= record.createdAt
                  }) ?? true,
                  record.nativeExecutionContext.map({ context in
                      context.observedAt.timeIntervalSince1970.isFinite &&
                        context.executionDeadline.timeIntervalSince1970.isFinite &&
                        record.nativeApproval.map {
                            context.observedAt >= $0.approvedAt
                      } == true &&
                        context.executionDeadline >= context.observedAt
                  }) ?? true,
                  record.nativeDeliveryReceipt.map({
                      $0.nativeDeliveryNonce == record.nativeDeliveryNonce &&
                        $0.owner.isValid
                  }) ?? true else {
                return nil
            }
            if let payload = record.state.request {
                guard let object = payload.wireObject(for: record),
                      let data = ExtensionBridge.payloadData(object, options: [.sortedKeys]),
                      data.count <= ExtensionBridge.maximumPayloadBytes,
                      ExtensionBridge.correlationFingerprint(object) == record.requestFingerprint,
                      ExtensionBridge.admissionDeadlineDisposition(
                          payload.request(for: record).admissionDeadline,
                          now: record.admissionCreatedAt
                      ) == .admissible else {
                    return nil
                }
            }
            if let responseData = record.state.responseData,
               Self.responseJSON(responseData, id: record.id) == nil {
                return nil
            }
            switch record.state {
            case .completed(let since, _, _):
                guard since >= record.createdAt else { return nil }
            case .pending, .claimed, .broadcastPrepared:
                break
            }
        }
        return ValidatedProfile(state: profile)
    }

    static func boundedResponseData(
        _ response: ResponseToExtension,
        request: SafariRequest,
        recoveryResponseData: Data? = nil
    ) -> Data? {
        if let data = exactResponseData(response) { return data }
        if let recoveryResponseData { return recoveryResponseData }
        var fallback = ResponseToExtension(
            for: request,
            payload: .error(.internalError)
        )
        if response.approvalCommitted {
            fallback = fallback.markingApprovalCommitted()
        }
        return exactResponseData(fallback)
    }

    static func exactResponseData(_ response: ResponseToExtension) -> Data? {
        guard let data = ExtensionBridge.payloadData(response.json, options: [.sortedKeys]),
              data.count <= ExtensionBridge.maximumPayloadBytes,
              responseJSON(data, id: response.id) != nil else { return nil }
        return data
    }

    static func responseJSON(_ data: Data, id: Int) -> [String: Any]? {
        guard data.count <= ExtensionBridge.maximumPayloadBytes,
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decoded = ResponseToExtension(json: response),
              decoded.id == id else { return nil }
        return decoded.json
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    struct DecodedProfile {
        let profile: ExtensionRequestProfile
        let requiresAuthorityPublication: Bool
    }

    func decodeProfile(
        _ data: Data,
        expectedIdentifier: UUID?,
        recoverAuthority: Bool,
        now: Date
    ) -> DecodedProfile? {
        guard var state = try? PropertyListDecoder().decode(ProfileState.self, from: data),
              state.authoritySequence >= 0,
              state.authoritySequence <= ExtensionRequestProfile.maximumRevision else { return nil }
        for record in state.records {
            switch record.state {
            case .pending, .claimed:
                if ExtensionRequestProfile.authorityStatus(record, in: state) == .inconsistentGrant {
                    state.invalidOrigins.insert(record.configurationKey)
                }
            case .broadcastPrepared, .completed:
                break
            }
        }
        if let profile = validate(state, expectedIdentifier: expectedIdentifier) {
            return DecodedProfile(profile: profile, requiresAuthorityPublication: false)
        }
        guard recoverAuthority,
              let repaired = repairAuthority(state, expectedIdentifier: expectedIdentifier, now: now) else {
            return nil
        }
        return DecodedProfile(profile: repaired, requiresAuthorityPublication: true)
    }

    static func profileData(_ profile: ExtensionRequestProfile) -> Data? {
        guard let authorityData = try? encode(profile.state.origins),
              authorityData.count <= ExtensionRequestProfile.maximumAuthorityBytes,
              let data = try? encode(profile.state),
              data.count <= ExtensionRequestProfile.maximumProfileBytes else { return nil }
        return data
    }
}
