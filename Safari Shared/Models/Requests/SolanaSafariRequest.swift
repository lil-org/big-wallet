// ∅ 2026 lil org

import Foundation

extension SafariRequest {

    struct Solana: Sendable {

        enum Method: String, Sendable {
            case connect
            case signMessage
            case signTransaction
            case signAllTransactions
            case signAndSendTransaction
        }

        enum MessageEncoding: Equatable, Sendable {
            case hex
            case utf8

            init?(wireValue: String) {
                switch wireValue.lowercased() {
                case "hex":
                    self = .hex
                case "utf8":
                    self = .utf8
                default:
                    return nil
                }
            }
        }

        let method: Method
        let publicKey: String
        let message: String?
        let transaction: String?
        let messages: [String]?
        let displayHex: Bool
        let signMessageEncoding: MessageEncoding?
        private let sendOptionsObject: WireProtocol.JSONObject?
        var sendOptions: [String: Any]? { sendOptionsObject?.json }
        let onlyIfTrusted: Bool

        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let publicKey = json["publicKey"] as? String
            else { return nil }

            self.method = method
            self.publicKey = publicKey

            let parameters = (json["object"] as? [String: Any])?["params"] as? [String: Any]
            if let value = parameters?["onlyIfTrusted"] {
                guard let flag = value as? Bool,
                      CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
                onlyIfTrusted = flag
            } else {
                onlyIfTrusted = false
            }
            self.message = parameters?["message"] as? String
            self.transaction = parameters?["transaction"] as? String
            self.messages = parameters?["messages"] as? [String]
            let display = parameters?["display"] as? String
            self.displayHex = display?.lowercased() == "hex"
            if let messageEncoding = parameters?["messageEncoding"] as? String {
                self.signMessageEncoding = MessageEncoding(wireValue: messageEncoding)
            } else {
                self.signMessageEncoding = display?.lowercased() == "utf8" ? .utf8 : .hex
            }
            self.sendOptionsObject = (parameters?["options"] as? [String: Any]).flatMap { WireProtocol.JSONObject($0) }
        }



    }

}
