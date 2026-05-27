// ∅ 2026 lil org

import Foundation

struct TransactionInspector {
    private enum ParsedArgument {
        case type(String)
        case tuple([ParsedArgument], suffix: String)
    }
    
    static let shared = TransactionInspector()
    private init() {}
    
    private let urlSession = URLSession.shared
    
    func interpret(data: String, completion: @escaping (String) -> Void) {
        let length = 8
        let nameHex = String(data.cleanHex.prefix(length))
        guard nameHex.count == length else { return }
        
        getMethodSignature(nameHex: nameHex) { signature in
            let decoded = decode(data: data, nameHex: nameHex, signature: signature)
            let result = decoded ?? (signature + "\n\n" + data)
            DispatchQueue.main.async { completion(result) }
        }
    }
    
    // https://github.com/ethereum-lists/4bytes
    private func getMethodSignature(nameHex: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "https://raw.githubusercontent.com/ethereum-lists/4bytes/master/signatures/\(nameHex)") else { return }
        let dataTask = urlSession.dataTask(with: url) { (data, response, error) in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil,
               (200...299).contains(statusCode),
               let data = data,
               let sig = String(data: data, encoding: .utf8),
               !sig.isEmpty {
                completion(sig)
            }
        }
        dataTask.resume()
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
