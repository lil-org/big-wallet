// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
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
    case nativeCanto = 36
    case sommelier = 37
    case fetchAI = 38
    case mars = 39
    case umee = 40
    case quasar = 41
    case persistence = 42
    case akash = 43
    case noble = 44
    case sei = 45
    case stargaze = 46
    case nativeEvmos = 47
    case tia = 48
    case juno = 49
    case tbinance = 50
    case stride = 51
    case axelar = 52
    case crescent = 53
    case kujira = 54
    case comdex = 55
    case neutron = 56

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
