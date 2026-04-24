// ∅ 2026 lil org

import Foundation

extension SafariRequest {

    struct Solana: SafariRequestBody {

        enum Method: String, Decodable, CaseIterable {
            case connect
            case signMessage
            case signTransaction
            case signAllTransactions
            case signAndSendTransaction
        }

        enum MessageEncoding: Equatable {
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
        let sendOptions: [String: Any]?

        init?(name: String, json: [String: Any]) {
            guard let method = Method(rawValue: name),
                  let publicKey = json["publicKey"] as? String
            else { return nil }

            self.method = method
            self.publicKey = publicKey

            let parameters = (json["object"] as? [String: Any])?["params"] as? [String: Any]
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
            self.sendOptions = parameters?["options"] as? [String: Any]
        }

        var responseUpdatesStoredConfiguration: Bool {
            switch method {
            case .connect:
                return true
            case .signMessage, .signTransaction, .signAllTransactions, .signAndSendTransaction:
                return false
            }
        }

    }

}
