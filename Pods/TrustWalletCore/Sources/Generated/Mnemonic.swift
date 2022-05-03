// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public struct Mnemonic {

    public static func isValid(mnemonic: String) -> Bool {
        let mnemonicString = TWStringCreateWithNSString(mnemonic)
        defer {
            TWStringDelete(mnemonicString)
        }
        return TWMnemonicIsValid(mnemonicString)
    }

    public static func isValidWord(word: String) -> Bool {
        let wordString = TWStringCreateWithNSString(word)
        defer {
            TWStringDelete(wordString)
        }
        return TWMnemonicIsValidWord(wordString)
    }

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
