// ∅ 2024 lil org

import Foundation

struct InternalSafariRequest: Codable {
    let id: Int
    let subject: Subject
    let body: String?
    let chainId: String?
    
    enum Subject: String, Codable {
        case getResponse, cancelRequest, rpc
    }
}
