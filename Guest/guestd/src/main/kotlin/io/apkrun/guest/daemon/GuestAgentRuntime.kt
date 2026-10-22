package io.apkrun.guest.daemon

import android.content.Context
import android.os.Looper
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SystemContext
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** The agent log of a development agent (guest-components.md §9). */
private const val DEVELOPMENT_LOG_PATH = "/data/local/tmp/apkrun/agent.log"

/**
 * Creates the same daemon for the stock-image `app_process` entry point and the custom-image
 * persistent APK. The caller must run on Android's main thread after its main looper is ready.
 */
object GuestAgentRuntime {
    fun create(context: Context, mode: AgentMode): Daemon {
        check(Looper.myLooper() === Looper.getMainLooper()) {
            "the guest agent must start on Android's main thread"
        }
        if (mode == AgentMode.AGENT_MODE_PRIVILEGED_APP) {
            SystemContext.install(context)
        }
        val logFile =
            if (mode == AgentMode.AGENT_MODE_DEVELOPMENT_SHELL) {
                File(DEVELOPMENT_LOG_PATH)
            } else {
                File(context.cacheDir, "agent.log")
            }
        logFile.parentFile?.mkdirs()
        AgentLog.install(logFile)
        return Daemon(CoroutineScope(SupervisorJob() + Dispatchers.Default), mode)
    }
}
