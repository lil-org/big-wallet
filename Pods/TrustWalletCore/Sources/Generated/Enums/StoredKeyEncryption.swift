// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Preset encryption kind
public enum StoredKeyEncryption: UInt32, CaseIterable {
    case aes128Ctr = 0
    case aes128Cbc = 1
    case aes192Ctr = 2
    case aes256Ctr = 3
}
