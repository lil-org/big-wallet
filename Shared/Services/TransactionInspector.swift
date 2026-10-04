// ∅ 2026 lil org

import Foundation

struct TransactionInspector: Sendable {

    private enum ParsedArgument {
        case type(String)
        case tuple([ParsedArgument], suffix: String)
    }
    
    static let shared = TransactionInspector()
    private let methodSignatures: MethodSignatureStore
    private let decoder:
    (@Sendable (_ data: String, _ nameHex: String, _ signature: String) -> String?)?

    init(
        urlSession: URLSession = .shared,
        onSubscriberRegistered: (@Sendable () -> Void)? = nil,
        decoder:
            (@Sendable (_ data: String, _ nameHex: String, _ signature: String) -> String?)?
            = nil
    ) {
        methodSignatures = MethodSignatureStore(urlSession: urlSession, onSubscriberRegistered: onSubscriberRegistered)
        self.decoder = decoder
    }

    @concurrent
    func interpret(data: String) async throws -> String? {
        try Task.checkCancellation()
        let nameHex = String(data.cleanHex.prefix(8)).lowercased()
        guard nameHex.count == 8, nameHex.allSatisfy(\.isHexDigit) else { return nil }
        guard let signature = try await methodSignatures.resolve(nameHex: nameHex) else { return nil }
        try Task.checkCancellation()
        let decoded: String?
        if let decoder {
            decoded = decoder(data, nameHex, signature)
        } else {
            decoded = decode(data: data, nameHex: nameHex, signature: signature)
        }
        try Task.checkCancellation()
        return decoded ?? (signature + "\n\n" + data)
    }

    func decode(data: String, nameHex: String, signature: String) -> String? {
        guard let start = signature.firstIndex(of: "("), signature.hasSuffix(")") else { return nil }
        let name = signature.prefix(upTo: start)
        let args = String(signature.dropFirst(name.count + 1).dropLast())
        guard let parsedArguments = parseArguments(args) else { return nil }
        let inputs = parsedArguments.map { argToDict(arg: $0) }
        let dict: [String: Any] = ["inputs": inputs, "name": name, "outputs": []]
        let abi = [nameHex: dict]
        if let abiData = try? JSONSerialization.data(withJSONObject: abi),
           let abiString = String(data: abiData, encoding: .utf8),
           let callData = WalletCrypto.hexData(string: data),
           let decoded = WalletCrypto.decodeEthereumCall(data: callData, abi: abiString),
           let decodedData = decoded.data(using: .utf8),
           let decodedInputs = (try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any])?["inputs"] as? [[String: Any]] {
            let values = decodedInputs.compactMap { flatValueFrom(input: $0) }
            guard values.count == decodedInputs.count else { return nil }
            guard values.contains(where: { !$0.isEmpty }) else { return nil }
            let flat = [signature] + values
            return flat.joined(separator: "\n\n")
        } else {
            return nil
        }
    }
    
    private func parseArguments(_ arguments: String) -> [ParsedArgument]? {
        var args = [ParsedArgument]()
        var currentArg = ""
        var parenthesisLevel = 0
        var pendingTupleComponents: [ParsedArgument]?

        func appendCurrentArgument() -> Bool {
            let text = currentArg.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                currentArg = ""
                pendingTupleComponents = nil
            }
            if let pendingTupleComponents {
                guard isTupleSuffix(text) else { return false }
                args.append(.tuple(pendingTupleComponents, suffix: text))
            } else if !text.isEmpty {
                args.append(.type(text))
            }
            return true
        }
        
        for char in arguments {
            if char == "(" {
                guard pendingTupleComponents == nil else { return nil }
                if parenthesisLevel == 0, !currentArg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                parenthesisLevel += 1
                if parenthesisLevel > 1 {
                    currentArg.append(char)
                }
            } else if char == ")" {
                parenthesisLevel -= 1
                guard parenthesisLevel >= 0 else { return nil }
                if parenthesisLevel > 0 {
                    currentArg.append(char)
                } else if parenthesisLevel == 0 {
                    guard let components = parseArguments(currentArg) else { return nil }
                    pendingTupleComponents = components
                    currentArg = ""
                }
            } else if char == "," {
                if parenthesisLevel == 0 {
                    guard appendCurrentArgument() else { return nil }
                } else {
                    currentArg.append(char)
                }
            } else {
                currentArg.append(char)
            }
        }
        
        guard parenthesisLevel == 0, appendCurrentArgument() else { return nil }
        
        return args
    }
    
    private func flatValueFrom(input: [String: Any], inAggregate: Bool = false) -> String? {
        if let components = input["components"] as? [[String: Any]] {
            return flatTupleFrom(components: components)
        }
        guard let value = input["value"] else { return nil }
        return flatValueFrom(value: value, type: input["type"] as? String, inAggregate: inAggregate)
    }

    private func flatValueFrom(value: Any, type: String?, inAggregate: Bool) -> String? {
        if let value = value as? String {
            if inAggregate, type == "string" {
                return quotedString(value)
            }
            return value
        }
        if let value = value as? Bool {
            return value ? "true" : "false"
        }
        if let values = value as? [Any], values.isEmpty {
            return "[]"
        }
        if let components = value as? [[String: Any]] {
            return flatTupleFrom(components: components)
        }
        if let values = value as? [Any] {
            let elementType = arrayElementType(from: type)
            let flatValues = values.compactMap { flatValueFrom(value: $0, type: elementType, inAggregate: true) }
            guard flatValues.count == values.count else { return nil }
            return "[" + flatValues.joined(separator: ", ") + "]"
        }
        return nil
    }

    private func flatTupleFrom(components: [[String: Any]]) -> String? {
        let flatComponents = components.compactMap { flatValueFrom(input: $0, inAggregate: true) }
        guard flatComponents.count == components.count else { return nil }
        let joined = flatComponents.joined(separator: ", ")
        return "(" + joined + ")"
    }
    
    private func argToDict(arg: ParsedArgument) -> [String: Any] {
        switch arg {
        case let .type(argString):
            return ["name": "", "type": argString]
        case let .tuple(args, suffix):
            let components = args.map { argToDict(arg: $0) }
            return ["name": "", "type": "tuple" + suffix, "components": components]
        }
    }

    private func isTupleSuffix(_ suffix: String) -> Bool {
        var remaining = suffix[...]
        while !remaining.isEmpty {
            guard remaining.first == "[" else { return false }
            guard let close = remaining.firstIndex(of: "]") else { return false }
            let countStart = remaining.index(after: remaining.startIndex)
            let count = remaining[countStart..<close]
            guard count.allSatisfy({ $0.isNumber }) else { return false }
            remaining = remaining[remaining.index(after: close)...]
        }
        return true
    }

    private func arrayElementType(from type: String?) -> String? {
        guard let type,
              let bracket = type.lastIndex(of: "["),
              type.hasSuffix("]") else { return nil }
        return String(type[..<bracket])
    }

    private func quotedString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8),
              json.hasPrefix("["),
              json.hasSuffix("]") else { return "\"\(value)\"" }
        return String(json.dropFirst().dropLast())
    }
    
}

