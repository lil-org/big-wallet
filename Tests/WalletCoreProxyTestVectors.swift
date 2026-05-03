// 2026 lil org

import Foundation

enum WalletCoreProxyTestVectors {

    static let abandonMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let walletCoreHDMnemonic = "ripple scissors kick mammal hire column oak again sun offer wealth tomorrow wagon turn fatal"
    static let coinAddressMnemonic = "shoot island position soft burden budget tooth cruel issue economy destroy above"
    static let multiAccountMnemonic = "team engine square letter hero song dizzy scrub tornado fabric divert saddle"

    static let invalidMnemonic = "ripple scissors hisc mammal hire column oak again sun offer wealth tomorrow"
    static let password = Data("password".utf8)
    static let wrongPassword = Data("wrong-password".utf8)

    static let sequentialPrivateKey = Data(1...32)
    static let zeroPrivateKey = Data(repeating: 0, count: 32)
    static let secp256k1PrivateKeyAtCurveOrder = data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
    static let secp256k1PrivateKeyAboveCurveOrder = data(hex: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    static let secpPrivateKey = data(hex: "afeefca74d9a325cf1d6b6911d61a65c32afa8e02bd5e78e2e4ac2910bab45f5")
    static let ethereumSignerPrivateKey = data(hex: "03a9ca895dca1623c7dfd69693f7b4111f5d819d2e145536e0b03c136025a25d")
    static let solanaAddressPrivateKey = data(hex: "a1269039e4ffdf43687852d7247a295f0b5bc55e6dda031cffaa3295ca0a9d7a")
    static let solanaSigningPrivateKey = data(hex: "44f480ca27711895586074a14c552e58cc52e66a58edb6c58cf9b9b7295d4a2d")
    static let ethereumTransactionPrivateKey = data(hex: "608dcb1742bb3fb7aec002074e3420e4fab7d00cced79ccdac53ed5b27138151")
    static let ethereumNativeTransferPrivateKey = data(hex: "4646464646464646464646464646464646464646464646464646464646464646")

    static let secpPublicKey = "0499c6f51ad6f98c9c583f8e92bb7758ab2ca9a04110c0a1126ec43e5453d196c166b489a4b7c491e7688e6ebea3a71fc3a1a48d60f98d5ce84c93b65e423fde91"
    static let solanaAddressPublicKey = "b14f1d4e6bc93589ae1a0c2c5f462c8041ff8b295c27515a993c516363ef276b"
    static let solanaSigningPublicKey = "ee6d61a89fc8f9909585a996bb0d2b2ac69ae23b5acf39a19f32631239ba06f9"
    static let secpEthereumAddress = "0xAc1ec44E4f0ca7D172B7803f6836De87Fb72b309"

    static let walletCoreHDEthereumAddress = "0x27Ef5cDBe01777D62438AfFeb695e33fC2335979"
    static let coinAddressEthereumAddress = "0x8f348F300873Fd5DA36950B2aC75a26584584feE"
    static let coinAddressSolanaAddress = "2bUBiBNZyD29gP1oV6de7nxowMLoDBtopMMTGgMvjG5m"
    static let coinAddressNearAddress = "0c91f6106ff835c0195d5388565a2d69e25038a7e23d26198f85caf6594117ec"
    static let multiAccountEthereumAddress = "0x494f60cb6Ac2c8F5E1393aD9FdBdF4Ad589507F7"
    static let multiAccountEthereumPublicKey = "04cc32a479080d83fdcf69966713f0aad1bc1dc3ecf873b034894e84259841bc1c9b122717803e68905220ff54952d3f5ea2ab2698ca31f843addf94ae73fae9fd"
    static let abandonEthereumExtendedPublicKey = "xpub6DCoCpSuQZB2jawqnGMEPS63ePKWkwWPH4TU45Q7LPXWuNd8TMtVxRrgjtEshuqpK3mdhaWHPFsBngh5GFZaM6si3yZdUsT8ddYM3PwnATt"
    static let abandonEthereumAddress = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
    static let abandonEthereumSecondAddress = "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0"
    static let abandonEthereumSecondPublicKey = "049fd0991d0222b4e1339c1a1a5b5f6d9f6a96672a3247b638ee6156d9ea877a2f1735e3a9260940e4c2225c344a8cea6c7b6a6057d0eb90a9a875f446c131031d"
    static let abandonSolanaDefaultExtendedPublicKey = "xpub6BwjtyUeq36Y418KAz1FZTzryD9MXUSuKeYVyfbhN8ffEWEWYNAEhM6Seg6nj5t9RmAZQpWQk4R1VxfefwwTiWMBPPWHNEaABFUAy9Mv2Hc"
    static let abandonNearDefaultExtendedPublicKey = "xpub6DVyUnweRi8KSxhSMJuRTMAGD7MWdU2QdrJAPguZtQsLZg8Dh4DBZyCRGAWqWh62WZENXkTjPYLmtjpj7vLzBCy2JvPipAgQyAP8t5ZiowE"
    static let solanaAddressFromPublicKey = "Cw98eCpH6kkCCVadhei4UNi6VxszmVwSxqypns33Ssr2"

    static let solanaMessage = Data("Hello world".utf8)
    static let solanaMessageSignature = "2iBZ6zrQRKHcbD8NWmm552gU5vGvh1dk3XV4jxnyEdRKm8up8AeQk1GFr9pJokSmchw7i9gMtNyFBdDt8tBxM1cG"
    static let nearMessageSignature = "2iBZ6zrQRKHcbD8NWmm552gU5vGvh1dk3XV4jxnyEdRKm8up8AeQk1GFr9pJokSmchw7i9gMtNyFBdDt8tBxM1cG"
    static let ethereumPersonalMessage = Data("Foo".utf8)
    static let ethereumPersonalMessageSignature = "0x21a779d499957e7fd39392d49a079679009e60e492d9654a148829be43d2490736ec72bc4a5644047d979c3cf4ebe2c1c514044cf436b063cb89fc6676be71101b"
    static let ethereumSignerAddress = "0xd0972E2312518Ca15A2304D56ff9cc0b7ea0Ea37"

    static let abandonEthereumAccountOneExtendedPublicKey = "xpub6DCoCpSuQZB2k9PnGSMK9tinTK8kx3hcv7F4BWwhs5N2wnwGiLg17r9J7j2JcYP9gkip3sC87J1F99YxeBHGuFMg6ejA8qQEKSuzzaKvqBR"
    static let abandonEthereumAccountOneAddress = "0x78839F6054d7ed13918bAe0473BA31b1Ca9D7265"

    static let walletCoreJSONPrivateKeyPassword = Data("testpassword".utf8)
    static let walletCoreJSONPrivateKeyData = data(hex: "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d")
    static let walletCoreJSONPrivateKeyAddress = "0x008AeEda4D805471dF9b2A5B0f38A0C3bCBA786b"
    static let walletCoreJSONPrivateKeyFixture = data(utf8: """
    {
      "crypto": {
        "cipher": "aes-128-ctr",
        "cipherparams": {
          "iv": "83dbcc02d8ccb40e466191a123791e0e"
        },
        "ciphertext": "d172bf743a674da9cdad04534d56926ef8358534d458fffccd4e6ad2fbde479c",
        "kdf": "scrypt",
        "kdfparams": {
          "dklen": 32,
          "n": 262144,
          "p": 8,
          "prf": "hmac-sha256",
          "r": 1,
          "salt": "ab0c7876052600dd703518d6fc3fe8984592145b591fc8fb5c6d43190334ba19"
        },
        "mac": "2103ac29920d71da29f15d75b4a16dbe95cfd7ff8faea1056c33131d846e3097"
      },
      "address": "0x008AeEda4D805471dF9b2A5B0f38A0C3bCBA786b",
      "id": "e13b209c-3b2f-4327-bab0-3bef2e51630d",
      "coin": 60,
      "version": 3
    }
    """)

    static let walletCoreJSONMnemonicPassword = Data("password".utf8)
    static let walletCoreJSONMnemonic = "ripple scissors kick mammal hire column oak again sun offer wealth tomorrow wagon turn fatal"
    static let walletCoreJSONMnemonicStoredEthereumAddress = "32dd55E0BCF509a35A3F5eEb8593fbEb244796b1"
    static let walletCoreJSONMnemonicDerivedEthereumAddress = "0xA3Dcd899C0f3832DFDFed9479a9d828c6A4EB2A7"
    static let walletCoreJSONMnemonicDerivedEthereumPublicKey = "0448a9ffac8022f1c7eb5253746e24d11d9b6b2737c0aecd48335feabb95a179916b1f3a97bed6740a85a2d11c663d38566acfb08af48a47ce0c835c65c9b23d0d"
    static let walletCoreJSONMnemonicFixture = data(utf8: """
    {
      "version": 3,
      "id": "e0fe53d0-7a3d-4f65-88b1-9bb4e245a169",
      "crypto": {
        "ciphertext": "3f6401e478074fc9c50a69dd88ea21baca70dd8064d8590b64f64b64d493e6e50bb6ff5ffc6aabcaac18c4aad25f29c53fe1029f8d6fa4ed24fc99938f27e38bea0b0cd7f8215f38d2526c655bff0b8f1638e948d8c1b9bdaa95ab0b",
        "cipherparams": {
          "iv": "09246e7f7af92374eda0237da20c6696"
        },
        "kdf": "scrypt",
        "kdfparams": {
          "r": 8,
          "p": 6,
          "n": 4096,
          "dklen": 32,
          "salt": "9cf4521a3543f0e116a86f188572f295a99081fd2e4143129cb5ee8760bec367"
        },
        "mac": "67a8bf187bdeec076ac1e3647914e20b1dcbb15a5cb4643e6047fc2a07694055",
        "cipher": "aes-128-ctr"
      },
      "type": "mnemonic",
      "coin": 60,
      "address": "32dd55E0BCF509a35A3F5eEb8593fbEb244796b1"
    }
    """)

    static let walletCoreJSONMixedAccountPassword = Data("e28ddf66cec05c1fc09939a00628b230459202b2493fccac288038ef37815723".utf8)
    static let walletCoreJSONMixedAccountMnemonic = "often tobacco bread scare imitate song kind common bar forest yard wisdom"
    static let walletCoreJSONMixedAccountEthereumAddress = "0x33F44330cc4253cCd4ce4224186DB9baCe2190ea"
    static let walletCoreJSONMixedAccountNearAddress = "NEARzwYRo7ArKyLBdmAU7XiMzz4kgYgrfM3VxCn6H9PXnPaAoZuSB"
    static let walletCoreJSONMixedAccountFixture = data(utf8: """
    {
      "activeAccounts": [{
        "address": "bc1q4zehq85jqx9zzgzvzn9t64yjy66nunn3vehuv6",
        "derivationPath": "m/84'/0'/0'/0/0",
        "extendedPublicKey": "zpub6qMRMrwcEYaqjf8wSpNqtBfUee6MqpQjrZNKfj5a48EUFUx2yUmfkDJMdHwWvkg8SjdS3ua6dy9ofMrzrytTfdyy2pXg344yFwm2Ta9cm6Q"
      }, {
        "address": "0x33F44330cc4253cCd4ce4224186DB9baCe2190ea",
        "derivationPath": "m/44'/60'/0'/0/0"
      }, {
        "address": "bnb1njuczq3hgvupu2vnczrjz7rc8x4uxlmhjyq95z",
        "derivationPath": "m/44'/714'/0'/0/0"
      }, {
        "address": "NEARzwYRo7ArKyLBdmAU7XiMzz4kgYgrfM3VxCn6H9PXnPaAoZuSB",
        "derivationPath": "m/44'/397'/0'"
      }],
      "crypto": {
        "cipher": "aes-128-ctr",
        "cipherparams": {
          "iv": "cfeacebdf0d0c57cbbe6260094cdf3a9"
        },
        "ciphertext": "60358be4204c0d9c723775159bcadd63a51f0c06fce4024294d8ed4c19acb85cba3ca769dc3521fb572a06f8986d8bbc5736d6900e3e215f9bc112acffa470b178a621922041300bd7",
        "kdf": "scrypt",
        "kdfparams": {
          "dklen": 32,
          "n": 4096,
          "p": 6,
          "r": 8,
          "salt": "14198d7e5f2afbfde2b00539d0c9abaec99e708dd4a2242448c57248e3e07c77"
        },
        "mac": "90b65f299a9ac59f50d24c6f80f4cdcffe6500c86687df716a15d79461992085"
      },
      "id": "3c937d42-443d-4acf-9311-2d9dfa857e1c",
      "name": "",
      "type": "mnemonic",
      "version": 3
    }
    """)

    static let typedDataDigest = "a85c2e2b118698e88db68a8105b794a8cc7cec074e89ef991cb4f5f533819cc2"
    static let malformedTypedDataJSON = "not json"
    static let malformedTypedDataDigest = Data()
    static let typedDataJSON = """
    {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Person": [
                {"name": "name", "type": "string"},
                {"name": "wallets", "type": "address[]"}
            ],
            "Mail": [
                {"name": "from", "type": "Person"},
                {"name": "to", "type": "Person[]"},
                {"name": "contents", "type": "string"}
            ]
        },
        "primaryType": "Mail",
        "domain": {
            "name": "Ether Mail",
            "version": "1",
            "chainId": 1,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "from": {
                "name": "Cow",
                "wallets": [
                    "CD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
                    "DeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF"
                ]
            },
            "to": [
                {
                    "name": "Bob",
                    "wallets": [
                        "bBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB",
                        "B0BdaBea57B0BDABeA57b0bdABEA57b0BDabEa57",
                        "B0B0b0b0b0b0B000000000000000000000000000"
                    ]
                }
            ],
            "contents": "Hello, Bob!"
        }
    }
    """

    static let abiEncodedCall = data(hex: "c47f0027000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000086465616462656566000000000000000000000000000000000000000000000000")
    static let abiJSON = #"{"c47f0027":{"constant":false,"inputs":[{"name":"name","type":"string"}],"name":"setName","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiDecodedCall = #"{"function":"setName(string)","inputs":[{"name":"name","type":"string","value":"deadbeef"}]}"#

    static let signedERC20Transaction = "f8aa808509c7652400830130b9946b175474e89094c44da98b954eedeac495271d0f80b844a9059cbb0000000000000000000000005322b34c88ed0691971bf52a7047448f0f4efc840000000000000000000000000000000000000000000000001bc16d674ec8000025a0724c62ad4fbf47346b02de06e603e013f26f26b56fdc0be7ba3d6273401d98cea0032131cae15da7ddcda66963e8bef51ca0d9962bfef0547d3f02597a4a58c931"
    static let signedEmptySendTransaction = "f85f8001825208940000000000000000000000000000000000000001808026a043b16e8e5617621fe2b209d803f4271b1debce20e59f7275d101b20538a8938aa06f3280d17c64af0100109ddbf1b635035ee29bb2848e062cdac082a5977cbf83"
    static let signedOneWeiTransaction = "f85f8001825208940000000000000000000000000000000000000001018026a0799bab69dff6408b09598df6fff2b06074214c9affbd2adfef376df21a4a41a3a0151fff9b870fd736b9b760e061035f46fa8502932af5a6559da1e71e5f986bc0"
    static let signedNativeTransferTransaction = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"

    static func data(hex: String) -> Data {
        let hexString = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        precondition(hexString.count.isMultiple(of: 2), "Hex fixture must have even length")

        var result = Data()
        result.reserveCapacity(hexString.count / 2)

        var highNibble: UInt8?
        for byte in hexString.utf8 {
            guard let value = hexValue(byte) else {
                preconditionFailure("Invalid hex fixture")
            }

            if let high = highNibble {
                result.append((high << 4) | value)
                highNibble = nil
            } else {
                highNibble = value
            }
        }

        return result
    }

    private static func data(utf8 string: String) -> Data {
        return Data(string.utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

}
