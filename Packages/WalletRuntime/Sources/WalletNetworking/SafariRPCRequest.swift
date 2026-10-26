import Foundation
import WalletDomain
import Synchronization

public struct SafariRPCLimits: Sendable {
    public var maximumRequestBytes: Int
    public var maximumRequestTokens: Int
    public var maximumResponseBytes: Int
    public var maximumResponseTokens: Int
    public var maximumActivePerOrigin: Int
    public var maximumActiveRequests: Int
    public var maximumOutstandingPerOrigin: Int
    public var maximumOutstandingRequests: Int
    public var maximumRetainedRequestBytes: Int
    public var maximumBufferedResponseBytes: Int
    public var maximumQueueWait: Duration
    public var maximumLifetime: Duration

    public static let live = SafariRPCLimits()

    public init(
        maximumRequestBytes: Int = WireProtocol.rpcMaximumRequestBytes,
        maximumRequestTokens: Int = 65_536,
        maximumResponseBytes: Int = WireProtocol.rpcMaximumResponseBytes,
        maximumResponseTokens: Int = 65_536,
        maximumActivePerOrigin: Int = WireProtocol.rpcMaximumActivePerOrigin,
        maximumActiveRequests: Int = WireProtocol.rpcMaximumActiveRequests,
        maximumOutstandingPerOrigin: Int = WireProtocol.rpcMaximumOutstandingPerOrigin,
        maximumOutstandingRequests: Int = WireProtocol.rpcMaximumOutstandingRequests,
        maximumRetainedRequestBytes: Int = WireProtocol.rpcMaximumRetainedRequestBytes,
        maximumBufferedResponseBytes: Int = WireProtocol.rpcMaximumBufferedResponseBytes,
        maximumQueueWait: Duration = .milliseconds(WireProtocol.rpcMaximumQueueWaitMilliseconds),
        maximumLifetime: Duration = .milliseconds(WireProtocol.rpcMaximumLifetimeMilliseconds)
    ) {
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumRequestTokens = maximumRequestTokens
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumResponseTokens = maximumResponseTokens
        self.maximumActivePerOrigin = maximumActivePerOrigin
        self.maximumActiveRequests = maximumActiveRequests
        self.maximumOutstandingPerOrigin = maximumOutstandingPerOrigin
        self.maximumOutstandingRequests = maximumOutstandingRequests
        self.maximumRetainedRequestBytes = maximumRetainedRequestBytes
        self.maximumBufferedResponseBytes = maximumBufferedResponseBytes
        self.maximumQueueWait = maximumQueueWait
        self.maximumLifetime = maximumLifetime
    }
}

public enum SafariRPCFailure: Error, Sendable, Equatable {
    case invalidJSON, invalidRequest, prohibitedMethod, requestTooLarge, responseTooLarge
    case busy, queueTimeout, timeout, cancelled, transport

    public var code: Int {
        switch self {
        case .invalidJSON: -32_700
        case .invalidRequest: -32_600
        case .prohibitedMethod: 4_200
        case .requestTooLarge, .responseTooLarge, .busy: -32_005
        case .queueTimeout, .timeout, .cancelled, .transport: -32_603
        }
    }

    public var message: String {
        switch self {
        case .invalidJSON: "Invalid JSON"
        case .invalidRequest: "Invalid RPC request"
        case .prohibitedMethod: "RPC method is unavailable through this transport"
        case .requestTooLarge: "RPC request exceeds the size limit"
        case .responseTooLarge: "RPC response exceeds the size limit"
        case .busy: "RPC capacity is temporarily exhausted"
        case .queueTimeout: "RPC request expired while waiting"
        case .timeout: "RPC request timed out"
        case .cancelled: "RPC request was cancelled"
        case .transport: "Failed to communicate with the RPC endpoint"
        }
    }

    public var reason: String {
        switch self {
        case .invalidJSON: "invalid_json"
        case .invalidRequest: "invalid_request"
        case .prohibitedMethod: "prohibited_method"
        case .requestTooLarge: "request_too_large"
        case .responseTooLarge: "response_too_large"
        case .busy: "busy"
        case .queueTimeout: "queue_timeout"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .transport: "transport"
        }
    }

