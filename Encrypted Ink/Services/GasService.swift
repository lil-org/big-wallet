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
        
        var sortedValues: [UInt] {
            return Set([slow, standard, fast, rapid]).sorted()
        }
    }
    
    static let shared = GasService()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .default)
    
    private init() {}
    
    var currentInfo: Info?
    
    func start() {
        let url = URL(string: "wss://www.gasnow.org/ws/gasprice")!
        webSocketTask?.cancel()
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        getMessage()
    }
    
    private func getMessage() {
        webSocketTask?.receive { [weak self] result in
            if case let .success(message) = result,
               case let .string(text) = message,
               let data = text.data(using: .utf8),
               let info = try? self?.jsonDecoder.decode(Message.self, from: data).data {
                DispatchQueue.main.async {
                    self?.currentInfo = info
                }
                self?.getMessage()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) {
                    self?.start()
                }
            }
        }
    }
    
}
