package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.NotificationRemovalReason
import io.apkrun.guest.protocol.v1.SetNotificationForwarding
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The §5.1 filters, the forwarding allowlist, the replay on SetNotificationForwarding, and the ops
 * of the notification path (desktop-integration.md §5). A fake
 * [NotificationBridge.NotificationAccess] stands in for the listener service.
 */
class NotificationBridgeTest {

    private fun post(key: String = "key", pkg: String = "io.app") =
        NotificationBridge.PostedNotification(
            key = key,
            packageName = pkg,
            isGroupSummary = false,
            isOngoingOrService = false,
            isTransport = false,
            title = "Title",
            text = "Body",
            postTimeMs = 1000,
            category = "msg",
            hasContentIntent = true,
            ongoing = false,
            channelId = "ch",
            groupKey = "grp",
            onlyAlertOnce = false,
            actionTitles = listOf("Reply", "Open", "Mark read", "Archive"),
        )

    private val defaultRanking =
        NotificationBridge.Ranking(importance = 3 /* IMPORTANCE_DEFAULT */, channelBlocked = false)

    private class FakeAccess : NotificationBridge.NotificationAccess {
        var active = mutableListOf<NotificationBridge.PostedNotification>()
        var ranking = NotificationBridge.Ranking(3, false)
        var granted = true
        var cancelled = mutableListOf<String>()
        var fired: Triple<String, Int?, Int>? = null
        var fireResult = true

        override fun active() = active.toList()

        override fun cancel(key: String) {
            cancelled += key
        }

        override fun fire(key: String, actionIndex: Int?, displayId: Int): Boolean {
            fired = Triple(key, actionIndex, displayId)
            return fireResult
        }

        override fun accessGranted() = granted

        override fun ranking(key: String) = ranking
    }

    private fun bridge(): Triple<NotificationBridge, FakeAccess, ByteArrayOutputStream> {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        events.attach(FrameWriter(output))
        val access = FakeAccess()
        return Triple(NotificationBridge(events, access), access, output)
    }

    private fun events(output: ByteArrayOutputStream): List<Event> {
        val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
        val events = mutableListOf<Event>()
        while (true) {
            try {
                events += reader.next().event
            } catch (_: EOFException) {
                return events
            }
        }
    }

    private fun forward(bridge: NotificationBridge, vararg packages: String) {
        bridge.setForwarding(
            SetNotificationForwarding.newBuilder().addAllPackages(packages.toList()).build()
        )
    }

    @Test
    fun `a notification outside the allowlist is not sent`() {
        val (bridge, access, output) = bridge()
        forward(bridge, "io.app")
        bridge.posted(post(pkg = "io.other"), defaultRanking)
        assertTrue(events(output).isEmpty())
    }

    @Test
    fun `a forwarded notification emits notification_posted`() {
        val (bridge, access, output) = bridge()
        forward(bridge, "io.app")
        bridge.posted(post(key = "k1"), defaultRanking)
        val events = events(output)
        assertEquals(1, events.size)
        val n = events[0].notificationPosted
        assertEquals("k1", n.key)
        assertEquals("io.app", n.`package`)
        assertEquals(3, n.actionsCount) // at most three action titles reach the host
    }

    @Test
    fun `group summaries and ongoing and transport and low importance are filtered`() {
        val (bridge, access, output) = bridge()
        forward(bridge, "io.app")
        bridge.posted(post(key = "g").copy(isGroupSummary = true), defaultRanking)
        bridge.posted(post(key = "o").copy(isOngoingOrService = true), defaultRanking)
        bridge.posted(post(key = "t").copy(isTransport = true), defaultRanking)
        bridge.posted(post(key = "m"), defaultRanking.copy(importance = 1 /* IMPORTANCE_MIN */))
        bridge.posted(post(key = "b"), defaultRanking.copy(channelBlocked = true))
        assertTrue(events(output).isEmpty())
    }

    @Test
    fun `removal is only reported for forwarded keys`() {
        val (bridge, access, output) = bridge()
        forward(bridge, "io.app")
        bridge.removed(
            "never-forwarded",
            NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_OTHER,
        )
        bridge.posted(post(key = "k1"), defaultRanking)
        output.reset()
        bridge.removed(
            "k1",
            NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_DISMISSED_BY_USER,
        )
        val events = events(output)
        assertEquals(1, events.size)
        assertEquals("k1", events[0].notificationRemoved.key)
        assertEquals(
            NotificationRemovalReason.NOTIFICATION_REMOVAL_REASON_DISMISSED_BY_USER,
            events[0].notificationRemoved.reason,
        )
    }

    @Test
    fun `setForwarding replays active notifications with replay set`() {
        val (bridge, access, output) = bridge()
        access.active += post(key = "a1")
        access.active += post(key = "a2", pkg = "io.other")
        forward(bridge, "io.app")
        val events = events(output)
        assertEquals(1, events.size)
        assertEquals("a1", events[0].notificationPosted.key)
        assertTrue(events[0].notificationPosted.replay)
    }

    @Test
    fun `activate fires the intent and reports not found`() {
        val (bridge, access, _) = bridge()
        bridge.activate("k1", 2, 7)
        assertEquals(Triple("k1", 2, 7), access.fired)
        access.fireResult = false
        val failure = assertThrows(GuestFailure::class.java) { bridge.activate("gone", null, 0) }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure.code)
    }

    @Test
    fun `dismiss cancels through the listener`() {
        val (bridge, access, _) = bridge()
        bridge.dismiss("k1")
        assertEquals(listOf("k1"), access.cancelled)
    }

    @Test
    fun `a lost listener reports the health warning once until it returns`() {
        val (bridge, access, output) = bridge()
        access.granted = false
        bridge.checkAccess()
        bridge.checkAccess()
        val first = events(output)
        assertEquals(1, first.size)
        assertTrue(first[0].hasHealthWarning())
        access.granted = true
        bridge.checkAccess()
        access.granted = false
        bridge.checkAccess()
        assertEquals(2, events(output).size)
    }
}
