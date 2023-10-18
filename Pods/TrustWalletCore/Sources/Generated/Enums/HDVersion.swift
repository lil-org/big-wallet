// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

/// Registered HD version bytes
///
/// \see https://github.com/satoshilabs/slips/blob/master/slip-0132.md
public enum HDVersion: UInt32, CaseIterable {
    case none = 0
    case xpub = 0x0488b21e
    case xprv = 0x0488ade4
    case ypub = 0x049d7cb2
    case yprv = 0x049d7878
    case zpub = 0x04b24746
    case zprv = 0x04b2430c
    case vpub = 0x045f1cf6
    case vprv = 0x045f18bc
    case tpub = 0x043587cf
    case tprv = 0x04358394
    case ltub = 0x019da462
    case ltpv = 0x019d9cfe
    case mtub = 0x01b26ef6
    case mtpv = 0x01b26792
    case ttub = 0x0436f6e1
    case ttpv = 0x0436ef7d
    case dpub = 0x2fda926
    case dprv = 0x2fda4e8
    case dgub = 0x02facafd
    case dgpv = 0x02fac398
}
