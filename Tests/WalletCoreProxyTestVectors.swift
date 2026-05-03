// 2026 lil org

import Foundation

enum WalletCoreProxyTestVectors {

    static let abandonMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let walletCoreHDMnemonic = "ripple scissors kick mammal hire column oak again sun offer wealth tomorrow wagon turn fatal"
    static let coinAddressMnemonic = "shoot island position soft burden budget tooth cruel issue economy destroy above"
    static let multiAccountMnemonic = "team engine square letter hero song dizzy scrub tornado fabric divert saddle"
    static let valid18WordMnemonic = "find view amazing inject mistake school zone ticket deposit edit deer fuel expect pioneer alpha mirror joke private"
    static let valid21WordMnemonic = "tiger parent future endorse chuckle crazy seat tomato orient prevent swarm nerve duty crazy chief cruel purity team happy strategy level"
    static let zeroEntropy24WordMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"

    static let invalidMnemonic = "ripple scissors hisc mammal hire column oak again sun offer wealth tomorrow"
    static let invalidChecksumMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
    static let invalidWordCountMnemonic = "credit expect life fade cover suit response wash what skull force"
    static let invalidWordMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon zzz"
    static let uppercaseMnemonic = "ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABANDON ABOUT"
    static let mixedWhitespaceMnemonic = " abandon  abandon abandon\tabandon abandon abandon abandon abandon abandon abandon abandon about "
    static let password = Data("password".utf8)
    static let wrongPassword = Data("wrong-password".utf8)
    static let longPassword = Data(repeating: 0x70, count: 1024)

    static let base58KnownVectors: [(data: Data, encoded: String)] = [
        (data(hex: "61"), "2g"),
        (data(hex: "626262"), "a3gV"),
        (data(hex: "636363"), "aPEr"),
        (data(hex: "73696d706c792061206c6f6e6720737472696e67"), "2cFupjhnEsSn59qHXstmK2ffpLv2"),
        (data(hex: "00"), "1"),
        (data(hex: "00000001"), "1112"),
        (data(hex: "ffffffff"), "7YXq9G"),
        (data(hex: "000102030405060708090a0b0c0d0e0f"), "12drXXUifSrRnXLGbXg8E"),
    ]

    static let keccakBinaryVectors: [(name: String, data: Data, digest: String)] = [
        ("zero 32 bytes", Data(repeating: 0, count: 32), "290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563"),
        ("all byte values", Data((0...255).map { UInt8($0) }), "dc924469b334aed2a19fac7252e9961aea41f8d91996366029dbe0884229bf36"),
        ("long binary payload", Data(repeating: 0xab, count: 1024), "1549e03b2fd519bc2621fee2b4f0e94e796658d7b94c952316fdf05b98d23b25"),
    ]

    static let sequentialPrivateKey = Data(1...32)
    static let onePrivateKey = Data(repeating: 0, count: 31) + Data([1])
    static let zeroPrivateKey = Data(repeating: 0, count: 32)
    static let secp256k1PrivateKeyBelowCurveOrder = data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
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
    static let sequentialEthereumPublicKey = "0484bf7562262bbd6940085748f3be6afa52ae317155181ece31b66351ccffa4b08cc43d63b2859d469fee15f31c9edb5324266e6fd0407e87382d60fc4511acd8"
    static let sequentialSolanaPublicKey = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
    static let sequentialEthereumAddress = "0x6370eF2f4Db3611D657b90667De398a2Cc2a370C"
    static let sequentialSolanaAddress = "9C6hybhQ6Aycep9jaUnP6uL9ZYvDjUp1aSkFWPUFJtpj"
    static let oneEthereumAddress = "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    static let oneSolanaAddress = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt"
    static let secp256k1PrivateKeyBelowCurveOrderEthereumPublicKey = "0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798b7c52588d95c3b9aa25b0403f1eef75702e84bb7597aabe663b82f6f04ef2777"
    static let secp256k1PrivateKeyBelowCurveOrderEthereumAddress = "0x80C0dbf239224071c59dD8970ab9d542E3414aB2"
    static let secp256k1PrivateKeyBelowCurveOrderSolanaPublicKey = "db829af23b58dbea3bd1d0ef9c97afd3f2ee04df984425fafa84c30fe340a1d4"
    static let secp256k1PrivateKeyBelowCurveOrderSolanaAddress = "Fmso3DbsuWGKrXsDVayLu13dbGqTuXW5a2b5BLCo2o47"
    static let secp256k1PrivateKeyAtCurveOrderSolanaPublicKey = "e4edb845d09d604c6063dbafbc8c7e36068362949f84ffeb2eeccac68761dc5d"
    static let secp256k1PrivateKeyAtCurveOrderSolanaAddress = "GQeCMLHLy3hDXZy96751SBKwwmG6cEjFXULsQ4iyi5PA"
    static let secp256k1PrivateKeyAboveCurveOrderSolanaPublicKey = "76a1592044a6e4f511265bca73a604d90b0529d1df602be30a19a9257660d1f5"
    static let secp256k1PrivateKeyAboveCurveOrderSolanaAddress = "8z5oiZDBaCrP7ZCP1vQZbxkUt2eevdpPnyvpQAvAYuiL"

