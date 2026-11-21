package io.apkrun.guest.url

import io.apkrun.guest.daemon.EventBus
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.HealthWarning
import io.apkrun.guest.protocol.v1.HealthWarningKind
import io.apkrun.guest.protocol.v1.OpenUrlOnHost
import io.apkrun.guest.protocol.v1.ResolveUrl
import io.apkrun.guest.protocol.v1.SetUrlRedirect
import io.apkrun.guest.protocol.v1.UrlAction
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * The Android end of the link path (desktop-integration.md §7.1). [UrlRedirectActivity] holds the
 * browser role and calls [onLink] for every `VIEW`/`SENDTO` it intercepts; the bridge either passes
 * the intent to the in-Android browser or keeps it and publishes `open_url_on_host` (event 43). The
 * host answers with `ResolveUrl` (op 50): `OPEN_IN_GUEST` starts the kept intent on its display,
 * the other actions finish it. A kept intent lives at most [KEEP_MILLIS].
 *
 * The framework calls are injected: the activity supplies them, a test supplies fakes.
 */
class UrlRedirect(
    private val events: EventBus,
    private val uptimeMillis: () -> Long,
    /** Whether the app holds `RoleManager.ROLE_BROWSER`. */
    private val roleHeld: () -> Boolean,
    /** Takes the browser role again (`RoleManager.addRoleHolderAsUser`). */
    private val takeRole: () -> Unit,
) {
    /** The redirect state the `SetUrlRedirect` operation (op 44) writes. */
    internal data class Config(val enabled: Boolean, val excludedPackages: Set<String>)

    /**
     * A link waiting for the host's `ResolveUrl`. [reopen] restarts the kept intent in the
     * in-Android browser on the display it came from (desktop-integration.md §7.1).
     */
    internal data class KeptLink(
        val displayId: Int,
        val deadlineMs: Long,
        val reopen: (displayId: Int) -> Unit,
    )

    private val pending = ConcurrentHashMap<Long, KeptLink>()
    private val sequence = AtomicLong()
    @Volatile private var config = Config(enabled = false, excludedPackages = emptySet())
    private var warningSent = false

    /** `SetUrlRedirect` (op 44): the global switch and the per-package keep list. */
    fun setRedirect(request: SetUrlRedirect) {
        config = Config(request.enabled, request.excludedPackagesList.toSet())
        if (request.enabled) {
            checkBrowserRole()
        }
    }

    /**
     * One intercepted link. When the redirect is off or the source is excluded, the intent goes to
     * the in-Android browser through [reopen] and no event is sent (§7.1).
     */
    fun onLink(
        url: String,
        sourcePackage: String,
        displayId: Int,
        reopen: (displayId: Int) -> Unit,
    ) {
        val current = config
        if (!current.enabled || sourcePackage in current.excludedPackages) {
            reopen(displayId)
            return
        }
        val requestId = sequence.incrementAndGet()
        pending[requestId] = KeptLink(displayId, uptimeMillis() + KEEP_MILLIS, reopen)
        events.publish {
            it.openUrlOnHost =
                OpenUrlOnHost.newBuilder()
                    .setRequestId(requestId)
                    .setUrl(url)
                    .setSourcePackage(sourcePackage)
                    .setDisplayId(displayId)
                    .build()
        }
    }

    /**
     * `ResolveUrl` (op 50): `OPEN_IN_GUEST` starts the kept intent on its display; `OPENED_ON_HOST`
     * and `DROP` finish it. An unknown or expired request answers NOT_FOUND (issue #82 step 3).
     */
    fun resolve(request: ResolveUrl) {
        val kept = pending.remove(request.requestId)
        if (kept == null || kept.deadlineMs <= uptimeMillis()) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the link request is unknown or expired",
                mapOf("request_id" to request.requestId.toString()),
            )
        }
        if (request.action == UrlAction.URL_ACTION_OPEN_IN_GUEST) {
            kept.reopen(kept.displayId)
        }
    }

    /**
     * Reports `BROWSER_ROLE_LOST` once per loss and takes the role again (guest-components.md §5,
     * issue #82 step 2).
     */
    fun checkBrowserRole() {
        if (roleHeld()) {
            synchronized(this) { warningSent = false }
            return
        }
        synchronized(this) {
            if (warningSent) return
            warningSent = true
        }
        events.publish {
            it.healthWarning =
                HealthWarning.newBuilder()
                    .setKind(HealthWarningKind.HEALTH_WARNING_KIND_BROWSER_ROLE_LOST)
                    .build()
        }
        takeRole()
    }

    /** Whether the app currently holds the browser role. */
    fun browserRoleHeld(): Boolean = roleHeld()

    /** The kept intents, for tests. */
    internal fun pendingCount(): Int = pending.size

    companion object {
        /** How long a kept intent waits for the host's answer (desktop-integration.md §7.1). */
        const val KEEP_MILLIS = 60_000L

        /**
         * The activity finds the daemon's bridge here: in `PRIVILEGED_APP` mode both run in the
         * `io.apkrun.guest` process. Null in development, where the daemon is the shell uid and the
         * activity stays disabled (guest-components.md §3.2, TODO(#36)).
         */
        @Volatile var instance: UrlRedirect? = null
    }
}
