import CoreFoundation
import Foundation
import Synchronization
import WalletAuthority
import WalletDomain

public final class NativeIngressGate: Sendable {
    public static let shared = NativeIngressGate()

    struct Limits: Sendable {
        var maximumDepth = 64
        var maximumPayloadBytes = 262_144
        var maximumPayloadTextBytes = 262_144
        var maximumContextTextBytes = 16_384
        var maximumNodes = 262_656
        var maximumRPCBodyBytes = 4_194_304
        var maximumRPCMetadataNodes = 512
        var ordinaryInspectionSlots = 4
        var reservedInspectionSlots = 2
        var ordinaryRetainedBytes = 16_777_216
        var reservedRetainedBytes = 524_288
        var ordinaryProcessSlots = 8
        var ordinaryProfileSlots = 4
        var ordinaryScopeSlots = 2
        var rejectionSlots = 1
        var revocationSlots = 1
        var completionProcessSlots = 4
        var completionProfileSlots = 2
        var completionScopeSlots = 2
        var maximumScopes = 256
        var maximumProfiles = 64
    }

    public enum RejectionReason: String, Sendable {
        case busy
        case requestTooLarge = "request_too_large"
        case requestTooComplex = "request_too_complex"
    }

    public struct Rejection: Sendable {
        public let id: Int
        public let reason: RejectionReason

        public var response: WireProtocol.ValidatedObject? {
            var value: [String: Any] = [
                "id": id, "workflowVersion": WireProtocol.workflowVersion,
                "nativeAdmissionRejected": true, "reason": reason.rawValue,
                "code": -32_005, "dispatched": false,
            ]
            if reason == .busy { value["retryAfterMilliseconds"] = 500 }
            return WireProtocol.object(.nativeAdmissionRejection, value: value)
        }
    }

    public enum Failure: Swift.Error, Sendable {
        case invalidMessage
        case rejected(Rejection)
    }

    public struct Admission: Sendable {
        public let message: WireProtocol.JSONObject
        public let context: NativeRequestContext
        private let lease: Lease

        fileprivate init(message: WireProtocol.JSONObject, context: NativeRequestContext, lease: Lease) {
            self.message = message
            self.context = context
            self.lease = lease
        }

        public func rpcAdmissionDecided() { lease.handoffRPC() }
        public func finish() { lease.finish() }
    }

    struct Statistics: Equatable {
        let inspecting: Int
        let retainedBytes: Int
        let ordinary: Int
        let rejection: Int
        let revocation: Int
        let completion: Int
        let scopes: Int
        let profiles: Int
    }

    private enum Pool { case ordinary, reserved }
    private enum Lane { case ordinary, rejection, revocation, completion, rpc }

    private struct Scope: Hashable {
        let profile: UUID?
        let source: String
        let origin: String?
        let tabID: Int?
        let frameID: Int?
        let documentID: Data?
        let documentSession: String?

        init(_ context: NativeRequestContext) {
            profile = context.profileIdentifier
            switch context.source {
            case .site(let site, let document):
                source = "site"
                origin = site.configurationKey
                tabID = document.tabID
                frameID = document.frameID
                documentID = document.documentID.map { Data($0.utf8) }
                documentSession = document.documentSession
            case .popup, .worker:
                source = context.source == .popup ? "popup" : "worker"
                origin = nil
                tabID = nil
                frameID = nil
                documentID = nil
                documentSession = nil
            }
        }
    }

    private struct Record {
        let pool: Pool
        var inspecting = true
        var chargedBytes = 0
        var lane: Lane?
        var scope: Scope?
    }

    private struct State {
        var records = [UUID: Record]()
    }

    fileprivate final class Lease: Sendable {
        let gate: NativeIngressGate
        let id: UUID

        init(gate: NativeIngressGate, id: UUID) {
            self.gate = gate
            self.id = id
        }

        func handoffRPC() {
            gate.state.withLock { state in
                guard state.records[id]?.lane == .rpc else { return }
                state.records.removeValue(forKey: id)
            }
        }

        func finish() { gate.state.withLock { _ = $0.records.removeValue(forKey: id) } }
        deinit { finish() }
    }

