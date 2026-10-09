package io.apkrun.guest.runtime

import java.lang.reflect.Method

/** A call to a hidden method that the wrapper of its service did not resolve. */
class ServiceMethodMissing(val service: String, val method: String) :
    RuntimeException("the system service $service has no usable method $method")

/**
 * One system service, reached through `ServiceManager` and its `I*.Stub.asInterface` with
 * reflection (guest-components.md §6.2). The methods are resolved once. A method that the image
 * does not have makes only that method unusable: [available] is then false for the call, and the
 * capability that needs it fails, while the agent keeps running.
 */
class SystemServiceWrapper(
    /** The name registered with `ServiceManager`, such as `display`. */
    val serviceName: String,
    /** The hidden interface, such as `android.hardware.display.IDisplayManager`. */
    val interfaceName: String,
    private val requirements: List<MethodRequirement>,
) {
    private val resolution: Resolution by lazy { resolve() }

    /** The methods the image lacks. Empty when the wrapper resolves completely. */
    val missingMethods: List<String>
        get() = resolution.missing

    /** Whether the service is registered and every required method resolved. */
    val available: Boolean
        get() = resolution.service != null && resolution.missing.isEmpty()

    /** The interface object, or null when the service is not registered. */
    val service: Any?
        get() = resolution.service

    /** The resolved interface class, or null when the interface does not exist on this image. */
    val interfaceClass: Class<*>?
        get() = resolution.interfaceClass

    /** The number of parameters of the resolved method [name], or null when it did not resolve. */
    fun parameterCount(name: String): Int? = resolution.methods[name]?.parameterCount

    /**
     * Calls the hidden method [name] with [arguments]. Throws [ServiceMethodMissing] when the
     * method did not resolve, so that the caller fails only its own capability.
     */
    fun call(name: String, vararg arguments: Any?): Any? {
        val target = resolution.service ?: throw ServiceMethodMissing(serviceName, name)
        val method = resolution.methods[name] ?: throw ServiceMethodMissing(serviceName, name)
        return try {
            method.invoke(target, *arguments)
        } catch (error: java.lang.reflect.InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun resolve(): Resolution {
        val binder = HiddenApi.serviceBinder(serviceName)
        val service = HiddenApi.asInterface(interfaceName, binder)
        val interfaceClass = HiddenApi.classOrNull(interfaceName)
        if (service == null || interfaceClass == null) {
            return Resolution(service, interfaceClass, emptyMap(), requirements.map { it.name })
        }
        val methods = mutableMapOf<String, Method>()
        val missing = mutableListOf<String>()
        for (requirement in requirements) {
            val method = requirement.resolve(interfaceClass)
            if (method == null) {
                missing += requirement.name
            } else {
                methods[requirement.name] = method
            }
        }
        return Resolution(service, interfaceClass, methods, missing)
    }

    private class Resolution(
        val service: Any?,
        val interfaceClass: Class<*>?,
        val methods: Map<String, Method>,
        val missing: List<String>,
    )
}

/**
 * The system services of guest-components.md §6.2 that the development agent uses. Each wrapper
 * resolves on its own, so a service that is absent or changed fails only the capabilities that call
 * it.
 */
object SystemServices {
    /** `DisplayManager`: display list, info, and the change callback (display.v1). */
    val display =
        SystemServiceWrapper(
            serviceName = "display",
            interfaceName = "android.hardware.display.IDisplayManager",
            requirements =
                listOf(
                    MethodRequirement("getDisplayIds", listOf(listOf(), listOf("boolean"))),
                    MethodRequirement("getDisplayInfo", listOf(listOf("int"))),
                    MethodRequirement(
                        "registerCallback",
                        listOf(listOf("android.hardware.display.IDisplayManagerCallback")),
                    ),
                ),
        )

    /** `WindowManager`: forced density and the IME policy of a display (display.v1). */
    val window =
        SystemServiceWrapper(
            serviceName = "window",
            interfaceName = "android.view.IWindowManager",
            requirements =
                listOf(
                    MethodRequirement(
                        "setForcedDisplayDensityForUser",
                        listOf(listOf("int", "int", "int")),
                    ),
                    MethodRequirement("setDisplayImePolicy", listOf(listOf("int", "int"))),
                ),
        )

    /**
     * `ActivityTaskManager`: task lists, the task listener, focus, and moves (launch.v1, input.v1).
     */
    val activityTask =
        SystemServiceWrapper(
            serviceName = "activity_task",
            interfaceName = "android.app.IActivityTaskManager",
            requirements =
                listOf(
                    MethodRequirement(
                        "getTasks",
                        listOf(listOf("int", "boolean", "boolean", "int"), listOf("int")),
                    ),
                    MethodRequirement(
                        "registerTaskStackListener",
                        listOf(listOf("android.app.ITaskStackListener")),
                    ),
                    MethodRequirement(
                        "startActivityAsUser",
                        listOf(
                            listOf(
                                "android.app.IApplicationThread",
                                "java.lang.String",
                                "java.lang.String",
                                "android.content.Intent",
                                "java.lang.String",
                                "android.os.IBinder",
                                "java.lang.String",
                                "int",
                                "int",
                                "android.app.ProfilerInfo",
                                "android.os.Bundle",
                                "int",
                            )
                        ),
                    ),
                    MethodRequirement("setFocusedTask", listOf(listOf("int"))),
                    MethodRequirement("moveRootTaskToDisplay", listOf(listOf("int", "int"))),
                ),
        )

    /** `InputManager`: event injection. It resolves now and is used from #024 on (input.v1). */
    val input =
        SystemServiceWrapper(
            serviceName = "input",
            interfaceName = "android.hardware.input.IInputManager",
            requirements =
                listOf(
                    MethodRequirement(
                        "injectInputEvent",
                        listOf(listOf("android.view.InputEvent", "int")),
                    )
                ),
        )

    /** `LockSettings`: the keyguard switch that device setup applies (guest-components.md §3.4). */
    val lockSettings =
        SystemServiceWrapper(
            serviceName = "lock_settings",
            interfaceName = "com.android.internal.widget.ILockSettings",
            requirements =
                listOf(
                    MethodRequirement(
                        "setBoolean",
                        listOf(listOf("java.lang.String", "boolean", "int")),
                    )
                ),
        )

    /** Every wrapper, in the order that the service check reports them. */
    val all: List<SystemServiceWrapper>
        get() = listOf(display, window, activityTask, input, lockSettings)
}
