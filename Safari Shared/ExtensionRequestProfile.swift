// ∅ 2026 lil org

import Foundation
import CryptoKit

struct ExtensionRequestProfile {
    var state: State

    func request(for record: Record) -> SafariRequest? {
        guard let payload = record.state.request else { return nil }
        var request = payload.request(for: record)
        if case .unknown = request.body {
            let authority = Self.authoritySnapshot(state, configurationKey: record.configurationKey)
            if record.authority == authority.version {
                request.connectedAccounts = [authority.ethereumAccount, authority.solanaAccount].compactMap { $0 }
            }
        }
        return request
    }

    mutating func complete(at index: Int, response: Data, date: Date) {
        state.records[index].complete(response: response, at: date)
    }

    struct ActiveRequestPayload: Codable {
        let name: String
        let provider: InpageProvider
        let favicon: String?
        let admissionDeadlineMilliseconds: Int
        let bodyData: Data
        let body: SafariRequest.Body

        private enum CodingKeys: String, CodingKey {
            case name, provider, favicon, admissionDeadlineMilliseconds, bodyData
        }

        init?(request: SafariRequest, body: [String: Any], favicon: String?) {
            guard let bodyData = ExtensionBridge.payloadData(body, options: [.sortedKeys]) else { return nil }
            name = request.name
            provider = request.provider
            self.favicon = favicon
            admissionDeadlineMilliseconds = request.admissionDeadlineMilliseconds
            self.bodyData = bodyData
            self.body = request.body
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            provider = try values.decode(InpageProvider.self, forKey: .provider)
            favicon = try values.decodeIfPresent(String.self, forKey: .favicon)
            admissionDeadlineMilliseconds = try values.decode(Int.self, forKey: .admissionDeadlineMilliseconds)
            bodyData = try values.decode(Data.self, forKey: .bodyData)
            guard admissionDeadlineMilliseconds > 0,
                  admissionDeadlineMilliseconds <= 9_007_199_254_740_991,
                  bodyData.count <= ExtensionBridge.maximumPayloadBytes,
                  let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let body = SafariRequest.Body(provider: provider, name: name, json: object) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid active request payload"))
            }
            self.body = body
        }

        func request(for record: Record) -> SafariRequest {
            SafariRequest(
                id: record.id,
                name: name,
                provider: provider,
                body: body,
                host: record.host,
                configurationKey: record.configurationKey,
                favicon: SafariRequest.normalizedFavicon(favicon, host: record.host),
                enqueueAttempt: record.enqueueAttempt,
                admissionDeadlineMilliseconds: admissionDeadlineMilliseconds,
                authority: record.authority,
                authorizedAccount: record.authorizedAccount
            )
        }