    private let limits: Limits
    private let state = Mutex(State())

    public convenience init() { self.init(limits: Limits()) }
    init(limits: Limits) { self.limits = limits }

    var statistics: Statistics {
        state.withLock { state in
            let records = Array(state.records.values)
            let scopes = Set(records.compactMap(\.scope))
            return Statistics(
                inspecting: records.filter(\.inspecting).count,
                retainedBytes: records.reduce(0) { $0 + $1.chargedBytes },
                ordinary: records.filter { $0.lane == .ordinary }.count,
                rejection: records.filter { $0.lane == .rejection }.count,
                revocation: records.filter { $0.lane == .revocation }.count,
                completion: records.filter { $0.lane == .completion }.count,
                scopes: scopes.count,
                profiles: Set(scopes.map(\.profile)).count
            )
        }
    }

    public func admit(_ raw: Any, profileIdentifier: UUID?) throws -> Admission {
        guard let object = raw as? NSDictionary else { throw Failure.invalidMessage }
        let correlation = Self.correlationID(object)
        let provisionalLane = Self.provisionalLane(object)
        let pool: Pool = Self.isReserved(provisionalLane) ? .reserved : .ordinary
        let lease: Lease
        do {
            lease = try reserveInspection(pool: pool)
        } catch {
            throw Self.failure(.busy, id: correlation)
        }
        do {
            var inspection = Inspection(limits: limits, rpc: provisionalLane == .rpc)
            try inspection.visitRoot(object)
            guard reserveBytes(inspection.charge, lease: lease) else {
                throw InspectionFailure.rejected(.busy)
            }
            guard let snapshot = WireProtocol.JSONObject(object),
                  let ingress = NativeRequestContext.extract(from: snapshot, profileIdentifier: profileIdentifier),
                  let lane = Self.validatedLane(message: ingress.message, context: ingress.context),
                  lane == provisionalLane else { throw Failure.invalidMessage }
            if lane != .rpc {
                guard let encoded = ExtensionBridge.payloadData(ingress.message.json) else { throw Failure.invalidMessage }
                guard encoded.count <= limits.maximumPayloadBytes else {
                    throw InspectionFailure.rejected(.requestTooLarge)
                }
            }
            guard reserveDispatch(lane: lane, context: ingress.context, lease: lease) else {
                throw InspectionFailure.rejected(.busy)
            }
            return Admission(message: ingress.message, context: ingress.context, lease: lease)
        } catch {
            lease.finish()
            if case InspectionFailure.rejected(let reason) = error {
                throw Self.failure(reason, id: correlation)
            }
            throw Failure.invalidMessage
        }
    }

    private func reserveInspection(pool: Pool) throws -> Lease {
        let id = UUID()
        let accepted = state.withLock { state in
            let count = state.records.values.filter { $0.pool == pool && $0.inspecting }.count
            let maximum = pool == .ordinary ? limits.ordinaryInspectionSlots : limits.reservedInspectionSlots
            guard count < maximum else { return false }
            state.records[id] = Record(pool: pool)
            return true
        }
        guard accepted else { throw Failure.invalidMessage }
        return Lease(gate: self, id: id)
    }

    private func reserveBytes(_ bytes: Int, lease: Lease) -> Bool {
        state.withLock { state in
            guard var record = state.records[lease.id] else { return false }
            let used = state.records.values.filter { $0.pool == record.pool }.reduce(0) { $0 + $1.chargedBytes }
            let maximum = record.pool == .ordinary ? limits.ordinaryRetainedBytes : limits.reservedRetainedBytes
            guard bytes <= maximum - used else { return false }
            record.chargedBytes = bytes
            state.records[lease.id] = record
            return true
        }
    }