    public func response(id: Int, dispatched: Bool) -> RPCResponseToExtension {
        RPCResponseToExtension(upstream: [
            "id": id,
            "error": [
                "code": code, "message": message,
                "data": ["reason": reason, "dispatched": dispatched],
            ],
        ], expectedResponseID: id)!
    }
}

public enum SafariRPCJSONPreflight {
    public static func validate(
        _ bytes: some Sequence<UInt8>, maximumTokens: Int,
        tokenLimitFailure: SafariRPCFailure, depthLimitFailure: SafariRPCFailure,
        checkCancellation: () throws -> Void
    ) throws {
        var tokens = 0
        var depth = 0
        var inString = false
        var escaped = false
        var inScalar = false
        for (offset, byte) in bytes.enumerated() {
            if offset % 4096 == 0 { try checkCancellation() }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34:
                tokens += 1
                inString = true
                inScalar = false
            case 91, 123:
                tokens += 1
                depth += 1
                inScalar = false
                guard depth <= WireProtocol.maximumJSONDepth else { throw depthLimitFailure }
            case 93, 125:
                depth -= 1
                inScalar = false
            case 9, 10, 13, 32, 44, 58:
                inScalar = false
            default:
                if !inScalar { tokens += 1 }
                inScalar = true
            }
            guard tokens <= maximumTokens else { throw tokenLimitFailure }
        }
        try checkCancellation()
    }
}

public struct ValidatedRPCRequest: Sendable {
    public let id: Int
    public let method: String
    public let body: Data
    public let allowsUnauthorizedReplay: Bool

    public init(body: String, id: Int, limits: SafariRPCLimits = .live) throws {
        self = try Self.prepare(body: body, id: id, limits: limits).serialize()
    }

    private init(id: Int, method: String, body: Data) {
        self.id = id
        self.method = method
        self.body = body
        allowsUnauthorizedReplay = Self.replaySafeMethods.contains(method)
    }

    public struct Prepared: Sendable {
        fileprivate let id: Int
        fileprivate let method: String
        fileprivate let value: WireProtocol.JSONValue
        public let canonicalByteCount: Int
        fileprivate let checkCancellation: @Sendable () throws -> Void

        public func serialize() throws -> ValidatedRPCRequest {
            try checkCancellation()
            var data = Data(count: canonicalByteCount)
            try data.withUnsafeMutableBytes { buffer in
                var writer = CanonicalWriter(maximumBytes: canonicalByteCount, buffer: buffer, checkCancellation: checkCancellation)
                try writer.write(value)
                guard writer.count == canonicalByteCount else { throw SafariRPCFailure.invalidRequest }
            }
            try checkCancellation()
            return ValidatedRPCRequest(id: id, method: method, body: data)
        }
    }

