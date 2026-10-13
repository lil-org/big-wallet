import Darwin
import Foundation
import Synchronization

indirect enum HarnessValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HarnessValue])
    case object([String: HarnessValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else { self = .object(try value.decode([String: Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func convert(_ value: Any) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
    }

    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundation)
        case .object(let value): value.mapValues(\.foundation)
        }
    }

    var object: [String: Self] { if case .object(let value) = self { value } else { [:] } }
    var array: [Self] { if case .array(let value) = self { value } else { [] } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? { number.flatMap { $0.isFinite ? Int(exactly: $0) : nil } }
    subscript(_ key: String) -> Self { object[key] ?? .null }

    func requiredString(_ key: String) throws -> String {
        guard let value = self[key].string else { throw HarnessError.invalid("Missing string: \(key)") }
        return value
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case invalid(String)
    case timeout(String)
    case closed

    var description: String {
        switch self {
        case .invalid(let message): message
        case .timeout(let message): "Timed out: \(message)"
        case .closed: "Harness input closed"
        }
    }
}

enum HarnessOperation {
    @TaskLocal static var name = "idle"
    @TaskLocal static var identity = HarnessValue.null
}

final class HarnessIPC: Sendable {
    private final class Gate: Sendable {
        private enum State {
            case pending
            case waiting(CheckedContinuation<HarnessValue, Error>)
            case finished(Result<HarnessValue, Error>)
        }
        private let state = Mutex(State.pending)
        private let semaphore = DispatchSemaphore(value: 0)

        func resolve(_ result: Result<HarnessValue, Error>) {
            let continuation = state.withLock { state -> CheckedContinuation<HarnessValue, Error>? in
                switch state {
                case .finished: return nil
                case .pending: state = .finished(result); return nil
                case .waiting(let continuation): state = .finished(result); return continuation
                }
            }
            semaphore.signal()
            continuation?.resume(with: result)
        }

        func wait() async throws -> HarnessValue {
            try await withCheckedThrowingContinuation { continuation in
                let resolved = state.withLock { state -> Result<HarnessValue, Error>? in
                    switch state {
                    case .pending: state = .waiting(continuation); return nil
                    case .finished(let result): return result
                    case .waiting: return .failure(HarnessError.invalid("Duplicate gate waiter"))
                    }
                }
                if let resolved { continuation.resume(with: resolved) }
            }
        }

        func waitSync() throws -> HarnessValue {
            semaphore.wait()
            return try state.withLock { state in
                guard case .finished(let result) = state else { throw HarnessError.closed }
                return try result.get()
            }
        }
    }

    private struct Rule: Sendable {
        let name: String
        let operation: String?
        let occurrence: Int
        let action: String
        let errorNumber: Int32
        var matches = 0
    }

    private struct State {
        var sequence = 0
        var gates = [String: Gate]()
        var rules = [Rule]()
        var partialWriteBytes: Int?
        var closed = false
    }

    let epoch: String
    let role: String
    private let state = Mutex(State())
    private let outputLock = Mutex(())

    init(epoch: String, role: String) {
        self.epoch = epoch
        self.role = role
    }

    var partialWriteBytes: Int? { state.withLock { $0.partialWriteBytes } }

    func configure(_ payload: HarnessValue) throws {
        let rules = try payload["rules"].array.map { value in
            let action = try value.requiredString("action")
            guard action == "hold" || action == "fail" else { throw HarnessError.invalid("Invalid checkpoint action") }
            return Rule(name: try value.requiredString("name"), operation: value["operation"].string,
                occurrence: max(1, value["occurrence"].int ?? 1), action: action,
                errorNumber: Int32(clamping: value["errno"].int ?? Int(EIO)))
        }
        state.withLock {
            $0.rules = rules
            $0.partialWriteBytes = payload["partialWriteBytes"].int.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    func send(_ value: HarnessValue) {
        outputLock.withLock { _ in write(value) }
    }

    private func write(_ value: HarnessValue) {
        do {
            var data = try JSONEncoder().encode(value)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch { Darwin._exit(74) }
    }

    func reply(id: HarnessValue, result: Result<HarnessValue, Error>) {
        var envelope: [String: HarnessValue] = ["kind": .string("reply"), "id": id, "epoch": .string(epoch)]
        switch result {
        case .success(let value): envelope["ok"] = .bool(true); envelope["result"] = value
        case .failure(let error): envelope["ok"] = .bool(false); envelope["error"] = .string(String(describing: error))
        }
        send(.object(envelope))
    }

    func event(_ name: String, details: HarnessValue = .object([:]), gate: String? = nil) {
        outputLock.withLock { _ in
            let sequence = state.withLock { state in state.sequence += 1; return state.sequence }
            var envelope: [String: HarnessValue] = ["kind": .string("event"), "epoch": .string(epoch),
                "role": .string(role), "sequence": .number(Double(sequence)), "event": .string(name), "details": details]
            if let gate { envelope["gate"] = .string(gate) }
            write(.object(envelope))
        }
    }

    func request(_ name: String, details: HarnessValue) async throws -> HarnessValue {
        let (identifier, gate) = try makeGate()
        event(name, details: details, gate: identifier)
        return try await withTaskCancellationHandler {
            try await gate.wait()
        } onCancel: { [self] in release(identifier, result: .failure(CancellationError())) }
    }

    func checkpoint(_ name: String, details: HarnessValue = .object([:])) async throws {
        let decision = checkpointDecision(name)
        let details = checkpointDetails(details)
        if let decision, decision.action == "fail" {
            event("checkpoint", details: details.merging(["name": .string(name), "fault": .bool(true)]))
            throw POSIXError(POSIXErrorCode(rawValue: decision.errorNumber) ?? .EIO)
        }
        if decision != nil || name == "signer.before" || name == "signer.after" {
            let value = try await request("checkpoint", details: details.merging([
                "name": .string(name), "hold": .bool(decision != nil),
            ]))
            try validateRelease(value)
        } else if !name.hasPrefix("persistence.") {
            event("checkpoint", details: details.merging(["name": .string(name)]))
        }
    }

    func checkpointSync(_ name: String, details: HarnessValue = .object([:])) throws {
        guard let decision = checkpointDecision(name) else {
            if !name.hasPrefix("persistence.") {
                event("checkpoint", details: checkpointDetails(details).merging(["name": .string(name)]))
            }
            return
        }
        let details = checkpointDetails(details).merging(["name": .string(name), "hold": .bool(true)])
        if decision.action == "fail" {
            event("checkpoint", details: details.merging(["fault": .bool(true)]))
            throw POSIXError(POSIXErrorCode(rawValue: decision.errorNumber) ?? .EIO)
        }
        let (identifier, gate) = try makeGate()
        event("checkpoint", details: details, gate: identifier)
        let value = try gate.waitSync()
        try validateRelease(value)
    }

    func receiveRelease(_ value: HarnessValue) {
        guard value["epoch"].string == epoch, let identifier = value["gate"].string else { return }
        release(identifier, result: .success(value["value"]))
    }

    func close() {
        let gates = state.withLock { state -> [Gate] in
            state.closed = true
            let gates = Array(state.gates.values)
            state.gates.removeAll()
            return gates
        }
        gates.forEach { $0.resolve(.failure(HarnessError.closed)) }
    }

    private func checkpointDetails(_ details: HarnessValue) -> HarnessValue {
        details.merging(["operation": .string(HarnessOperation.name), "identity": HarnessOperation.identity])
    }

    private func checkpointDecision(_ name: String) -> Rule? {
        state.withLock { state in
            for index in state.rules.indices where state.rules[index].name == name &&
                (state.rules[index].operation == nil || state.rules[index].operation == HarnessOperation.name) {
                state.rules[index].matches += 1
                if state.rules[index].matches == state.rules[index].occurrence { return state.rules[index] }
            }
            return nil
        }
    }

    private func validateRelease(_ value: HarnessValue) throws {
        if value["cancel"].bool == true { throw CancellationError() }
        if value["fail"].bool == true {
            throw POSIXError(POSIXErrorCode(rawValue: Int32(clamping: value["errno"].int ?? Int(EIO))) ?? .EIO)
        }
    }

    private func makeGate() throws -> (String, Gate) {
        let identifier = UUID().uuidString.lowercased()
        let gate = Gate()
        try state.withLock { state in
            guard !state.closed else { throw HarnessError.closed }
            state.gates[identifier] = gate
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.expireGate(identifier)
        }
        return (identifier, gate)
    }

    private func expireGate(_ identifier: String) {
        guard let gate = state.withLock({ $0.gates.removeValue(forKey: identifier) }) else { return }
        event("watchdog", details: .object(["gate": .string(identifier)]))
        gate.resolve(.failure(HarnessError.timeout(identifier)))
    }

    private func release(_ identifier: String, result: Result<HarnessValue, Error>) {
        let gate = state.withLock { $0.gates.removeValue(forKey: identifier) }
        gate?.resolve(result)
    }
}

extension HarnessValue {
    func merging(_ fields: [String: HarnessValue]) -> Self {
        .object(object.merging(fields) { _, new in new })
    }
}
