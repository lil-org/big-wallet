// ∅ 2026 lil org

import Foundation

extension SafariRequest {

    public struct Solana: Sendable {

        public enum Method: String, Sendable {
            case connect
            case signMessage
            case signTransaction
            case signAllTransactions
            case signAndSendTransaction
        }

        public enum MessageEncoding: Equatable, Sendable {
            case hex
            case utf8

            public init?(wireValue: String) {
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

        public let method: Method
        public let publicKey: String
        public let message: String?
        public let transaction: String?
        public let messages: [String]?
        public let displayHex: Bool
        public let signMessageEncoding: MessageEncoding?
        private let sendOptionsObject: WireProtocol.JSONObject?
        public var sendOptions: [String: Any]? { sendOptionsObject?.json }
        public let onlyIfTrusted: Bool

        public init?(name: String, json: [String: Any]) {
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