    public static func prepare(
        body: String, id: Int, limits: SafariRPCLimits = .live,
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Prepared {
        guard body.utf8.count <= limits.maximumRequestBytes else { throw SafariRPCFailure.requestTooLarge }
        try SafariRPCJSONPreflight.validate(
            body.utf8, maximumTokens: limits.maximumRequestTokens,
            tokenLimitFailure: .requestTooLarge, depthLimitFailure: .invalidRequest,
            checkCancellation: checkCancellation
        )
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed]) }
        catch { throw SafariRPCFailure.invalidJSON }
        try checkCancellation()
        guard let object = decoded as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              let requestID = object["id"] as? NSNumber,
              CFGetTypeID(requestID) != CFBooleanGetTypeID(),
              requestID as? Int == id,
              WireProtocol.validate(.requestID, value: id),
              let method = object["method"] as? String,
              !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SafariRPCFailure.invalidRequest
        }
        guard !Self.isProhibited(method, params: object["params"]) else { throw SafariRPCFailure.prohibitedMethod }
        var canonical: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        canonical["params"] = object["params"]
        guard let value = WireProtocol.JSONValue(canonical) else { throw SafariRPCFailure.invalidRequest }
        var writer = CanonicalWriter(maximumBytes: limits.maximumRequestBytes, checkCancellation: checkCancellation)
        try writer.write(value)
        return Prepared(id: id, method: method, value: value, canonicalByteCount: writer.count, checkCancellation: checkCancellation)
    }

    private struct CanonicalWriter {
        let maximumBytes: Int
        var buffer: UnsafeMutableRawBufferPointer? = nil
        let checkCancellation: @Sendable () throws -> Void
        var count = 0
        var visitedValues = 0

        mutating func write(_ value: WireProtocol.JSONValue) throws {
            if visitedValues % 1024 == 0 { try checkCancellation() }
            visitedValues += 1
            switch value {
            case .null:
                try append(contentsOf: "null".utf8)
            case .boolean(let value):
                try append(contentsOf: (value ? "true" : "false").utf8)
            case .integer(let value):
                try append(contentsOf: String(value).utf8)
            case .unsignedInteger(let value):
                try append(contentsOf: String(value).utf8)
            case .number(let value):
                guard value.isFinite else { throw SafariRPCFailure.invalidRequest }
                try append(contentsOf: String(value).utf8)
            case .decimal(let value):
                guard !value.isNaN else { throw SafariRPCFailure.invalidRequest }
                try append(contentsOf: NSDecimalNumber(decimal: value).stringValue.utf8)
            case .string(let value):
                try writeString(value)
            case .array(let values):
                try append(91)
                for (index, value) in values.enumerated() {
                    if index > 0 { try append(44) }
                    try write(value)
                }
                try append(93)
            case .object(let values):
                try append(123)
                for (index, element) in values.sorted(by: { $0.key < $1.key }).enumerated() {
                    if index > 0 { try append(44) }
                    try writeString(element.key)
                    try append(58)
                    try write(element.value)
                }
                try append(125)
            }
        }

        private mutating func writeString(_ value: String) throws {
            try append(34)
            for (offset, byte) in value.utf8.enumerated() {
                if offset % 4096 == 0 { try checkCancellation() }
                switch byte {
                case 34, 47, 92:
                    try append(92)
                    try append(byte)
                case 8: try append(contentsOf: "\\b".utf8)
                case 9: try append(contentsOf: "\\t".utf8)
                case 10: try append(contentsOf: "\\n".utf8)
                case 12: try append(contentsOf: "\\f".utf8)
                case 13: try append(contentsOf: "\\r".utf8)
                case 0...31:
                    try append(contentsOf: "\\u00".utf8)
                    try append(Self.hexDigits[Int(byte >> 4)])
                    try append(Self.hexDigits[Int(byte & 15)])
                default: try append(byte)
                }
            }
            try append(34)
        }

        private mutating func append(_ byte: UInt8) throws {
            guard count < maximumBytes else { throw SafariRPCFailure.requestTooLarge }
            buffer?[count] = byte
            count += 1
        }

        private mutating func append<Bytes: Collection>(contentsOf bytes: Bytes) throws where Bytes.Element == UInt8 {
            guard bytes.count <= maximumBytes - count else { throw SafariRPCFailure.requestTooLarge }
            if let buffer {
                for byte in bytes {
                    buffer[count] = byte
                    count += 1
                }
            } else {
                count += bytes.count
            }
        }

        private static let hexDigits = Array("0123456789abcdef".utf8)
    }

    private static func isProhibited(_ method: String, params: Any?) -> Bool {
        let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "debug_getbadblocks",
           let file = (params as? [Any])?.first ?? (params as? [String: Any])?["file"] {
            return !(file is NSNull)
        }
        return prohibitedMethods.contains(normalized) ||
            prohibitedPrefixes.contains { normalized.hasPrefix($0) } ||
            (normalized.hasPrefix("debug_") &&
                (normalized.hasSuffix("tofile") || normalized.hasSuffix("fromfile")))
    }

    private static let prohibitedPrefixes = [
        "admin_", "personal_", "miner_", "engine_", "hardhat_", "anvil_", "evm_", "signer_", "eth_sign",
        "debug_set", "debug_start", "debug_stop", "debug_write",
    ]

    private static let prohibitedMethods: Set<String> = [
        "eth_accounts", "eth_coinbase", "net_version", "eth_chainid", "eth_requestaccounts",
        "wallet_getpermissions", "wallet_requestpermissions", "wallet_revokepermissions",
        "wallet_switchethereumchain", "wallet_addethereumchain", "eth_sendtransaction", "eth_sendtransactionsync",
        "eth_sendunsignedtransaction", "eth_submittransaction", "eth_resend", "parity_posttransaction",
        "parity_postsign", "parity_signmessage", "parity_setmode",
        "parity_acceptnonreservedpeers", "parity_addreservedpeer", "parity_dropnonreservedpeers",
        "parity_executeupgrade", "parity_removereservedpeer", "parity_setauthor", "parity_setchain",
        "parity_setenginesigner", "parity_setextradata", "parity_setgasceiltarget", "parity_setgasfloortarget",
        "parity_setmaxtransactiongas", "parity_setmingasprice", "parity_settransactionslimit",
        "parity_changepassword", "parity_deriveaddresshash", "parity_deriveaddressindex", "parity_importgethaccounts",
        "parity_killaccount", "parity_newaccountfromphrase", "parity_newaccountfromsecret", "parity_newaccountfromwallet",
        "parity_removeaddress", "parity_setaccountmeta", "parity_setaccountname", "parity_changevault",
        "parity_changevaultpassword", "parity_closevault", "parity_newvault", "parity_openvault", "parity_setvaultmeta",
        "parity_hardwarepinmatrixack", "parity_removetransaction", "parity_exportaccount", "parity_testpassword",
        "parity_decryptmessage",
        "perm_addaccountstoallowlist", "perm_removeaccountsfromallowlist",
        "perm_addnodestoallowlist", "perm_removenodesfromallowlist", "perm_reloadpermissionsfromfile",
        "qbft_proposevalidatorvote", "qbft_discardvalidatorvote",
        "ibft_proposevalidatorvote", "ibft_discardvalidatorvote", "clique_propose", "clique_discard",
        "eth_newfilter", "eth_newblockfilter",
        "eth_newpendingtransactionfilter", "eth_uninstallfilter", "eth_subscribe", "eth_unsubscribe",
        "debug_backtraceat", "debug_blockprofile", "debug_cpuprofile", "debug_mutexprofile",
        "debug_gotrace", "debug_freeosmemory", "debug_freezeclient", "debug_chaindbcompact",
        "debug_deletechainslice", "debug_resethead", "debug_verbosity", "debug_vmodule",
        "debug_cleartxpool", "tenderly_setbalance", "tenderly_addbalance",
        "tenderly_seterc20balance", "tenderly_adderc20balance", "tenderly_setmaxerc20balance",
        "tenderly_setstorageat", "tenderly_setcode", "tenderly_setnextblocktimestamp",
        "tenderly_startsync", "tenderly_stopsync", "tenderly_syncnext", "tenderly_revertsync",
        "debug_insertreceipts", "debug_migratereceipts",
        "testing_commitblockv1",
    ]

    private static let replaySafeMethods: Set<String> = [
        "eth_baseFee", "eth_blobBaseFee", "eth_blockNumber", "eth_call", "eth_callBundle", "eth_callMany",
        "eth_createAccessList", "eth_estimateGas", "eth_estimateUserOperationGas", "eth_feeHistory",
        "eth_fillTransaction", "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_pendingTransactions",
        "eth_protocolVersion", "eth_supportedEntryPoints", "eth_syncing", "net_listening", "net_peerCount",
        "parity_pendingTransactions", "rundler_maxPriorityFeePerGas", "txpool_content", "txpool_contentFrom",
        "txpool_inspect", "txpool_status", "web3_clientVersion", "web3_sha3",
        "eth_getBalance", "eth_getCode", "eth_getStorageAt", "eth_getProof", "eth_getLogs", "eth_getFilterLogs",
        "eth_getBlockByHash", "eth_getBlockByNumber", "eth_getBlockReceipts",
        "eth_getBlockTransactionCountByHash", "eth_getBlockTransactionCountByNumber",
        "eth_getTransactionCount", "eth_getTransactionByHash", "eth_getTransactionReceipt",
        "eth_getTransactionByBlockHashAndIndex", "eth_getTransactionByBlockNumberAndIndex",
        "eth_getRawTransactionByHash", "eth_getRawTransactionByBlockHashAndIndex", "eth_getRawTransactionByBlockNumberAndIndex",
        "eth_getUncleCountByBlockHash", "eth_getUncleCountByBlockNumber",
        "eth_getUncleByBlockHashAndIndex", "eth_getUncleByBlockNumberAndIndex",
        "eth_getUserOperationByHash", "eth_getUserOperationReceipt", "eth_simulateV1",
        "debug_traceTransaction", "debug_traceCall", "debug_traceCallMany", "debug_traceBlock",
        "debug_traceBlockByHash", "debug_traceBlockByNumber", "debug_traceBadBlock",
        "trace_call", "trace_callMany", "trace_rawTransaction", "trace_replayTransaction",
        "trace_replayBlockTransactions", "trace_filter", "trace_get", "trace_transaction", "trace_block",
        "alchemy_getAssetTransfers", "alchemy_getTokenBalances", "alchemy_getTokenMetadata", "alchemy_getTransactionReceipts",
        "alchemy_simulateAssetChanges", "alchemy_simulateExecution", "alchemy_simulateAssetChangesBundle",
        "alchemy_simulateExecutionBundle", "alchemy_simulateUserOperationAssetChanges",
    ]
}

