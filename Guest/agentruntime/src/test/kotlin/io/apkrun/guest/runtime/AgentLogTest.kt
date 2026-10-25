package io.apkrun.guest.runtime

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AgentLogTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun installUsesGuestTagByDefault() {
        AgentLog.install(temporaryFolder.newFile("agent.log"))

        assertEquals("ApkRunGuest", AgentLog.configuredTag)
    }

    @Test
    fun installAcceptsAnAgentSpecificTag() {
        AgentLog.install(temporaryFolder.newFile("store.log"), tag = "ApkRunStore")

        assertEquals("ApkRunStore", AgentLog.configuredTag)
    }
}
