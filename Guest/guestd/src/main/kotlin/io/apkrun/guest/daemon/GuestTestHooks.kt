package io.apkrun.guest.daemon

import io.apkrun.guest.BuildConfig
import io.apkrun.guest.runtime.HiddenApi

/** Test-image behavior is disabled in ordinary APK builds. */
internal object GuestTestHooks {
    fun healthFailureRequested(): Boolean {
        val property = BuildConfig.IMAGE_HEALTH_FAILURE_PROPERTY
        return property.isNotEmpty() && HiddenApi.systemProperty(property) == "1"
    }
}
