// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Preset encryption parameter with different security strength, for key store
public enum StoredKeyEncryptionLevel: UInt32, CaseIterable {
    case `default` = 0
    case minimal = 1
    case weak = 2
    case standard = 3
}
