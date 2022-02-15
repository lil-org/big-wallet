import UIKit
import Alamofire
import SwiftyJSON
import BigInt

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
    func getBalances(for chains: [EthereumChain], completion: @escaping(String?, EthereumChain) -> Void) {
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
                    if let data = data, let json = try? JSON(data: data) {
                        let value = json["result"].stringValue.removedPrefix("0x")
                        if let amount = BigUInt(value, radix: 16) {
                            completion(formatToPrecision(amount, numberDecimals: 18, formattingDecimals: 18), chain)
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

// MARK: - Web3Swift

/// Formats a BigUInt object to String. The supplied number is first divided into integer and decimal part based on "numberDecimals",
/// then limits the decimal part to "formattingDecimals" symbols and uses a "decimalSeparator" as a separator.
/// Fallbacks to scientific format if higher precision is required.
///
/// Returns nil of formatting is not possible to satisfy.
/// https://github.com/skywinder/web3swift/blob/5b45521c05006195ccd5109d24570e35150c87e1/Sources/web3swift/Web3/Web3%2BUtils.swift#L6046-L6096
fileprivate func formatToPrecision(_ bigNumber: BigUInt, numberDecimals: Int = 18, formattingDecimals: Int = 4, decimalSeparator: String = ".", fallbackToScientific: Bool = false) -> String? {
    if bigNumber == 0 {
        return "0"
    }
    let unitDecimals = numberDecimals
    var toDecimals = formattingDecimals
    if unitDecimals < toDecimals {
        toDecimals = unitDecimals
    }
    let divisor = BigUInt(10).power(unitDecimals)
    let (quotient, remainder) = bigNumber.quotientAndRemainder(dividingBy: divisor)
    var fullRemainder = String(remainder);
    let fullPaddedRemainder = fullRemainder.leftPadding(toLength: unitDecimals, withPad: "0")
    let remainderPadded = fullPaddedRemainder[0..<toDecimals]
    if remainderPadded == String(repeating: "0", count: toDecimals) {
        if quotient != 0 {
            return String(quotient)
        } else if fallbackToScientific {
            var firstDigit = 0
            for char in fullPaddedRemainder {
                if (char == "0") {
                    firstDigit = firstDigit + 1;
                } else {
                    let firstDecimalUnit = String(fullPaddedRemainder[firstDigit ..< firstDigit+1])
                    var remainingDigits = ""
                    let numOfRemainingDecimals = fullPaddedRemainder.count - firstDigit - 1
                    if numOfRemainingDecimals <= 0 {
                        remainingDigits = ""
                    } else if numOfRemainingDecimals > formattingDecimals {
                        let end = firstDigit+1+formattingDecimals > fullPaddedRemainder.count ? fullPaddedRemainder.count : firstDigit+1+formattingDecimals
                        remainingDigits = String(fullPaddedRemainder[firstDigit+1 ..< end])
                    } else {
                        remainingDigits = String(fullPaddedRemainder[firstDigit+1 ..< fullPaddedRemainder.count])
                    }
                    if remainingDigits != "" {
                        fullRemainder = firstDecimalUnit + decimalSeparator + remainingDigits
                    } else {
                        fullRemainder = firstDecimalUnit
                    }
                    firstDigit = firstDigit + 1;
                    break
                }
            }
            return fullRemainder + "e-" + String(firstDigit)
        }
    }
    if (toDecimals == 0) {
        return String(quotient)
    }
    return String(quotient) + decimalSeparator + remainderPadded
}

extension String {
    /// https://github.com/skywinder/web3swift/blob/5484e81580219ea491d48e94f6aef6f18d8ec58f/Sources/web3swift/Convenience/String%2BExtension.swift#L36-L40
    fileprivate subscript (bounds: CountableClosedRange<Int>) -> String {
        let start = index(self.startIndex, offsetBy: bounds.lowerBound)
        let end = index(self.startIndex, offsetBy: bounds.upperBound)
        return String(self[start...end])
    }
    
    /// https://github.com/skywinder/web3swift/blob/5484e81580219ea491d48e94f6aef6f18d8ec58f/Sources/web3swift/Convenience/String%2BExtension.swift#L42-L46
    fileprivate subscript (bounds: CountableRange<Int>) -> String {
        let start = index(self.startIndex, offsetBy: bounds.lowerBound)
        let end = index(self.startIndex, offsetBy: bounds.upperBound)
        return String(self[start..<end])
    }
    
    /// https://github.com/skywinder/web3swift/blob/5484e81580219ea491d48e94f6aef6f18d8ec58f/Sources/web3swift/Convenience/String%2BExtension.swift#L48-L52
    fileprivate subscript (bounds: CountablePartialRangeFrom<Int>) -> String {
        let start = index(self.startIndex, offsetBy: bounds.lowerBound)
        let end = self.endIndex
        return String(self[start..<end])
    }
    
    /// https://github.com/skywinder/web3swift/blob/5484e81580219ea491d48e94f6aef6f18d8ec58f/Sources/web3swift/Convenience/String%2BExtension.swift#L54-L61
    fileprivate func leftPadding(toLength: Int, withPad character: Character) -> String {
        let stringLength = self.count
        if stringLength < toLength {
            return String(repeatElement(character, count: toLength - stringLength)) + self
        } else {
            return String(self.suffix(toLength))
        }
    }
}
