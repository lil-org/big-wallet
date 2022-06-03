// https://github.com/near/near-api-swift/blob/master/nearclientios/Sources/Utils/Int2x/UInt2X.swift

// swiftlint:disable all

import Foundation
import Accelerate.vecLib

public typealias UInt1X = FixedWidthInteger & BinaryInteger & UnsignedInteger & Codable

public struct UInt2X<Word:UInt1X>: Hashable, Codable {
    public typealias IntegerLiteralType = UInt64
    public typealias Magnitude = UInt2X
    public typealias Words = [Word.Words.Element]
    public typealias Stride = Int
    // internally it is least significant word first to make Accelerate happy
    public var lo:Word = 0
    public var hi:Word = 0
    public init(hi:Word, lo:Word) { (self.hi, self.lo) = (hi, lo) }
    public init(_ source:UInt2X){ (hi, lo) = (source.hi, source.lo) }
}
// Swift bug?
// auto-generated == incorrectly reports
// UInt2X(hi:nonzero, lo:0) == 0 is true
extension UInt2X {
    public static func == (_ lhs: UInt2X, _ rhs: UInt2X)->Bool {
        return lhs.hi == rhs.hi && lhs.lo == rhs.lo
    }
}
extension UInt2X : ExpressibleByIntegerLiteral {
    public static var isSigned: Bool { return false }
    public static var bitWidth: Int {
        return Word.bitWidth * 2
    }
    public static var min:UInt2X { return UInt2X(hi:Word.min, lo:Word.min) }
    public static var max:UInt2X { return UInt2X(hi:Word.max, lo:Word.max) }
    public init(_ source: Word) {
        (hi, lo) = (0, source)
    }
    public init?<T>(exactly source: T) where T : BinaryInteger {
        guard source.bitWidth <= UInt2X.bitWidth || source <= T(UInt2X.max) else {
            return nil
        }
        self.init(source)
    }
    public init<T>(_ source: T) where T : BinaryInteger  {
        self.hi = Word(source.magnitude >> Word.bitWidth)
        self.lo = Word(truncatingIfNeeded:source.magnitude)
    }
    public init?<T>(exactly source: T) where T : BinaryFloatingPoint {
        print("\(#line)", source)
        guard source.sign != .minus else { return nil }
        guard source.exponent < UInt2X.bitWidth else { return nil }
        self = UInt2X(source.significandBitPattern | (1 << T.significandBitCount) )
        self <<= Int(source.exponent) - T.significandBitCount
    }
    public init<T>(_ source: T) where T : BinaryFloatingPoint {
        guard let result = UInt2X(exactly: source) else {
            fatalError("Not enough bits to represent a signed value")
        }
        self = result
    }
    // alway succeeds
    public init<T:BinaryInteger>(truncatingIfNeeded source: T) {
        self.hi = Word(truncatingIfNeeded:source.magnitude >> Word.bitWidth)
        self.lo = Word(truncatingIfNeeded:source.magnitude)
    }
    // alway succeeds
    public init<T:BinaryInteger>(clamping source: T) {
        self = UInt2X(exactly: source) ?? UInt2X.max
    }
    public init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
}
// Comparable
extension UInt2X : Comparable {
    public static func < (lhs: UInt2X, rhs: UInt2X) -> Bool {
        return lhs.hi < rhs.hi ? true : lhs.hi == rhs.hi && lhs.lo < rhs.lo
    }
}
// Accelerate support
// careful with the significance order.  Accerelate is least significant first.
#if os(macOS) || os(iOS)
import Accelerate
#endif
public class Int2XConfig {
    #if os(macOS) || os(iOS)
    public static var useAccelerate = true
    #else
    public static let useAccelerate = false
    #endif
}
// numeric
extension UInt2X : Numeric {
   public var magnitude: UInt2X {
        return self
    }
    // unary operators
    public static prefix func ~(_ value:UInt2X)->UInt2X {
        return UInt2X(hi:~value.hi, lo:~value.lo)
    }
    public static prefix func +(_ value:UInt2X)->UInt2X {
        return value
    }
    public static prefix func -(_ value:UInt2X)->UInt2X {
        return ~value &+ 1  // two's complement
    }
    // additions
    public func addingReportingOverflow(_ other: UInt2X) -> (partialValue: UInt2X, overflow: Bool) {
        guard self  != 0 else { return (other, false) }
        guard other != 0 else { return (self,  false) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            //print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).addingReportingOverflow(\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((self,  vU128()), to:vU256.self)
                var b = unsafeBitCast((other, vU128()), to:vU256.self)
                var ab = vU256()
                vU256Add(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            case is UInt256:
                var a = unsafeBitCast((self,  vU256()), to:vU512.self)
                var b = unsafeBitCast((other, vU256()), to:vU512.self)
                var ab = vU512()
                vU512Add(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            case is UInt512:
                var a = unsafeBitCast((self,  vU512()), to:vU1024.self)
                var b = unsafeBitCast((other, vU512()), to:vU1024.self)
                var ab = vU1024()
                vU1024Add(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            default:
                break
            }
        }
        #endif
        var of = false
        let (lv, lf) = self.lo.addingReportingOverflow(other.lo)
        var (hv, uo) = self.hi.addingReportingOverflow(other.hi)
        if lf {
            (hv, of) = hv.addingReportingOverflow(1)
        }
        return (partialValue: UInt2X(hi:hv, lo:lv), overflow: uo || of)
    }
    public func addingReportingOverflow(_ other: Word) -> (partialValue: UInt2X, overflow: Bool) {
        return self.addingReportingOverflow(UInt2X(hi:0, lo:other))
    }
    public static func &+(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        return lhs.addingReportingOverflow(rhs).partialValue
    }
    public static func +(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        precondition(~lhs >= rhs, "\(lhs) + \(rhs): Addition overflow!")
        return lhs &+ rhs
    }
    public static func +(_ lhs:UInt2X, _ rhs:Word)->UInt2X {
        return lhs + UInt2X(hi:0, lo:rhs)
    }
    public static func +(_ lhs:Word, _ rhs:UInt2X)->UInt2X {
        return UInt2X(hi:0, lo:lhs) + rhs
    }
    public static func += (lhs: inout UInt2X, rhs: UInt2X) {
        lhs = lhs + rhs
    }
    public static func += (lhs: inout UInt2X, rhs: Word) {
        lhs = lhs + rhs
    }
    // subtraction
    public func subtractingReportingOverflow(_ other: UInt2X) -> (partialValue: UInt2X, overflow: Bool) {
        guard self  != other else { return (0,  false) }
        guard self  != 0 else { return (-other, false) }
        guard other != 0 else { return (+self,  false) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).subtractingReportingOverflow(\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((self,  vU128()), to:vU256.self)
                var b = unsafeBitCast((other, vU128()), to:vU256.self)
                var ab = vU256()
                vU256Sub(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            case is UInt256:
                var a = unsafeBitCast((self,  vU256()), to:vU512.self)
                var b = unsafeBitCast((other, vU256()), to:vU512.self)
                var ab = vU512()
                vU512Sub(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            case is UInt512:
                var a = unsafeBitCast((self,  vU512()), to:vU1024.self)
                var b = unsafeBitCast((other, vU512()), to:vU1024.self)
                var ab = vU1024()
                vU1024Sub(&a, &b, &ab)
                let (r, o) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (r, o != 0)
            default:
                break
            }
        }
        #endif
        return self.addingReportingOverflow(-other)
    }
    public func subtractingReportingOverflow(_ other: Word) -> (partialValue: UInt2X, overflow: Bool) {
        return self.subtractingReportingOverflow(UInt2X(hi:0, lo:other))
    }
    public static func &-(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        return lhs.subtractingReportingOverflow(rhs).partialValue
    }
    public static func -(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        precondition(lhs >= rhs, "\(lhs) - \(rhs): Subtraction overflow!")
        return lhs &- rhs
    }
    public static func -(_ lhs:UInt2X, _ rhs:Word)->UInt2X {
        return lhs - UInt2X(hi:0, lo:rhs)
    }
    public static func -(_ lhs:Word, _ rhs:UInt2X)->UInt2X {
        return UInt2X(hi:0, lo:lhs) - rhs
    }
    public static func -= (lhs: inout UInt2X, rhs: UInt2X) {
        lhs = lhs - rhs
    }
    public static func -= (lhs: inout UInt2X, rhs: Word) {
        lhs = lhs - rhs
    }
    // multiplication
    public func multipliedHalfWidth(by other: Word) -> (high: UInt2X, low: Magnitude) {
        guard self  != 0 else { return (0, 0) }
        guard other != 0 else { return (0, 0) }
        let l = self.lo.multipliedFullWidth(by:other)
        let h = self.hi.multipliedFullWidth(by:other)
        let r0          = Word(l.low)
        let (r1, o1)    = Word(h.low).addingReportingOverflow(Word(l.high))
        let r2          = Word(h.high) &+ (o1 ? 1 : 0)  // will not overflow
        return (UInt2X(hi:0, lo:r2), UInt2X(hi:r1, lo:r0))
    }
    public func multipliedFullWidth(by other: UInt2X) -> (high: UInt2X, low: Magnitude) {
        guard self  != 0 else { return (0, 0) }
        guard other != 0 else { return (0, 0) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).multipliedFullWidth(by:\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast(self,  to:vU128.self)
                var b = unsafeBitCast(other, to:vU128.self)
                var ab = vU256()
                vU128FullMultiply(&a, &b, &ab)
                let (l, h) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (h, l)
            case is UInt256:
                var a = unsafeBitCast(self,  to:vU256.self)
                var b = unsafeBitCast(other, to:vU256.self)
                var ab = vU512()
                vU256FullMultiply(&a, &b, &ab)
                let (l, h) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (h, l)
            case is UInt512:
                var a = unsafeBitCast(self,  to:vU512.self)
                var b = unsafeBitCast(other, to:vU512.self)
                var ab = vU1024()
                vU512FullMultiply(&a, &b, &ab)
                let (l, h) = unsafeBitCast(ab, to:(UInt2X, UInt2X).self)
                return (h, l)
            default:
                break
            }
        }
        #endif
        let l  = self.multipliedHalfWidth(by: other.lo)
        let hs = self.multipliedHalfWidth(by: other.hi)
        let h  = (high:UInt2X(hi:hs.high.lo, lo:hs.low.hi), low:UInt2X(hi:hs.low.lo, lo:0))
        let (rl, ol) = h.low.addingReportingOverflow(l.low)
        let rh       = h.high &+ l.high &+ (ol ? 1 : 0) // will not overflow
        return (rh, rl)
    }
    public func multipliedReportingOverflow(by other: UInt2X) -> (partialValue: UInt2X, overflow: Bool) {
        guard self  != 0 else { return (0, false) }
        guard other != 0 else { return (0, false) }
        let result = self.multipliedFullWidth(by: other)
        return (result.low, 0 < result.high)
    }
    public static func &*(lhs: UInt2X, rhs: UInt2X) -> UInt2X {
        return lhs.multipliedReportingOverflow(by: rhs).partialValue
    }
    public static func &*(lhs: UInt2X, rhs: Word) -> UInt2X {
        return lhs.multipliedHalfWidth(by: rhs).low
    }
    public static func &*(lhs: Word, rhs: UInt2X) -> UInt2X {
        return rhs.multipliedHalfWidth(by: lhs).low
    }
    public static func *(lhs: UInt2X, rhs: UInt2X) -> UInt2X {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        precondition(!result.overflow, "Multiplication overflow!")
        return result.partialValue
    }
    public static func *(lhs: UInt2X, rhs: Word) -> UInt2X {
        let result = lhs.multipliedHalfWidth(by: rhs)
        precondition(result.high == 0, "Multiplication overflow!")
        return result.low
    }
    public static func *(lhs: Word, rhs: UInt2X) -> UInt2X {
        let result = rhs.multipliedHalfWidth(by: lhs)
        precondition(result.high == 0, "Multiplication overflow!")
        return result.low
    }
    public static func *= (lhs: inout UInt2X, rhs: UInt2X) {
        lhs = lhs * rhs
    }
    public static func *= (lhs: inout UInt2X, rhs: Word) {
        lhs = lhs * rhs
    }
}
// bitshifts
extension UInt2X {
    public func rShifted(_ width:Int)->UInt2X {
        if width <  0 { return self.lShifted(-width) }
        if width == 0 { return self }
        if width == Word.bitWidth     { return UInt2X(hi:0, lo:self.hi) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).rShifted(\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((self,  vU128()), to:vU256.self)
                var r = vU256()
                vLR256Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
            case is UInt256:
                var a = unsafeBitCast(self, to:vU256.self)
                var r = vU256()
                vLR256Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            case is UInt512:
                var a = unsafeBitCast(self, to:vU512.self)
                var r = vU512()
                vLR512Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            case is UInt1024:
                var a = unsafeBitCast(self, to:vU1024.self)
                var r = vU1024()
                vLR1024Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            default:
                break
            }
        }
        #endif
        if Word.bitWidth < width {
            return UInt2X(hi:0, lo:self.hi >> (width - Word.bitWidth))
        }
        else {
            let mask = Word((1 << width) &- 1)
            let carry = (self.hi & mask) << (Word.bitWidth - width)
            return UInt2X(hi: self.hi >> width, lo: carry | self.lo >> width)
        }
    }
    public func lShifted(_ width:Int)->UInt2X {
        if width <  0 { return self.rShifted(-width) }
        if width == 0 { return self }
        if width == Word.bitWidth     { return UInt2X(hi:self.lo, lo:0) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).lShifted(\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((self,  vU128()), to:vU256.self)
                var r = vU256()
                vLL256Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
            case is UInt256:
                var a = unsafeBitCast(self, to:vU256.self)
                var r = vU256()
                vLL256Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            case is UInt512:
                var a = unsafeBitCast(self, to:vU512.self)
                var r = vU512()
                vLL512Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            case is UInt1024:
                var a = unsafeBitCast(self, to:vU1024.self)
                var r = vU1024()
                vLL1024Shift(&a, UInt32(width), &r)
                return unsafeBitCast(r, to:UInt2X.self)
            default:
                break
            }
        }
        #endif
        if Word.bitWidth < width {
            return UInt2X(hi:self.lo << (width - Word.bitWidth), lo:0)
        }
        else {
            let carry = self.lo >> (Word.bitWidth - width)
            return UInt2X(hi: self.hi << width | carry, lo: self.lo << width)
        }
    }
    public static func &>>(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        return lhs.rShifted(Int(rhs.lo))
    }
    public static func &>>=(_ lhs:inout UInt2X, _ rhs:UInt2X) {
        return lhs = lhs &>> rhs
    }
    public static func &<<(_ lhs:UInt2X, _ rhs:UInt2X)->UInt2X {
        return lhs.lShifted(Int(rhs.lo))
    }
    public static func &<<=(_ lhs:inout UInt2X, _ rhs:UInt2X) {
        return lhs = lhs &<< rhs
    }
}
// division, which is rather tough
extension UInt2X {
    public func quotientAndRemainder(dividingBy other: Word) -> (quotient: UInt2X, remainder: UInt2X) {
        precondition(other != 0, "division by zero!")
        let (qh, rh) = self.hi.quotientAndRemainder(dividingBy: other)
        let (ql, rl) = other.dividingFullWidth((high: rh, low:self.lo.magnitude))
        return (UInt2X(hi:qh, lo:ql), UInt2X(rl))
    }
    public func quotientAndRemainder(dividingBy other: UInt2X) -> (quotient: UInt2X, remainder: UInt2X) {
        precondition(other != 0, "division by zero!")
        guard other != self else { return (1, 0) }
        guard other <  self else { return (0, self) }
        guard other.hi != 0 else {
            return self.quotientAndRemainder(dividingBy: other.lo)
        }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).quotientAndRemainder(dividingBy:\(other))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((self,  vU128()), to:vU256.self)
                var b = unsafeBitCast((other, vU128()), to:vU256.self)
                var (q, r) = (vU256(), vU256())
                vU256Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:(UInt2X, UInt2X).self).0
                let rr = unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
                return (qq, rr)
            case is UInt256:
                var a = unsafeBitCast(self,  to:vU256.self)
                var b = unsafeBitCast(other, to:vU256.self)
                var (q, r) = (vU256(), vU256())
                vU256Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:UInt2X.self)
                let rr = unsafeBitCast(r, to:UInt2X.self)
                return (qq, rr)
            case is UInt512:
                var a = unsafeBitCast(self,  to:vU512.self)
                var b = unsafeBitCast(other, to:vU512.self)
                var (q, r) = (vU512(), vU512())
                vU512Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:UInt2X.self)
                let rr = unsafeBitCast(r, to:UInt2X.self)
                return (qq, rr)
            case is UInt1024:
                var a = unsafeBitCast(self,  to:vU1024.self)
                var b = unsafeBitCast(other, to:vU1024.self)
                var (q, r) = (vU1024(), vU1024())
                vU1024Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:UInt2X.self)
                let rr = unsafeBitCast(r, to:UInt2X.self)
                return (qq, rr)
           default:
                break
            }
        }
        #endif
        #if false
        if Word.bitWidth * 2 <= UInt64.bitWidth { // cheat when we can :-)
            let divided = (UInt64(self.hi)  << Word.bitWidth) +  UInt64(self.lo)
            let divider = (UInt64(other.hi) << Word.bitWidth) + UInt64(other.lo)
            let (q, r) = divided.quotientAndRemainder(dividingBy: divider)
            return (UInt2X(q), UInt2X(r))
        }
        #endif
        // slow but steady bitwise long division
        // print("line \(#line): \(UInt2X.self)(\(self)).quotientAndRemainder(dividingBy:\(other))")
        var (q, r) = (UInt2X(0), UInt2X(0))
        for i in (0..<UInt2X.bitWidth).reversed() {
            r <<= 1
            r |= (self >> i) & 1
            if other <= r {
                r -= other
                q |= (1 << i)
            }
        }
        return (q, r)
    }
    public static func / (_ lhs:UInt2X, rhs:UInt2X)->UInt2X {
        return lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }
    public static func /= (_ lhs:inout UInt2X, rhs:UInt2X) {
        lhs = lhs / rhs
    }
    public static func % (_ lhs:UInt2X, rhs:UInt2X)->UInt2X {
        return lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }
    public static func %= (_ lhs:inout UInt2X, rhs:UInt2X) {
        lhs = lhs % rhs
    }
    public func dividedReportingOverflow(by other :UInt2X) -> (partialValue: UInt2X, overflow:Bool) {
        return (self / other, false)
    }
    public func remainderReportingOverflow(dividingBy other :UInt2X) -> (partialValue: UInt2X, overflow:Bool) {
        return (self % other, false)
    }
    public func dividingFullWidth(_ dividend: (high: UInt2X, low: Magnitude)) -> (quotient: UInt2X, remainder: UInt2X) {
        precondition(self != 0, "division by zero!")
        guard dividend.high != 0 else { return dividend.low.quotientAndRemainder(dividingBy: self) }
        #if os(macOS)
        if Int2XConfig.useAccelerate {
            // print("line \(#line):Accelerated! \(UInt2X.self)(\(self)).dividingFullWidth(\(dividend))")
            switch self {
            case is UInt128:
                var a = unsafeBitCast((dividend.low, dividend.high), to:vU256.self)
                var b = unsafeBitCast((self, vU128()), to:vU256.self)
                var (q, r) = (vU256(), vU256())
                vU256Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:(UInt2X, UInt2X).self).0
                let rr = unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
                return (qq, rr)
            case is UInt256:
                var a = unsafeBitCast((dividend.low, dividend.high), to:vU512.self)
                var b = unsafeBitCast((self, vU256()), to:vU512.self)
                var (q, r) = (vU512(), vU512())
                vU512Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:(UInt2X, UInt2X).self).0
                let rr = unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
                return (qq, rr)
            case is UInt512:
                var a = unsafeBitCast((dividend.low, dividend.high), to:vU1024.self)
                var b = unsafeBitCast((self, vU512()), to:vU1024.self)
                var (q, r) = (vU1024(), vU1024())
                vU1024Divide(&a, &b, &q, &r)
                let qq = unsafeBitCast(q, to:(UInt2X, UInt2X).self).0
                let rr = unsafeBitCast(r, to:(UInt2X, UInt2X).self).0
                return (qq, rr)
            default:
                break
            }
        }
        #endif
        // slow but steady bitwise long division
        // print("line \(#line): \(UInt2X.self)(\(self)).dividingFullWidth(\(dividend))")
        var (q, r) = (UInt2X(0), dividend.high % self)
        for i in (0..<UInt2X.bitWidth).reversed() {
            r <<= 1
            r |= (dividend.low >> i) & 1
            if self <= r {
                r -= self
                q |= (1 << i)
            }
        }
        return (q, r)
    }
}
// UInt2X -> String
extension UInt2X : CustomStringConvertible, CustomDebugStringConvertible {
    public func toString(radix:Int=10, uppercase:Bool=false) -> String {
        precondition((2...36) ~= radix, "radix must be within the range of 2-36.")
        if self == 0 { return "0" }
        if self.hi == 0 { return String(self.lo, radix:radix, uppercase:uppercase) }
        if radix == 16 || radix == 4 || radix == 2 { // time-saver
            let sl = String(self.lo, radix:radix, uppercase:uppercase)
            let dCount  = Word.bitWidth / (radix == 16 ? 4 : radix == 4 ? 2 : 1)
            let zeros   = [Character](repeating: "0", count: dCount - sl.count)
            return String(self.hi, radix:radix, uppercase:uppercase) + String(zeros) + sl
        }
        let digits = uppercase
            ? Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            : Array("0123456789abcdefghijklmnopqrstuvwxyz")
        #if false // slow but steady digit by digit conversion
        var result = [Character]()
        var qr = (quotient: self, remainder: UInt2X(0))
        repeat {
            qr = qr.quotient.quotientAndRemainder(dividingBy: Word(radix))
            result.append(digits[Int(qr.remainder.lo)])
        } while qr.quotient != UInt2X(0)
        return String(result.reversed())
        #else // faster n-digit-at-once conversion
        let base:UInt64 = [
            0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0xa8b8b452291fe800, //  0 ~  3
            0x0000000000000000, 0x6765c793fa100800, 0x41c21cb8e1000000, 0x3642798750226200, //  4 ~  7
            0x8000000000000000, 0xa8b8b452291fe800, 0x8ac7230489e80000, 0x4d28cb56c33fa400, //  8 ~ 11
            0x1eca170c00000000, 0x780c7372621bd800, 0x1e39a5057d810000, 0x5b27ac993df97800, // 11 ~ 15
            0x0000000000000000, 0x27b95e997e21da00, 0x5da0e1e53c5c8000, 0xd2ae3299c1c4b000, // 16 ~ 19
            0x16bcc41e90000000, 0x2d04b7fdd9c0f000, 0x5658597bcaa24000, 0xa0e2073737609000, // 20 ~ 23
            0x0c29e98000000000, 0x14adf4b732033500, 0x226ed36478bfa000, 0x383d9170b85ff800, // 24 ~ 27
            0x5a3c23e39c000000, 0x8e65137388122800, 0xdd41bb36d259e000, 0x0aee5720ee830680, // 28 ~ 31
            0x1000000000000000, 0x172588ad4f5f0a00, 0x211e44f7d02c1000, 0x2ee56725f06e5c00, // 32 ~ 35
            0x41c21cb8e1000000                                                              // 36
        ][radix]
        let nlen = base.description.count - 1
        // print("base=",base)
        var qr = (quotient: self, remainder: UInt2X(0))
        var result = [UInt64]()
        repeat {
            qr = qr.quotient.quotientAndRemainder(dividingBy: UInt2X(base))
            result.append(UInt64(qr.remainder))
        }  while qr.quotient != UInt2X(0)
        let firstDigit = result.removeLast()
        return String(firstDigit, radix:radix, uppercase:uppercase) + result.map {
            let s = String($0, radix:radix, uppercase:uppercase)
            return String([Character](repeating: "0", count:nlen - s.count)) + s
        }.reversed().joined()
        #endif
    }
    public var description:String {
        return toString()
    }
    public var debugDescription:String {
        return "0x" + toString(radix: 16)
    }
}
extension StringProtocol {
    public init?<Word>(_ source:UInt2X<Word>, radix:Int=10, uppercase:Bool=false) {
        self.init(source.toString(radix:radix, uppercase:uppercase))
    }
}
// String <- UInt2X
extension UInt2X : ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init()
        if let result = UInt2X.fromString(value) {
            self = result
        }
    }
    internal static func fromString(_ value: String) -> UInt2X? {
        let radix = UInt2X.radixFromString(value)
        let source = radix == 10 ? value : String(value.dropFirst(2))
        return UInt2X(source, radix:radix)
    }
    internal static func radixFromString(_ string: String) -> Int {
        switch string.prefix(2) {
        case "0b": return 2
        case "0o": return 8
        case "0x": return 16
        default:   return 10
        }
    }
}
// Int -> UInt2X
extension Int {
    public init<Word>(_ source:UInt2X<Word>) {
        self.init(bitPattern:UInt(source.hi << Word.bitWidth + source.lo))
    }
}
// Strideable
extension UInt2X: Strideable {
    public func distance(to other: UInt2X) -> Int {
        return Int(other) - Int(self)
    }
    public func advanced(by n: Int) -> UInt2X {
        return self + UInt2X(n)
    }
}
// BinaryInteger
extension UInt2X: BinaryInteger {
    public var bitWidth: Int {
        return Word.bitWidth * 2
    }
    public var words: Words {
        return Array(self.lo.words) + Array(self.hi.words)
    }
    public var trailingZeroBitCount: Int {
        return self.hi == 0 ? self.lo.trailingZeroBitCount : self.hi.trailingZeroBitCount + Word.bitWidth
    }
    public static func &= (lhs: inout UInt2X, rhs: UInt2X) {
        lhs = UInt2X(hi:lhs.hi & rhs.hi, lo:lhs.lo & rhs.lo)
    }
    public static func |= (lhs: inout UInt2X, rhs: UInt2X) {
        lhs = UInt2X(hi:lhs.hi | rhs.hi, lo:lhs.lo | rhs.lo)
    }
    public static func ^= (lhs: inout UInt2X<Word>, rhs: UInt2X<Word>) {
        lhs = UInt2X(hi:lhs.hi ^ rhs.hi, lo:lhs.lo ^ rhs.lo)
    }
    public static func <<= <RHS>(lhs: inout UInt2X<Word>, rhs: RHS) where RHS : BinaryInteger {
        lhs = lhs.lShifted(Int(rhs))
    }
    public static func >>= <RHS>(lhs: inout UInt2X, rhs: RHS) where RHS : BinaryInteger {
        lhs = lhs.rShifted(Int(rhs))
    }
}
// FixedWidthInteger
extension UInt2X: FixedWidthInteger {
    public init(_truncatingBits bits: UInt) {
        fatalError()
    }
    public var nonzeroBitCount: Int {
        return self.hi.nonzeroBitCount + self.lo.nonzeroBitCount
    }
    public var leadingZeroBitCount: Int {
        return self.hi == 0 ? self.lo.leadingZeroBitCount + Word.bitWidth : self.hi.leadingZeroBitCount
    }
    public var byteSwapped: UInt2X {
        return UInt2X(hi:self.lo.byteSwapped, lo:self.hi.byteSwapped)
    }
}
// UnsignedInteger
extension UInt2X: UnsignedInteger {}

public typealias UInt128    = UInt2X<UInt64>
public typealias UInt256    = UInt2X<UInt128>
public typealias UInt512    = UInt2X<UInt256>
public typealias UInt1024   = UInt2X<UInt512>
