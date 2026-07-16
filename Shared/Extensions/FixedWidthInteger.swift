// ∅ 2026 lil org

extension FixedWidthInteger {
    
    init?(hexString: String) {
        self.init(hexString.cleanHex, radix: 16)
    }
    
}
