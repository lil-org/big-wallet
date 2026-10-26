// ∅ 2026 lil org

extension FixedWidthInteger {
    
    public init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
}
