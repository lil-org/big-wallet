// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// CoinTypeConfiguration functions
public struct CoinTypeConfiguration {

    /// Returns stock symbol of coin
    ///
    /// - Parameter type: A coin type
    /// - Returns: A non-null TWString stock symbol of coin
    /// - Note: Caller must free returned object
    public static func getSymbol(type: CoinType) -> String {
        return TWStringNSString(TWCoinTypeConfigurationGetSymbol(TWCoinType(rawValue: type.rawValue)))
    }

    /// Returns max count decimal places for minimal coin unit
    ///
    /// - Parameter type: A coin type
    /// - Returns: Returns max count decimal places for minimal coin unit
    public static func getDecimals(type: CoinType) -> Int32 {
        return TWCoinTypeConfigurationGetDecimals(TWCoinType(rawValue: type.rawValue))
    }

    /// Returns transaction url in blockchain explorer
    ///
    /// - Parameter type: A coin type
    /// - Parameter transactionID: A transaction identifier
    /// - Returns: Returns a non-null TWString transaction url in blockchain explorer
    public static func getTransactionURL(type: CoinType, transactionID: String) -> String {
        let transactionIDString = TWStringCreateWithNSString(transactionID)
        defer {
            TWStringDelete(transactionIDString)
        }
        return TWStringNSString(TWCoinTypeConfigurationGetTransactionURL(TWCoinType(rawValue: type.rawValue), transactionIDString))
    }

    /// Returns account url in blockchain explorer
    ///
    /// - Parameter type: A coin type
    /// - Parameter accountID: an Account identifier
    /// - Returns: Returns a non-null TWString account url in blockchain explorer
    public static func getAccountURL(type: CoinType, accountID: String) -> String {
        let accountIDString = TWStringCreateWithNSString(accountID)
        defer {
            TWStringDelete(accountIDString)
        }
        return TWStringNSString(TWCoinTypeConfigurationGetAccountURL(TWCoinType(rawValue: type.rawValue), accountIDString))
    }

    /// Returns full name of coin in lower case
    ///
    /// - Parameter type: A coin type
    /// - Returns: Returns a non-null TWString, full name of coin in lower case
    public static func getID(type: CoinType) -> String {
        return TWStringNSString(TWCoinTypeConfigurationGetID(TWCoinType(rawValue: type.rawValue)))
    }

    /// Returns full name of coin
    ///
    /// - Parameter type: A coin type
    /// - Returns: Returns a non-null TWString, full name of coin
    public static func getName(type: CoinType) -> String {
        return TWStringNSString(TWCoinTypeConfigurationGetName(TWCoinType(rawValue: type.rawValue)))
    }


    init() {
    }


}
