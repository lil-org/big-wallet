// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

let semaphore = DispatchSemaphore(value: 0)

let projectDir = FileManager.default.currentDirectoryPath
let filePath = "\(projectDir)/Shared/Supporting Files/ethereum-networks.json"

let mainnets = [1, 42161, 137, 10, 56, 43114, 100, 250, 42220, 1313161554, 245022934, 8453, 7777777, 8217, 534352]
let testnets = [421611, 144545313136048, 69, 5, 80001, 97, 43113, 4002, 64240, 245022926, 534351]

func fetchChains(completion: @escaping ([EIP155ChainData]) -> Void) {
    URLSession.shared.dataTask(with: URL(string: "https://chainid.network/chains.json")!) { (data, _, _) in
        completion(try! JSONDecoder().decode([EIP155ChainData].self, from: data!))
    }.resume()
}

fetchChains { chains in
    let ok = Set(mainnets + testnets)
    let filtered = chains.filter { ok.contains($0.chainId) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    let data = try! encoder.encode(filtered)
    try! data.write(to: URL(fileURLWithPath: filePath))
    semaphore.signal()
}

semaphore.wait()
