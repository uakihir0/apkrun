package io.apkrun.guest.protocol

/**
 * A protocol version: a major and a minor number (guest-protocol.md §5.2). A different major is a
 * different protocol, and a higher minor is compatible.
 *
 * The wire fields are uint32. protobuf-javalite returns them as signed Int values, so both numbers
 * are held as unsigned values in a Long. Use [fromWire] to convert those values.
 */
data class ProtocolVersion(val major: Long, val minor: Long) : Comparable<ProtocolVersion> {
    override fun compareTo(other: ProtocolVersion): Int =
        compareValuesBy(this, other, { it.major }, { it.minor })

    override fun toString(): String = "$major.$minor"

    companion object {
        /** The version that this build of the agent speaks. */
        val HOST = ProtocolVersion(1L, 0L)

        /** The majors that this build of the agent speaks. Major 1 is the only one in v1 (§5.2). */
        val SUPPORTED_MAJORS: LongRange = 1L..1L

        /**
         * Converts the uint32 fields of a wire version. A value of 2^31 or more arrives as a
         * negative Int, and it is read as the unsigned number it encodes.
         */
        fun fromWire(major: Int, minor: Int): ProtocolVersion =
            ProtocolVersion(Integer.toUnsignedLong(major), Integer.toUnsignedLong(minor))

        /** Compares a major version with [SUPPORTED_MAJORS]. */
        fun compatibility(version: ProtocolVersion): ProtocolCompatibility =
            when {
                version.major in SUPPORTED_MAJORS -> ProtocolCompatibility.COMPATIBLE
                version.major < SUPPORTED_MAJORS.first -> ProtocolCompatibility.BELOW_SUPPORTED
                else -> ProtocolCompatibility.ABOVE_SUPPORTED
            }
    }
}

/** How a major version relates to [ProtocolVersion.SUPPORTED_MAJORS]. */
enum class ProtocolCompatibility {
    COMPATIBLE,
    BELOW_SUPPORTED,
    ABOVE_SUPPORTED,
}