public final class SafariRPCResponseBudget: Sendable {
    public final class Lease: Sendable {
        private let budget: SafariRPCResponseBudget
        private let retained = Mutex<Int?>(0)

        fileprivate init(budget: SafariRPCResponseBudget) { self.budget = budget }

        public var retainedBytes: Int { retained.withLock { $0 ?? 0 } }

        public func reserve(_ additionalBytes: Int) throws {
            try retained.withLock { retained in
                guard let current = retained, additionalBytes >= 0 else { throw SafariRPCFailure.busy }
                try budget.reserve(additionalBytes)
                retained = current + additionalBytes
            }
        }

        public func release() {
            retained.withLock { retained in
                guard let current = retained else { return }
                retained = nil
                budget.release(current)
            }
        }

        deinit { release() }
    }

    private let maximumBytes: Int
    private let retained = Mutex(0)

    public init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }

    public var bufferedBytes: Int { retained.withLock { $0 } }

    public func acquire() -> Lease { Lease(budget: self) }

    private func reserve(_ count: Int) throws {
        try retained.withLock { retained in
            guard count <= maximumBytes - retained else { throw SafariRPCFailure.busy }
            retained += count
        }
    }

    private func release(_ count: Int) {
        retained.withLock { $0 -= count }
    }

}

public final class SafariRPCExecution: Sendable {
    private struct State {
        var dispatched = false
        var stopped = false
    }

    public let deadline: ContinuousClock.Instant
    public let limits: SafariRPCLimits
    public let responseBudget: SafariRPCResponseBudget
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex(State())

    public init(
        deadline: ContinuousClock.Instant,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        limits: SafariRPCLimits = .live,
        responseBudget: SafariRPCResponseBudget
    ) {
        self.deadline = deadline
        self.now = now
        self.limits = limits
        self.responseBudget = responseBudget
    }

    public var dispatched: Bool { state.withLock { $0.dispatched } }

    public func cancel() { state.withLock { $0.stopped = true } }

    public func checkCancellationAndDeadline() throws {
        try Task.checkCancellation()
        guard now() < deadline else { throw SafariRPCFailure.timeout }
        guard !state.withLock({ $0.stopped }) else { throw CancellationError() }
    }

    public func markDispatched() throws {
        try state.withLock { state in
            try Task.checkCancellation()
            guard now() < deadline else { throw SafariRPCFailure.timeout }
            guard !state.stopped else { throw CancellationError() }
            state.dispatched = true
        }
    }
}