    static let walletCoreHDEthereumAddress = "0x27Ef5cDBe01777D62438AfFeb695e33fC2335979"
    static let walletCoreHDNoPassphraseEthereumAddress = "0xA3Dcd899C0f3832DFDFed9479a9d828c6A4EB2A7"
    static let walletCoreHDEthereumPrivateKey = data(hex: "c4f77b4a9f5a0db3a7ffc3599e61bef986037ae9a7cc1972a10d55c030270020")
    static let walletCoreHDNoPassphraseEthereumPrivateKey = data(hex: "ab4accc9310d90a61fc354d8f353bca4a2b3c0590685d3eb82d0216af3badddc")
    static let coinAddressEthereumAddress = "0x8f348F300873Fd5DA36950B2aC75a26584584feE"
    static let coinAddressSolanaAddress = "2bUBiBNZyD29gP1oV6de7nxowMLoDBtopMMTGgMvjG5m"
    static let multiAccountEthereumAddress = "0x494f60cb6Ac2c8F5E1393aD9FdBdF4Ad589507F7"
    static let multiAccountEthereumPublicKey = "04cc32a479080d83fdcf69966713f0aad1bc1dc3ecf873b034894e84259841bc1c9b122717803e68905220ff54952d3f5ea2ab2698ca31f843addf94ae73fae9fd"
    static let multiAccountEthereumPrivateKey = data(hex: "7c31f39a3be635a842da243e5c5e4da6885b04d302288b812449c07604f7f8f7")
    static let abandonEthereumExtendedPublicKey = "xpub6DCoCpSuQZB2jawqnGMEPS63ePKWkwWPH4TU45Q7LPXWuNd8TMtVxRrgjtEshuqpK3mdhaWHPFsBngh5GFZaM6si3yZdUsT8ddYM3PwnATt"
    static let abandonEthereumAddress = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
    static let abandonEthereumSecondAddress = "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0"
    static let abandonEthereumSecondPublicKey = "049fd0991d0222b4e1339c1a1a5b5f6d9f6a96672a3247b638ee6156d9ea877a2f1735e3a9260940e4c2225c344a8cea6c7b6a6057d0eb90a9a875f446c131031d"
    static let abandonEthereumChangeZeroAddress = "0x399Db6Ed32539fbDF44c3e7678b5b428e378F666"
    static let abandonEthereumChangeZeroPublicKey = "04abdc0424e5a951abb5e12df771738e269566fc170dfe8a5f0dae27052a1685590ed3baf090b916db5f923ae4c5d34aba23466c172027e17749f0c8f579f0935b"
    static let abandonEthereumChangeOneAddress = "0x26db4d065800Bd118928848E69A1cBF956Cff1D0"
    static let abandonEthereumChangeOnePublicKey = "04dd553226bc6d4d2efafabfe7600a10d4d069de1371dd3207a293fb96766b307376605b0580017eb8e3ee5202d613fca46d7befcbbe3303ccc1da9d32f8fd4e96"
    static let abandonSolanaDefaultExtendedPublicKey = "xpub6BwjtyUeq36Y418KAz1FZTzryD9MXUSuKeYVyfbhN8ffEWEWYNAEhM6Seg6nj5t9RmAZQpWQk4R1VxfefwwTiWMBPPWHNEaABFUAy9Mv2Hc"

    static let solanaAddressFromPublicKey = "Cw98eCpH6kkCCVadhei4UNi6VxszmVwSxqypns33Ssr2"

