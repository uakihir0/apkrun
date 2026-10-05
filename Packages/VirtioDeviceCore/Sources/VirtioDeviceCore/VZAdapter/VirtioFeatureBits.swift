package struct VirtioFeatureBits: Equatable, Sendable {
    package let subset0: UInt32
    package let subset1: UInt32

    package init(_ bits: UInt64) {
        subset0 = UInt32(truncatingIfNeeded: bits)
        subset1 = UInt32(truncatingIfNeeded: bits >> 32)
    }

    package var combined: UInt64 {
        UInt64(subset0) | (UInt64(subset1) << 32)
    }
}
