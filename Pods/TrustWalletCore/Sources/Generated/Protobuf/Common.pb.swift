// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Common.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

public enum TW_Common_Proto_SigningError: SwiftProtobuf.Enum {
  public typealias RawValue = Int

  /// OK
  case ok // = 0

  /// chain-generic, generic
  case errorGeneral // = 1
  case errorInternal // = 2

  /// chain-generic, input
  case errorLowBalance // = 3

  /// Requested amount is zero
  case errorZeroAmountRequested // = 4
  case errorMissingPrivateKey // = 5
  case errorInvalidPrivateKey // = 15
  case errorInvalidAddress // = 16
  case errorInvalidUtxo // = 17
  case errorInvalidUtxoAmount // = 18

  /// chain-generic, fee
  case errorWrongFee // = 6

  /// chain-generic, signing
  case errorSigning // = 7

  /// [NEO] Transaction too big, fee in GAS needed or try send by parts
  case errorTxTooBig // = 8

  /// UTXO-chain specific, inputs
  case errorMissingInputUtxos // = 9

  /// Not enough non-dust input UTXOs to cover requested amount (dust UTXOs are filtered out) [BTC]
  case errorNotEnoughUtxos // = 10

  /// UTXO-chain specific, script
  case errorScriptRedeem // = 11

  /// [BTC] Invalid output script
  case errorScriptOutput // = 12

  /// [BTC] Unrecognized witness program
  case errorScriptWitnessProgram // = 13

  /// e.g. [XRP] Invalid tag
  case errorInvalidMemo // = 14

  /// e.g. Invalid input data
  case errorInputParse // = 19

  /// e.g. Not support multi-input and multi-output transaction
  case errorNoSupportN2N // = 20

  /// Incorrect count of signatures passed to compile
  case errorSignaturesCount // = 21

  /// Incorrect parameters
  case errorInvalidParams // = 22
  case UNRECOGNIZED(Int)

  public init() {
    self = .ok
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .ok
    case 1: self = .errorGeneral
    case 2: self = .errorInternal
    case 3: self = .errorLowBalance
    case 4: self = .errorZeroAmountRequested
    case 5: self = .errorMissingPrivateKey
    case 6: self = .errorWrongFee
    case 7: self = .errorSigning
    case 8: self = .errorTxTooBig
    case 9: self = .errorMissingInputUtxos
    case 10: self = .errorNotEnoughUtxos
    case 11: self = .errorScriptRedeem
    case 12: self = .errorScriptOutput
    case 13: self = .errorScriptWitnessProgram
    case 14: self = .errorInvalidMemo
    case 15: self = .errorInvalidPrivateKey
    case 16: self = .errorInvalidAddress
    case 17: self = .errorInvalidUtxo
    case 18: self = .errorInvalidUtxoAmount
    case 19: self = .errorInputParse
    case 20: self = .errorNoSupportN2N
    case 21: self = .errorSignaturesCount
    case 22: self = .errorInvalidParams
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .ok: return 0
    case .errorGeneral: return 1
    case .errorInternal: return 2
    case .errorLowBalance: return 3
    case .errorZeroAmountRequested: return 4
    case .errorMissingPrivateKey: return 5
    case .errorWrongFee: return 6
    case .errorSigning: return 7
    case .errorTxTooBig: return 8
    case .errorMissingInputUtxos: return 9
    case .errorNotEnoughUtxos: return 10
    case .errorScriptRedeem: return 11
    case .errorScriptOutput: return 12
    case .errorScriptWitnessProgram: return 13
    case .errorInvalidMemo: return 14
    case .errorInvalidPrivateKey: return 15
    case .errorInvalidAddress: return 16
    case .errorInvalidUtxo: return 17
    case .errorInvalidUtxoAmount: return 18
    case .errorInputParse: return 19
    case .errorNoSupportN2N: return 20
    case .errorSignaturesCount: return 21
    case .errorInvalidParams: return 22
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension TW_Common_Proto_SigningError: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [TW_Common_Proto_SigningError] = [
    .ok,
    .errorGeneral,
    .errorInternal,
    .errorLowBalance,
    .errorZeroAmountRequested,
    .errorMissingPrivateKey,
    .errorInvalidPrivateKey,
    .errorInvalidAddress,
    .errorInvalidUtxo,
    .errorInvalidUtxoAmount,
    .errorWrongFee,
    .errorSigning,
    .errorTxTooBig,
    .errorMissingInputUtxos,
    .errorNotEnoughUtxos,
    .errorScriptRedeem,
    .errorScriptOutput,
    .errorScriptWitnessProgram,
    .errorInvalidMemo,
    .errorInputParse,
    .errorNoSupportN2N,
    .errorSignaturesCount,
    .errorInvalidParams,
  ]
}

#endif  // swift(>=4.2)

// MARK: - Code below here is support for the SwiftProtobuf runtime.

extension TW_Common_Proto_SigningError: SwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    0: .same(proto: "OK"),
    1: .same(proto: "Error_general"),
    2: .same(proto: "Error_internal"),
    3: .same(proto: "Error_low_balance"),
    4: .same(proto: "Error_zero_amount_requested"),
    5: .same(proto: "Error_missing_private_key"),
    6: .same(proto: "Error_wrong_fee"),
    7: .same(proto: "Error_signing"),
    8: .same(proto: "Error_tx_too_big"),
    9: .same(proto: "Error_missing_input_utxos"),
    10: .same(proto: "Error_not_enough_utxos"),
    11: .same(proto: "Error_script_redeem"),
    12: .same(proto: "Error_script_output"),
    13: .same(proto: "Error_script_witness_program"),
    14: .same(proto: "Error_invalid_memo"),
    15: .same(proto: "Error_invalid_private_key"),
    16: .same(proto: "Error_invalid_address"),
    17: .same(proto: "Error_invalid_utxo"),
    18: .same(proto: "Error_invalid_utxo_amount"),
    19: .same(proto: "Error_input_parse"),
    20: .same(proto: "Error_no_support_n2n"),
    21: .same(proto: "Error_signatures_count"),
    22: .same(proto: "Error_invalid_params"),
  ]
}
