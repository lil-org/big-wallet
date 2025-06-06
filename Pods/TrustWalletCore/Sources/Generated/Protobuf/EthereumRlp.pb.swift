// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: EthereumRlp.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

import Foundation
import WalletCoreSwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of WalletCoreSwiftProtobuf.to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: WalletCoreSwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: WalletCoreSwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

/// List of elements.
public struct TW_EthereumRlp_Proto_RlpList {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  public var items: [TW_EthereumRlp_Proto_RlpItem] = []

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// RLP item.
public struct TW_EthereumRlp_Proto_RlpItem {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  public var item: TW_EthereumRlp_Proto_RlpItem.OneOf_Item? = nil

  /// A string to be encoded.
  public var stringItem: String {
    get {
      if case .stringItem(let v)? = item {return v}
      return String()
    }
    set {item = .stringItem(newValue)}
  }

  /// A U64 number to be encoded.
  public var numberU64: UInt64 {
    get {
      if case .numberU64(let v)? = item {return v}
      return 0
    }
    set {item = .numberU64(newValue)}
  }

  /// A U256 number to be encoded.
  public var numberU256: Data {
    get {
      if case .numberU256(let v)? = item {return v}
      return Data()
    }
    set {item = .numberU256(newValue)}
  }

  /// An address to be encoded.
  public var address: String {
    get {
      if case .address(let v)? = item {return v}
      return String()
    }
    set {item = .address(newValue)}
  }

  /// A data to be encoded.
  public var data: Data {
    get {
      if case .data(let v)? = item {return v}
      return Data()
    }
    set {item = .data(newValue)}
  }

  /// A list of items to be encoded.
  public var list: TW_EthereumRlp_Proto_RlpList {
    get {
      if case .list(let v)? = item {return v}
      return TW_EthereumRlp_Proto_RlpList()
    }
    set {item = .list(newValue)}
  }