        func wireObject(for record: Record) -> [String: Any]? {
            guard let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { return nil }
            var object: [String: Any] = [
                "id": record.id,
                "name": name,
                "provider": provider.rawValue,
                "body": body,
                "host": record.host,
                "configurationKey": record.configurationKey,
                "enqueueAttempt": record.enqueueAttempt,
                "admissionDeadline": admissionDeadlineMilliseconds,
                "authority": record.authority.json,
                "workflowVersion": ExtensionBridge.workflowVersion,
            ]
            object["favicon"] = favicon
            return object
        }
    }

    struct State: Codable {
        let schemaVersion: Int
        let workflowVersion: Int
        let profileIdentifier: UUID?
        let authorityEpoch: UUID
        var authoritySequence: Int
        var origins: [String: OriginState]
        var mutationReceipts: [MutationReceipt]
        var records: [Record]
        var invalidOrigins = Set<String>()
        var invalidOriginsContainer = false

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, workflowVersion, profileIdentifier, authorityEpoch
            case authoritySequence, origins, mutationReceipts, records
        }

        init(profileIdentifier: UUID?, authorityEpoch: UUID) {
            schemaVersion = ExtensionRequestProfile.profileSchemaVersion
            workflowVersion = ExtensionBridge.workflowVersion
            self.profileIdentifier = profileIdentifier
            self.authorityEpoch = authorityEpoch
            authoritySequence = 0
            origins = [:]
            mutationReceipts = []
            records = []
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            workflowVersion = try values.decode(Int.self, forKey: .workflowVersion)
            profileIdentifier = try values.decodeIfPresent(UUID.self, forKey: .profileIdentifier)
            authorityEpoch = try values.decode(UUID.self, forKey: .authorityEpoch)
            authoritySequence = try values.decode(Int.self, forKey: .authoritySequence)
            mutationReceipts = try values.decode([MutationReceipt].self, forKey: .mutationReceipts)
            records = try values.decode([Record].self, forKey: .records)
            if let decodedOrigins = try? values.decode([String: DecodedOrigin].self, forKey: .origins) {
                origins = decodedOrigins.compactMapValues(\.value)
                invalidOrigins = Set(decodedOrigins.filter { $0.value.value == nil }.keys)
            } else {
                origins = [:]
                invalidOriginsContainer = true
            }
        }
    }

    struct DecodedOrigin: Decodable {
        let value: OriginState?

        init(from decoder: Decoder) throws {
            value = try? OriginState(from: decoder)
        }
    }

    struct OriginState: Codable {
        var ethereumAccount: WalletAccountDescriptor?
        var ethereumChainId = "0x1"
        var solanaAccount: WalletAccountDescriptor?
        var revisions: ExtensionBridge.ProviderRevisions

        var isDefaultDisconnected: Bool {
            ethereumAccount == nil && solanaAccount == nil && ethereumChainId == "0x1"
        }
    }

    struct MutationReceipt: Codable {
        let configurationKey: String
        let provider: InpageProvider
        let attempt: String
        let expected: ExtensionBridge.AuthorityVersion
        let createdAt: Date
    }

    struct Record: Codable {
        struct NativeApproval: Codable {
            let approvedAt: Date
            let receipt: ExtensionBridge.NativeDeliveryReceipt
        }

        enum PendingApproval: Codable {
            case unowned
            case delivered(ExtensionBridge.NativeDeliveryReceipt)
        }

        enum ClaimedApproval: Codable {
            case ordinary(deadline: Date)
            case native(NativeApproval, context: ExtensionBridge.NativeExecutionContext)

            var deadline: Date {
                switch self {
                case .ordinary(let deadline): return deadline
                case .native(_, let context): return context.executionDeadline
                }
            }

            var broadcast: BroadcastApproval {
                switch self {
                case .ordinary:
                    return .ordinary
                case .native(let approval, _):
                    return .native(approval)
                }
            }
        }

        enum BroadcastApproval: Codable {
            case ordinary
            case native(NativeApproval)
        }

        enum State: Codable {
            case pending(request: ActiveRequestPayload, approval: PendingApproval)
            case claimed(claimID: UUID, request: ActiveRequestPayload, approval: ClaimedApproval)
            case broadcastPrepared(
                claimID: UUID,
                request: ActiveRequestPayload,
                recoveryResponse: Data,
                approval: BroadcastApproval
            )
            case completed(since: Date, response: Data, acknowledged: Bool)

            var request: ActiveRequestPayload? {
                switch self {
                case .pending(let request, _), .claimed(_, let request, _),
                     .broadcastPrepared(_, let request, _, _):
                    return request
                case .completed:
                    return nil
                }
            }

            var responseData: Data? {
                switch self {
                case .broadcastPrepared(_, _, let response, _),
                     .completed(_, let response, _):
                    return response
                case .pending, .claimed:
                    return nil
                }
            }

            var isActive: Bool {
                switch self {
                case .pending, .claimed, .broadcastPrepared:
                    return true
                case .completed:
                    return false
                }
            }
        }

        let id: Int
        let profileIdentifier: UUID?
        let enqueueAttempt: String
        let requestToken: UUID
        let host: String
        let configurationKey: String
        let requestFingerprint: Data
        let authority: ExtensionBridge.AuthorityVersion
        let authorizedAccount: WalletAccountDescriptor?
        var revisions: ExtensionBridge.ProviderRevisions { authority.revisions }
        let admissionCreatedAt: Date
        var createdAt: Date
        var state: State
        let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce

        var nativeApproval: NativeApproval? {
            switch state {
            case .claimed(_, _, .native(let approval, _)),
                 .broadcastPrepared(_, _, _, .native(let approval)):
                return approval
            case .pending, .claimed, .broadcastPrepared, .completed:
                return nil
            }
        }

        var nativeDeliveryReceipt: ExtensionBridge.NativeDeliveryReceipt? {
            if case .pending(_, .delivered(let receipt)) = state {
                return receipt
            }
            return nativeApproval?.receipt
        }

        var nativeExecutionContext: ExtensionBridge.NativeExecutionContext? {
            switch state {
            case .claimed(_, _, .native(_, let context)):
                return context
            case .pending, .claimed, .broadcastPrepared, .completed:
                return nil
            }
        }

        var claimedApproval: ClaimedApproval? {
            guard case .claimed(_, _, let approval) = state else { return nil }
            return approval
        }

        func authorizesExecution(
            authority: ExtensionBridge.ExecutionAuthority,
            now: Date,
            isCancelled: Bool
        ) -> Bool {
            switch authority {
            case .ordinary:
                if case .broadcastPrepared = state { return true }
                guard case .claimed(_, _, .ordinary(let deadline)) = state else { return false }
                return ExtensionRequestProfile.executionDeadlineIsCurrent(deadline, now: now)
            case .mobileSigning(let deadline):
                guard case .claimed(_, _, .ordinary(let claimedDeadline)) = state else { return false }
                return deadline == claimedDeadline && ExtensionRequestProfile.executionDeadlineIsCurrent(deadline, now: now)
            case .native(let expected):
                return !isCancelled && nativeExecutionContext == expected &&
                    now >= expected.observedAt &&
                    now < expected.executionDeadline
            }
        }


        var responseAcknowledged: Bool {
            guard case .completed(_, _, let acknowledged) = state else {
                return false
            }
            return acknowledged
        }

        var handle: ExtensionBridge.Handle {
            ExtensionBridge.Handle(
                id: id,
                token: .init(value: requestToken),
                profileIdentifier: profileIdentifier
            )
        }

        mutating func claim(id: UUID, approval: ClaimedApproval) -> Bool {
            guard case .pending(let request, let pendingApproval) = state else { return false }
            switch (pendingApproval, approval) {
            case (.unowned, .ordinary):
                break
            case (.delivered(let receipt), .native(let native, _)) where receipt == native.receipt:
                break
            default:
                return false
            }
            state = .claimed(claimID: id, request: request, approval: approval)
            return true
        }

        mutating func prepareBroadcast(recoveryResponse: Data) -> Bool {
            guard case .claimed(let claimID, let request, let approval) = state else { return false }
            state = .broadcastPrepared(
                claimID: claimID, request: request,
                recoveryResponse: recoveryResponse, approval: approval.broadcast
            )
            return true
        }

        enum DeliveryChange {
            case changed, unchanged, ownershipLost
        }

        mutating func recordDeliveryReceipt(_ receipt: ExtensionBridge.NativeDeliveryReceipt) -> DeliveryChange {
            guard case .pending(let request, _) = state,
                  receipt.nativeDeliveryNonce == nativeDeliveryNonce else { return .ownershipLost }
            if let existing = nativeDeliveryReceipt {
                return existing == receipt ? .unchanged : .ownershipLost
            }
            state = .pending(request: request, approval: .delivered(receipt))
            return .changed
        }

        mutating func clearDeliveryReceipt(
            nonce: ExtensionBridge.NativeDeliveryNonce,
            runtimeInstanceIdentifier: UUID
        ) -> DeliveryChange {
            guard case .pending(let request, _) = state,
                  nativeDeliveryNonce == nonce else { return .ownershipLost }
            guard let existing = nativeDeliveryReceipt else { return .unchanged }
            guard existing.matches(nativeDeliveryNonce: nonce, runtimeInstanceIdentifier: runtimeInstanceIdentifier) else {
                return .ownershipLost
            }
            state = .pending(request: request, approval: .unowned)
            return .changed
        }

        enum Acknowledgment {
            case recorded, alreadyRecorded, notCompleted
        }

        mutating func acknowledgeResponse() -> Acknowledgment {
            guard case .completed(let since, let response, let acknowledged) = state else { return .notCompleted }
            guard !acknowledged else { return .alreadyRecorded }
            state = .completed(since: since, response: response, acknowledged: true)
            return .recorded
        }

        @discardableResult
        mutating func restorePendingClaim() -> Bool {
            guard case .claimed(_, let request, .ordinary) = state else {
                return false
            }
            state = .pending(request: request, approval: .unowned)
            return true
        }

        mutating func complete(response: Data, at date: Date) {
            state = .completed(
                since: max(createdAt, date),
                response: response,
                acknowledged: false
            )
        }
    }

    enum PendingDeadlineTransition {
        case active(SafariRequest), expired, unavailable
    }

    enum AuthorityStatus { case current, stale, inconsistentGrant }

    static let profileSchemaVersion = 9
    static let maximumProfileBytes =
        ExtensionBridge.maximumRetainedBytes + ExtensionRequestProfile.maximumAuthorityBytes + ExtensionRequestProfile.maximumMutationReceiptBytes + 64 * 1024
    static let maximumOrigins = 512
    static let maximumAuthorityBytes = 1_024 * 1_024
    static let maximumMutationReceipts = 256
    static let maximumMutationReceiptBytes = 256 * 1_024
    static let mutationReceiptLifetime: TimeInterval = 60 * 60
    static let maximumRevision = 9_007_199_254_740_991
    static let executionLifetime: TimeInterval = 150
    static let futureSkew = ExtensionBridge.admissionDeadlineFutureSkew

    struct ReceiptIdentity {
        let nativeDeliveryNonce: ExtensionBridge.NativeDeliveryNonce
        let runtimeInstanceIdentifier: UUID
    }

    static func removalInvalidates(_ request: SafariRequest, matching removal: WalletAuthorityRemoval) -> Bool {
        switch request.body {
        case .ethereum(let body):
            switch body.method {
            case .requestAccounts:
                return request.authorizedAccount.map(removal.matches) ?? true
            case .signMessage, .signPersonalMessage, .signTypedMessage, .signTransaction:
                return request.authorizedAccount.map(removal.matches) == true
            case .addEthereumChain, .switchEthereumChain, .ecRecover:
                return false
            }
        case .solana(let body):
            if body.method == .connect {
                return request.authorizedAccount.map(removal.matches) ?? true
            }
            return request.authorizedAccount.map(removal.matches) == true
        case .unknown:
            return true
        }
    }

    static func validConfigurationKey(_ value: String) -> Bool {
        guard value.utf8.count <= 4_096, let url = URL(string: value) else { return false }
        let host: String
        if url.scheme == "file" { host = value }
        else if let separator = value.range(of: "://") { host = String(value[separator.upperBound...]) }
        else { return false }
        return ExtensionBridge.isValidIdentity(host: host, configurationKey: value)
    }

    static func revisions(ethereum: Int, solana: Int) -> ExtensionBridge.ProviderRevisions {
        ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": ethereum, "solana": solana])!
    }

    static func authoritySnapshot(_ profile: State, configurationKey: String) -> ExtensionBridge.AuthoritySnapshot {
        let origin = profile.origins[configurationKey]
        let context = Data(SHA256.hash(data: Data(
            (profile.authorityEpoch.uuidString.lowercased() + "\n" + configurationKey).utf8
        ))).map { String(format: "%02x", $0) }.joined()
        return .init(
            version: .init(context: context, revisions: origin?.revisions ?? revisions(
                ethereum: profile.authoritySequence, solana: profile.authoritySequence
            )),
            ethereumAccount: origin?.ethereumAccount,
            ethereumChainId: origin?.ethereumChainId ?? "0x1",
            solanaAccount: origin?.solanaAccount
        )
    }

    static func authorityMatches(
        _ expected: ExtensionBridge.AuthorityVersion,
        current: ExtensionBridge.AuthorityVersion,
        provider: InpageProvider,
        requestName: String? = nil
    ) -> Bool {
        guard expected.context == current.context else { return false }
        if provider == .ethereum && requestName == SafariRequest.Ethereum.Method.ecRecover.rawValue {
            return true
        }
        switch provider {
        case .ethereum: return expected.revisions.ethereum == current.revisions.ethereum
        case .solana: return expected.revisions.solana == current.revisions.solana
        case .unknown, .multiple: return expected.revisions == current.revisions
        }
    }

    static func authorityIsCurrent(_ record: Record, in profile: State) -> Bool {
        authorityStatus(record, in: profile) == .current
    }

    static func authorityStatus(_ record: Record, in profile: State) -> AuthorityStatus {
        guard let request = record.state.request else { return .stale }
        let provider = request.provider
        let name = request.name
        let snapshot = authoritySnapshot(profile, configurationKey: record.configurationKey)
        guard authorityMatches(record.authority, current: snapshot.version,
                               provider: provider, requestName: name) else { return .stale }
        let account: WalletAccountDescriptor?
        let requiresGrant: Bool
        switch provider {
        case .ethereum:
            guard let method = SafariRequest.Ethereum.Method(rawValue: name) else { return .stale }
            switch method {
            case .ecRecover: return .current
            case .requestAccounts, .addEthereumChain, .switchEthereumChain: requiresGrant = false
            default: requiresGrant = true
            }
            account = snapshot.ethereumAccount
        case .solana:
            requiresGrant = name != SafariRequest.Solana.Method.connect.rawValue
            account = snapshot.solanaAccount
        case .unknown, .multiple:
            return .current
        }
        return (!requiresGrant || account != nil) && record.authorizedAccount == account
            ? .current : .inconsistentGrant
    }

    static func nextRevision(in profile: inout State) -> Int? {
        guard profile.authoritySequence < Self.maximumRevision else { return nil }
        profile.authoritySequence += 1
        return profile.authoritySequence
    }

    @discardableResult
    static func reclaimAuthority(in profile: inout State, now: Date) -> Bool {
        let previousCount = profile.mutationReceipts.count
        profile.mutationReceipts.removeAll { now.timeIntervalSince($0.createdAt) >= Self.mutationReceiptLifetime }
        let referenced = Set(profile.records.map(\.configurationKey) + profile.mutationReceipts.map(\.configurationKey))
        let removable = profile.origins.filter { $0.value.isDefaultDisconnected && !referenced.contains($0.key) }.map(\.key)
        if !removable.isEmpty, nextRevision(in: &profile) != nil {
            for key in removable { profile.origins.removeValue(forKey: key) }
            return true
        }
        return previousCount != profile.mutationReceipts.count
    }

    static func pinOrigin(in profile: inout State, configurationKey: String, now: Date) -> Bool {
        if profile.origins[configurationKey] != nil { return true }
        profile.origins[configurationKey] = .init(revisions: revisions(
            ethereum: profile.authoritySequence, solana: profile.authoritySequence
        ))
        if authorityFits(profile.origins) { return true }
        let referenced = Set(profile.records.map(\.configurationKey) + profile.mutationReceipts.map(\.configurationKey))
        let removable = profile.origins.filter { key, origin in
            key != configurationKey && !referenced.contains(key) &&
                origin.ethereumAccount == nil && origin.solanaAccount == nil
        }.map(\.key).sorted()
        guard !removable.isEmpty, nextRevision(in: &profile) != nil else { return false }
        for key in removable {
            profile.origins.removeValue(forKey: key)
            if authorityFits(profile.origins) { return true }
        }
        return false
    }

    static func authorityFits(_ origins: [String: OriginState]) -> Bool {
        origins.count <= Self.maximumOrigins &&
            (try? ExtensionRequestProfileCodec.encode(origins).count).map { $0 <= Self.maximumAuthorityBytes } == true
    }

    static func requestIsAuthorized(_ request: SafariRequest, by snapshot: ExtensionBridge.AuthoritySnapshot) -> Bool {
        switch request.body {
        case .ethereum(let body):
            switch body.method {
            case .requestAccounts, .addEthereumChain, .switchEthereumChain, .ecRecover:
                return true
            case .signMessage, .signPersonalMessage, .signTypedMessage, .signTransaction:
                guard let account = snapshot.ethereumAccount,
                      account.coin.normalizedAddress(body.address) == account.normalizedAddress else { return false }
                if let chain = body.currentChainId, String.hex(chain, withPrefix: true) != snapshot.ethereumChainId { return false }
                return body.method != .signTransaction || body.currentChainId != nil
            }
        case .solana(let body):
            return body.method == .connect || snapshot.solanaAccount?.normalizedAddress == body.publicKey
        case .unknown:
            return true
        }
    }

    mutating func invalidateStaleRequests(
        configurationKey: String,
        excluding: ExtensionBridge.Handle?,
        now: Date
    ) -> Bool {
        for index in self.state.records.indices {
            let record = self.state.records[index]
            guard record.configurationKey == configurationKey, record.handle != excluding else { continue }
            switch record.state {
            case .pending, .claimed:
                guard !Self.authorityIsCurrent(record, in: self.state) else { continue }
                guard let request = self.request(for: record),
                      let response = ExtensionRequestProfileCodec.boundedResponseData(ResponseToExtension(
                        for: request, payload: .error(.init(message: Strings.providerNotReady, code: 4100))
                      ), request: request) else { return false }
                self.complete(at: index, response: response, date: now)
            case .broadcastPrepared, .completed:
                break
            }
        }
        return true
    }

    mutating func applyAuthorityEffect(
        _ response: ResponseToExtension,
        record: Record,
        now: Date
    ) -> Bool {
        guard let mutation = response.mutation else { return response.approvedAccounts.isEmpty }
        guard var origin = self.state.origins[record.configurationKey] else { return false }
        switch mutation {
        case .accounts(let updates):
            guard let request = self.request(for: record) else { return false }
            switch request.body {
            case .ethereum(let body):
                guard body.method == .requestAccounts, updates.count == 1,
                      updates.first?.provider == .ethereum else { return false }
            case .solana(let body):
                guard body.method == .connect, updates.count == 1,
                      updates.first?.provider == .solana else { return false }
            case .unknown:
                break
            }
            guard Set(updates.map(\.provider)).count == updates.count,
                  response.approvedAccounts.allSatisfy(\.isValid),
                  Set(response.approvedAccounts.map(\.coin)).count == response.approvedAccounts.count else { return false }
            var matched = Set<WalletAccountDescriptor>()
            for update in updates {
                guard let revision = Self.nextRevision(in: &self.state) else { return false }
                switch update {
                case .ethereum(let address, let chainId):
                    guard let account = response.approvedAccounts.first(where: {
                        $0.coin == .ethereum && $0.normalizedAddress == WalletCoin.ethereum.normalizedAddress(address)
                    }), Self.canonicalChainID(chainId) else { return false }
                    origin.ethereumAccount = account
                    origin.ethereumChainId = chainId
                    origin.revisions = Self.revisions(ethereum: revision, solana: origin.revisions.solana)
                    matched.insert(account)
                case .solana(let publicKey):
                    guard let account = response.approvedAccounts.first(where: {
                        $0.coin == .solana && $0.normalizedAddress == publicKey
                    }) else { return false }
                    origin.solanaAccount = account
                    origin.revisions = Self.revisions(ethereum: origin.revisions.ethereum, solana: revision)
                    matched.insert(account)
                case .disconnectEthereum:
                    origin.ethereumAccount = nil
                    origin.revisions = Self.revisions(ethereum: revision, solana: origin.revisions.solana)
                case .disconnectSolana:
                    origin.solanaAccount = nil
                    origin.revisions = Self.revisions(ethereum: origin.revisions.ethereum, solana: revision)
                }
            }
            guard matched == Set(response.approvedAccounts) else { return false }
        case .ethereumChain(let chainId):
            guard let request = self.request(for: record), case .ethereum(let body) = request.body,
                  body.method == .addEthereumChain || body.method == .switchEthereumChain else { return false }
            guard response.approvedAccounts.isEmpty, Self.canonicalChainID(chainId) else { return false }
            guard origin.ethereumChainId != chainId else { return true }
            guard let revision = Self.nextRevision(in: &self.state) else { return false }
            origin.ethereumChainId = chainId
            origin.revisions = Self.revisions(ethereum: revision, solana: origin.revisions.solana)
        case .revokeSolana(let publicKey):
            guard response.approvedAccounts.isEmpty else { return false }
            guard origin.solanaAccount?.normalizedAddress == publicKey else { return true }
            guard let revision = Self.nextRevision(in: &self.state) else { return false }
            origin.solanaAccount = nil
            origin.revisions = Self.revisions(ethereum: origin.revisions.ethereum, solana: revision)
        }
        self.state.origins[record.configurationKey] = origin
        guard (try? ExtensionRequestProfileCodec.encode(self.state.origins).count).map({ $0 <= Self.maximumAuthorityBytes }) == true else { return false }
        return invalidateStaleRequests(configurationKey: record.configurationKey, excluding: record.handle, now: now)
    }

    static func canonicalChainID(_ value: String) -> Bool {
        guard let id = Int(hexString: value), id > 0 else { return false }
        return String.hex(id, withPrefix: true) == value
    }

    static func manualSwitchRequestsFit(
        _ requests: [ExtensionBridge.ManualSwitchRequest]
    ) -> Bool {
        guard requests.count <= ExtensionBridge.maximumRequests else { return false }
        let descriptors = requests.map { request in
            var descriptor = request.json
            descriptor["state"] = ExtensionBridge.ManualSwitchRequestState.completed.rawValue
            return descriptor
        }
        return ExtensionBridge.payloadData([
            "id": Int.min,
            "requests": descriptors,
        ]).map { $0.count <= ExtensionBridge.maximumManualSwitchResponseBytes } ?? false
    }

    static func isManualSwitch(_ record: Record, in profile: ExtensionRequestProfile) -> Bool {
        if let request = profile.request(for: record) {
            return request.name == "switchAccount" && request.provider == .unknown
        }
        return record.state.responseData.flatMap {
            ExtensionRequestProfileCodec.responseJSON($0, id: record.id)
        }?["name"] as? String == "switchAccount"
    }

    static func manualSwitchRequest(_ record: Record) -> ExtensionBridge.ManualSwitchRequest {
        let state: ExtensionBridge.ManualSwitchRequestState
        switch record.state {
        case .completed:
            state = .completed
        case .claimed, .broadcastPrepared:
            state = .approved
        case .pending:
            state = .pending
        }
        return .init(
            handle: record.handle,
            host: record.host,
            configurationKey: record.configurationKey,
            revisions: record.revisions,
            state: state
        )
    }

    mutating func interruptNativeRecord(
        at index: Int,
        now: Date
    ) -> Bool {
        let record = self.state.records[index]
        let response: Data
        switch record.state {
        case .completed:
            return true
        case .broadcastPrepared(_, _, let recoveryResponse, _):
            response = recoveryResponse
        case .pending, .claimed:
            guard let data = ExtensionRequestProfileCodec.interruptionResponseData(for: self.request(for: record)) else {
                return false
            }
            response = data
        }
        self.complete(at: index, response: response, date: now)
        return true
    }

    mutating func transitionExpiredPending(
        at index: Int,
        now: Date
    ) -> PendingDeadlineTransition {
        let request = self.request(for: self.state.records[index])
        return Self.transitionExpiredPending(
            &self.state.records[index],
            request: request,
            now: now
        )
    }

    static func transitionExpiredPending(
        _ record: inout Record,
        request: SafariRequest?,
        now: Date
    ) -> PendingDeadlineTransition {
        guard case .pending = record.state, let request else {
            return .unavailable
        }
        guard request.admissionDeadline <= now else {
            return .active(request)
        }
        guard let responseData = ExtensionRequestProfileCodec.expirationResponseData(for: request) else {
            return .unavailable
        }
        record.complete(response: responseData, at: now)
        return .expired
    }

    static func validOrigin(_ origin: OriginState, sequence: Int) -> Bool {
        canonicalChainID(origin.ethereumChainId) &&
            origin.revisions.ethereum <= sequence && origin.revisions.solana <= sequence &&
            (origin.ethereumAccount.map { $0.isValid && $0.coin == .ethereum } ?? true) &&
            (origin.solanaAccount.map { $0.isValid && $0.coin == .solana } ?? true)
    }

    mutating func normalizeFutureDates(
        now: Date
    ) -> Bool {
        let futureLimit = now.addingTimeInterval(Self.futureSkew)
        var changed = false
        for index in state.records.indices {
            var record = state.records[index]
            if record.createdAt > futureLimit {
                record.createdAt = now
                changed = true
            }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                break
            case .completed(let since, let response, let acknowledged):
                if since > futureLimit {
                    record.state = .completed(
                        since: max(record.createdAt, now),
                        response: response,
                        acknowledged: acknowledged
                    )
                    changed = true
                }
            }
            state.records[index] = record
        }
        return changed
    }

    static func snapshot(
        _ record: Record,
        request: SafariRequest?,
        sequence: Int
    ) -> ExtensionBridge.Snapshot? {
        let state: ExtensionBridge.Snapshot.State
        switch record.state {
        case .pending(_, let approval):
            guard let request else { return nil }
            let queuedApproval: ExtensionBridge.Snapshot.QueuedApproval
            switch approval {
            case .unowned:
                queuedApproval = .unowned
            case .delivered(let receipt):
                queuedApproval = .delivered(receipt)
            }
            state = .queued(request: request, approval: queuedApproval)
        case .claimed, .broadcastPrepared:
            guard let request else { return nil }
            state = .approving(
                request: request,
                nativeApproval: record.nativeApproval.map {
                    .init(receipt: $0.receipt, approvedAt: $0.approvedAt,
                          executionContext: record.nativeExecutionContext)
                }
            )
        case .completed:
            state = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: record.handle,
            state: state,
            nativeDeliveryNonce: record.nativeDeliveryNonce,
            host: record.host,
            configurationKey: record.configurationKey,
            revisions: record.revisions,
            createdAt: record.createdAt,
            enqueueAttempt: record.enqueueAttempt,
            sequence: sequence
        )
    }

    static func makeRoomForAdmission(
        _ incoming: Record,
        in records: inout [Record],
        now: Date
    ) -> [ExtensionBridge.Handle]? {
        guard let incomingBytes = retainedStorageBytes(incoming) else { return nil }
        var totalBytes = incomingBytes
        var originBytes = incomingBytes
        var candidates = [(record: Record, bytes: Int, since: Date, index: Int)]()
        for (index, record) in records.enumerated() {
            guard let bytes = retainedStorageBytes(record) else { return nil }
            totalBytes += bytes
            if record.configurationKey == incoming.configurationKey {
                originBytes += bytes
            }
            if case .completed(let since, let response, let acknowledged) = record.state,
               canRetireAdmissionRecord(record, now: now),
               acknowledged || ExtensionRequestProfileCodec.responseJSON(response, id: record.id)?["name"] as? String != "switchAccount" {
                candidates.append((record, bytes, since, index))
            }
        }
        candidates.sort {
            $0.since == $1.since ? $0.index < $1.index : $0.since < $1.since
        }
        var retired = Set<ExtensionBridge.Handle>()
        for candidate in candidates where
            originBytes > ExtensionBridge.maximumRetainedBytesPerOrigin &&
                candidate.record.configurationKey == incoming.configurationKey {
            retired.insert(candidate.record.handle)
            originBytes -= candidate.bytes
            totalBytes -= candidate.bytes
        }
        guard originBytes <= ExtensionBridge.maximumRetainedBytesPerOrigin else {
            return nil
        }
        for candidate in candidates where
            totalBytes > ExtensionBridge.maximumRetainedBytes &&
                !retired.contains(candidate.record.handle) {
            retired.insert(candidate.record.handle)
            totalBytes -= candidate.bytes
        }
        guard totalBytes <= ExtensionBridge.maximumRetainedBytes else { return nil }
        records.removeAll { retired.contains($0.handle) }
        return Array(retired)
    }

    static func retainedStorageBytes(_ record: Record) -> Int? {
        var metadata = record
        if record.state.isActive {
            metadata.state = .completed(since: record.createdAt, response: Data(), acknowledged: false)
        }
        guard let data = try? ExtensionRequestProfileCodec.encode(metadata) else {
            return nil
        }
        return data.count + (record.state.isActive
            ? ExtensionBridge.maximumStoredRecordBytes + 32 * 1024
            : 0)
    }

    static func canRetireAdmissionRecord(_ record: Record, now: Date) -> Bool {
        let retryWindow = ExtensionBridge.requestTTL + Self.futureSkew
        return record.admissionCreatedAt.addingTimeInterval(retryWindow) <= now
    }

    static func executionDeadlineIsCurrent(_ deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0 && remaining <= Self.executionLifetime
    }

    static func receiptMatches(
        _ receipt: ExtensionBridge.NativeDeliveryReceipt?,
        expected: ReceiptIdentity?
    ) -> Bool {
        guard let expected else { return receipt == nil }
        return receipt?.matches(
            nativeDeliveryNonce: expected.nativeDeliveryNonce,
            runtimeInstanceIdentifier: expected.runtimeInstanceIdentifier
        ) == true
    }

    struct Maintenance {
        let changed: Bool
        let operationLocksToRemove: [ExtensionBridge.Handle]
    }

    mutating func maintain(
        now: Date,
        abandonedHandles: Set<ExtensionBridge.Handle>
    ) -> Maintenance? {
        var changed = false
        var locksToRemove = [ExtensionBridge.Handle]()
        var kept = [Record]()
        for var record in self.state.records {
            switch record.state {
            case .claimed:
                if abandonedHandles.contains(record.handle) {
                    if record.nativeApproval != nil {
                        guard let response = ExtensionRequestProfileCodec.interruptionResponseData(for: self.request(for: record)) else {
                            return nil
                        }
                        record.complete(response: response, at: now)
                    } else {
                        record.restorePendingClaim()
                    }
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .broadcastPrepared(_, _, let recoveryResponse, _):
                if abandonedHandles.contains(record.handle) {
                    record.complete(response: recoveryResponse, at: now)
                    changed = true
                    locksToRemove.append(record.handle)
                }
            case .pending, .completed:
                break
            }
            switch record.state {
            case .pending:
                let request = self.request(for: record)
                switch Self.transitionExpiredPending(
                    &record,
                    request: request,
                    now: now
                ) {
                case .active:
                    break
                case .expired:
                    changed = true
                    if !locksToRemove.contains(record.handle) {
                        locksToRemove.append(record.handle)
                    }
                case .unavailable:
                    return nil
                }
                kept.append(record)
            case .completed(let since, _, _):
                if now.timeIntervalSince(since) >= ExtensionBridge.responseExpiry,
                   ExtensionRequestProfile.canRetireAdmissionRecord(record, now: now) {
                    changed = true
                    locksToRemove.append(record.handle)
                } else {
                    kept.append(record)
                }
            case .claimed, .broadcastPrepared:
                kept.append(record)
            }
        }
        self.state.records = kept
        changed = Self.reclaimAuthority(in: &state, now: now) || changed
        return Maintenance(changed: changed, operationLocksToRemove: locksToRemove)
    }

    mutating func revokeWalletAuthority(matching removal: WalletAuthorityRemoval, now: Date) -> Bool? {
        var changedOrigins = [String]()
        for key in self.state.origins.keys.sorted() {
            guard var origin = self.state.origins[key] else { continue }
            let ethereum = origin.ethereumAccount.map(removal.matches) == true
            let solana = origin.solanaAccount.map(removal.matches) == true
            guard ethereum || solana else { continue }
            if ethereum {
                guard let revision = Self.nextRevision(in: &self.state) else {
                    return nil
                }
                origin.ethereumAccount = nil
                origin.revisions = Self.revisions(ethereum: revision, solana: origin.revisions.solana)
            }
            if solana {
                guard let revision = Self.nextRevision(in: &self.state) else {
                    return nil
                }
                origin.solanaAccount = nil
                origin.revisions = Self.revisions(ethereum: origin.revisions.ethereum, solana: revision)
            }
            self.state.origins[key] = origin
            changedOrigins.append(key)
        }
        for key in changedOrigins {
            guard self.invalidateStaleRequests(configurationKey: key, excluding: nil, now: now) else {
                return nil
            }
        }
        var changed = !changedOrigins.isEmpty
        for index in self.state.records.indices {
            let record = self.state.records[index]
            switch record.state {
            case .pending, .claimed:
                guard let request = self.request(for: record),
                      Self.removalInvalidates(request, matching: removal) else { continue }
                guard let response = ExtensionRequestProfileCodec.boundedResponseData(ResponseToExtension(
                    for: request, payload: .error(.init(message: Strings.providerNotReady, code: 4100))
                ), request: request) else { return nil }
                self.complete(at: index, response: response, date: now)
                changed = true
            case .broadcastPrepared, .completed:
                break
            }
        }
        return changed
    }

    mutating func admit(
        _ record: Record,
        now: Date
    ) -> [ExtensionBridge.Handle]? {
        guard let retiredHandles = Self.makeRoomForAdmission(record, in: &state.records, now: now) else {
            return nil
        }
        state.records.append(record)
        Self.reclaimAuthority(in: &state, now: now)
        return retiredHandles
    }

    mutating func revokeProvider(
        configurationKey: String,
        provider: InpageProvider,
        attempt: String,
        expected: ExtensionBridge.AuthorityVersion,
        now: Date
    ) -> Bool {
        guard Self.pinOrigin(in: &state, configurationKey: configurationKey, now: now),
              let revision = Self.nextRevision(in: &state),
              var origin = state.origins[configurationKey] else { return false }
        if provider == .ethereum {
            origin.ethereumAccount = nil
            origin.revisions = Self.revisions(ethereum: revision, solana: origin.revisions.solana)
        } else {
            origin.solanaAccount = nil
            origin.revisions = Self.revisions(ethereum: origin.revisions.ethereum, solana: revision)
        }
        state.origins[configurationKey] = origin
        state.mutationReceipts.append(.init(
            configurationKey: configurationKey, provider: provider,
            attempt: attempt, expected: expected, createdAt: now
        ))
        while state.mutationReceipts.count > Self.maximumMutationReceipts ||
            (try? ExtensionRequestProfileCodec.encode(state.mutationReceipts).count).map({ $0 > Self.maximumMutationReceiptBytes }) == true {
            state.mutationReceipts.removeFirst()
        }
        return invalidateStaleRequests(configurationKey: configurationKey, excluding: nil, now: now)
    }

    static func repairAuthorityState(
        _ stored: State,
        expectedIdentifier: UUID?
    ) -> (state: State, invalidOrigins: Set<String>)? {
        guard stored.schemaVersion == Self.profileSchemaVersion,
              stored.workflowVersion == ExtensionBridge.workflowVersion,
              stored.profileIdentifier == expectedIdentifier,
              stored.authoritySequence >= 0, stored.authoritySequence < Self.maximumRevision,
              stored.records.allSatisfy({
                  $0.revisions.ethereum <= stored.authoritySequence && $0.revisions.solana <= stored.authoritySequence
              }) else { return nil }
        let referencedOrigins = Set(stored.records.map(\.configurationKey) + stored.mutationReceipts.map(\.configurationKey))
        let invalidOrigins = stored.invalidOrigins
            .union(stored.origins.filter { !Self.validOrigin($0.value, sequence: stored.authoritySequence) }.keys)
            .union(referencedOrigins.subtracting(stored.origins.keys))
        guard stored.invalidOriginsContainer || !invalidOrigins.isEmpty,
              invalidOrigins.allSatisfy(Self.validConfigurationKey),
              Set(stored.origins.keys).union(invalidOrigins).count <= Self.maximumOrigins else { return nil }

        var state = stored
        guard let revision = Self.nextRevision(in: &state) else { return nil }
        for key in invalidOrigins {
            state.origins[key] = OriginState(revisions: Self.revisions(ethereum: revision, solana: revision))
        }
        state.invalidOrigins.removeAll()
        state.invalidOriginsContainer = false
        return (state, invalidOrigins)
    }
}
