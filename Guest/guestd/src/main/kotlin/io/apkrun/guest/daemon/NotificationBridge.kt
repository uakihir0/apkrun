package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.HealthWarning
import io.apkrun.guest.protocol.v1.HealthWarningKind
import io.apkrun.guest.protocol.v1.Notification as WireNotification
import io.apkrun.guest.protocol.v1.NotificationAction
import io.apkrun.guest.protocol.v1.NotificationRemovalReason
import io.apkrun.guest.protocol.v1.NotificationRemoved
import io.apkrun.guest.protocol.v1.SetNotificationForwarding

/**
 * The Android end of the notification path (desktop-integration.md §5). The
 * [ApkRunNotificationListener] service turns StatusBarNotifications into [PostedNotification]s and
 * reports them; the bridge applies the §5.1 forwarding filters and allowlist, emits
 * `notification_posted`/`notification_removed` events, and fires content or action intents on
 * `ActivateNotification` (op 41).
 *
 * The framework calls live in [NotificationAccess]; the listener service implements them, and a
 * unit test gives a fake.
 */
internal class NotificationBridge(
    private val events: EventBus,
    private val access: NotificationAccess,
) {

    /**
     * The notification fields the §5.1 filters and the wire message need, freed of framework types
     * so unit tests can build them.
     */
    internal data class PostedNotification(
        val key: String,
        val packageName: String,
        val isGroupSummary: Boolean,
        val isOngoingOrService: Boolean,
        val isTransport: Boolean,
        val title: String,
        val text: String,
        val postTimeMs: Long,
        val category: String,
        val hasContentIntent: Boolean,
        val ongoing: Boolean,
        val channelId: String,
        val groupKey: String,
        val onlyAlertOnce: Boolean,
        val actionTitles: List<String>,
    )

    /** What the listener's RankingMap says about a notification (§5.1). */
    internal data class Ranking(val importance: Int, val channelBlocked: Boolean)

    /** The listener-service calls the bridge needs (desktop-integration.md §5). */
    internal interface NotificationAccess {
        /** The listener's currently active notifications. */
        fun active(): List<PostedNotification>

        /** Cancels the notification of a key (the swipe-away of §5.4). */
        fun cancel(key: String)

        /**
         * Sends the content intent of a notification, or the action at [actionIndex], targeting
         * [displayId] (§5.4). Returns false when the notification has gone.
         */
        fun fire(key: String, actionIndex: Int?, displayId: Int): Boolean

        /** Whether the listener currently has access; loss reports a health warning. */
        fun accessGranted(): Boolean

        /** The RankingMap entry of an active notification (importance, channel blocked). */
        fun ranking(key: String): Ranking
    }

    private val lock = Any()

    /** The packages whose notifications may leave the guest (§5.1). */
    private var forwarding: Set<String> = emptySet()

    /** Keys forwarded to the host, so a removal is reported only for those (§5.1). */
    private val forwarded = mutableSetOf<String>()

    /** Whether a health warning was already sent for the current access loss. */
    private var warningSent = false

    /**
     * Applies `SetNotificationForwarding` (op 43): replace the allowlist and replay active ones.
     */
    fun setForwarding(request: SetNotificationForwarding) {
        synchronized(lock) {
            forwarding = request.packagesList.toSet()
            forwarded.clear()
        }
        // Re-send every forwarded notification with replay = true so the host rebuilds its key map
        // and badges without banners (desktop-integration.md §5.3).
        for (notification in access.active()) {
            val wire =
                wireIfForwardable(notification, access.ranking(notification.key), replay = true)
                    ?: continue
            synchronized(lock) { forwarded.add(notification.key) }
            events.publish(GuestCapability.NOTIFICATIONS) { it.notificationPosted = wire }
        }
    }

    /** A `NotificationListenerService.onNotificationPosted` report, filtered by §5.1. */
    fun posted(notification: PostedNotification, ranking: Ranking) {
        val wire = wireIfForwardable(notification, ranking, replay = false) ?: return
        synchronized(lock) { forwarded.add(notification.key) }
        events.publish(GuestCapability.NOTIFICATIONS) { it.notificationPosted = wire }
    }

    /** A `NotificationListenerService.onNotificationRemoved` report (§5.1). */
    fun removed(key: String, reason: NotificationRemovalReason) {
        synchronized(lock) {
            if (!forwarded.remove(key)) return
        }
        events.publish(GuestCapability.NOTIFICATIONS) {
            it.notificationRemoved =
                NotificationRemoved.newBuilder().setKey(key).setReason(reason).build()
        }
    }

    /** `ActivateNotification` (op 41, §5.4): the content or action intent on the display. */
    fun activate(key: String, actionIndex: Int?, displayId: Int) {
        if (!access.fire(key, actionIndex, displayId)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the notification has gone",
                mapOf("key" to key),
            )
        }
    }

    /** `DismissNotification` (op 42, §5.4): the swipe-away. */
    fun dismiss(key: String) = access.cancel(key)

    /** Reports NOTIFICATION_LISTENER_DISABLED once per access loss (guest-components.md §5). */
    fun checkAccess() {
        val granted = access.accessGranted()
        synchronized(lock) {
            if (granted) {
                warningSent = false
                return
            }
            if (warningSent) return
            warningSent = true
        }
        events.publish(GuestCapability.HEALTH) {
            it.healthWarning =
                HealthWarning.newBuilder()
                    .setKind(HealthWarningKind.HEALTH_WARNING_KIND_NOTIFICATION_LISTENER_DISABLED)
                    .build()
        }
    }

    /** Whether the listener currently has access; the snapshot reports it (§5.1). */
    fun listenerEnabled(): Boolean = access.accessGranted()

    /** The forwarded key set; tests read it to check the allowlist behavior. */
    internal fun forwardedKeys(): Set<String> = synchronized(lock) { forwarded.toSet() }

    private fun wireIfForwardable(
        notification: PostedNotification,
        ranking: Ranking,
        replay: Boolean,
    ): WireNotification? {
        synchronized(lock) {
            if (notification.packageName !in forwarding) return null
        }
        if (!forwardable(notification, ranking)) return null
        return wireOf(notification, replay, ranking.importance)
    }

    companion object {
        private const val IMPORTANCE_MIN = android.app.NotificationManager.IMPORTANCE_MIN
        private const val TITLE_LIMIT = 256
        private const val TEXT_LIMIT = 2048
        private const val ACTION_LIMIT = 3

        /** The §5.1 filters, all applied in the agent before anything is sent. */
        internal fun forwardable(notification: PostedNotification, ranking: Ranking): Boolean =
            !notification.isGroupSummary &&
                !notification.isOngoingOrService &&
                !notification.isTransport &&
                ranking.importance > IMPORTANCE_MIN &&
                !ranking.channelBlocked

        /** The wire `Notification` of a post (§5.1 payload). */
        internal fun wireOf(
            notification: PostedNotification,
            replay: Boolean,
            importance: Int,
        ): WireNotification {
            val builder =
                WireNotification.newBuilder()
                    .setKey(notification.key)
                    .setPackage(notification.packageName)
                    .setTitle(notification.title.take(TITLE_LIMIT))
                    .setText(notification.text.take(TEXT_LIMIT))
                    .setWhenMs(notification.postTimeMs)
                    .setCategory(notification.category)
                    .setHasContentIntent(notification.hasContentIntent)
                    .setOngoing(notification.ongoing)
                    .setChannelId(notification.channelId)
                    .setImportance(importance)
                    .setGroupKey(notification.groupKey)
                    .setAlert(!notification.onlyAlertOnce)
                    .setReplay(replay)
            for (title in notification.actionTitles.take(ACTION_LIMIT)) {
                builder.addActions(NotificationAction.newBuilder().setTitle(title))
            }
            return builder.build()
        }
    }
}
