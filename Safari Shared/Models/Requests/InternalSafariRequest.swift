// ∅ 2026 lil org

struct InternalSafariRequest: Decodable {
    let id: Int
    let subject: Subject
    let body: String?
    let chainId: String?
    let provider: InpageProvider?
    
    enum Subject: String, Decodable {
        case getResponse, cancelRequest, rpc, prewarmAlchemy
    }
}
