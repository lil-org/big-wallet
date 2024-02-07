// ∅ 2024 lil org

import Foundation

struct DirectTransactionRequest: Codable {
    let id: Int
    let to: String
    let from: String
    let data: String
    let value: String
    let gas: String
    let gasPrice: String
    let swap: String
    let token: String
    let ticker: String
    let amountTo: String
    let amountFrom: String
}

extension DirectTransactionRequest {
    
    init?(from urlString: String) {
        guard let url = URL(string: urlString),
              let host = url.host, ["farcap.vercel.app", "yo.finance"].contains(host), // TODO: remove vercel
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        var parameters = queryItems.reduce(into: [String: Any]()) { (result, item) in
            result[item.name] = item.value ?? ""
        }
        
        parameters["id"] = Int.random(in: 1..<Int.max)
        
        do {
            let data = try JSONSerialization.data(withJSONObject: parameters, options: [])
            self = try JSONDecoder().decode(DirectTransactionRequest.self, from: data)
        } catch { return nil }
    }
    
}
