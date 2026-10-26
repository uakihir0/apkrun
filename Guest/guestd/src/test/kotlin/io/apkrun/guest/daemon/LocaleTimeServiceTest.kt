package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.ClockFormat
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.SetClockFormat
import io.apkrun.guest.protocol.v1.SetLocale
import io.apkrun.guest.protocol.v1.SetTimeZone
import io.apkrun.guest.protocol.v1.SyncTime
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

private class FakeLocaleTimeBackend : LocaleTimeBackend {
    var localeTags = listOf("en-US")
    var knownTimeZones = setOf("Etc/UTC", "Asia/Tokyo")
    var timeZoneId = "Etc/UTC"
    var clockFormat: String? = "12"
    var hasTimePermission = true
    var wallClockMillis = 10_000L
    val localeWrites = mutableListOf<List<String>>()
    val timeZoneWrites = mutableListOf<String>()
    val clockFormatWrites = mutableListOf<String>()
    val wallClockWrites = mutableListOf<Long>()

    override fun currentLocaleTags(): List<String> = localeTags

    override fun updateLocaleTags(tags: List<String>) {
        localeWrites += tags
        localeTags = tags
    }

    override fun isKnownTimeZone(zoneId: String): Boolean = zoneId in knownTimeZones

    override fun currentTimeZoneId(): String = timeZoneId

    override fun updateTimeZone(zoneId: String) {
        timeZoneWrites += zoneId
        timeZoneId = zoneId
    }

    override fun currentClockFormat(): String? = clockFormat

    override fun updateClockFormat(value: String) {
        clockFormatWrites += value
        clockFormat = value
    }

    override fun canSetTime(): Boolean = hasTimePermission

    override fun currentWallClockMillis(): Long = wallClockMillis

    override fun updateWallClock(unixTimeMillis: Long) {
        wallClockWrites += unixTimeMillis
        wallClockMillis = unixTimeMillis
    }
}

class LocaleTimeServiceTest {
    @Test
    fun localeTagsKeepScriptAndRegionAndSkipAnUnchangedList() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)

        service.setLocale(SetLocale.newBuilder().addBcp47("zh-hant-tw").addBcp47("en-us").build())
        service.setLocale(SetLocale.newBuilder().addBcp47("zh-Hant-TW").addBcp47("en-US").build())

        assertEquals(listOf(listOf("zh-Hant-TW", "en-US")), backend.localeWrites)
    }

    @Test
    fun localeRejectsAnEmptyOversizedOrMalformedList() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)
        val empty = SetLocale.getDefaultInstance()
        val oversized =
            SetLocale.newBuilder()
                .addBcp47("en-US")
                .addBcp47("fr-FR")
                .addBcp47("de-DE")
                .addBcp47("ja-JP")
                .addBcp47("ko-KR")
                .addBcp47("zh-Hans")
                .addBcp47("zh-Hant")
                .addBcp47("es-ES")
                .addBcp47("it-IT")
                .build()
        val malformed = SetLocale.newBuilder().addBcp47("not a language tag").build()

        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
            assertThrows(GuestFailure::class.java) { service.setLocale(empty) }.code,
        )
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
            assertThrows(GuestFailure::class.java) { service.setLocale(oversized) }.code,
        )
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
            assertThrows(GuestFailure::class.java) { service.setLocale(malformed) }.code,
        )
        assertEquals(emptyList<List<String>>(), backend.localeWrites)
    }

    @Test
    fun unknownTimeZoneReturnsNotFoundWithoutChangingTheDevice() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)

        val error =
            assertThrows(GuestFailure::class.java) {
                service.setTimeZone(SetTimeZone.newBuilder().setTzId("Mars/Olympus_Mons").build())
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, error.code)
        assertEquals(emptyList<String>(), backend.timeZoneWrites)
        assertEquals("Etc/UTC", backend.timeZoneId)
    }

    @Test
    fun knownTimeZoneIsAppliedOnlyWhenDifferent() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)
        val tokyo = SetTimeZone.newBuilder().setTzId("Asia/Tokyo").build()

        service.setTimeZone(tokyo)
        service.setTimeZone(tokyo)

        assertEquals(listOf("Asia/Tokyo"), backend.timeZoneWrites)
    }

    @Test
    fun clockFormatUsesAndroidValuesAndSkipsUnchangedValues() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)
        val twentyFourHour =
            SetClockFormat.newBuilder().setFormat(ClockFormat.CLOCK_FORMAT_TWENTY_FOUR).build()

        service.setClockFormat(twentyFourHour)
        service.setClockFormat(twentyFourHour)

        assertEquals(listOf("24"), backend.clockFormatWrites)
    }

    @Test
    fun unspecifiedClockFormatIsInvalid() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)

        val error =
            assertThrows(GuestFailure::class.java) {
                service.setClockFormat(
                    SetClockFormat.newBuilder()
                        .setFormat(ClockFormat.CLOCK_FORMAT_UNSPECIFIED)
                        .build()
                )
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, error.code)
        assertEquals(emptyList<String>(), backend.clockFormatWrites)
    }

    @Test
    fun clockUsesHalfTheRoundTripAndSkipsDriftAtOrBelowThreshold() {
        val backend = FakeLocaleTimeBackend().apply { wallClockMillis = 9_000L }
        val service = LocaleTimeService(backend)

        service.syncTime(SyncTime.newBuilder().setUnixTimeMs(10_000L).setRttMs(1_000).build())
        service.syncTime(SyncTime.newBuilder().setUnixTimeMs(10_000L).setRttMs(0).build())

        assertEquals(listOf(10_500L), backend.wallClockWrites)
    }

    @Test
    fun clockRejectsUnsignedRoundTripsAboveTheBound() {
        val backend = FakeLocaleTimeBackend()
        val service = LocaleTimeService(backend)
        val request = SyncTime.newBuilder().setUnixTimeMs(20_000L).setRttMs(Int.MIN_VALUE).build()

        val error = assertThrows(GuestFailure::class.java) { service.syncTime(request) }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, error.code)
        assertEquals(emptyList<Long>(), backend.wallClockWrites)
    }

    @Test
    fun clockSettingRequiresThePrivilegedPermission() {
        val backend = FakeLocaleTimeBackend().apply { hasTimePermission = false }
        val service = LocaleTimeService(backend)
        val request = SyncTime.newBuilder().setUnixTimeMs(20_000L).setRttMs(0).build()

        val error = assertThrows(GuestFailure::class.java) { service.syncTime(request) }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, error.code)
        assertEquals(emptyList<Long>(), backend.wallClockWrites)
    }
}