  /// An RLP encoded item to be appended as it is.
  public var rawEncoded: Data {
    get {
      if case .rawEncoded(let v)? = item {return v}
      return Data()
    }
    set {item = .rawEncoded(newValue)}
  }

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public enum OneOf_Item: Equatable {
    /// A string to be encoded.
    case stringItem(String)
    /// A U64 number to be encoded.
    case numberU64(UInt64)
    /// A U256 number to be encoded.
    case numberU256(Data)
    /// An address to be encoded.
    case address(String)
    /// A data to be encoded.
    case data(Data)
    /// A list of items to be encoded.
    case list(TW_EthereumRlp_Proto_RlpList)
    /// An RLP encoded item to be appended as it is.
    case rawEncoded(Data)

  #if !swift(>=4.1)
    public static func ==(lhs: TW_EthereumRlp_Proto_RlpItem.OneOf_Item, rhs: TW_EthereumRlp_Proto_RlpItem.OneOf_Item) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.stringItem, .stringItem): return {
        guard case .stringItem(let l) = lhs, case .stringItem(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.numberU64, .numberU64): return {
        guard case .numberU64(let l) = lhs, case .numberU64(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.numberU256, .numberU256): return {
        guard case .numberU256(let l) = lhs, case .numberU256(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.address, .address): return {
        guard case .address(let l) = lhs, case .address(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.data, .data): return {
        guard case .data(let l) = lhs, case .data(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.list, .list): return {
        guard case .list(let l) = lhs, case .list(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.rawEncoded, .rawEncoded): return {
        guard case .rawEncoded(let l) = lhs, case .rawEncoded(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      default: return false
      }
    }
  #endif
  }

  public init() {}
}

/// RLP encoding input.
public struct TW_EthereumRlp_Proto_EncodingInput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// An item or a list to encode.
  public var item: TW_EthereumRlp_Proto_RlpItem {
    get {return _item ?? TW_EthereumRlp_Proto_RlpItem()}
    set {_item = newValue}
  }
  /// Returns true if `item` has been explicitly set.
  public var hasItem: Bool {return self._item != nil}
  /// Clears the value of `item`. Subsequent reads from it will return its default value.
  public mutating func clearItem() {self._item = nil}

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _item: TW_EthereumRlp_Proto_RlpItem? = nil
}

//// RLP encoding output.
public struct TW_EthereumRlp_Proto_EncodingOutput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// An item RLP encoded.
  public var encoded: Data = Data()

  /// Error code, 0 is ok, other codes will be treated as errors.
  public var error: TW_Common_Proto_SigningError = .ok

  /// Error code description.
  public var errorMessage: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

// MARK: - Code below here is support for the WalletCoreSwiftProtobuf.runtime.

fileprivate let _protobuf_package = "TW.EthereumRlp.Proto"

extension TW_EthereumRlp_Proto_RlpList: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".RlpList"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "items"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeRepeatedMessageField(value: &self.items) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.items.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.items, fieldNumber: 1)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_EthereumRlp_Proto_RlpList, rhs: TW_EthereumRlp_Proto_RlpList) -> Bool {
    if lhs.items != rhs.items {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_EthereumRlp_Proto_RlpItem: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".RlpItem"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "string_item"),
    2: .standard(proto: "number_u64"),
    3: .standard(proto: "number_u256"),
    4: .same(proto: "address"),
    5: .same(proto: "data"),
    6: .same(proto: "list"),
    7: .standard(proto: "raw_encoded"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try {
        var v: String?
        try decoder.decodeSingularStringField(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .stringItem(v)
        }
      }()
      case 2: try {
        var v: UInt64?
        try decoder.decodeSingularUInt64Field(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .numberU64(v)
        }
      }()
      case 3: try {
        var v: Data?
        try decoder.decodeSingularBytesField(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .numberU256(v)
        }
      }()
      case 4: try {
        var v: String?
        try decoder.decodeSingularStringField(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .address(v)
        }
      }()
      case 5: try {
        var v: Data?
        try decoder.decodeSingularBytesField(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .data(v)
        }
      }()
      case 6: try {
        var v: TW_EthereumRlp_Proto_RlpList?
        var hadOneofValue = false
        if let current = self.item {
          hadOneofValue = true
          if case .list(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.item = .list(v)
        }
      }()
      case 7: try {
        var v: Data?
        try decoder.decodeSingularBytesField(value: &v)
        if let v = v {
          if self.item != nil {try decoder.handleConflictingOneOf()}
          self.item = .rawEncoded(v)
        }
      }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    switch self.item {
    case .stringItem?: try {
      guard case .stringItem(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularStringField(value: v, fieldNumber: 1)
    }()
    case .numberU64?: try {
      guard case .numberU64(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularUInt64Field(value: v, fieldNumber: 2)
    }()
    case .numberU256?: try {
      guard case .numberU256(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularBytesField(value: v, fieldNumber: 3)
    }()
    case .address?: try {
      guard case .address(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularStringField(value: v, fieldNumber: 4)
    }()
    case .data?: try {
      guard case .data(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularBytesField(value: v, fieldNumber: 5)
    }()
    case .list?: try {
      guard case .list(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 6)
    }()
    case .rawEncoded?: try {
      guard case .rawEncoded(let v)? = self.item else { preconditionFailure() }
      try visitor.visitSingularBytesField(value: v, fieldNumber: 7)
    }()
    case nil: break
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_EthereumRlp_Proto_RlpItem, rhs: TW_EthereumRlp_Proto_RlpItem) -> Bool {
    if lhs.item != rhs.item {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_EthereumRlp_Proto_EncodingInput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".EncodingInput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "item"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularMessageField(value: &self._item) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    try { if let v = self._item {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    } }()
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_EthereumRlp_Proto_EncodingInput, rhs: TW_EthereumRlp_Proto_EncodingInput) -> Bool {
    if lhs._item != rhs._item {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_EthereumRlp_Proto_EncodingOutput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".EncodingOutput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "encoded"),
    2: .same(proto: "error"),
    3: .standard(proto: "error_message"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.encoded) }()
      case 2: try { try decoder.decodeSingularEnumField(value: &self.error) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.errorMessage) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.encoded.isEmpty {
      try visitor.visitSingularBytesField(value: self.encoded, fieldNumber: 1)
    }
    if self.error != .ok {
      try visitor.visitSingularEnumField(value: self.error, fieldNumber: 2)
    }
    if !self.errorMessage.isEmpty {
      try visitor.visitSingularStringField(value: self.errorMessage, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_EthereumRlp_Proto_EncodingOutput, rhs: TW_EthereumRlp_Proto_EncodingOutput) -> Bool {
    if lhs.encoded != rhs.encoded {return false}
    if lhs.error != rhs.error {return false}
    if lhs.errorMessage != rhs.errorMessage {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
