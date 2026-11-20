package io.apkrun.store

import android.app.Application
import io.apkrun.guest.runtime.AgentLog

/**
 * The Store Agent application (guest-components.md §8.1). It is persistent and direct-boot aware,
 * so Android keeps it running and its sockets stay bound. The agent never shows UI.
 */
class StoreAgentApplication : Application() {
    internal val daemon = StoreDaemon(this)

    override fun onCreate() {
        super.onCreate()
        // Socket setup must not delay the main thread of a persistent app.
        Thread({ daemon.start() }, "apkrun-store-init").apply {
            isDaemon = true
            start()
        }
        AgentLog.info("io.apkrun.store started")
    }
}
