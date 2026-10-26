// ∅ 2026 lil org

import Foundation
import WalletDomain

public enum SolanaMessageFixture {

    public static func wireMessage(version: UInt8? = nil,
                            requiredSignatures: UInt8 = 1,
                            readOnlySignedAccounts: UInt8 = 0,
                            readOnlyUnsignedAccounts: UInt8 = 0,
                            accountKeySeeds: [UInt8],
                            blockhashSeed: UInt8 = 9,
                            bodyAfterBlockhash: Data) -> Data {
        return wireMessage(version: version,
                           requiredSignatures: requiredSignatures,
                           readOnlySignedAccounts: readOnlySignedAccounts,
                           readOnlyUnsignedAccounts: readOnlyUnsignedAccounts,
                           accountKeys: accountKeySeeds.map { Data(repeating: $0, count: 32) },
                           blockhashSeed: blockhashSeed,
                           bodyAfterBlockhash: bodyAfterBlockhash)
    }

    public static func wireMessage(version: UInt8? = nil,
                            requiredSignatures: UInt8 = 1,
                            readOnlySignedAccounts: UInt8 = 0,
                            readOnlyUnsignedAccounts: UInt8 = 0,
                            accountKeys: [Data],
                            blockhashSeed: UInt8 = 9,
                            bodyAfterBlockhash: Data) -> Data {
        var message = Data()
        if let version {
            message.append(UInt8(0x80) | version)
            message.append(requiredSignatures)
        } else {
            message.append(requiredSignatures)
        }

        message.append(readOnlySignedAccounts)
        message.append(readOnlyUnsignedAccounts)
        message += Data.encodeLength(accountKeys.count)

        for accountKey in accountKeys {
            message.append(accountKey)
        }
        message.append(Data(repeating: blockhashSeed, count: 32))
        message.append(bodyAfterBlockhash)

        return message
    }

    public static func wireMessage(version: UInt8? = nil,
                            requiredSignatures: UInt8 = 1,
                            readOnlySignedAccounts: UInt8 = 0,
                            readOnlyUnsignedAccounts: UInt8 = 0,
                            accountKeySeeds: [UInt8],
                            blockhashSeed: UInt8 = 9,
                            bodyAfterBlockhash: [UInt8]) -> Data {
        return wireMessage(version: version,
                           requiredSignatures: requiredSignatures,
                           readOnlySignedAccounts: readOnlySignedAccounts,
                           readOnlyUnsignedAccounts: readOnlyUnsignedAccounts,
                           accountKeySeeds: accountKeySeeds,
                           blockhashSeed: blockhashSeed,
                           bodyAfterBlockhash: Data(bodyAfterBlockhash))
    }

    public static func instruction(programIdIndex: UInt8, accountIndices: [UInt8], data: Data) -> Data {
        var body = Data.encodeLength(1)
        body += compiledInstruction(programIdIndex: programIdIndex,
                                    accountIndices: accountIndices,
                                    data: data)
        return body
    }

    public static func compiledInstruction(programIdIndex: UInt8, accountIndices: [UInt8], data: Data) -> Data {
        var instruction = Data([programIdIndex])
        instruction += Data.encodeLength(accountIndices.count)
        instruction.append(contentsOf: accountIndices)
        instruction += Data.encodeLength(data.count)
        instruction.append(data)
        return instruction
    }

    public static func uint32LE(_ value: UInt32) -> Data {
        return Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    public static func uint64LE(_ value: UInt64) -> Data {
        return Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 56) & 0xff),
        ])
    }

}
