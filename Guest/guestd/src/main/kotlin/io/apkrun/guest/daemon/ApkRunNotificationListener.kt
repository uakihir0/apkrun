package io.apkrun.guest.daemon

import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.apkrun.guest.protocol.v1.NotificationRemovalReason

/**
 * The `NotificationListenerService` of the Guest Agent (desktop-integration.md §5.1). DeviceSetup
 * grants it access at start (`enabled_notification_listeners`, guest-components.md §5); the service
 * converts StatusBarNotifications to [NotificationBridge.PostedNotification]s and reports them to
 * the [NotificationBridge], which filters them.
 */
internal class ApkRunNotificationListener : NotificationListenerService() {

    override fun onCreate() {
        super.onCreate()
        liveInstance = this
    }

    override fun onDestroy() {
        liveInstance = null
        super.onDestroy()
    }

    override fun onListenerConnected() {
        bridge?.checkAccess()
    }

    override fun onListenerDisconnected() {
        bridge?.checkAccess()
    }

    override fun onNotificationPosted(notification: StatusBarNotification) {
        bridge?.posted(postedOf(notification), rankingOf(notification.key))
    }

    override fun onNotificationRemoved(
        notification: StatusBarNotification,
        rankingMap: RankingMap?,
        reason: Int,
    ) {
        bridge?.removed(notification.key, wireReason(reason))
    }

    /** The wire removal reason of the listener's reason code (guest-protocol.md §8.4). */
    private fun wireReason(reason: Int): NotificationRemovalReason =
        when (reason) {
            REASON_CLICK -> NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_DISMISSED_BY_USER
            REASON_CANCEL,
            REASON_CANCEL_ALL ->
                NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_CANCELLED_BY_APP
            else -> NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_OTHER
        }

    /** The RankingMap entry of a key, or a permissive default when the ranking is gone. */
    private fun rankingOf(key: String): NotificationBridge.Ranking {
        val ranking = Ranking()
        val found =
            try {
                currentRanking?.getRanking(key, ranking) == true
            } catch (_: Throwable) {
                false
            }
        return if (found) {
            NotificationBridge.Ranking(
                importance = ranking.importance,
                channelBlocked =
                    ranking.channel?.let {
                        it.importance == NotificationManager.IMPORTANCE_NONE
                    } == true,
            )
        } else {
            NotificationBridge.Ranking(
                importance = NotificationManager.IMPORTANCE_DEFAULT,
                channelBlocked = false,
            )
        }
    }

    companion object {
        /** The live bridge; [Daemon] sets it when the services start. */
        @Volatile internal var bridge: NotificationBridge? = null

        @Volatile private var liveInstance: ApkRunNotificationListener? = null

        private fun instance(): ApkRunNotificationListener? = liveInstance

        /**
         * The bridge's view of a StatusBarNotification (desktop-integration.md §5.1). The text is
         * the last MessagingStyle message, else EXTRA_BIG_TEXT, else EXTRA_TEXT.
         */
        internal fun postedOf(
            notification: StatusBarNotification
        ): NotificationBridge.PostedNotification {
            val n = notification.notification ?: Notification()
            val extras = n.extras
            val messagingText = runCatching {
                Notification.MessagingStyle.Message.getMessagesFromBundleArray(
                    extras.getParcelableArray(Notification.EXTRA_MESSAGES)
                )
            }
                .getOrNull()
                ?.lastOrNull()
                ?.text
                ?.toString()
            val text =
                messagingText
                    ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
                    ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
                    ?: ""
            return NotificationBridge.PostedNotification(
                key = notification.key,
                packageName = notification.packageName,
                isGroupSummary = n.flags and Notification.FLAG_GROUP_SUMMARY != 0,
                isOngoingOrService =
                    n.flags and Notification.FLAG_ONGOING_EVENT != 0 ||
                        n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0,
                isTransport = n.category == Notification.CATEGORY_TRANSPORT,
                title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: "",
                text = text,
                postTimeMs = notification.postTime,
                category = n.category ?: "",
                hasContentIntent = n.contentIntent != null,
                ongoing = n.flags and Notification.FLAG_ONGOING_EVENT != 0,
                channelId = n.channelId ?: "",
                groupKey = notification.groupKey ?: "",
                onlyAlertOnce = n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0,
                actionTitles = (n.actions ?: emptyArray()).map { it.title?.toString() ?: "" },
            )
        }

        /** The NotificationAccess implementation over the connected listener. */
        internal fun access(): NotificationBridge.NotificationAccess =
            object : NotificationBridge.NotificationAccess {
                override fun active(): List<NotificationBridge.PostedNotification> =
                    instance()?.activeNotifications?.map { postedOf(it) } ?: emptyList()

                override fun cancel(key: String) {
                    instance()?.cancelNotification(key)
                }

                override fun fire(key: String, actionIndex: Int?, displayId: Int): Boolean {
                    val listener = instance() ?: return false
                    val notification =
                        listener.activeNotifications.firstOrNull { it.key == key } ?: return false
                    val intent =
                        if (actionIndex == null) {
                            notification.notification?.contentIntent
                        } else {
                            notification.notification?.actions?.getOrNull(actionIndex)?.actionIntent
                        } ?: return false
                    val options =
                        ActivityOptions.makeBasic().apply { launchDisplayId = displayId }.toBundle()
                    return runCatching {
                            intent.send(listener, 0, null, null, null, null, options)
                            true
                        }
                        .getOrDefault(false)
                }

                override fun accessGranted(): Boolean = instance() != null

                override fun ranking(key: String): NotificationBridge.Ranking =
                    instance()?.rankingOf(key)
                        ?: NotificationBridge.Ranking(
                            importance = NotificationManager.IMPORTANCE_DEFAULT,
                            channelBlocked = false,
                        )
            }
    }
}
