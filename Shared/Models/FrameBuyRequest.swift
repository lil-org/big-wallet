// ∅ 2024 lil org

import Foundation

struct FrameBuyRequest: Codable {
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

extension FrameBuyRequest {
    
    init?(from urlString: String) {
        guard let url = URL(string: urlString),
              let host = url.host, ["farcap.vercel.app", "yo.finance"].contains(host), // TODO: remove vercel
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        let parameters = queryItems.reduce(into: [String: String]()) { (result, item) in
            result[item.name] = item.value ?? ""
        }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: parameters, options: [])
            self = try JSONDecoder().decode(FrameBuyRequest.self, from: data)
        } catch { return nil }
    }
    
}
