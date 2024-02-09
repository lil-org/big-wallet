// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

///  Registered human-readable parts for BIP-0173
///
/// - SeeAlso: https://github.com/satoshilabs/slips/blob/master/slip-0173.md
public enum HRP: UInt32, CaseIterable, CustomStringConvertible  {
    case unknown = 0
    case bitcoin = 1
    case litecoin = 2
    case viacoin = 3
    case groestlcoin = 4
    case digiByte = 5
    case monacoin = 6
    case syscoin = 7
    case verge = 8
    case cosmos = 9
    case bitcoinCash = 10
    case bitcoinGold = 11
    case ioTeX = 12
    case nervos = 13
    case zilliqa = 14
    case terra = 15
    case cryptoOrg = 16
    case kava = 17
    case oasis = 18
    case bluzelle = 19
    case bandChain = 20
    case multiversX = 21
    case secret = 22
    case agoric = 23
    case binance = 24
    case ecash = 25
    case thorchain = 26
    case bitcoinDiamond = 27
    case harmony = 28
    case cardano = 29
    case qtum = 30
    case stratis = 31
    case nativeInjective = 32
    case osmosis = 33
    case terraV2 = 34
    case coreum = 35
    case nativeZetaChain = 36
    case nativeCanto = 37
    case sommelier = 38
    case fetchAI = 39
    case mars = 40
    case umee = 41
    case quasar = 42
    case persistence = 43
    case akash = 44
    case noble = 45
    case sei = 46
    case stargaze = 47
    case nativeEvmos = 48
    case tia = 49
    case dydx = 50
    case juno = 51
    case tbinance = 52
    case stride = 53
    case axelar = 54
    case crescent = 55
    case kujira = 56
    case comdex = 57
    case neutron = 58

    public var description: String {
        switch self {
        case .unknown: return ""
        case .bitcoin: return "bc"
        case .litecoin: return "ltc"
        case .viacoin: return "via"
        case .groestlcoin: return "grs"
        case .digiByte: return "dgb"
        case .monacoin: return "mona"
        case .syscoin: return "sys"
        case .verge: return "vg"
        case .cosmos: return "cosmos"
        case .bitcoinCash: return "bitcoincash"
        case .bitcoinGold: return "btg"
        case .ioTeX: return "io"
        case .nervos: return "ckb"
        case .zilliqa: return "zil"
        case .terra: return "terra"
        case .cryptoOrg: return "cro"
        case .kava: return "kava"
        case .oasis: return "oasis"
        case .bluzelle: return "bluzelle"
        case .bandChain: return "band"
        case .multiversX: return "erd"
        case .secret: return "secret"
        case .agoric: return "agoric"
        case .binance: return "bnb"
        case .ecash: return "ecash"
        case .thorchain: return "thor"
        case .bitcoinDiamond: return "bcd"
        case .harmony: return "one"
        case .cardano: return "addr"
        case .qtum: return "qc"
        case .stratis: return "strax"
        case .nativeInjective: return "inj"
        case .osmosis: return "osmo"
        case .terraV2: return "terra"
        case .coreum: return "core"
        case .nativeZetaChain: return "zeta"
        case .nativeCanto: return "canto"
        case .sommelier: return "somm"
        case .fetchAI: return "fetch"
        case .mars: return "mars"
        case .umee: return "umee"
        case .quasar: return "quasar"
        case .persistence: return "persistence"
        case .akash: return "akash"
        case .noble: return "noble"
        case .sei: return "sei"
        case .stargaze: return "stars"
        case .nativeEvmos: return "evmos"
        case .tia: return "celestia"
        case .dydx: return "dydx"
        case .juno: return "juno"
        case .tbinance: return "tbnb"
        case .stride: return "stride"
        case .axelar: return "axelar"
        case .crescent: return "cre"
        case .kujira: return "kujira"
        case .comdex: return "comdex"
        case .neutron: return "neutron"
        }
    }
}
