package io.apkrun.guest.url

import io.apkrun.guest.daemon.EventBus
import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.HealthWarningKind
import io.apkrun.guest.protocol.v1.ResolveUrl
import io.apkrun.guest.protocol.v1.SetUrlRedirect
import io.apkrun.guest.protocol.v1.UrlAction
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The UrlRedirect tests of desktop-integration.md §7.1 (issue #82). */
class UrlRedirectTest {
    private class Harness(
        var clock: Long = 0,
        val opened: MutableList<Int> = mutableListOf(),
        var roleHeld: Boolean = true,
        var roleTakes: Int = 0,
        val scheduled: MutableList<Pair<Long, () -> Unit>> = mutableListOf(),
    ) {
        val output = ByteArrayOutputStream()
        val events = EventBus().also { it.attach(FrameWriter(output)) }
        val redirect =
            UrlRedirect(
                events,
                uptimeMillis = { clock },
                roleHeld = { roleHeld },
                takeRole = { roleTakes += 1 },
                schedule = { delay, action -> scheduled += delay to action },
            )

        fun published(): List<Event> {
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

        fun link(url: String, source: String, displayId: Int) {
            redirect.onLink(url, source, displayId) { opened += it }
        }
    }

    private fun enable(redirect: UrlRedirect, vararg excluded: String) {
        redirect.setRedirect(
            SetUrlRedirect.newBuilder()
                .setEnabled(true)
                .addAllExcludedPackages(excluded.toList())
                .build()
        )
    }

    private fun resolve(id: Long, action: UrlAction): ResolveUrl =
        ResolveUrl.newBuilder().setRequestId(id).setAction(action).build()

    @Test
    fun `an intercepted link publishes open_url_on_host and keeps the intent`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com/x", "io.app", 2)
        val event = harness.published().single().openUrlOnHost
        assertEquals("https://example.com/x", event.url)
        assertEquals("io.app", event.sourcePackage)
        assertEquals(2, event.displayId)
        assertEquals(1, harness.redirect.pendingCount())
    }

    @Test
    fun `an excluded package goes straight to the in-Android browser`() {
        val harness = Harness()
        enable(harness.redirect, "io.app")
        harness.link("https://example.com", "io.app", 1)
        assertTrue(harness.published().isEmpty())
        assertEquals(listOf(1), harness.opened)
    }

    @Test
    fun `a disabled redirect keeps every link in Android`() {
        val harness = Harness()
        harness.redirect.setRedirect(SetUrlRedirect.newBuilder().setEnabled(false).build())
        harness.link("https://example.com", "io.app", 1)
        assertTrue(harness.published().isEmpty())
        assertEquals(1, harness.opened.size)
    }

    @Test
    fun `open_in_guest starts the kept intent on its display`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com", "io.app", 3)
        val id = harness.published().single().openUrlOnHost.requestId
        harness.redirect.resolve(resolve(id, UrlAction.URL_ACTION_OPEN_IN_GUEST))
        assertEquals(listOf(3), harness.opened)
        assertEquals(0, harness.redirect.pendingCount())
    }

    @Test
    fun `drop finishes the kept intent without starting it`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com", "io.app", 3)
        val id = harness.published().single().openUrlOnHost.requestId
        harness.redirect.resolve(resolve(id, UrlAction.URL_ACTION_DROP))
        assertTrue(harness.opened.isEmpty())
        assertEquals(0, harness.redirect.pendingCount())
    }

    @Test
    fun `an expired request answers NOT_FOUND`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com", "io.app", 3)
        val id = harness.published().single().openUrlOnHost.requestId
        harness.clock = UrlRedirect.KEEP_MILLIS
        assertThrows(GuestFailure::class.java) {
            harness.redirect.resolve(resolve(id, UrlAction.URL_ACTION_OPEN_IN_GUEST))
        }
    }

    @Test
    fun `an unknown request answers NOT_FOUND`() {
        val harness = Harness()
        enable(harness.redirect)
        assertThrows(GuestFailure::class.java) {
            harness.redirect.resolve(resolve(99, UrlAction.URL_ACTION_DROP))
        }
    }

    @Test
    fun `a lost browser role warns once and retakes the role`() {
        val harness = Harness(roleHeld = false)
        enable(harness.redirect)
        harness.redirect.checkBrowserRole()
        harness.redirect.checkBrowserRole()
        val warnings =
            harness.published().filter { it.hasHealthWarning() }.map { it.healthWarning.kind }
        assertEquals(listOf(HealthWarningKind.HEALTH_WARNING_KIND_BROWSER_ROLE_LOST), warnings)
        assertEquals(1, harness.roleTakes)
    }

    @Test
    fun `losing the role between links warns and retakes on the next link`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.roleHeld = false
        harness.link("https://example.com", "io.app", 1)
        val warnings =
            harness.published().filter { it.hasHealthWarning() }.map { it.healthWarning.kind }
        assertEquals(listOf(HealthWarningKind.HEALTH_WARNING_KIND_BROWSER_ROLE_LOST), warnings)
        assertEquals(1, harness.roleTakes)
    }

    @Test
    fun `a kept intent expires at the deadline even without an answer`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com", "io.app", 3)
        assertEquals(1, harness.redirect.pendingCount())
        val (delay, expiry) = harness.scheduled.single()
        assertEquals(UrlRedirect.KEEP_MILLIS, delay)
        expiry()
        assertEquals(0, harness.redirect.pendingCount())
        val id = harness.published().single().openUrlOnHost.requestId
        assertThrows(GuestFailure::class.java) {
            harness.redirect.resolve(resolve(id, UrlAction.URL_ACTION_OPEN_IN_GUEST))
        }
    }

    @Test
    fun `stale kept intents are purged when the next link arrives`() {
        val harness = Harness()
        enable(harness.redirect)
        harness.link("https://example.com/a", "io.app", 1)
        harness.clock = UrlRedirect.KEEP_MILLIS
        harness.link("https://example.com/b", "io.app", 2)
        assertEquals(1, harness.redirect.pendingCount())
    }
}