    static let solanaMessage = Data("Hello world".utf8)
    static let solanaMessageBase58 = "JxF12TrwXzT5jvT"
    static let solanaMessageHex = "48656c6c6f20776f726c64"
    static let solanaMessageSignature = "2iBZ6zrQRKHcbD8NWmm552gU5vGvh1dk3XV4jxnyEdRKm8up8AeQk1GFr9pJokSmchw7i9gMtNyFBdDt8tBxM1cG"
    static let solanaEmptyMessageSignature = "3SBCToyrhSQZkB4sqHJvUurrzv5c5Y17W5qY5cbHH2XWBzAkB2yWM6NuwUV7ytapKn6xwp77bbtoQYvAsbySWU3q"
    static let solanaZeroMessageSignature = "4iXB9qCBysmuLa9cttk9yYfx7SE9FpD9z79zzcPNWCurYgxGjTkpbcRtVBdic3s1Q1xZHEYYdud3yNKftYHqyo7u"
    static let solanaBinaryMessage = data(hex: "000102ff48656c6c6f")
    static let solanaBinaryMessageSignature = "21mmPTuCnWosSwBT5PPpYGYCbietfKW7B4b1mvogJ3s1rEojKy8MgqMGYWx4wx13VsJH3GeBMLAqE6vBF28eStcW"
    static let solanaLongMessage = Data((0..<128).map { UInt8($0) })
    static let solanaLongMessageSignature = "4bYXqrzTP31C1W7VDGpAubaYfS5CJTjY8HYFTUDKNJ2fFrMDkR4fNwELQtNwfUKqyd9q35ev81ymkZS6EEi1RY7t"
    static let ethereumRawSignDigest = data(hex: "3f891fda3704f0368dab65fa81ebe616f4aa2a0854995da4dc0b59d2cadbd64f")
    static let ethereumOverlongRawSignDigest = data(hex: "3f891fda3704f0368dab65fa81ebe616f4aa2a0854995da4dc0b59d2cadbd64faa")
    static let ethereumZeroRawSignDigest = Data(repeating: 0, count: 32)
    static let ethereumMaxRawSignDigest = data(hex: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    static let ethereumRawSignature = "0x10680d9870f49b668d9509e1e9a6a28d1d35f3a2a935cc8cf9cfff6a4314af851a0f7f77534befda09f0f8771205517ede3c236caeed079344a5ac844df83aec1b"
    static let ethereumZeroRawSignature = "0x7cf725baea04fcee0650b499ed271171e96d7aad534dc13dbe1be7483bd0284e40ec0f7065a21b74ca42418e23df91d4d435924cb8838184d9d48a2c8db1c32f1b"
    static let ethereumMaxRawSignature = "0xb12bcd34ff2c1e98b63617cd6d77c0e22681fd8b651374655776c2628516cce1388ccb2ae1d00b484b2b9664f4bee989820f1e967410bdaeaa7cc38d6ca6f4151b"
    static let ethereumPersonalMessage = Data("Foo".utf8)
    static let ethereumPersonalMessageSignature = "0x21a779d499957e7fd39392d49a079679009e60e492d9654a148829be43d2490736ec72bc4a5644047d979c3cf4ebe2c1c514044cf436b063cb89fc6676be71101b"
    static let ethereumEmptyPersonalMessageSignature = "0x75ee6bac1fd86fef91281b5d4be96f157ffa82ea581fcf00f3e673eaa5f319fe62fa633166c9599f952d748cdebd01fa2ababbba3d95b972c969c45eaaff00d81c"
    static let ethereumBinaryPersonalMessage = data(hex: "000102ff48656c6c6f")
    static let ethereumBinaryPersonalMessageSignature = "0xd99a610559e2efb64a00bf5f7cfae4b3c81db68776e188e1e5328fa250920643730c4251db430c62522a1a2fd0b970c0d9e32dc2d45d53e4a3fdb57b3f5008b11c"
    static let ethereumNewlinePersonalMessage = Data("Line one\nLine two".utf8)
    static let ethereumNewlinePersonalMessageSignature = "0x8c7645a57f7fe39f85c0e45bc3a8fbdc9c270f0e3db75f0a17f0c7c84202e3c8496628ae440ad3d1aad4f3da9cb12295804ff6328fbdf9661b4b41455b1abeef1b"
    static let ethereumLongPersonalMessage = Data((0..<128).map { UInt8($0) })
    static let ethereumLongPersonalMessageSignature = "0x9fbf231ec5ebfabea35a2994bcc79b77875b71023aae0269983c05cb264eadc6302ae5ad4201ccb99847177382707803711ebb6b0f67c8907639e431e831e5e61b"
    static let ethereumSignerAddress = "0xd0972E2312518Ca15A2304D56ff9cc0b7ea0Ea37"
    static let ethereumTypedDataSignature = "0x590ef5a00564df1ef0f0fdb0a4d517d0090344c267c75e9580dea40a67569eb3129449b460da5dfca0366093d0ecf8416151aed6dba8903c28d0c327c69e05661c"

    static let abandonEthereumAccountOneExtendedPublicKey = "xpub6DCoCpSuQZB2k9PnGSMK9tinTK8kx3hcv7F4BWwhs5N2wnwGiLg17r9J7j2JcYP9gkip3sC87J1F99YxeBHGuFMg6ejA8qQEKSuzzaKvqBR"
    static let abandonEthereumAccountTwoExtendedPublicKey = "xpub6DCoCpSuQZB2ot5sZMhVj1zbCa9smR2h7YGPfJjzjauzsnCqqp8GHwUQTDMrFK2gExmmpCjspBVanYdRaTg3H1eyxyG1ddXfZyNT2JRAYWk"
    static let abandonEthereumAccountOneAddress = "0x78839F6054d7ed13918bAe0473BA31b1Ca9D7265"

    static let abandonEthereumHDVectors: [(index: Int, path: String, privateKey: Data, publicKey: String, address: String)] = [
        (0, "m/44'/60'/0'/0/0", data(hex: "1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727"), "0437b0bb7a8288d38ed49a524b5dc98cff3eb5ca824c9f9dc0dfdb3d9cd600f299a6179912b7451c09896c4098eca7ce6b2e58330672795e847c4d6af44e024230", "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"),
        (1, "m/44'/60'/0'/0/1", data(hex: "9a983cb3d832fbde5ab49d692b7a8bf5b5d232479c99333d0fc8e1d21f1b55b6"), "049fd0991d0222b4e1339c1a1a5b5f6d9f6a96672a3247b638ee6156d9ea877a2f1735e3a9260940e4c2225c344a8cea6c7b6a6057d0eb90a9a875f446c131031d", "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0"),
        (2, "m/44'/60'/0'/0/2", data(hex: "5b824bd1104617939cd07c117ddc4301eb5beeca0904f964158963d69ab9d831"), "04880bcb4bf46b49bdb071e307e282b11b9166907d9708f8c706092c44743f3e67cf16b2c08d5424a0c8b210b0d8df671a4f455adc49349ca06a1476c029b73847", "0xb6716976A3ebe8D39aCEB04372f22Ff8e6802D7A"),
        (3, "m/44'/60'/0'/0/3", data(hex: "9ffce93c14680776a0c319c76b4c25e7ad03bd780bf47f27ae9153324dcac585"), "0471fd9d361f19065cb8e7be22dfd2ff3f7f265dcaf01f45cfcc956e55dba8b124ff0d2d6f290ecdf643eaccacf514baa7dc5ec94bb32ff878e9d0d6c13c2ac569", "0xF3f50213C1d2e255e4B2bAD430F8A38EEF8D718E"),
        (4, "m/44'/60'/0'/0/4", data(hex: "bd443149113127d73c350d0baeceedd2c83be3f10e3d57613a730649ddfaf0c0"), "04b1692ae0dfea1c15ba4250f4feb903a6633a3458acffa46a5380ef55645d16958c441ff4c78f565837a06c22d9574b29c743cb39a39c035a82028227a16bdece", "0x51cA8ff9f1C0a99f88E86B8112eA3237F55374cA"),
        (5, "m/44'/60'/0'/0/5", data(hex: "5a8787e6b7e11a74a22ee97b8164c7d69cd5668c6065bbfbc87e6a34a24b135c"), "04e3b32aa461b0be7833198fbb49c0d3f5a2bbabf9ab052a7bb97545d0e05c2816d68c3aa522581e3e7952ac5bc153dcefbff9e8db427d44cb7fef53c1fd7a726d", "0xA40cFBFc8534FFC84E20a7d8bBC3729B26a35F6f"),
        (6, "m/44'/60'/0'/0/6", data(hex: "56e506258e5b0e3b6023b17941d84f8a13d655c525419b9ff0a52999a2c687a3"), "04aed1de6d479451b94c8635a10db38e2ea5ec612ec166bc8d78029a08d28783328bb94d81e9a0546523bd8056a50844e498d6d7761e18d0d023949db3c2f195a8", "0xB191a13bfE648B61002F2e2135867015B71816a6"),
        (7, "m/44'/60'/0'/0/7", data(hex: "dfb0930bcb8f6ca83296c1870e941998c641d3d0d413013c890b8b255dd537b5"), "0479b17216ab974c61dcd96feeff8d90e2dc449d27bfe474565859ac3a0df6e3c27de7ef72210f104ce759740e5eb59880da363687986484fb4e248ad9e2a7958e", "0x593814d3309e2dF31D112824F0bb5aa7Cb0D7d47"),
        (8, "m/44'/60'/0'/0/8", data(hex: "66014718190fedba55dc3f4709f6b5b34b9b1feebb110e7b87391054cbbffdd2"), "04339d0a24275c9e67cf247669a0dc6bfa70044ff4a074d78bdce6ac648f67b1d6cd9a80b2c2a073a2c0b5513bbe5be20a8cb6b0c54a785f2132cf1feeac750488", "0xB14c391e2bf19E5a26941617ab546FA620A4f163"),
        (9, "m/44'/60'/0'/0/9", data(hex: "22fb8f2fe3b2dbf632bc5eb450a96ec56185733234f17e49c2483bb337ebf145"), "0476c0e5cf2e56e519b44946ac76c7703023457d8c78ce3d44e4a571faa6addb85abce6a600a77b506ff8ab5b9eea9e934ba39f4401ba0a560f53752e69962e704", "0x4C1C56443AbFe6dD33de31dAaF0a6E929DBc4971"),
        (10, "m/44'/60'/0'/0/10", data(hex: "1d8e676c6da57922d80336cffc5bf9020d0cce4730cff872aeb2dcce08320ce6"), "04a2075c4f558e4b1b4688b3e55eff56e84f574a3fe563db4fececd8cd978bfed13d35b9722e9b32c20a0189be73f6a8622299de0200de62b5e0f2f4ffbc7b17bd", "0xEf4ba16373841C53a9Ba168873fC3967118C1d37"),
        (11, "m/44'/60'/0'/0/11", data(hex: "b677c2e3953bf8133227eaeac8653514f6f2040a58edcd75062c1a7b63d2c4f5"), "04dca1645d3ab3b2b0a2327349d2e72f0b3f6c3f8d299658cefae7d20b0d9511f096f14f4abd4b6bae3485c3bb078031aa7cc4a118a26a9ea8770a7c5f6fad1ee1", "0xa251F9b1F365bF1be54b6bDa3bbEAD414f1Af763"),
        (12, "m/44'/60'/0'/0/12", data(hex: "8f101494c262218bd6eb3692c77dafeff1b8a5512cd33e1cb50c7f7324ed4d74"), "04948e9881cd76a42abe2f75b69c3939889b67f5bedc39fddeaf68bd119bf2a93fc1cf810c1d3b3f6dcc958f6b60b9fa5f8c9ce8bfd48173d6a0adf410afe944c7", "0x7286A5102BB0FaC25F53A4819A5F933698155945"),
        (13, "m/44'/60'/0'/0/13", data(hex: "babc8a4218800dfdb58e42d66b21960470cfdfc524af3bc90be13f306e16780a"), "04fec2772229838c151d139b947970f03572b4a1e085c5a11f16dd999f3f27774f1edcd868ba94ba3d3a264f3d60ceba4ae9d2212ddf082d59d899281cd3bb7096", "0x5Edc7559F077dD692901e7e4E92970ad81022Ee7"),
        (14, "m/44'/60'/0'/0/14", data(hex: "8c6947351b681a054bbef77cdb58e61acdb91b5e9a75209d6a3f5bef31397f4e"), "04677011ecc56ae98f297372db8f0f3503046da7d3486988190f38cd7eaa0e873d2d5a9788f4cb220db2da830640a33d2f6cf4636d6a39dda2564c1e5f4db24f6d", "0x9Ef58eAb71ab36B337450598a9F56451e13DB8E3"),
        (15, "m/44'/60'/0'/0/15", data(hex: "009a1ccd9c667416d9db6246a35d022b1799517c0cd8547bb07ce280c119ae3c"), "048e0993f4cb4b55fa83b7476f3192d57e082a0673f458c1fb23be35e70654f3a87b4265d01de564c5a0b776d7f9eb981e4da2ee73899fdb6768571a84946efdfa", "0xa25d37554EB084969C85362f7E6B1A6108e51d0e"),
        (16, "m/44'/60'/0'/0/16", data(hex: "4518a0eb8a68ef32da0a8f19c16873e2a03be81d67221cfa9a3cabe092424c7b"), "0483581e36e032b770c6084d2118934d8d759e3a90b05862363fbbe623cc64cdd0d7b35c3bb79a900469b625918b1e96f82aefb3f86cb1d225789b68bd5d6c62d7", "0xF4EeD1f0589E2Cd7cF29CCE5f6f45e1ed65594aB"),
        (17, "m/44'/60'/0'/0/17", data(hex: "763cd54858bbb95d9ae0988809b0860abc8ea9f5feca3a4402598dfec96a7191"), "0422129db06753beff10cfbfdc0f330934036d4301d43421835038045d25f9e24afe6bed0c05a2770ef1856280d888870f6b807f66b5695126358310355b9a8f36", "0x516A2191b53f7654654F209CcA9668b16f149988"),
        (18, "m/44'/60'/0'/0/18", data(hex: "634d867c47e9396435e90e9b637ca1e6b1c789f0e7bb15814e116b09d5d8dcb7"), "04a4831ed3c4f9c6478789f0c7cb9a26866aefab9412addfc2ea3325714ca73adfcb6d81cdd06b43c73c36ae00e5cbb9e135d4a90923ec046028da72279de07ea3", "0x944A807C53BCe5a96dD4E558E993833aB41CE65F"),
        (19, "m/44'/60'/0'/0/19", data(hex: "6f8076173176655d6c52dc222fcaec81a94342051442eea4d4ce307418e29e1e"), "04851f3f43111d8f89f3a9d69fa4297c07959e7969ea880d0e6ae38a8d6490c469e32011fecdd235a4e8c6d813d7763f076f0956cd19e4051c9d6aa63fe07016e3", "0x5096eEe90Aa1b783AF381669938C688F02bb43D8"),
        (20, "m/44'/60'/0'/0/20", data(hex: "5ecdffccf06949c82241cc7c81af52bbe2cb8dd870894d0b14d141d00750a14e"), "041681919ee7bb2a23f833d412e3f39831b11b864787c2cdb04a21943e02bd22bb74aedc69f846cc1837984ada9dcdb98de707bed72217024719e1efcc8b648358", "0x0f7479EC9cB833971eE60A4B09d7E048f689029B"),
        (21, "m/44'/60'/0'/0/21", data(hex: "e86433e088dd7a2fb00f1044847f9e588edd77963de031d80d1563a9a2fd54bc"), "04175784a6a6a6826ac0587e4623dad88dafe16fbedda2088594fcfceabf4597d62d41e7cb6812c79312d11ef52e535a1019d8a9f1470cb75b18b4dc09ca90049c", "0xDD2E4e4DdAc2AAff7001f2677459aa67671dD22f"),
    ]

    static let abandonSolanaHDVectors: [(index: Int, path: String, privateKey: Data, publicKey: String, address: String)] = [
        (0, "m/44'/501'/0'/0'", data(hex: "37df573b3ac4ad5b522e064e25b63ea16bcbe79d449e81a0268d1047948bb445"), "f036276246a75b9de3349ed42b15e232f6518fc20f5fcd4f1d64e81f9bd258f7", "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"),
        (1, "m/44'/501'/1'/0'", data(hex: "ba5e7b6e3680b4eb81db8e54c8e466b2e9a899355888403355d858ab985d2fc4"), "f8029acf5cbcbdd5ac46ec147f3b78a3df6e5022ef0411db2bab650d329a4cd4", "Hh8QwFUA6MtVu1qAoq12ucvFHNwCcVTV7hpWjeY1Hztb"),
        (2, "m/44'/501'/2'/0'", data(hex: "2f2d4843b13aec3867edc61fbeac4a1fa58797a8629aa35217bd183405bcc202"), "60c5985f58a32ff8ab91e2fbd1d211b8de6b4acc4f6ce4458830efc0c801ca1c", "7WktogJEd2wQ9eH2oWusmcoFTgeYi6rS632UviTBJ2jm"),
        (3, "m/44'/501'/3'/0'", data(hex: "aca2b17c35b7772de2a58e1083a33f7a4eadd0d30d7add9742c7de06fdf73d55"), "25deec12e0409b3f009b208fad2d9bd9d7f9c195d3e829897f9b21dfdb4a8649", "3YqEpfo3c818GhvbQ1UmVY1nJxw16vtu4JB9peJXT94k"),
        (4, "m/44'/501'/4'/0'", data(hex: "145a14915070ba876a79777a2788a22080e1a9cab99ae5d805ea66314aadffec"), "5606495f786320894dddea3473da80de07e66c70b16cdca2155a8c4ad41c831e", "6nod592sTfEWD3VSVPdQndLMVBCNmMc6ngt7MyGBK21j"),
        (5, "m/44'/501'/5'/0'", data(hex: "62ef17513b1a1ffa96eb94c441fd3e7fc0f43df1a3780c96c14f6439ed40c2ac"), "124fbb5086d5e4f49b23538a3267f97218f9e58844a40797b8c2f1a435b956b6", "2EUrWmf5xMmWER9BtDbXbGbZjoL7R3eTDMXYR6H6cKPj"),
        (6, "m/44'/501'/6'/0'", data(hex: "8c0bf5e3cfc6b08723454528ed220f1c3f8337aef3c1b2e30afd1f69c2775f13"), "411362b15d612b9185f2b1625cb95c4e635e68fcbfcd0aa55f568bd58fe4a8a4", "5P2eQoLncuFMjAmNNF4PspnAXYNaDSE2t1gb5os76Svw"),
        (7, "m/44'/501'/7'/0'", data(hex: "3a2be7cc1eda377a74f14a9e69fd2b2dfe91d5cfe59db6ac27a461108f6a742a"), "811d6aa295c9db8b6f12d71a10a4d0dad4f0e92e6f6526d0c238a82eaa81683d", "9h1cLBiraaUqM1CdJTaVaew1oQtgQUW24FZ8YdnLLgJY"),
        (8, "m/44'/501'/8'/0'", data(hex: "04eb1d0a12833e5120d3010935517b8410b3e597ffcbae5ce740ae68782ea4a3"), "e54d15a9b6b9f1a946b12b25816b281055889fcc97040eb8bade43aab1ff8205", "GS6Y8rQB8W3SWfLpQuooT1pEm7mqRKnTP1EkNKL2Xeha"),
        (9, "m/44'/501'/9'/0'", data(hex: "6c7e8217c3ea3fd5f6df67c75937b2fe766425d5547c711bd2f241f6788c7ff0"), "f10dcc1824bae5ed9b650b728eb0642f7e9f52274f2563c03f7100342a37f52d", "HDyTY5B1TJ3WgyfaziZtDGaBqj3ofKm8499Q8meqk4nx"),
        (10, "m/44'/501'/10'/0'", data(hex: "0492ead19236fe31cb115a2a65f6a387bf3b9ca4d5ee4dc224b2250b06dcfb63"), "8ec67b662faddd44e7d79875a4cf1e7f8c3f756a4b171ccea95a4149b8dddf2b", "AcLS2t8rzEqeQnbJK4HBS7g8NBCa7SowjARdvxtqBE3t"),
        (11, "m/44'/501'/11'/0'", data(hex: "9cad5afb017ab36d8990628971650d2001407304bfda9cdd1009c097abe9efbd"), "d523049b8db090f8b47bdbfc027ba4c42df08782835303be44ea61d9f1955dfb", "FLzoxtpBbnn5nGcyokN47Di2M3VJ7FaiUNGpeZWVRUgz"),
        (12, "m/44'/501'/12'/0'", data(hex: "f035bae8873ee8c92c943dc3af8662dba72e10fa438d9cb780f9ac7fc44f6f89"), "28657270c4fb400254635f294c7c32cb28df65b3bc239edebd46103f5c4ba6b0", "3ih2doS8hZJsnMnZ4Xho4rckrZKq8Co5N5GdCEnD6Mx3"),
        (13, "m/44'/501'/13'/0'", data(hex: "b119fa860e46a957ff1d1b508ebb18478917ea0483df1ee8174876dc912c5614"), "f3d1dde4bab409b1c5e685e516ac314cebcc4b444c5d7ae1fbf6321909725156", "HQmgK6Syw5XG8zkEnSoBaNz3fhrGHLt1LUfeGWaVuhLh"),
        (14, "m/44'/501'/14'/0'", data(hex: "2f94198bba132fef2f10f84922a5e4bd3c655d0af721c15939128dd527fe8218"), "7469397223e860958e4699a947260b5579f5da3d7edf6c276070952ee9973c41", "8qRMXdEGhfrVMSEgYiBvDrPVQTR83PXWPzUFsLzwp1hS"),
        (15, "m/44'/501'/15'/0'", data(hex: "a54ba74bc04e176d134d3b17b3e38d00bb7966a380f4705e61637a6a5b3adfbe"), "bf4bd7aa1667244e7cccd528e45f34148f227a7e2fef555fff1882a33df91e3f", "DsjwrNNNQL9LpRrGmgvzvuFHrApXDCQ2mVTZg4NT4mGr"),
        (16, "m/44'/501'/16'/0'", data(hex: "e7869fd9d3c1941fde49f9b5c2c02ae491559e62e81bba6e85742cab2af63b2d"), "e2c0f46df0fbcf89fff16e807df7c639087bf48b4097cb7a260e11f6eb9440e4", "GG9npDte2RMSejBwzBuLsdENouHZVdcMgTK3FEnsdHxF"),
        (17, "m/44'/501'/17'/0'", data(hex: "b7769dee399bea6f202f6ec7033879c20cca2de664c9658fb7cbc3fb79f60ae3"), "7ca921b52b6213838ee46b441f6cffe5fbcd6e74fcab79d7f2a09cbae195e470", "9Pd8ratWtmsyVXtcThE6rzURzSk77iAheqBn87Q66RtB"),
        (18, "m/44'/501'/18'/0'", data(hex: "74c449c05ebc312db3af006c099568d0d4f5d2f155fac32b9ed34193f5dedea0"), "b20e54da7edd322e1984b5a44a97a9f2b7dcb7ba9ffa1f718f9f6d1f30ca82cb", "Cz4FDEewmYtKpoBQYmMVaXXL6GJPU3ZjHx7RH2enm5Pp"),
        (19, "m/44'/501'/19'/0'", data(hex: "438bc5590b4a33458df3bf177c7e0eae17eddad93f1f873895674999022220b1"), "aaf1f9df77ba3d96bf9604239cf1307600df0a8d45d2519812f59d11aca0782a", "CWJKBYW8VndqhBJyMLX1kaHbx5R47CTKCbHHx78dhFQV"),
        (20, "m/44'/501'/20'/0'", data(hex: "689ece224ac5e7faeeccff1c9b3ab9eb2fcec8349d66b00bc2875059a793444d"), "9e6d1eb957e99e6c9f1cff21412bb81fbcd6d3dfb8a249081c6e4d72d060467d", "BfRvWRsTyQRGgeZJNzumCiDrRQriyL1Jwwdhrua6wtig"),
        (21, "m/44'/501'/21'/0'", data(hex: "b6494aef9d9836fc874bcf650a935c8fc79a1fa15ad78880460ecab8c2f54bc7"), "185c0f3ccd2ef5119a70db8c1bcf1582fb4300cbfbacc5579e4afffabf45101f", "2e6CkjBeCbQgP4qP1ciPLThDk287sVWmRDMJT5hRQrPg"),
    ]

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

    static let walletCoreJSONPBKDF2PrivateKeyPassword = Data("variant-password".utf8)
    static let walletCoreJSONVariantPrivateKeyFixtures: [(name: String, json: Data)] = [
        ("pbkdf2 aes-128-ctr lowercase crypto", walletCoreJSONPBKDF2AES128PrivateKeyFixture),
        ("pbkdf2 aes-128-ctr uppercase Crypto", walletCoreJSONPBKDF2AES128UppercaseCryptoPrivateKeyFixture),
        ("pbkdf2 aes-256-ctr", walletCoreJSONPBKDF2AES256PrivateKeyFixture),
    ]
    private static let walletCoreJSONPBKDF2AES128PrivateKeyFixture = walletCoreJSONPBKDF2PrivateKeyFixture(
        cryptoKey: "crypto",
        cipher: "aes-128-ctr",
        ciphertext: "74a57cdf067e4deafcf7843b385a2e852c1a418860f4ee4c687ee65330052e5a",
        mac: "40bf78143970e3be3e66b81b735d3bb43174c2594e90a1bd53e263e2cb4b7a2c"
    )
    private static let walletCoreJSONPBKDF2AES128UppercaseCryptoPrivateKeyFixture = walletCoreJSONPBKDF2PrivateKeyFixture(
        cryptoKey: "Crypto",
        cipher: "aes-128-ctr",
        ciphertext: "74a57cdf067e4deafcf7843b385a2e852c1a418860f4ee4c687ee65330052e5a",
        mac: "40bf78143970e3be3e66b81b735d3bb43174c2594e90a1bd53e263e2cb4b7a2c"
    )
    private static let walletCoreJSONPBKDF2AES256PrivateKeyFixture = walletCoreJSONPBKDF2PrivateKeyFixture(
        cryptoKey: "crypto",
        cipher: "aes-256-ctr",
        ciphertext: "59534779fa36ff0613646b52eb477af86bf94c877f97b6ab7f6c63e02d298152",
        mac: "cf270bca8353d38ddeb8169aa9df45cf6001deb7fbc7fabcc0448b5857718350"
    )

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
    static let permitTypedDataDigest = "8e234d3348fdfb087478de9d65c030e111fafc3abc824ee2ee1a2fe9e938b592"
    static let complexTypedDataDigest = "aea54d086891128eb6108615e38873a455602a1f39ac88292408c0a311485ec8"
    static let permitTypedDataSignature = "0x1ebbd25f52fac9e961055fef6d721b64111cec07a6e608b43906c1ec5eed7af0087936763d38beb188b1f0fbde802a9d427f6dfb96288c2e7096bbc1f2966c2d1c"
    static let complexTypedDataSignature = "0xb28af5ba51dc58c0fc8fcf5bcbda747921a10932c72bf5e9aed54c70a61f84311a559c41020af10b026dec561f6ba62a35aebede40a6b0414c7840c9532d95a31b"
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
    static let permitTypedDataJSON = """
    {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Permit": [
                {"name": "owner", "type": "address"},
                {"name": "spender", "type": "address"},
                {"name": "value", "type": "uint256"},
                {"name": "nonce", "type": "uint256"},
                {"name": "deadline", "type": "uint256"}
            ]
        },
        "primaryType": "Permit",
        "domain": {
            "name": "Big Wallet",
            "version": "1",
            "chainId": 1,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "owner": "0xd0972E2312518Ca15A2304D56ff9cc0b7ea0Ea37",
            "spender": "0x000000000000000000000000000000000000dEaD",
            "value": 123456789,
            "nonce": 7,
            "deadline": 1700000000
        }
    }
    """
    static let complexTypedDataJSON = """
    {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Attachment": [
                {"name": "kind", "type": "bytes4"},
                {"name": "digest", "type": "bytes32"},
                {"name": "payload", "type": "bytes"},
                {"name": "weights", "type": "uint16[]"}
            ],
            "Order": [
                {"name": "maker", "type": "address"},
                {"name": "active", "type": "bool"},
                {"name": "side", "type": "int8"},
                {"name": "quantity", "type": "uint16"},
                {"name": "price", "type": "uint64"},
                {"name": "netAmount", "type": "int256"},
                {"name": "tags", "type": "bytes32[2]"},
                {"name": "fills", "type": "uint8[]"},
                {"name": "attachment", "type": "Attachment"}
            ]
        },
        "primaryType": "Order",
        "domain": {
            "name": "Big Wallet Typed Data Coverage",
            "version": "2",
            "chainId": 11155111,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "maker": "0xd0972E2312518Ca15A2304D56ff9cc0b7ea0Ea37",
            "active": true,
            "side": -1,
            "quantity": 65535,
            "price": 1234567890,
            "netAmount": -42,
            "tags": [
                "0x1111111111111111111111111111111111111111111111111111111111111111",
                "0x2222222222222222222222222222222222222222222222222222222222222222"
            ],
            "fills": [1, 2, 255],
            "attachment": {
                "kind": "0xdeadbeef",
                "digest": "0x3333333333333333333333333333333333333333333333333333333333333333",
                "payload": "0x000102ff",
                "weights": [0, 17, 65535]
            }
        }
    }
    """

    static let abiEncodedCall = data(hex: "c47f0027000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000086465616462656566000000000000000000000000000000000000000000000000")
    static let abiJSON = #"{"c47f0027":{"constant":false,"inputs":[{"name":"name","type":"string"}],"name":"setName","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiDecodedCall = #"{"function":"setName(string)","inputs":[{"name":"name","type":"string","value":"deadbeef"}]}"#
    static let abiERC20TransferCall = data(hex: "a9059cbb0000000000000000000000005322b34c88ed0691971bf52a7047448f0f4efc840000000000000000000000000000000000000000000000001bc16d674ec80000")
    static let abiERC20TransferJSON = #"{"a9059cbb":{"constant":false,"inputs":[{"name":"to","type":"address"},{"name":"value","type":"uint256"}],"name":"transfer","outputs":[{"name":"","type":"bool"}],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiERC20TransferDecodedCall = #"{"function":"transfer(address,uint256)","inputs":[{"name":"to","type":"address","value":"0x5322B34c88Ed0691971Bf52A7047448f0F4eFC84"},{"name":"value","type":"uint256","value":"2000000000000000000"}]}"#
    static let abiStaticAndDynamicBytesCall = data(hex:
        "12345678" +
        "0000000000000000000000000000000000000000000000000000000000000001" +
        "deadbeef00000000000000000000000000000000000000000000000000000000" +
        "1111111111111111111111111111111111111111111111111111111111111111" +
        "0000000000000000000000000000000000000000000000000000000000000080" +
        "0000000000000000000000000000000000000000000000000000000000000004" +
        "000102ff00000000000000000000000000000000000000000000000000000000"
    )
    static let abiStaticAndDynamicBytesJSON = #"{"12345678":{"constant":false,"inputs":[{"name":"flag","type":"bool"},{"name":"tag","type":"bytes4"},{"name":"digest","type":"bytes32"},{"name":"payload","type":"bytes"}],"name":"setPayload","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiStaticAndDynamicBytesDecodedCall = #"{"function":"setPayload(bool,bytes4,bytes32,bytes)","inputs":[{"name":"flag","type":"bool","value":true},{"name":"tag","type":"bytes4","value":"0xdeadbeef"},{"name":"digest","type":"bytes32","value":"0x1111111111111111111111111111111111111111111111111111111111111111"},{"name":"payload","type":"bytes","value":"0x000102ff"}]}"#
    static let abiArrayCall = data(hex:
        "abcdef01" +
        "0000000000000000000000000000000000000000000000000000000000000060" +
        "0000000000000000000000001111111111111111111111111111111111111111" +
        "0000000000000000000000002222222222222222222222222222222222222222" +
        "0000000000000000000000000000000000000000000000000000000000000003" +
        "0000000000000000000000000000000000000000000000000000000000000001" +
        "0000000000000000000000000000000000000000000000000000000000000002" +
        "00000000000000000000000000000000000000000000000000000000000003e8"
    )
    static let abiArrayJSON = #"{"abcdef01":{"constant":false,"inputs":[{"name":"values","type":"uint256[]"},{"name":"recipients","type":"address[2]"}],"name":"batch","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiArrayDecodedCall = #"{"function":"batch(uint256[],address[2])","inputs":[{"name":"values","type":"uint256[]","value":["1","2","1000"]},{"name":"recipients","type":"address[2]","value":["0x1111111111111111111111111111111111111111","0x2222222222222222222222222222222222222222"]}]}"#
    static let abiTupleCall = data(hex:
        "0badc0de" +
        "000000000000000000000000d0972e2312518ca15a2304d56ff9cc0b7ea0ea37" +
        "000000000000000000000000000000000000000000000000000000000000002a" +
        "0000000000000000000000000000000000000000000000000000000000000001"
    )
    static let abiTupleJSON = #"{"0badc0de":{"constant":false,"inputs":[{"name":"order","type":"tuple","components":[{"name":"maker","type":"address"},{"name":"amount","type":"uint256"},{"name":"active","type":"bool"}]}],"name":"submit","outputs":[],"payable":false,"stateMutability":"nonpayable","type":"function"}}"#
    static let abiTupleDecodedCall = #"{"function":"submit((address,uint256,bool))","inputs":[{"name":"order","type":"tuple","components":[{"name":"maker","type":"address","value":"0xd0972E2312518Ca15A2304D56ff9cc0b7ea0Ea37"},{"name":"amount","type":"uint256","value":"42"},{"name":"active","type":"bool","value":true}]}]}"#
    static let abiDecodeFixtures: [(name: String, data: Data, abi: String, decoded: String)] = [
        ("erc20 transfer", abiERC20TransferCall, abiERC20TransferJSON, abiERC20TransferDecodedCall),
        ("static and dynamic bytes", abiStaticAndDynamicBytesCall, abiStaticAndDynamicBytesJSON, abiStaticAndDynamicBytesDecodedCall),
        ("dynamic and fixed arrays", abiArrayCall, abiArrayJSON, abiArrayDecodedCall),
        ("tuple", abiTupleCall, abiTupleJSON, abiTupleDecodedCall),
    ]

    static let signedERC20Transaction = "f8aa808509c7652400830130b9946b175474e89094c44da98b954eedeac495271d0f80b844a9059cbb0000000000000000000000005322b34c88ed0691971bf52a7047448f0f4efc840000000000000000000000000000000000000000000000001bc16d674ec8000025a0724c62ad4fbf47346b02de06e603e013f26f26b56fdc0be7ba3d6273401d98cea0032131cae15da7ddcda66963e8bef51ca0d9962bfef0547d3f02597a4a58c931"
    static let signedEmptySendTransaction = "f85f8001825208940000000000000000000000000000000000000001808026a043b16e8e5617621fe2b209d803f4271b1debce20e59f7275d101b20538a8938aa06f3280d17c64af0100109ddbf1b635035ee29bb2848e062cdac082a5977cbf83"
    static let signedOneWeiTransaction = "f85f8001825208940000000000000000000000000000000000000001018026a0799bab69dff6408b09598df6fff2b06074214c9affbd2adfef376df21a4a41a3a0151fff9b870fd736b9b760e061035f46fa8502932af5a6559da1e71e5f986bc0"
    static let signedEmptyChainIDTransaction = "f85f800182520894000000000000000000000000000000000000000180801ca00ec1695e83877837a0f8c23d4ce5edb611b503e67a0fc9ea0292718e4dba58d7a051cba1536e66a6d04addb29a4144281eff12683fde7111d5e306f58d8c328884"
    static let signedNativeTransferTransaction = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
    static let signedDataOnlyTransaction = "f869808509c7652400830130b9946b175474e89094c44da98b954eedeac495271d0f8084deadbeef25a0372f1792338dd8fd0a1be8901c6dd79faa412936eb5c62d053639663630fa540a01ffd8afd49f74806135d76623344e2b3a45571880acca8a5ec88b66a085650e0"
    static let signedChainThreeOneWeiTransaction = "f864068504a817c80082520894353535353535353535353535353535353535353501802aa0e059a80a438240f955e8fd75dc852f1e87a20c0c22f842a4a251e69527ba0d7da075ef56fc4a39b1201f3058471a054dd02f209926a2aadf67815761991b627f45"
    static let signedBaseChainOneWeiTransaction = "f866068504a817c800825208943535353535353535353535353535353535353535018082422ea0a21c950697a9926a6aca62f1ec6e22602e12918f21acb4522ba7a0e851b3ac1da0789de2323b18c9b15bb7926a95d89c20ba365b38e70d03cd21eeeaf18e229569"

    static let solanaSequentialSeedBase58 = "4wBqpZM9xaSheZzJSMawUKKwhdpChKbZ5eu5ky4Vigw"
    static let solanaSequentialSecretKeyBase58 = "2Ana1pUpv2ZbMVkwF5FXapYeBEjdxDatLn7nvJkhgTSdZd8hbDHTd21as7EAsg7ypityqfsw2pMQKJcVDVcAEsd"
    static let solanaSequentialSecretKeyByteArray = "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,121,181,86,46,143,230,84,249,64,120,177,18,232,169,139,167,144,31,133,58,230,149,190,215,224,227,145,11,173,4,150,100]"
    static let ethereumHexThatDecodesAsInvalidSolanaSecretBase58 = "1111111111111111111111111111111111111111111111111111111111111aaa"

    static let solanaPreparedSignerPrivateKey = data(hex: "44f480ca27711895586074a14c552e58cc52e66a58edb6c58cf9b9b7295d4a2d")
    static let solanaPreparedSignerPublicKey = "H3imdwa5VQMB5V6yBNyrWwPdSKs4k9Pcpsu4diogoAcg"
    static let solanaPreparedSerializedTransaction = "4smDpCXsnHgmoapt2q3Hx3gdVHty7Vta81VAZYPSmzNSHXjtvyfJu4qz1WMHCx2MVXACDb6QY6B1V7CD2u9bgVEGWjqi5gjLcz2PDvti8vYQs7gAZu1DEPmutwqpvUo8T7GjTBKsBLD8fb8Q3N5WKf6K3vj5o3wiZHHv4BkgaXkQ4aoq1PnyxoRpajUXPL3kif4xbSGP9uwSci17SHyEhs5spxyD5sXztX"
    static let solanaPreparedApprovalMessage = "Ax4iqYdG9oPfJ69gGc6GB8JVZZ4AWaXH8UFGWuGwEV4qSnjzcnggaXudEKtSpDUM6vNz6xFAwjP2JepUv5RLf8FV5Mg1Dsnawvpv8PePBsHkHafXas7z2WxqkvhrThXa8HZWzWSQF"
    static let solanaPreparedSignedTransactionBase64 = "ASOwhMKmQHx0GUNT+6f9wK7I50y7GUKGMIjAiwAtzVjc04WE1GiUEz3bL4GHmbHj16TIOyxQRjHXpsz9Bpo/CwsBAAEC7m1hqJ/I+ZCVhamWuw0rKsaa4jtazzmhnzJjEjm6BvkAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJAA=="

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

    private static func walletCoreJSONPBKDF2PrivateKeyFixture(cryptoKey: String,
                                                              cipher: String,
                                                              ciphertext: String,
                                                              mac: String) -> Data {
        return data(utf8: """
        {
          "\(cryptoKey)": {
            "cipher": "\(cipher)",
            "cipherparams": {
              "iv": "1f1e1d1c1b1a19181716151413121110"
            },
            "ciphertext": "\(ciphertext)",
            "kdf": "pbkdf2",
            "kdfparams": {
              "c": 1024,
              "dklen": 32,
              "prf": "hmac-sha256",
              "salt": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
            },
            "mac": "\(mac)"
          },
          "address": "\(secpEthereumAddress)",
          "id": "a9e74f13-0a38-4d1b-a882-8f4b8cf7945f",
          "coin": 60,
          "version": 3
        }
        """)
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
