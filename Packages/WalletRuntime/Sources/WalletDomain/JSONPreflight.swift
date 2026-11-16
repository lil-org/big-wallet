import Foundation

package enum JSONPreflight {
    package enum Failure: Error, Equatable {
        case tooDeep, tooManyTokens, unbalanced
    }

    // Bounds parser work; callers still decode JSON to validate its syntax.
    package static func validate(
        _ bytes: some Sequence<UInt8>,
        maximumDepth: Int,
        maximumTokens: Int = .max,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        var tokens = 0
        var depth = 0
        var inString = false
        var escaped = false
        var inScalar = false
        for (offset, byte) in bytes.enumerated() {
            if offset.isMultiple(of: 1_024) { try checkCancellation() }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34:
                tokens += 1
                inString = true
                inScalar = false
            case 91, 123:
                tokens += 1
                depth += 1
                inScalar = false
                guard depth <= maximumDepth else { throw Failure.tooDeep }
            case 93, 125:
                depth -= 1
                inScalar = false
                guard depth >= 0 else { throw Failure.unbalanced }
            case 9, 10, 13, 32, 44, 58:
                inScalar = false
            default:
                if !inScalar { tokens += 1 }
                inScalar = true
            }
            guard tokens <= maximumTokens else { throw Failure.tooManyTokens }
        }
        guard !inString, depth == 0 else { throw Failure.unbalanced }
    }
}
