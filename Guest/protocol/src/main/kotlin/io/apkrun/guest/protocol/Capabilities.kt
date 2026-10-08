package io.apkrun.guest.protocol

/**
 * The capabilities of guest-protocol.md §5.3, in table order. The wire name is
 * `<area>.<feature>.v<n>`.
 */
enum class GuestCapability(val wireName: String) {
    CORE("core.v1"),
    DISPLAY("display.v1"),
    LAUNCH("launch.v1"),
    INPUT("input.v1"),
    IME("ime.v1"),
    PACKAGES("packages.v1"),
    HEALTH("health.v1"),
    SYSTEM("system.v1"),
    CLIPBOARD_TEXT("clipboard.text.v1"),
    CLIPBOARD_IMAGE("clipboard.image.v1"),
    NOTIFICATIONS("notifications.v1"),
    URL("url.v1"),
    FILES("files.v1"),
    FILES_SHARED("files.shared.v1"),
    LOCALE("locale.v1"),
    AUDIO("audio.v1"),
    DIAGNOSTICS("diagnostics.v1"),
    BULK("bulk.v1"),
    STORE_INSTALL("store.install.v1"),
    STORE_METADATA("store.metadata.v1"),
    STORE_ICON("store.icon.v1"),
    STORE_ROLLBACK("store.rollback.v1"),
    STORE_OWNERSHIP("store.ownership.v1"),
    STORE_CONSTRAINTS("store.constraints.v1");

    companion object {
        /**
         * The capabilities that a connection enables: the advertised ones that [supported]
         * contains. Unknown strings are ignored, and the result is sorted (§5.3).
         */
        fun enabled(
            advertised: Collection<String>,
            supported: Set<GuestCapability> = entries.toSet(),
        ): List<String> {
            val supportedNames = supported.map { it.wireName }.toSet()
            return advertised.toSet().intersect(supportedNames).sorted()
        }
    }
}
