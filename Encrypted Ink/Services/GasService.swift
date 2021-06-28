// Copyright © 2021 Encrypted Ink. All rights reserved.

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
    }
    
    static let shared = GasService()
    
    private let webSocketTask: URLSessionWebSocketTask
    private let jsonDecoder = JSONDecoder()
    
    private init() {
        let url = URL(string: "wss://www.gasnow.org/ws/gasprice")!
        let urlSession = URLSession(configuration: .default)
        webSocketTask = urlSession.webSocketTask(with: url)
    }
    
    var currentInfo: Info?
    
    func start() {
        webSocketTask.resume()
        getMessage()
    }
    
    private func getMessage() {
        webSocketTask.receive { [weak self] result in
            if case let .success(message) = result,
               case let .string(text) = message,
               let data = text.data(using: .utf8),
               let info = try? self?.jsonDecoder.decode(Message.self, from: data).data {
                DispatchQueue.main.async {
                    self?.currentInfo = info
                }
            }
            self?.getMessage()
        }
    }
    
}
