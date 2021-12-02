// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

class GasService {
    
    struct Message: Codable {
        let data: Info
    }
    
    struct Info: Codable {
        let standard: UInt
        let slow: UInt
        let fast: UInt
        let rapid: UInt
        
        var sortedValues: [UInt] {
            return Set([slow, standard, fast, rapid]).sorted()
        }
    }
    
    static let shared = GasService()
    
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .default)
    
    private init() {}
    
    var currentInfo: Info?
    
    func start() {
        getMessage()
    }
    
    private func getMessage() {
        let url = URL(string: "https://etherchain.org/api/gasnow")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            if let data = data, let info = try? self?.jsonDecoder.decode(Message.self, from: data).data {
                DispatchQueue.main.async {
                    self?.currentInfo = info
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(30)) {
                self?.getMessage()
            }
        }
        dataTask.resume()
    }
    
}
