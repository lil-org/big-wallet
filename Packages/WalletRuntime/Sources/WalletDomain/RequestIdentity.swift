import Foundation

public struct RequestToken: Hashable, Codable, Sendable {
    public let value: UUID

    public init(value: UUID) { self.value = value }

    public init?(rawValue: String) {
        guard let value = WireIdentity.lowercaseUUID(rawValue) else { return nil }
        self.value = value
    }

    public var rawValue: String { value.uuidString.lowercased() }
}

public struct NativeDeliveryNonce: Hashable, Codable, Sendable {
    public let value: UUID

    public init(value: UUID) { self.value = value }

    public init?(rawValue: String) {
        guard let value = WireIdentity.lowercaseUUID(rawValue) else {
            return nil
        }
        self.value = value
    }

    public var rawValue: String { value.uuidString.lowercased() }
}

public struct NativeDeliveryOwner: Codable, Equatable, Sendable {
    public let runtimeInstanceIdentifier: UUID
    public let processIdentifier: Int32
    public let processStartDate: Date
    public let bundlePath: String
    public let marketingVersion: String
    public let buildVersion: String

    public init?(
        runtimeInstanceIdentifier: UUID,
        processIdentifier: Int32,
        processStartDate: Date,
        bundleURL: URL,
        marketingVersion: String,
        buildVersion: String
    ) {
        self.runtimeInstanceIdentifier = runtimeInstanceIdentifier
        self.processIdentifier = processIdentifier
        self.processStartDate = processStartDate
        bundlePath = bundleURL.standardizedFileURL.path
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        guard isValid else { return nil }
    }

    public var bundleURL: URL {
        URL(fileURLWithPath: bundlePath).standardizedFileURL
    }

    public var isValid: Bool {
        processIdentifier > 0 &&
            processStartDate.timeIntervalSince1970.isFinite &&
            processStartDate.timeIntervalSince1970 > 0 &&
            !bundlePath.isEmpty && bundlePath.count <= 4_096 &&
            bundleURL.path == bundlePath &&
            bundleURL.pathExtension == "app" &&
            !marketingVersion.isEmpty && marketingVersion.count <= 128 &&
            !buildVersion.isEmpty && buildVersion.count <= 128
    }
}

public struct NativeDeliveryReceipt: Codable, Equatable, Sendable {
    public let nativeDeliveryNonce: NativeDeliveryNonce
    public let owner: NativeDeliveryOwner

    public init(
        nativeDeliveryNonce: NativeDeliveryNonce,
        owner: NativeDeliveryOwner
    ) {
        self.nativeDeliveryNonce = nativeDeliveryNonce
        self.owner = owner
    }

    public func matches(
        nativeDeliveryNonce: NativeDeliveryNonce,
        runtimeInstanceIdentifier: UUID
    ) -> Bool {
        self.nativeDeliveryNonce == nativeDeliveryNonce &&
            owner.runtimeInstanceIdentifier == runtimeInstanceIdentifier
    }
}

public struct RequestHandle: Hashable, Sendable {
    public let id: Int
    public let token: RequestToken
    public let profileIdentifier: UUID?

    public init(id: Int, token: RequestToken, profileIdentifier: UUID?) {
        self.id = id
        self.token = token
        self.profileIdentifier = profileIdentifier
    }

    public init?(id: Int, requestToken: String, profileIdentifier: UUID?) {
        guard let token = RequestToken(rawValue: requestToken) else { return nil }
        self.init(id: id, token: token, profileIdentifier: profileIdentifier)
    }

    public var requestToken: String { token.rawValue }
}

public enum RequestPhase: String, Codable, Sendable { case queued, approving, responded }

public enum ManualSwitchRequestState: String, Sendable {
    case pending, approved, completed
}

public struct ManualSwitchRequest: Equatable, Sendable {
    public let handle: RequestHandle
    public let host: String
    public let configurationKey: String
    public let revisions: ProviderRevisions
    public let state: ManualSwitchRequestState

    public var json: [String: Any] {
        [
            "id": handle.id,
            "host": host,
            "configurationKey": configurationKey,
            "requestToken": handle.requestToken,
            "revisions": revisions.json,
            "state": state.rawValue,
        ]
    }

