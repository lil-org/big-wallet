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
    case zcash = 10
    case bitcoinCash = 11
    case bitcoinGold = 12
    case ioTeX = 13
    case nervos = 14
    case zilliqa = 15
    case terra = 16
    case cryptoOrg = 17
    case kava = 18
    case oasis = 19
    case bluzelle = 20
    case bandChain = 21
    case multiversX = 22
    case secret = 23
    case agoric = 24
    case binance = 25
    case ecash = 26
    case thorchain = 27
    case bitcoinDiamond = 28
    case harmony = 29
    case cardano = 30
    case qtum = 31
    case pactus = 32
    case stratis = 33
    case nativeInjective = 34
    case osmosis = 35
    case terraV2 = 36
    case coreum = 37
    case nativeZetaChain = 38
    case nativeCanto = 39
    case sommelier = 40
    case fetchAI = 41
    case mars = 42
    case umee = 43
    case quasar = 44
    case persistence = 45
    case akash = 46
    case noble = 47
    case sei = 48
    case stargaze = 49
    case nativeEvmos = 50
    case tia = 51
    case dydx = 52
    case juno = 53
    case tbinance = 54
    case stride = 55
    case axelar = 56
    case crescent = 57
    case kujira = 58
    case comdex = 59
    case neutron = 60

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
        case .zcash: return "tex"
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
        case .pactus: return "pc"
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
