// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

let semaphore = DispatchSemaphore(value: 0)

let projectDir = FileManager.default.currentDirectoryPath
let filePath = "\(projectDir)/tools/generated/ethereum-networks.json"

func fetchChains(completion: @escaping ([EIP155ChainData]) -> Void) {
    URLSession.shared.dataTask(with: URL(string: "https://chainid.network/chains.json")!) { (data, _, _) in
        completion(try! JSONDecoder().decode([EIP155ChainData].self, from: data!))
    }.resume()
}

fetchChains { chains in
    let currentData = try! Data(contentsOf: URL(fileURLWithPath: filePath))
    let currentNetworks = try! JSONDecoder().decode([EthereumNetwork].self, from: currentData)
    let ids = Set(currentNetworks.map { $0.chainId })
    
    let filtered = chains.filter { ids.contains($0.chainId) }
    let result = filtered.map {
        EthereumNetwork(chainId: $0.chainId,
                        name: $0.name,
                        symbol: $0.nativeCurrency.symbol,
                        nodeURLString: $0.rpc.first ?? "")
    }
    
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
    let data = try! encoder.encode(result)
    try! data.write(to: URL(fileURLWithPath: filePath))
    semaphore.signal()
}

semaphore.wait()
print("🟢 all done")