    public init(handle: RequestHandle, host: String, configurationKey: String, revisions: ProviderRevisions, state: ManualSwitchRequestState) {
        self.handle = handle
        self.host = host
        self.configurationKey = configurationKey
        self.revisions = revisions
        self.state = state
    }
}

public struct ProviderRevisions: Codable, Equatable, Sendable {
    public let ethereum: Int
    public let solana: Int

    public init?(rawValue: Any?) {
        guard let rawValue,
              let value = WireProtocol.decode(.revisions, value: rawValue) as? [String: Any] else { return nil }
        self.init(validatedJSON: value)
    }

    public init?(validatedJSON: [String: Any]) {
        guard let ethereum = validatedJSON["ethereum"] as? Int,
              let solana = validatedJSON["solana"] as? Int else { return nil }
        self.ethereum = ethereum
        self.solana = solana
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireProtocol.object(.revisions, from: decoder)
        guard let value = Self(validatedJSON: wire.json) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "invalid provider revisions"
            ))
        }
        self = value
    }

    public var json: [String: Any] { ["ethereum": ethereum, "solana": solana] }
}

public struct RequestAuthorityVersion: Codable, Equatable, Sendable {
    public let context: String
    public let revisions: ProviderRevisions

    public init(context: String, revisions: ProviderRevisions) {
        self.context = context
        self.revisions = revisions
    }

    public init?(rawValue: Any?) {
        guard let rawValue,
              let value = WireProtocol.decode(.authorityVersion, value: rawValue) as? [String: Any] else { return nil }
        self.init(validatedJSON: value)
    }

    public init?(validatedJSON: [String: Any]) {
        guard let context = validatedJSON["context"] as? String,
              let values = validatedJSON["revisions"] as? [String: Any],
              let revisions = ProviderRevisions(validatedJSON: values) else { return nil }
        self.init(context: context, revisions: revisions)
    }

    public init(from decoder: Decoder) throws {
        let wire = try WireProtocol.object(.authorityVersion, from: decoder)
        guard let version = Self(validatedJSON: wire.json) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "invalid authority version"
            ))
        }
        self = version
    }

    public var json: [String: Any] { ["context": context, "revisions": revisions.json] }
}

public struct RequestAuthoritySnapshot: Sendable {
    public let version: RequestAuthorityVersion
    public let ethereumAccount: WalletAccountDescriptor?
    public let ethereumChainId: String
    public let solanaAccount: WalletAccountDescriptor?

    public var json: [String: Any] {
        [
            "context": version.context,
            "revisions": version.revisions.json,
            "ethereum": ["address": ethereumAccount?.normalizedAddress ?? "", "chainId": ethereumChainId],
            "solana": solanaAccount.map { ["publicKey": $0.normalizedAddress] as Any } ?? NSNull(),
        ]
    }

    public init(version: RequestAuthorityVersion, ethereumAccount: WalletAccountDescriptor?, ethereumChainId: String, solanaAccount: WalletAccountDescriptor?) {
        self.version = version
        self.ethereumAccount = ethereumAccount
        self.ethereumChainId = ethereumChainId
        self.solanaAccount = solanaAccount
    }
}

public struct RecoveryRequest: Sendable {
    public let handle: RequestHandle
    public let configurationKey: String
    public let manual: Bool
    public let state: ManualSwitchRequestState

    public var json: [String: Any] {
        ["id": handle.id, "requestToken": handle.requestToken,
         "configurationKey": configurationKey, "manual": manual, "state": state.rawValue]
    }

    public init(handle: RequestHandle, configurationKey: String, manual: Bool, state: ManualSwitchRequestState) {
        self.handle = handle
        self.configurationKey = configurationKey
        self.manual = manual
        self.state = state
    }
}

public struct NativeExecutionContext: Codable, Equatable, Sendable {
    public let revisions: ProviderRevisions
    public let observedAt: Date
    public let executionDeadline: Date

    public init(revisions: ProviderRevisions, observedAt: Date, executionDeadline: Date) {
        self.revisions = revisions
        self.observedAt = observedAt
        self.executionDeadline = executionDeadline
    }
}

public enum WireIdentity {
    public static func lowercaseUUID(_ raw: String) -> UUID? {
        guard let value = UUID(uuidString: raw), value.uuidString.lowercased() == raw else { return nil }
        return value
    }
}
