import UIKit
import Alamofire
import SwiftyJSON

extension TokenaryWallet {
    
    var walletName: String? {
        get {
            return UserDefaults.standard.value(forKey: "wallet_\(self.id)") as? String
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "wallet_\(self.id)")
            NotificationCenter.default.post(name: .walletsUpdated, object: nil)
        }
    }
    //EthereumChain
    func getBalances(for chains: [EthereumChain], completion: @escaping(Double?, EthereumChain)->Void) {
        for chain in chains {
            guard let address = self.ethereumAddress else {
                completion(nil, chain)
                return
            }
            let endpoint = chain.nodeURLString
            let parameters: [String: Any] = [
                "jsonrpc" : "2.0",
                "method" : "eth_getBalance",
                "params" : [address, "latest"],
                "id" : 1
            ]
            AF.request(endpoint, method: .post, parameters: parameters, encoding: JSONEncoding.default).response { response in
                switch response.result {
                case .success(let data):
                    if let data = data {
                        let json = try! JSON(data: data)
                        let value = json["result"].stringValue.removedPrefix("0x")
                        if let d4 = Int(value, radix: 16) {
                            let ethBalance = Double(d4) / 1000000000000000000
                            completion(ethBalance, chain)
                        } else {
                            print("don't get value for \(chain.name)")
                            print(value)
                        }
                    }
                case .failure(_):
                    completion(nil, chain)
                    break
                }
            }
        }
    }
}
