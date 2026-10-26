package io.apkrun.guest.daemon

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.res.Configuration
import android.os.LocaleList
import android.os.Process
import android.provider.Settings
import io.apkrun.guest.protocol.v1.ClockFormat
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.SetClockFormat
import io.apkrun.guest.protocol.v1.SetLocale
import io.apkrun.guest.protocol.v1.SetTimeZone
import io.apkrun.guest.protocol.v1.SyncTime
import io.apkrun.guest.runtime.MethodRequirement
import io.apkrun.guest.runtime.SystemContext
import io.apkrun.guest.runtime.SystemServiceWrapper
import java.util.IllformedLocaleException
import java.util.Locale
import java.util.TimeZone

/**
 * Applies host locale and time preferences (desktop-integration.md §9). The guest reads current
 * Android state first and does not send redundant updates, because changing the locale can restart
 * activities.
 */
class LocaleTimeService private constructor(private val backend: () -> LocaleTimeBackend) {
    /** Uses the Android framework backend when a setter is first called. */
    constructor() : this({ AndroidLocaleTimeBackend() })

    internal constructor(backend: LocaleTimeBackend) : this({ backend })

    private val device: LocaleTimeBackend by lazy(backend)

    /** Applies a BCP 47 language list in the host's order, with at most eight entries. */
    fun setLocale(request: SetLocale) {
        val tags = canonicalLanguageTags(request.bcp47List)
        if (device.currentLocaleTags() != tags) {
            device.updateLocaleTags(tags)
        }
    }

    /** Applies a known IANA time-zone ID. Unknown IDs are reported to the host for fallback. */
    fun setTimeZone(request: SetTimeZone) {
        val zoneId = request.tzId
        if (!device.isKnownTimeZone(zoneId)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "Android does not know the requested time zone",
                mapOf("time_zone" to zoneId),
            )
        }
        if (device.currentTimeZoneId() != zoneId) {
            device.updateTimeZone(zoneId)
        }
    }

    /** Stores Android's conventional `"12"` or `"24"` setting. */
    fun setClockFormat(request: SetClockFormat) {
        val value =
            when (request.format) {
                ClockFormat.CLOCK_FORMAT_TWELVE -> "12"
                ClockFormat.CLOCK_FORMAT_TWENTY_FOUR -> "24"
                else ->
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the requested clock format is not supported",
                        mapOf("field" to "format"),
                    )
            }
        if (device.currentClockFormat() != value) {
            device.updateClockFormat(value)
        }
    }

    /**
     * Applies the host time plus half the measured round-trip time when the drift exceeds 500 ms.
     */
    fun syncTime(request: SyncTime) {
        val roundTripMillis = request.rttMs.toUInt().toLong()
        if (request.unixTimeMs <= 0 || roundTripMillis > MAX_ROUND_TRIP_MILLIS) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the requested clock synchronization is outside the supported range",
                mapOf("field" to "unix_time_ms or rtt_ms"),
            )
        }
        if (!device.canSetTime()) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "this Guest Agent does not have permission to set the wall clock",
            )
        }
        val targetTime =
            try {
                Math.addExact(request.unixTimeMs, roundTripMillis / 2)
            } catch (_: ArithmeticException) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the requested clock synchronization overflows Android time",
                    mapOf("field" to "unix_time_ms"),
                )
            }
        if (
            kotlin.math.abs(targetTime - device.currentWallClockMillis()) >
                CLOCK_DRIFT_THRESHOLD_MILLIS
        ) {
            device.updateWallClock(targetTime)
        }
    }

    private fun canonicalLanguageTags(tags: List<String>): List<String> {
        if (tags.isEmpty() || tags.size > MAX_LANGUAGE_TAGS) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the locale must contain between one and eight language tags",
                mapOf("field" to "bcp47"),
            )
        }
        return tags.map { tag ->
            try {
                Locale.Builder().setLanguageTag(tag).build().toLanguageTag()
            } catch (_: IllformedLocaleException) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the locale contains an invalid BCP 47 language tag",
                    mapOf("field" to "bcp47"),
                )
            }
        }
    }

    private companion object {
        const val MAX_LANGUAGE_TAGS = 8
        const val CLOCK_DRIFT_THRESHOLD_MILLIS = 500L
        const val MAX_ROUND_TRIP_MILLIS = 30_000L
    }
}