private actor MethodSignatureStore {
    private struct PendingRequest {
        let identifier: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<String?, Error>]
    }

    private let urlSession: URLSession
    private let onSubscriberRegistered: (@Sendable () -> Void)?
    private var cache = [String: String]()
    private var cacheOrder = [String]()
    private var pendingRequests = [String: PendingRequest]()

    init(urlSession: URLSession, onSubscriberRegistered: (@Sendable () -> Void)?) {
        self.urlSession = urlSession
        self.onSubscriberRegistered = onSubscriberRegistered
    }

    func resolve(nameHex: String) async throws -> String? {
        try Task.checkCancellation()
        if let signature = cache[nameHex] { return signature }
        guard
            let url = URL(
                string: "https://raw.githubusercontent.com/ethereum-lists/4bytes/master/signatures/\(nameHex)")
        else { return nil }
        let subscriberID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                defer { onSubscriberRegistered?() }
                if pendingRequests[nameHex] != nil {
                    pendingRequests[nameHex]?.subscribers[subscriberID] = continuation
                    return
                }
                let requestID = UUID()
                let task = Task { [weak self, urlSession] in
                    let result: Result<String?, Error>
                    do {
                        let (data, response) = try await urlSession.data(from: url)
                        try Task.checkCancellation()
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        let signature = String(data: data, encoding: .utf8)
                        result = .success(
                            (200...299).contains(statusCode) && signature?.isEmpty == false ? signature : nil)
                    } catch {
                        result = .failure(error)
                    }
                    await self?.complete(nameHex: nameHex, requestID: requestID, result: result)
                }
                pendingRequests[nameHex] = PendingRequest(
                    identifier: requestID, task: task, subscribers: [subscriberID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(nameHex: nameHex, subscriberID: subscriberID) }
        }
    }

    private func cancel(nameHex: String, subscriberID: UUID) {
        guard let continuation = pendingRequests[nameHex]?.subscribers.removeValue(forKey: subscriberID) else { return }
        continuation.resume(throwing: CancellationError())
        if pendingRequests[nameHex]?.subscribers.isEmpty == true {
            pendingRequests.removeValue(forKey: nameHex)?.task.cancel()
        }
    }

    private func complete(nameHex: String, requestID: UUID, result: Result<String?, Error>) {
        guard let pending = pendingRequests[nameHex], pending.identifier == requestID else { return }
        pendingRequests.removeValue(forKey: nameHex)
        if case .success(let signature?) = result {
            cache[nameHex] = signature
            cacheOrder.removeAll { $0 == nameHex }
            cacheOrder.append(nameHex)
            if cacheOrder.count > 256 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        for continuation in pending.subscribers.values {
            continuation.resume(with: result)
        }
    }
}
