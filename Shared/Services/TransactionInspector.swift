// Copyright © 2023 Tokenary. All rights reserved.

import Foundation
import WalletCore

struct TransactionInspector {
    
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
        let parsedArguments = parseArguments(args)
        let inputs = parsedArguments.compactMap { argToDict(arg: $0) }
        guard inputs.count == parsedArguments.count else { return nil }
        let dict: [String: Any] = ["inputs": inputs, "name": name, "outputs": []]
        let abi = [nameHex: dict]
        if let abiData = try? JSONSerialization.data(withJSONObject: abi),
           let abiString = String(data: abiData, encoding: .utf8),
           let callData = Data(hexString: data),
           let decoded = EthereumAbi.decodeCall(data: callData, abi: abiString),
           let decodedData = decoded.data(using: .utf8),
           let decodedInputs = (try? JSONSerialization.jsonObject(with: decodedData) as? [String: Any])?["inputs"] as? [[String: Any]] {
            let values = decodedInputs.compactMap { flatValueFrom(input: $0) }
            guard values.contains(where: { !$0.isEmpty }) else { return nil }
            let flat = [signature] + values
            return flat.joined(separator: "\n\n")
        } else {
            return nil
        }
    }
    
    private func parseArguments(_ arguments: String) -> [Any] {
        var args = [Any]()
        var currentArg = ""
        var parenthesisLevel = 0
        
        for char in arguments {
            if char == "(" {
                parenthesisLevel += 1
                if parenthesisLevel > 1 {
                    currentArg.append(char)
                }
            } else if char == ")" {
                parenthesisLevel -= 1
                if parenthesisLevel > 0 {
                    currentArg.append(char)
                } else if parenthesisLevel == 0 {
                    args.append(parseArguments(currentArg))
                    currentArg = ""
                }
            } else if char == "," {
                if parenthesisLevel == 0 {
                    if !currentArg.isEmpty {
                        args.append(currentArg.trimmingCharacters(in: .whitespacesAndNewlines))
                        currentArg = ""
                    }
                } else {
                    currentArg.append(char)
                }
            } else {
                currentArg.append(char)
            }
        }
        
        if !currentArg.isEmpty {
            args.append(parenthesisLevel == 0 ? currentArg.trimmingCharacters(in: .whitespacesAndNewlines) : parseArguments(currentArg))
        }
        
        return args
    }
    
    private func flatValueFrom(input: [String: Any]) -> String? {
        if let value = input["value"] as? String {
            return value
        } else if let components = input["components"] as? [[String: Any]] {
            let flatComponents = components.compactMap { flatValueFrom(input: $0) }
            let joined = flatComponents.joined(separator: ", ")
            return "(" + joined + ")"
        } else {
            return nil
        }
    }
    
    private func argToDict(arg: Any) -> [String: Any]? {
        if let argString = arg as? String {
            return ["name": "", "type": argString]
        } else if let args = arg as? [Any] {
            let components = args.compactMap { argToDict(arg: $0) }
            guard components.count == args.count else { return nil }
            return ["name": "", "type": "tuple", "components": components]
        } else {
            return nil
        }
    }
    
}
