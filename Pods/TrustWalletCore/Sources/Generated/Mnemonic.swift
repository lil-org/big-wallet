// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Mnemonic validate / lookup functions
public struct Mnemonic {

    /// Determines whether a BIP39 English mnemonic phrase is valid.
    ///
    /// - Parameter mnemonic: Non-null BIP39 english mnemonic
    /// - Returns: true if the mnemonic is valid, false otherwise
    public static func isValid(mnemonic: String) -> Bool {
        let mnemonicString = TWStringCreateWithNSString(mnemonic)
        defer {
            TWStringDelete(mnemonicString)
        }
        return TWMnemonicIsValid(mnemonicString)
    }

    /// Determines whether word is a valid BIP39 English mnemonic word.
    ///
    /// - Parameter word: Non-null BIP39 English mnemonic word
    /// - Returns: true if the word is a valid BIP39 English mnemonic word, false otherwise
    public static func isValidWord(word: String) -> Bool {
        let wordString = TWStringCreateWithNSString(word)
        defer {
            TWStringDelete(wordString)
        }
        return TWMnemonicIsValidWord(wordString)
    }

    /// Return BIP39 English words that match the given prefix. A single string is returned, with space-separated list of words.
    ///
    /// - Parameter prefix: Non-null string prefix
    /// - Returns: Single non-null string, space-separated list of words containing BIP39 words that match the given prefix.
    public static func suggest(prefix: String) -> String {
        let prefixString = TWStringCreateWithNSString(prefix)
        defer {
            TWStringDelete(prefixString)
        }
        return TWStringNSString(TWMnemonicSuggest(prefixString))
    }


    init() {
    }


}