    private func reserveDispatch(lane: Lane, context: NativeRequestContext, lease: Lease) -> Bool {
        state.withLock { state in
            guard var record = state.records[lease.id] else { return false }
            if lane == .rpc {
                record.lane = lane
                state.records[lease.id] = record
                return true
            }
            let scope = Scope(context)
            let scopes = Set(state.records.values.compactMap(\.scope))
            let profiles = Set(scopes.map(\.profile))
            guard scopes.contains(scope) || scopes.count < limits.maximumScopes,
                  profiles.contains(scope.profile) || profiles.count < limits.maximumProfiles else { return false }
            let occupied = state.records.values.filter { $0.lane == lane }
            switch lane {
            case .ordinary, .completion:
                let ordinary = lane == .ordinary
                guard occupied.count < (ordinary ? limits.ordinaryProcessSlots : limits.completionProcessSlots),
                      occupied.filter({ $0.scope?.profile == scope.profile }).count <
                        (ordinary ? limits.ordinaryProfileSlots : limits.completionProfileSlots),
                      occupied.filter({ $0.scope == scope }).count <
                        (ordinary ? limits.ordinaryScopeSlots : limits.completionScopeSlots) else { return false }
            case .rejection:
                guard occupied.count < limits.rejectionSlots else { return false }
            case .revocation:
                guard occupied.count < limits.revocationSlots else { return false }
            case .rpc:
                return false
            }
            record.inspecting = false
            record.lane = lane
            record.scope = scope
            state.records[lease.id] = record
            return true
        }
    }

    private static func isReserved(_ lane: Lane) -> Bool {
        lane == .rejection || lane == .revocation || lane == .completion
    }

    private static func provisionalLane(_ object: NSDictionary) -> Lane {
        switch smallString(object.object(forKey: "subject")) {
        case "rpc": return .rpc
        case "rejectRequest": return .rejection
        case "disconnect": return .revocation
        case "acknowledgeResponse", "getPendingRequests", "getRecoveryRequests": return .completion
        case "pollResponse" where smallString(object.object(forKey: "maintenance")) == "none": return .completion
        default: return .ordinary
        }
    }

    private static func validatedLane(message: WireProtocol.JSONObject, context: NativeRequestContext) -> Lane? {
        if message["subject"] == nil {
            guard let wire = WireProtocol.object(.dappRequest, snapshot: message),
                  let request = SafariRequest(wire: wire), context.authorizes(request) else { return nil }
            return .ordinary
        }
        guard let wire = WireProtocol.object(.nativeCommand, snapshot: message),
              let request = try? InternalSafariRequest(wire: wire), context.authorizes(request) else { return nil }
        switch request.command {
        case .page(.rpc): return .rpc
        case .page(.disconnect): return .revocation
        case .page(.acknowledgeResponse), .worker(.getRecoveryRequests), .popup(.getPendingRequests): return .completion
        case .worker(.pollResponse(let identity)) where identity.maintenance == .none: return .completion
        case .popup(.rejectRequest): return .rejection
        default: return .ordinary
        }
    }

    private static func smallString(_ value: Any?) -> String? {
        guard let string = value as? NSString, string.length <= 64 else { return nil }
        return string as String
    }

    private static func correlationID(_ object: NSDictionary) -> Int? {
        guard let rawID = object.object(forKey: "id") as? NSNumber,
              CFGetTypeID(rawID) != CFBooleanGetTypeID(),
              let rawVersion = object.object(forKey: "workflowVersion") as? NSNumber,
              CFGetTypeID(rawVersion) != CFBooleanGetTypeID(),
              rawVersion == NSNumber(value: WireProtocol.workflowVersion),
              WireProtocol.validate(.requestID, value: rawID),
              let id = Int(exactly: rawID.doubleValue) else { return nil }
        return id
    }