/** The small device boundary makes locale/time policy testable without an Android framework. */
internal interface LocaleTimeBackend {
    fun currentLocaleTags(): List<String>

    fun updateLocaleTags(tags: List<String>)

    fun isKnownTimeZone(zoneId: String): Boolean

    fun currentTimeZoneId(): String

    fun updateTimeZone(zoneId: String)

    fun currentClockFormat(): String?

    fun updateClockFormat(value: String)

    fun canSetTime(): Boolean

    fun currentWallClockMillis(): Long

    fun updateWallClock(unixTimeMillis: Long)
}

/** The caller-attributed framework implementation of the locale and time operations. */
private class AndroidLocaleTimeBackend : LocaleTimeBackend {
    private val context: Context by lazy {
        val systemContext = SystemContext.get()
        val callerPackage = callerPackageName(systemContext)
        systemContext.createPackageContext(callerPackage, 0)
    }

    private val timeZones: Set<String> by lazy { TimeZone.getAvailableIDs().toSet() }

    private val activity =
        SystemServiceWrapper(
            serviceName = "activity",
            interfaceName = "android.app.IActivityManager",
            requirements =
                listOf(
                    MethodRequirement(
                        "updatePersistentConfigurationWithAttribution",
                        listOf(
                            listOf(
                                "android.content.res.Configuration",
                                "java.lang.String",
                                "java.lang.String",
                            )
                        ),
                    )
                ),
        )

    private val alarmManager: AlarmManager by lazy {
        checkNotNull(context.getSystemService(AlarmManager::class.java)) {
            "AlarmManager is not registered"
        }
    }

    override fun currentLocaleTags(): List<String> =
        context.resources.configuration.locales
            .toLanguageTags()
            .split(',')
            .filter(String::isNotEmpty)

    override fun updateLocaleTags(tags: List<String>) {
        val configuration = Configuration(context.resources.configuration)
        configuration.setLocales(LocaleList.forLanguageTags(tags.joinToString(",")))
        activity.call(
            "updatePersistentConfigurationWithAttribution",
            configuration,
            context.packageName,
            null,
        )
    }

    override fun isKnownTimeZone(zoneId: String): Boolean = zoneId in timeZones

    override fun currentTimeZoneId(): String = TimeZone.getDefault().id

    override fun updateTimeZone(zoneId: String) {
        alarmManager.setTimeZone(zoneId)
    }

    override fun currentClockFormat(): String? =
        Settings.System.getString(context.contentResolver, Settings.System.TIME_12_24)

    override fun updateClockFormat(value: String) {
        if (
            !Settings.System.putString(context.contentResolver, Settings.System.TIME_12_24, value)
        ) {
            throw SecurityException("Android refused the clock-format setting")
        }
    }

    override fun canSetTime(): Boolean =
        Process.myUid() != Process.SHELL_UID &&
            context.checkSelfPermission(Manifest.permission.SET_TIME) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED

    override fun currentWallClockMillis(): Long = System.currentTimeMillis()

    override fun updateWallClock(unixTimeMillis: Long) {
        alarmManager.setTime(unixTimeMillis)
    }

    private fun callerPackageName(systemContext: Context): String {
        if (Process.myUid() == Process.SHELL_UID) {
            return SHELL_PACKAGE
        }
        val packages = systemContext.packageManager.getPackagesForUid(Process.myUid()).orEmpty()
        return packages.firstOrNull { it == GUEST_AGENT_PACKAGE }
            ?: throw IllegalStateException("the Guest Agent package does not own this process")
    }

    private companion object {
        const val SHELL_PACKAGE = "com.android.shell"
        const val GUEST_AGENT_PACKAGE = "io.apkrun.guest"
    }
}
