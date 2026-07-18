// ∅ 2026 lil org

import Foundation

final class SafariRPCClient {

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func send(url: URL,
              body: Data,
              completion: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        urlSession.dataTask(with: request) { data, _, _ in
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let response = object as? [String: Any] else {
                completion(nil)
                return
            }
            completion(response)
        }.resume()
    }

}