    private static func failure(_ reason: RejectionReason, id: Int?) -> Failure {
        id.map { .rejected(Rejection(id: $0, reason: reason)) } ?? .invalidMessage
    }

    private enum InspectionFailure: Swift.Error {
        case invalid
        case rejected(RejectionReason)
    }

    private struct Inspection {
        let limits: Limits
        let rpc: Bool
        var nodes = 0
        var payloadBytes = 0
        var contextBytes = 0
        var rpcBodyBytes = 0
        var path = Set<ObjectIdentifier>()

        var charge: Int { payloadBytes + contextBytes + rpcBodyBytes + nodes * 64 }

        mutating func visitRoot(_ object: NSDictionary) throws {
            try visit(object, depth: 0, context: false, root: true)
        }

        mutating func countNode() throws {
            let maximum = rpc ? limits.maximumRPCMetadataNodes : limits.maximumNodes
            guard nodes < maximum else { throw InspectionFailure.rejected(.requestTooComplex) }
            nodes += 1
        }

        mutating func countString(_ string: NSString, context: Bool, body: Bool = false) throws {
            let maximum: Int
            let used: Int
            if body { maximum = limits.maximumRPCBodyBytes; used = rpcBodyBytes }
            else if rpc { maximum = limits.maximumContextTextBytes; used = payloadBytes + contextBytes }
            else if context { maximum = limits.maximumContextTextBytes; used = contextBytes }
            else { maximum = limits.maximumPayloadTextBytes; used = payloadBytes }
            let remaining = maximum - used
            guard string.length <= remaining else { throw InspectionFailure.rejected(.requestTooLarge) }
            let bytes = (string as String).utf8.prefix(remaining + 1).count
            guard bytes <= remaining else { throw InspectionFailure.rejected(.requestTooLarge) }
            if body { rpcBodyBytes += bytes }
            else if context { contextBytes += bytes }
            else { payloadBytes += bytes }
        }

        mutating func visit(_ value: Any, depth: Int, context: Bool, root: Bool = false) throws {
            try countNode()
            if value is NSNull { return }
            if let string = value as? NSString {
                try countString(string, context: context)
                return
            }
            if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { throw InspectionFailure.invalid }
                return
            }
            guard depth < limits.maximumDepth else { throw InspectionFailure.rejected(.requestTooComplex) }
            if let array = value as? NSArray {
                guard array.count <= (rpc ? limits.maximumRPCMetadataNodes : limits.maximumNodes) - nodes else {
                    throw InspectionFailure.rejected(.requestTooComplex)
                }
                let identity = ObjectIdentifier(array)
                guard path.insert(identity).inserted else { throw InspectionFailure.invalid }
                defer { path.remove(identity) }
                for index in 0..<array.count {
                    try visit(array.object(at: index), depth: depth + 1, context: context)
                }
                return
            }
            guard let object = value as? NSDictionary else { throw InspectionFailure.invalid }
            let remainingNodes = (rpc ? limits.maximumRPCMetadataNodes : limits.maximumNodes) - nodes
            guard object.count <= remainingNodes / 2 else { throw InspectionFailure.rejected(.requestTooComplex) }
            let identity = ObjectIdentifier(object)
            guard path.insert(identity).inserted else { throw InspectionFailure.invalid }
            defer { path.remove(identity) }
            for rawKey in object.keyEnumerator() {
                guard let key = rawKey as? NSString, let item = object.object(forKey: rawKey) else {
                    throw InspectionFailure.invalid
                }
                try countNode()
                let isTransportContext = root && key.isEqual(to: WireProtocol.nativeContextKey)
                try countString(key, context: context || isTransportContext)
                if root, rpc, key.isEqual(to: "body") {
                    try countNode()
                    guard let body = item as? NSString else { throw InspectionFailure.invalid }
                    try countString(body, context: false, body: true)
                } else {
                    try visit(item, depth: depth + 1,
                              context: context || isTransportContext)
                }
            }
        }
    }
}
