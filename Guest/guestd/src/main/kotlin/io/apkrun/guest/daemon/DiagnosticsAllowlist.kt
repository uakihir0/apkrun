package io.apkrun.guest.daemon

/**
 * The guest side of the getprop allowlist (diagnostics.md §6.2). The agent omits every property
 * outside it, so the host never sees serials or device identifiers. The host applies the same list
 * again on its side.
 */
object DiagnosticsAllowlist {

    /** Property-name prefixes a report may keep. */
    private val PREFIXES =
        listOf(
            "ro.build.version.",
            "ro.product.cpu.abilist",
            "ro.hardware",
            "ro.boot.hardware.",
            "ro.apkrun.",
            "init.svc.",
            "dalvik.vm.heap",
        )

    /** Exact property names a report may keep. */
    private val EXACT =
        setOf(
            "ro.build.id",
            "ro.build.display.id",
            "ro.build.type",
            "ro.build.tags",
            "ro.product.name",
            "ro.product.device",
            "ro.product.board",
            "ro.product.model",
            "ro.product.brand",
            "ro.product.manufacturer",
            "ro.product.cpu.abi",
            "ro.build.product",
            "ro.build.characteristics",
            "ro.build.flavor",
            "ro.build.description",
            "ro.build.fingerprint",
            "ro.bootimage.build.date",
            "ro.bootimage.build.fingerprint",
            "ro.debuggable",
            "ro.secure",
            "ro.kernel.qemu",
            "ro.qemu.sf.fake_camera",
            "sys.boot_completed",
            "dev.bootcomplete",
            "init.svc.adbd",
            "dalvik.vm.heapsize",
            "persist.sys.timezone",
            "persist.sys.locale",
            "ro.product.locale",
            "ro.apkrun.agent.version",
            "ro.apkrun.image.version",
        )

    /** Property names that never appear, even under an allowed prefix. */
    private val NEVER =
        setOf("ro.serialno", "ro.boot.serialno", "ro.ril.oem.sno", "persist.sys.safemode_reason")

    /** Whether `name` may appear in a report. */
    fun allows(name: String): Boolean {
        if (name in NEVER) {
            return false
        }
        return name in EXACT || PREFIXES.any(name::startsWith)
    }

    /**
     * Filters `getprop` output, keeping one `[name]: [value]` line per allowlisted name, sorted for
     * a stable diff.
     */
    fun filterGetprop(output: ByteArray): ByteArray {
        val lines =
            String(output, Charsets.UTF_8)
                .lineSequence()
                .mapNotNull { line ->
                    val match = GETPROP_LINE.matchEntire(line.trim()) ?: return@mapNotNull null
                    val name = match.groupValues[1]
                    if (allows(name)) line.trim() else null
                }
                .sorted()
                .toList()
        return lines
            .joinToString("\n", postfix = if (lines.isEmpty()) "" else "\n")
            .toByteArray(Charsets.UTF_8)
    }

    private val GETPROP_LINE = Regex("^\\[([^]]+)]: \\[.*]$")
}
