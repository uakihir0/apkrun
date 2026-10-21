package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.AppProcessEvent
import io.apkrun.guest.protocol.v1.AppProcessEventKind
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.SystemServices
import java.lang.reflect.Method

/**
 * Observes app crashes and ANRs through the framework's single IActivityController slot
 * (guest-components.md §5). This is a best-effort observer; it returns the non-interfering answer
 * for every callback and never includes a stack trace in the protocol event.
 */
class ActivityControllerMonitor(
    private val events: EventBus,
    /** Moves event writes off the system-server Binder thread. */
    private val postCallback: (() -> Unit) -> Unit = { work -> work() },
    private val setActivityController: (Any) -> Unit = { controller ->
        val wrapper =
            when {
                SystemServices.activityController.supports("setActivityController") ->
                    SystemServices.activityController
                SystemServices.activityTaskController.supports("setActivityController") ->
                    SystemServices.activityTaskController
                else -> error("the framework has no activity-controller hook")
            }
        wrapper.call("setActivityController", controller, false)
    },
    private val controllerFactory: ((Method, Array<Any?>) -> Any?) -> Any =
        ::createActivityController,
    private val missingControllerMethods: () -> List<String> = ::findMissingControllerMethods,
    private val warning: (String) -> Unit = AgentLog::warning,
) {
    @Volatile
    var available: Boolean = false
        private set

    /** Installs the system-server callback. Failure disables only health.v1. */
    fun start() {
        try {
            setActivityController(controllerFactory(::handle))
            available = true
        } catch (error: Exception) {
            available = false
            warning(unavailableReason(error))
        } catch (error: LinkageError) {
            available = false
            warning(unavailableReason(error))
        }
    }

    private fun unavailableReason(error: Throwable): String {
        val missingMethods = missingControllerMethods()
        val detail =
            if (missingMethods.isNotEmpty()) {
                "missing ${missingMethods.distinct().sorted().joinToString()}"
            } else {
                error.javaClass.simpleName
            }
        return "app crash and ANR monitoring is unavailable: $detail"
    }

    private fun handle(method: Method, arguments: Array<Any?>): Any? {
        when (method.name) {
            "appCrashed" -> postCallback { publishCrash(arguments.copyOf()) }
            "appNotResponding" -> postCallback { publishAnr(arguments.copyOf()) }
        }
        return when (method.name) {
            "activityStarting",
            "activityResuming" -> true
            "appCrashed" -> false
            "appEarlyNotResponding",
            "appNotResponding",
            "systemNotResponding" -> 0
            else -> defaultValue(method.returnType)
        }
    }

    private fun publishCrash(arguments: Array<Any?>) {
        val processName = arguments.getOrNull(0) as? String ?: return
        val packageName = packageOfProcess(processName) ?: return
        val pid = (arguments.getOrNull(1) as? Number)?.toInt() ?: 0
        val message = shortMessage(arguments.getOrNull(2) as? String)
        val kind =
            if (message.startsWith("Native crash", ignoreCase = true)) {
                AppProcessEventKind.APP_PROCESS_EVENT_KIND_NATIVE_CRASH
            } else {
                AppProcessEventKind.APP_PROCESS_EVENT_KIND_CRASH
            }
        publish(packageName, kind, pid, message)
    }

    private fun publishAnr(arguments: Array<Any?>) {
        val processName = arguments.getOrNull(0) as? String ?: return
        val packageName = packageOfProcess(processName) ?: return
        val pid = (arguments.getOrNull(1) as? Number)?.toInt() ?: 0
        publish(
            packageName,
            AppProcessEventKind.APP_PROCESS_EVENT_KIND_ANR,
            pid,
            "Application is not responding",
        )
    }

    private fun publish(
        packageName: String,
        kind: AppProcessEventKind,
        pid: Int,
        message: String,
    ) {
        events.publish(GuestCapability.HEALTH) {
            it.setAppProcessEvent(
                AppProcessEvent.newBuilder()
                    .setPackage(packageName)
                    .setKind(kind)
                    .setPid(pid.coerceAtLeast(0))
                    .setShortMessage(message)
            )
        }
    }

    private fun packageOfProcess(processName: String): String? =
        processName.substringBefore(':').takeIf(PackageName::isValid)

    private fun shortMessage(message: String?): String =
        message
            .orEmpty()
            .lineSequence()
            .firstOrNull()
            .orEmpty()
            .filterNot(Char::isISOControl)
            .take(MAXIMUM_SHORT_MESSAGE_CHARACTERS)

    private fun defaultValue(type: Class<*>): Any? =
        when (type) {
            Boolean::class.javaPrimitiveType -> false
            Int::class.javaPrimitiveType -> 0
            Long::class.javaPrimitiveType -> 0L
            else -> null
        }

    private companion object {
        const val MAXIMUM_SHORT_MESSAGE_CHARACTERS = 256

        fun findMissingControllerMethods(): List<String> =
            try {
                listOf(
                        SystemServices.activityController,
                        SystemServices.activityTaskController,
                    )
                    .filterNot { it.supports("setActivityController") }
                    .map { "${it.serviceName}.setActivityController" }
            } catch (_: Exception) {
                emptyList()
            } catch (_: LinkageError) {
                emptyList()
            }

        fun createActivityController(onCall: (Method, Array<Any?>) -> Any?): Any {
            val interfaceClass =
                checkNotNull(HiddenApi.classOrNull("android.app.IActivityController")) {
                    "IActivityController is missing"
                }
            return HiddenApi.binderCallback(interfaceClass, onCall)
        }
    }
}
