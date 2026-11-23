package io.apkrun.guest.daemon

import android.app.AppOpsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Handler
import io.apkrun.guest.protocol.v1.RecordingChanged
import io.apkrun.guest.protocol.v1.SetMicrophoneAccess
import io.apkrun.guest.runtime.AgentLog

/**
 * The microphone allowlist of desktop-integration.md §8.2. `SetMicrophoneAccess` (op 53) carries
 * the packages the host's `AudioPolicy` enabled; every other third-party package is denied through
 * app-ops `OP_RECORD_AUDIO`, so a package the host never allowed keeps recording silence even when
 * Android would grant `RECORD_AUDIO` itself.
 *
 * Recording state comes from `AudioManager.registerAudioRecordingCallback`; a change publishes
 * `recording_changed` (event 45) with the recording package IDs — never levels or contents
 * (NFR-SEC-05).
 *
 * The framework calls live in [OpsAccess] and [RecordingAccess]; [AndroidOpsAccess] and
 * [AndroidRecordingAccess] implement them over `AppOpsManager` and `AudioManager`, and a unit test
 * gives fakes.
 */
internal class MicrophoneGate(
    private val events: EventBus,
    private val ops: OpsAccess,
    private val recording: RecordingAccess,
    private val packages: RecordablePackages,
) {
    /** One third-party package app-ops applies to. */
    internal data class RecordablePackage(val uid: Int, val name: String)

    /** The (uid, package) list the gate applies app-ops to. */
    internal fun interface RecordablePackages {
        fun recordablePackages(): List<RecordablePackage>
    }

    /** The app-ops calls the gate needs; `AppOpsManager` implements them. */
    internal interface OpsAccess {
        /** Sets `OP_RECORD_AUDIO` for one package. */
        fun setRecordAudioMode(uid: Int, packageName: String, allowed: Boolean)
    }

    /** The recording-callback registration the gate needs; `AudioManager` implements it. */
    internal interface RecordingAccess {
        /** Registers [listener] for recording-configuration changes. */
        fun register(listener: (Set<String>) -> Unit)

        /** Releases the registration on [listener]. */
        fun unregister()
    }

    @Volatile private var allowed: Set<String> = emptySet()

    @Volatile private var recordingPackages: Set<String> = emptySet()
    private var listenerRegistered = false

    /** Applies a `SetMicrophoneAccess` push: replace the allowlist, then re-apply app-ops. */
    fun setAccess(request: SetMicrophoneAccess) {
        allowed = request.packagesList.toSet()
        apply()
    }

    /** Re-applies app-ops for every recordable package; runs on PACKAGE_ADDED too (§9.2). */
    fun apply() {
        val allowed = allowed
        for (entry in packages.recordablePackages()) {
            ops.setRecordAudioMode(entry.uid, entry.name, entry.name in allowed)
        }
    }

    /** Starts listening for recording-configuration changes and publishing `recording_changed`. */
    fun start() {
        if (listenerRegistered) {
            return
        }
        listenerRegistered = true
        recording.register { packages -> onRecordingChanged(packages) }
    }

    /** Releases the recording callback. */
    fun stop() {
        if (!listenerRegistered) {
            return
        }
        listenerRegistered = false
        recording.unregister()
    }

    /** Publishes `recording_changed` when the recording package set changed. */
    private fun onRecordingChanged(packages: Set<String>) {
        if (packages == recordingPackages) {
            return
        }
        recordingPackages = packages
        val changed = RecordingChanged.newBuilder().addAllPackages(packages.sorted())
        events.publish { it.setRecordingChanged(changed) }
    }

    companion object {
        /** The `packageAdded` broadcast wiring; returns the receiver for tests. */
        fun packageAddedReceiver(onAdded: (String) -> Unit): BroadcastReceiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != Intent.ACTION_PACKAGE_ADDED) {
                        return
                    }
                    val packageName = intent.data?.schemeSpecificPart
                    if (packageName != null) {
                        onAdded(packageName)
                    }
                }
            }

        /** Registers the PACKAGE_ADDED receiver that re-applies app-ops (§9.2). */
        fun watchPackageAdded(context: Context, gate: MicrophoneGate) {
            context.registerReceiver(
                packageAddedReceiver { gate.apply() },
                IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply { addDataScheme("package") },
            )
        }
    }
}

/** `RecordablePackages` over `PackageManager`: third-party apps only. */
internal class AndroidRecordablePackages(private val context: Context) :
    MicrophoneGate.RecordablePackages {
    override fun recordablePackages(): List<MicrophoneGate.RecordablePackage> =
        context.packageManager.getInstalledPackages(0).mapNotNull { info ->
            val application = info.applicationInfo ?: return@mapNotNull null
            val isSystem = application.flags and ApplicationInfo.FLAG_SYSTEM != 0
            val isUpdatedSystem = application.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP != 0
            if (isSystem && !isUpdatedSystem) {
                null
            } else {
                MicrophoneGate.RecordablePackage(application.uid, info.packageName)
            }
        }
}

/** `OpsAccess` over `AppOpsManager`. */
internal class AndroidOpsAccess(private val context: Context) : MicrophoneGate.OpsAccess {
    private companion object {
        /** `AppOpsManager.OPSTR_RECORD_AUDIO`, hidden in the SDK stubs. */
        const val OP_RECORD_AUDIO = "android:record_audio"
    }

    override fun setRecordAudioMode(uid: Int, packageName: String, allowed: Boolean) {
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: return
        val mode =
            if (allowed) {
                AppOpsManager.MODE_ALLOWED
            } else {
                AppOpsManager.MODE_IGNORED
            }
        try {
            // `setMode` is a system API the SDK stubs hide; the privileged
            // agent reaches it reflectively (security-model.md §3.2).
            appOps.javaClass
                .getMethod(
                    "setMode",
                    String::class.java,
                    Int::class.java,
                    String::class.java,
                    Int::class.java,
                )
                .invoke(appOps, OP_RECORD_AUDIO, uid, packageName, mode)
        } catch (error: Exception) {
            AgentLog.error("app-ops RECORD_AUDIO for a package failed", error)
        }
    }
}

/** `RecordingAccess` over `AudioManager.registerAudioRecordingCallback`. */
internal class AndroidRecordingAccess(
    private val context: Context,
    private val handler: Handler,
) : MicrophoneGate.RecordingAccess {
    private var callback: AudioManager.AudioRecordingCallback? = null

    override fun register(listener: (Set<String>) -> Unit) {
        val audio = context.getSystemService(AudioManager::class.java) ?: return
        val callback =
            object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: List<AudioRecordingConfiguration>) {
                    val packages =
                        configs.mapNotNull { config -> packageOf(clientUid(config)) }.toSet()
                    listener(packages)
                }
            }
        this.callback = callback
        try {
            audio.registerAudioRecordingCallback(callback, handler)
        } catch (error: Exception) {
            AgentLog.error("the recording callback could not be registered", error)
        }
    }

    override fun unregister() {
        val audio = context.getSystemService(AudioManager::class.java) ?: return
        callback?.let { audio.unregisterAudioRecordingCallback(it) }
        callback = null
    }

    private fun packageOf(uid: Int): String? =
        context.packageManager.getNameForUid(uid)?.split(':')?.firstOrNull()

    /** `getClientUid` is hidden in the SDK stubs; the privileged agent reads it reflectively. */
    private fun clientUid(config: AudioRecordingConfiguration): Int =
        try {
            config.javaClass.getMethod("getClientUid").invoke(config) as Int
        } catch (error: Exception) {
            -1
        }
}
