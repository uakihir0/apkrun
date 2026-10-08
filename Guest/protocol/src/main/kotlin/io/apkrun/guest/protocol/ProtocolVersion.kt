package io.apkrun.guest.protocol

/**
 * A protocol version: a major and a minor number (guest-protocol.md §5.2). A different major is a
 * different protocol, and a higher minor is compatible.
 */
data class ProtocolVersion(val major: Int, val minor: Int) : Comparable<ProtocolVersion> {
    override fun compareTo(other: ProtocolVersion): Int =
        compareValuesBy(this, other, { it.major }, { it.minor })

    override fun toString(): String = "$major.$minor"

    companion object {
        /** The version that this build of the agent speaks. */
        val HOST = ProtocolVersion(1, 0)

        /** The majors that this build of the agent speaks. Major 1 is the only one in v1 (§5.2). */
        val SUPPORTED_MAJORS: IntRange = 1..1

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
