// ∅ 2026 lil org

import Dispatch
import Foundation
import XCTest
@testable import Big_Wallet

final class DappRequestProcessorTests: XCTestCase {

    func testEthereumTransactionHashUsesSignedWireBytes() {
        let signedTransaction =
            "f86c098504a817c800825208943535353535353535353535353535353535353535" +
            "880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d" +
            "3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9" +
            "f3dc64214b297fb1966a3b6d83"
        let expected =
            "0x33469b22e9f636356c4160a87eb19df52b7412e8eac32a4a55ffe88ea8350788"

        XCTAssertEqual(
            Ethereum.transactionHash(signedTransaction: signedTransaction),
            expected
        )
        XCTAssertEqual(
            Ethereum.transactionHash(
                signedTransaction: "0x" + signedTransaction
            ),
            expected
        )
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: ""))
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: "0x0"))
        XCTAssertNil(Ethereum.transactionHash(signedTransaction: "0xzz"))
    }

    func testEthereumSendProviderErrorPreservesRPCCodeMessageAndData() {
        let dataJSON =
            #"{"baseFeePerGas":"0x132","minimumPriorityFeePerGas":"0x1"}"#
        let rpcError = DappRequestProcessor.ethereumProviderError(
            for: .rpc(
                .serverError(
                    -32_000,
                    "FeeTooLow: EffectivePriorityFeePerGas too low 0 < 1",
                    dataJSON: dataJSON
                )
            )
        )

        XCTAssertEqual(rpcError.code, -32_000)
        XCTAssertEqual(rpcError.context, .dataJSON(dataJSON))
        XCTAssertEqual(
            rpcError.message,
            "FeeTooLow: EffectivePriorityFeePerGas too low 0 < 1"
        )

        XCTAssertEqual(
            DappRequestProcessor.ethereumProviderError(
                for: .failedToSign
            ).code,
            -32_603
        )
        XCTAssertEqual(
            DappRequestProcessor.ethereumProviderError(
                for: .transport
            ).code,
            -32_603
        )
        XCTAssertEqual(
            DappRequestProcessor.ethereumProviderError(
                for: .invalidTransaction
            ).code,
            -32_603
        )
    }

    func testResponseToExtensionPreservesEncodedRPCErrorData() throws {
        let requestJSON: [String: Any] = [
            "id": 42,
            "name": "signTransaction",
            "provider": "ethereum",
            "host": "example.com",
            "body": [
                "address":
                    "0x0000000000000000000000000000000000000001",
                "chainId": "0x1",
                "object": [
                    "to":
                        "0x0000000000000000000000000000000000000002",
                ],
            ],
        ]
        let requestData = try JSONSerialization.data(
            withJSONObject: requestJSON
        )
        let requestString = try XCTUnwrap(
            String(data: requestData, encoding: .utf8)
        )
        let request = try XCTUnwrap(SafariRequest(query: requestString))
        let response = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: "transaction underpriced",
                    code: -32_000,
                    context: .dataJSON("null")
                )
            )
        )

        XCTAssertEqual(response.json["error"] as? String, "transaction underpriced")
        XCTAssertEqual(response.json["errorCode"] as? Int, -32_000)
        XCTAssertEqual(response.json["errorDataJSON"] as? String, "null")
        XCTAssertEqual(response.json["provider"] as? String, "ethereum")
        XCTAssertNil(response.json["errorPublicKey"])
        XCTAssertNil(response.json["errorSignature"])
        XCTAssertNil(response.json["configurationToStore"])

        let canceledResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.canceled,
                    code: 4001
                )
            )
        )
        XCTAssertEqual(canceledResponse.json["error"] as? String, Strings.canceled)
        XCTAssertEqual(canceledResponse.json["errorCode"] as? Int, 4001)

        let unrecognizedChainResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.unrecognizedChainId,
                    code: 4902
                )
            )
        )
        XCTAssertEqual(
            unrecognizedChainResponse.json["error"] as? String,
            Strings.unrecognizedChainId
        )
        XCTAssertEqual(
            unrecognizedChainResponse.json["errorCode"] as? Int,
            4902
        )

        let codeLessResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(message: "generic failure")
            )
        )
        XCTAssertNil(codeLessResponse.json["errorCode"])

        let publicKeyResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.providerNotReady,
                    code: 4100,
                    context: .unauthorizedPublicKey("public-key")
                )
            )
        )
        XCTAssertEqual(
            publicKeyResponse.json["errorPublicKey"] as? String,
            "public-key"
        )
        XCTAssertNil(publicKeyResponse.json["errorDataJSON"])
        XCTAssertNil(publicKeyResponse.json["errorSignature"])

        let signatureResponse = ResponseToExtension(
            for: request,
            payload: .error(
                ProviderResponseError(
                    message: Strings.failedToSend,
                    code: -32_005,
                    context: .transactionSignature("signature")
                )
            )
        )
        XCTAssertEqual(
            signatureResponse.json["errorSignature"] as? String,
            "signature"
        )
        XCTAssertNil(signatureResponse.json["errorDataJSON"])
        XCTAssertNil(signatureResponse.json["errorPublicKey"])
    }

    func testEthereumTransactionFeeModeInferenceAndLegacyNonceOwnership() throws {
        let automatic = ethereumTransfer(parameters: [
            "nonce": "0x2a",
        ])
        XCTAssertEqual(automatic?.feeIntent, .automatic)
        XCTAssertNil(automatic?.preparedFee)
        XCTAssertNil(automatic?.nonce)

        let explicitLegacy = ethereumTransfer(parameters: [
            "type": "0x0",
        ])
        XCTAssertEqual(explicitLegacy?.feeIntent, .legacy(gasPrice: nil))
        XCTAssertNil(explicitLegacy?.preparedFee)

        let inferredLegacy = try XCTUnwrap(ethereumTransfer(parameters: [
            "gasPrice": "0x7",
        ]))
        XCTAssertEqual(inferredLegacy.feeIntent, .legacy(gasPrice: BigUInt(7)))
        XCTAssertEqual(inferredLegacy.preparedFee, .legacy(gasPrice: BigUInt(7)))
        XCTAssertEqual(inferredLegacy.gasPrice, "0x7")
        XCTAssertEqual(inferredLegacy.feeProvenance.gasPrice, .dapp)
        XCTAssertNil(inferredLegacy.feeProvenance.maxPriorityFeePerGas)
        XCTAssertNil(inferredLegacy.feeProvenance.maxFeePerGas)
    }

    func testEthereumTransactionParsesCompleteAndPartialEIP1559Fees() throws {
        let complete = try XCTUnwrap(ethereumTransfer(parameters: [
            "type": "0x2",
            "maxPriorityFeePerGas": "0x2",
            "maxFeePerGas": "0x9",
        ]))
        XCTAssertEqual(
            complete.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(9)
            )
        )
        XCTAssertEqual(
            complete.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(9)
            )
        )
        XCTAssertEqual(complete.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertEqual(complete.feeProvenance.maxFeePerGas, .dapp)
        XCTAssertNil(complete.gasPrice)

        let priorityOnly = try XCTUnwrap(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x3",
        ]))
        XCTAssertEqual(
            priorityOnly.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(3),
                maxFeePerGas: nil
            )
        )
        XCTAssertNil(priorityOnly.preparedFee)
        XCTAssertEqual(priorityOnly.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertNil(priorityOnly.feeProvenance.maxFeePerGas)

        let maxFeeOnly = try XCTUnwrap(ethereumTransfer(parameters: [
            "type": "0x2",
            "maxFeePerGas": "0xa",
        ]))
        XCTAssertEqual(
            maxFeeOnly.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: BigUInt(10)
            )
        )
        XCTAssertNil(maxFeeOnly.preparedFee)
        XCTAssertNil(maxFeeOnly.feeProvenance.maxPriorityFeePerGas)
        XCTAssertEqual(maxFeeOnly.feeProvenance.maxFeePerGas, .dapp)

        let accessListOnly = ethereumTransfer(parameters: [
            "accessList": [],
        ])
        XCTAssertEqual(
            accessListOnly?.feeIntent,
            .eip1559(maxPriorityFeePerGas: nil, maxFeePerGas: nil)
        )
        XCTAssertEqual(accessListOnly?.accessList, [])
    }

    func testEthereumTransactionRejectsFeeModeConflictsAndUnsupportedTypes() {
        let conflicts: [[String: Any]] = [
            ["gasPrice": "0x1", "maxFeePerGas": "0x2"],
            ["gasPrice": "0x1", "maxPriorityFeePerGas": "0x1"],
            ["gasPrice": "0x1", "accessList": []],
            ["type": "0x0", "maxFeePerGas": "0x2"],
            ["type": "0x0", "maxPriorityFeePerGas": "0x1"],
            ["type": "0x0", "accessList": []],
            ["type": "0x2", "gasPrice": "0x1"],
        ]
        for parameters in conflicts {
            XCTAssertNil(
                ethereumTransfer(parameters: parameters),
                "Expected conflicting transaction fields to be rejected: \(parameters)"
            )
        }

        for type in ["0x1", "0x3", "0x4", "0x5", "0xffff"] {
            XCTAssertNil(
                ethereumTransfer(parameters: ["type": type]),
                "Expected unsupported transaction type \(type) to be rejected"
            )
        }
        XCTAssertNil(ethereumTransfer(parameters: ["type": 2]))
    }

    func testEthereumTransactionParsingErrorsDistinguishInvalidParametersFromUnsupportedTypes() {
        let malformedParameters: [[String: Any]] = [
            ["gasPrice": "0x1", "maxFeePerGas": "0x2"],
            [
                "accessList": [[
                    "address": "0x1",
                    "storageKeys": [],
                ]],
            ],
            [
                "maxPriorityFeePerGas": "0x3",
                "maxFeePerGas": "0x2",
            ],
            ["data": 1],
            ["data": "not hex"],
            ["to": "0x1"],
            ["type": 2],
            ["type": "0x" + String(repeating: "f", count: 65)],
        ]

        for parameters in malformedParameters {
            XCTAssertEqual(
                ethereumTransferParsingError(parameters: parameters),
                .invalidParameters,
                "Expected invalid parameters for \(parameters)"
            )
        }
        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x00"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        XCTAssertEqual(
            ethereumTransfer(parameters: ["type": "0x00"])?.feeIntent,
            .legacy(gasPrice: nil)
        )
        XCTAssertEqual(
            ethereumTransferParsingError(
                parameters: ["chainId": "0x1"],
                selectedChainID: "0x64"
            ),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransactionParsingError(parameters: [:]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x1",
                "gasPrice": "0x00",
            ]),
            .unsupportedTransactionType
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x1",
                "accessList": [[
                    "address": "0x1",
                    "storageKeys": [],
                ]],
            ]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(
                parameters: [
                    "type": "0x1",
                    "chainId": "0x1",
                ],
                selectedChainID: "0x64"
            ),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x3",
                "gasPrice": "0x1",
                "maxFeePerGas": "0x2",
            ]),
            .invalidParameters
        )
        XCTAssertEqual(
            ethereumTransferParsingError(parameters: [
                "type": "0x3",
                "maxPriorityFeePerGas": "0x3",
                "maxFeePerGas": "0x2",
            ]),
            .invalidParameters
        )

        for type in ["0x1", "0x3", "0x4", "0x5", "0xffff"] {
            XCTAssertEqual(
                ethereumTransferParsingError(parameters: ["type": type]),
                .unsupportedTransactionType,
                "Expected unsupported transaction type for \(type)"
            )
        }
    }

    func testEthereumTransactionParsingErrorsMapToProviderCodes() {
        let invalidParameters = DappRequestProcessor
            .ethereumTransactionProviderError(for: .invalidParameters)
        XCTAssertEqual(invalidParameters.message, Strings.somethingWentWrong)
        XCTAssertEqual(invalidParameters.code, -32_602)

        let unsupportedType = DappRequestProcessor
            .ethereumTransactionProviderError(for: .unsupportedTransactionType)
        XCTAssertEqual(unsupportedType.message, Strings.somethingWentWrong)
        XCTAssertEqual(unsupportedType.code, 4200)
    }

    func testEthereumTransactionRejectsMalformedOverflowingOrUnsafeFeeQuantities() {
        let malformedValues: [Any] = [
            "0x",
            "1",
            "0xgg",
            NSNull(),
        ]
        for value in malformedValues {
            XCTAssertNil(
                ethereumTransfer(parameters: ["gasPrice": value]),
                "Expected malformed gas price to be rejected: \(value)"
            )
        }

        let overflowingUInt256 = "0x1" + String(repeating: "0", count: 64)
        XCTAssertNil(ethereumTransfer(parameters: [
            "gasPrice": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxFeePerGas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "type": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "gas": overflowingUInt256,
        ]))
        XCTAssertNil(ethereumTransfer(parameters: [
            "value": overflowingUInt256,
        ]))

        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x0"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        XCTAssertEqual(
            ethereumTransfer(parameters: ["gasPrice": "0x00"])?.feeIntent,
            .legacy(gasPrice: BigUInt(0))
        )
        let uppercasePrefixedLegacy = ethereumTransfer(parameters: [
            "gasPrice": "0X1",
        ])
        XCTAssertEqual(
            uppercasePrefixedLegacy?.feeIntent,
            .legacy(gasPrice: BigUInt(1))
        )
        XCTAssertEqual(uppercasePrefixedLegacy?.gasPrice, "0X1")
        let zeroPriority = ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x0",
        ])
        XCTAssertEqual(
            zeroPriority?.feeIntent,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(),
                maxFeePerGas: nil
            )
        )
        XCTAssertNil(zeroPriority?.preparedFee)
        XCTAssertNil(ethereumTransfer(parameters: [
            "maxPriorityFeePerGas": "0x3",
            "maxFeePerGas": "0x2",
        ]))
    }

    func testEthereumUInt256QuantityParserIsLiberalBoundedAndCaseInsensitive() throws {
        let maximum = "0x" + String(repeating: "F", count: 64)
        let parsedMaximum = try XCTUnwrap(
            EthereumQuantity.parseUInt256(maximum)
        )
        XCTAssertEqual(parsedMaximum.toData(), Data(repeating: 0xff, count: 32))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x0"), BigUInt(0))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0xaBcDeF"), BigUInt(0xabcdef))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0X1"), BigUInt(1))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x00"), BigUInt(0))
        XCTAssertEqual(EthereumQuantity.parseUInt256("0x01"), BigUInt(1))
        XCTAssertEqual(
            EthereumQuantity.parseUInt256("0x0de0b6b3a7640000"),
            BigUInt(1_000_000_000_000_000_000)
        )
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "0x" + String(repeating: "0", count: 64) + "1"
            ),
            BigUInt(1)
        )
        XCTAssertNil(EthereumQuantity.parseUInt256("abcdef"))
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "aBcDeF",
                allowPrefixless: true
            ),
            BigUInt(0xabcdef)
        )
        XCTAssertEqual(
            EthereumQuantity.parseUInt256(
                "01",
                allowPrefixless: true
            ),
            BigUInt(1)
        )
        XCTAssertNil(
            EthereumQuantity.parseUInt256("", allowPrefixless: true)
        )

        for malformed in [
            "",
            "0x",
            "0X",
            "0xg",
            "0xＦ",
            "0xＦ1",
            "0x" + String(repeating: "f", count: 65),
            "0x" + String(repeating: "0", count: 256) + "1",
        ] {
            XCTAssertNil(
                EthereumQuantity.parseUInt256(malformed),
                "Expected malformed quantity to be rejected: \(malformed)"
            )
        }
    }

    func testEthereumTransactionValidatesPresentGasAndValueQuantities() throws {
        let absent = try XCTUnwrap(ethereumTransfer(parameters: [:]))
        XCTAssertNil(absent.gas)
        XCTAssertEqual(absent.value, String.hexPrefix)

        let maximum = "0x" + String(repeating: "F", count: 64)
        let maximumTransaction = try XCTUnwrap(ethereumTransfer(parameters: [
            "gas": maximum,
            "value": maximum,
        ]))
        XCTAssertEqual(maximumTransaction.gas, maximum)
        XCTAssertEqual(maximumTransaction.value, maximum)

        let zero = try XCTUnwrap(ethereumTransfer(parameters: [
            "gas": "0x0",
            "value": "0x0",
        ]))
        XCTAssertEqual(zero.gas, "0x0")
        XCTAssertEqual(zero.value, "0x0")

        for encoded in ["0x00", "0x01", "0X1"] {
            let liberalGas = try XCTUnwrap(
                ethereumTransfer(parameters: ["gas": encoded]),
                "Expected liberal gas encoding to be accepted: \(encoded)"
            )
            XCTAssertEqual(liberalGas.gas, encoded)

            let liberalValue = try XCTUnwrap(
                ethereumTransfer(parameters: ["value": encoded]),
                "Expected liberal value encoding to be accepted: \(encoded)"
            )
            XCTAssertEqual(liberalValue.value, encoded)
        }

        let malformedValues: [Any] = [
            "0x",
            "0xgg",
            1,
            NSNull(),
        ]
        for field in ["gas", "value"] {
            for value in malformedValues {
                XCTAssertEqual(
                    ethereumTransferParsingError(parameters: [field: value]),
                    .invalidParameters,
                    "Expected malformed \(field) to be rejected: \(value)"
                )
            }
        }
    }

    func testEthereumTransactionValidatesOptionalFromAgainstSelectedAccount() throws {
        let selectedAddress =
            "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let caseVariedAddress =
            "0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD"

        let absent = try XCTUnwrap(
            ethereumTransfer(
                parameters: [:],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(absent.from, selectedAddress)

        let matching = try XCTUnwrap(
            ethereumTransfer(
                parameters: ["from": selectedAddress],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(matching.from, selectedAddress)

        let caseVaried = try XCTUnwrap(
            ethereumTransfer(
                parameters: ["from": caseVariedAddress],
                selectedAddress: selectedAddress
            )
        )
        XCTAssertEqual(caseVaried.from, selectedAddress)

        let invalidFromValues: [Any] = [
            "0x0000000000000000000000000000000000000002",
            "0x1",
            NSNull(),
            1,
        ]
        for value in invalidFromValues {
            XCTAssertEqual(
                ethereumTransferParsingError(
                    parameters: ["from": value],
                    selectedAddress: selectedAddress
                ),
                .invalidParameters,
                "Expected invalid from value: \(value)"
            )
        }
    }

    func testEthereumTransactionValidatesOptionalTransactionChainID() {
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0x64",
        ], selectedChainID: "0x64"))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": "0x1",
        ], selectedChainID: "0x64"))
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0x01",
        ], selectedChainID: "0x1"))
        XCTAssertNotNil(ethereumTransfer(parameters: [
            "chainId": "0X1",
        ], selectedChainID: "0x1"))
        XCTAssertNil(ethereumTransfer(parameters: [
            "chainId": 1,
        ], selectedChainID: "0x1"))
    }

    func testEthereumTransactionAccessListPreservesEntryAndStorageKeyOrder() throws {
        let firstAddress = "0x0000000000000000000000000000000000000001"
        let secondAddress = "0x00000000000000000000000000000000000000f0"
        let firstKey = "0x" + String(repeating: "0", count: 63) + "1"
        let secondKey = "0x" + String(repeating: "0", count: 62) + "20"
        let thirdKey = "0x" + String(repeating: "0", count: 61) + "300"

        let transaction = try XCTUnwrap(ethereumTransfer(parameters: [
            "accessList": [
                [
                    "address": firstAddress,
                    "storageKeys": [firstKey, secondKey],
                ],
                [
                    "address": secondAddress,
                    "storageKeys": [thirdKey],
                ],
            ],
        ]))

        XCTAssertEqual(
            transaction.feeIntent,
            .eip1559(maxPriorityFeePerGas: nil, maxFeePerGas: nil)
        )
        XCTAssertEqual(
            transaction.accessList.map(\.addressHexString),
            [firstAddress, secondAddress]
        )
        XCTAssertEqual(
            transaction.accessList.map(\.storageKeyHexStrings),
            [[firstKey, secondKey], [thirdKey]]
        )
    }

    func testEthereumTransactionRejectsMalformedAccessLists() {
        let address = "0x0000000000000000000000000000000000000001"
        let key = "0x" + String(repeating: "0", count: 63) + "1"
        let malformedAccessLists: [Any] = [
            NSNull(),
            ["not an entry"],
            [["storageKeys": [key]]],
            [["address": "0x1", "storageKeys": [key]]],
            [["address": address]],
            [["address": address, "storageKeys": key]],
            [["address": address, "storageKeys": ["0x1"]]],
            [["address": address, "storageKeys": [key, 1]]],
            [[
                "address": String(address.dropFirst(2)),
                "storageKeys": [key],
            ]],
            [[
                "address": "0X" + String(address.dropFirst(2)),
                "storageKeys": [key],
            ]],
            [[
                "address": address,
                "storageKeys": [String(key.dropFirst(2))],
            ]],
            [[
                "address": address,
                "storageKeys": ["0X" + String(key.dropFirst(2))],
            ]],
        ]

        for accessList in malformedAccessLists {
            XCTAssertNil(
                ethereumTransfer(parameters: ["accessList": accessList]),
                "Expected malformed access list to be rejected: \(accessList)"
            )
        }
    }

    func testEthereumContractCreationTransactionParsingRequiresInitcodeWhenDestinationIsMissingOrEmpty() {
        let initcode = "0x6001600055"

        let omittedDestination = ethereumTransaction(parameters: ["data": initcode])
        let nullDestination = ethereumTransaction(parameters: ["to": NSNull(), "data": initcode])
        let emptyDestination = ethereumTransaction(parameters: ["to": "", "data": initcode])

        XCTAssertEqual(omittedDestination?.to, "")
        XCTAssertEqual(omittedDestination?.data, initcode)
        XCTAssertEqual(nullDestination?.to, "")
        XCTAssertEqual(nullDestination?.data, initcode)
        XCTAssertEqual(emptyDestination?.to, "")
        XCTAssertEqual(emptyDestination?.data, initcode)
        XCTAssertEqual(ethereumTransaction(parameters: ["data": "6001600055"])?.to, "")
        XCTAssertEqual(ethereumTransaction(parameters: ["data": "0xABCD"])?.to, "")
        XCTAssertNil(ethereumTransaction(parameters: [:]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0x1"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "0X6001"]))
        XCTAssertNil(ethereumTransaction(parameters: ["data": "not hex"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": NSNull(), "data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": NSNull(), "data": "0xzz"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": "", "data": "0x"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": "", "data": "0x123"]))
        XCTAssertNil(ethereumTransaction(parameters: ["to": 0, "data": initcode]))
    }

    func testEthereumGasEstimateObjectOmitsDestinationForContractCreation() {
        let contractCreation = Transaction(from: "0x0000000000000000000000000000000000000001",
                                           to: "",
                                           nonce: nil,
                                           gasPrice: "0x1",
                                           gas: "0x5208",
                                           value: "0x",
                                           data: "0x6001600055")
        let transfer = Transaction(from: "0x0000000000000000000000000000000000000001",
                                   to: "0x0000000000000000000000000000000000000002",
                                   nonce: nil,
                                   gasPrice: "0x1",
                                   gas: "0x5208",
                                   value: "0x",
                                   data: "0x")

        let contractCreationObject = EthereumRPC.estimateGasTransactionObject(for: contractCreation)
        let transferObject = EthereumRPC.estimateGasTransactionObject(for: transfer)

        XCTAssertEqual(contractCreationObject["from"] as? String, contractCreation.from)
        XCTAssertEqual(contractCreationObject["data"] as? String, contractCreation.data)
        XCTAssertNil(contractCreationObject["to"])
        XCTAssertEqual(contractCreationObject["gasPrice"] as? String, contractCreation.gasPrice)
        XCTAssertEqual(contractCreationObject["gas"] as? String, contractCreation.gas)
        XCTAssertNil(contractCreationObject["value"])
        XCTAssertEqual(transferObject["to"] as? String, transfer.to)
    }

    func testSolanaSignMessageDecodingUsesWireEncodingNotDisplayEncoding() {
        let encodedHello = "0x68656c6c6f"
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage(encodedHello,
                                                                     messageEncoding: .hex),
                       Data("hello".utf8))
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage("hello",
                                                                     messageEncoding: .utf8),
                       Data("hello".utf8))
        XCTAssertEqual(DappRequestProcessor.decodedSolanaSignMessage("dead",
                                                                     messageEncoding: .utf8),
                       Data("dead".utf8))
        XCTAssertNil(DappRequestProcessor.decodedSolanaSignMessage("hello",
                                                                   messageEncoding: .hex))
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: "hex"), .hex)
        XCTAssertEqual(solanaSignMessageEncoding(display: "utf8", messageEncoding: nil), .utf8)
        XCTAssertNil(solanaSignMessageEncoding(display: "utf8", messageEncoding: "base58"))
    }

    private func ethereumTransfer(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> Transaction? {
        var transferParameters: [String: Any] = [
            "to": "0x0000000000000000000000000000000000000002",
        ]
        transferParameters.merge(parameters) { _, newValue in newValue }
        return ethereumTransaction(
            parameters: transferParameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        )
    }

    private func ethereumTransferParsingError(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> TransactionParsingError? {
        var transferParameters: [String: Any] = [
            "to": "0x0000000000000000000000000000000000000002",
        ]
        transferParameters.merge(parameters) { _, newValue in newValue }
        return ethereumTransactionParsingError(
            parameters: transferParameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        )
    }

    private func ethereumTransactionParsingError(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> TransactionParsingError? {
        switch ethereumRequest(
            parameters: parameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        ).transactionParsingResult {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }

    private func ethereumTransaction(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> Transaction? {
        try? ethereumRequest(
            parameters: parameters,
            selectedChainID: selectedChainID,
            selectedAddress: selectedAddress
        ).transactionParsingResult.get()
    }

    private func ethereumRequest(
        parameters: [String: Any],
        selectedChainID: String = "0x1",
        selectedAddress: String =
            "0x0000000000000000000000000000000000000001"
    ) -> SafariRequest.Ethereum {
        let json: [String: Any] = [
            "address": selectedAddress,
            "chainId": selectedChainID,
            "object": parameters,
        ]
        guard let request = SafariRequest.Ethereum(
            name: "signTransaction",
            json: json
        ) else {
            preconditionFailure("Invalid Ethereum request fixture")
        }
        return request
    }

    private func solanaSignMessageEncoding(display: String?,
                                           messageEncoding: String?) -> SafariRequest.Solana.MessageEncoding? {
        var params: [String: Any] = [:]
        if let display {
            params["display"] = display
        }
        if let messageEncoding {
            params["messageEncoding"] = messageEncoding
        }

        let json: [String: Any] = [
            "publicKey": "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
            "object": [
                "params": params,
            ],
        ]
        return SafariRequest.Solana(name: "signMessage", json: json)?.signMessageEncoding
    }

    func testSwitchAccountPreselectionPreservesResolvedAccountsAndFillsStaleProviders() {
        let ethereumAccount = "ethereum-account"
        let solanaAccount = "solana-account"
        let providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration] = [
            .init(provider: .ethereum, address: "0x0000000000000000000000000000000000000abc", chainId: "0x1"),
            .init(provider: .solana, address: "stale-solana-public-key", chainId: nil),
        ]

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: providerConfigurations,
                                                                                      accountForConfiguration: { configuration in
            guard configuration.provider == .ethereum else { return nil }
            return ethereumAccount
        }, suggestedValuesForProviders: { providers in
            XCTAssertEqual(providers, [.solana])
            return [solanaAccount]
        }, defaultSuggestedValues: {
            XCTFail("Expected stale provider fallback, not empty-configuration fallback")
            return []
        })

        XCTAssertEqual(preselectedAccounts, [ethereumAccount, solanaAccount])
    }

    func testSwitchAccountPreselectionUsesMalformedProviderEntriesForSuggestions() {
        let solanaAccount = "solana-account"
        let providerConfigurations: [SafariRequest.Unknown.ProviderConfiguration] = [
            .init(provider: .solana, address: nil, chainId: nil),
        ]

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: providerConfigurations,
                                                                                      accountForConfiguration: { _ in nil },
                                                                                      suggestedValuesForProviders: { providers in
            XCTAssertEqual(providers, [.solana])
            return [solanaAccount]
        }, defaultSuggestedValues: {
            XCTFail("Expected malformed provider fallback, not empty-configuration fallback")
            return []
        })

        XCTAssertEqual(preselectedAccounts, [solanaAccount])
    }

    func testSwitchAccountPreselectionUsesExplicitDefaultForEmptyConfigurations() {
        let ethereumAccount = "ethereum-account"

        let preselectedAccounts: [String] = DappRequestProcessor.preselectedAccounts(for: [],
                                                                                      accountForConfiguration: { _ in
            XCTFail("Empty configuration should not resolve stored accounts")
            return nil
        }, suggestedValuesForProviders: { _ in
            XCTFail("Empty configuration should use explicit default suggestions")
            return []
        }, defaultSuggestedValues: {
            [ethereumAccount]
        })

        XCTAssertEqual(preselectedAccounts, [ethereumAccount])
    }

    func testApprovedEthereumChainAdditionDoesNotOverwriteNetworkResolvedDuringApproval() {
        var persistCallCount = 0

        let didComplete = DappRequestProcessor.completeApprovedEthereumChainAddition(
            resolution: { self.resolvedEthereumNetworkResolution() },
            persist: {
                persistCallCount += 1
                return true
            }
        )

        XCTAssertTrue(didComplete)
        XCTAssertEqual(persistCallCount, 0)
    }

    func testApprovedEthereumChainAdditionFailsWhenUnavailableOrPersistenceDoesNotResolve() {
        var unavailablePersistCallCount = 0
        XCTAssertFalse(
            DappRequestProcessor.completeApprovedEthereumChainAddition(
                resolution: { .catalogOwnedButUnavailable },
                persist: {
                    unavailablePersistCallCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(unavailablePersistCallCount, 0)

        var failedPersistCallCount = 0
        XCTAssertFalse(
            DappRequestProcessor.completeApprovedEthereumChainAddition(
                resolution: { .unknown },
                persist: {
                    failedPersistCallCount += 1
                    return false
                }
            )
        )
        XCTAssertEqual(failedPersistCallCount, 1)

        var unresolvedPersistCallCount = 0
        XCTAssertFalse(
            DappRequestProcessor.completeApprovedEthereumChainAddition(
                resolution: { .unknown },
                persist: {
                    unresolvedPersistCallCount += 1
                    return true
                }
            )
        )
        XCTAssertEqual(unresolvedPersistCallCount, 1)
    }

    func testConcurrentApprovedEthereumChainAdditionsPersistOnce() {
        let resolvedResolution = resolvedEthereumNetworkResolution()
        let resultsLock = NSLock()
        var isResolved = false
        var persistCallCount = 0
        var results = [Bool]()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = DappRequestProcessor.completeApprovedEthereumChainAddition(
                resolution: {
                    return isResolved ? resolvedResolution : .unknown
                },
                persist: {
                    persistCallCount += 1
                    isResolved = true
                    return true
                }
            )

            resultsLock.lock()
            results.append(result)
            resultsLock.unlock()
        }

        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(persistCallCount, 1)
    }

    private func resolvedEthereumNetworkResolution() -> EthereumNetworkResolution {
        let rpcURL = URL(string: "https://custom.example")!
        let network = EthereumNetwork(
            chainId: 64_240,
            name: "Custom",
            symbol: "CUSTOM",
            rpcEndpoint: .unauthenticated(rpcURL),
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
        return .resolved(
            ResolvedEthereumNetwork(network: network, source: .custom)
        )
    }

}
