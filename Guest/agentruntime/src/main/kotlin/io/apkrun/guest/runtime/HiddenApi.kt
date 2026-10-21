package io.apkrun.guest.runtime

import android.os.IBinder
import android.os.Parcel
import android.os.Parcelable
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * Reflection over the hidden framework API (guest-components.md §6.2). The agents run under
 * `app_process` in development mode, where hidden APIs are not restricted, so these lookups reach
 * the same interfaces that scrcpy uses. Nothing here is compiled against a hidden class.
 */
object HiddenApi {
    /** The class with [name], or null when this image does not have it. */
    fun classOrNull(name: String): Class<*>? =
        try {
            Class.forName(name)
        } catch (error: ClassNotFoundException) {
            null
        }

    /** `ServiceManager.getService(name)`, or null when the service is not registered. */
    fun serviceBinder(name: String): Any? {
        val manager = classOrNull("android.os.ServiceManager") ?: return null
        return manager.getMethod("getService", String::class.java).invoke(null, name)
    }

    /**
     * The interface object of the service [serviceName], or null when the service or its stub is
     * missing.
     */
    fun service(serviceName: String, interfaceName: String): Any? =
        asInterface(interfaceName, serviceBinder(serviceName))

    /**
     * `<interfaceName>$Stub.asInterface(binder)`, or null when the binder or the stub is missing.
     */
    fun asInterface(interfaceName: String, binder: Any?): Any? {
        if (binder == null) {
            return null
        }
        val stub = classOrNull("$interfaceName\$Stub") ?: return null
        val ibinder = classOrNull("android.os.IBinder") ?: return null
        return stub.getMethod("asInterface", ibinder).invoke(null, binder)
    }

    /**
     * An implementation of [interfaceClass] whose calls go to [handler]. A call of `toString`,
     * `hashCode`, or `equals` is answered by the proxy itself, and the other calls are forwarded.
     */
    fun proxy(interfaceClass: Class<*>, handler: (Method, Array<Any?>) -> Any?): Any {
        val invocation = InvocationHandler { _, method, args ->
            when (method.name) {
                "toString" -> "apkrun-proxy(${interfaceClass.simpleName})"
                "hashCode" -> System.identityHashCode(args)
                "equals" -> false
                else -> handler(method, args ?: emptyArray())
            }
        }
        return Proxy.newProxyInstance(
            interfaceClass.classLoader,
            arrayOf(interfaceClass),
            invocation,
        )
    }

    /**
     * A listener for a framework callback interface. The framework calls its listener through
     * Binder, so the object it receives must answer `asBinder` with a Binder. Each call on that
     * Binder runs [onNotify], and the framework receives an empty reply. The callback carries no
     * data that the agent needs: the agent reads the state again when it is notified.
     */
    fun listener(interfaceClass: Class<*>, onNotify: () -> Unit): Any {
        val binder =
            object : android.os.Binder() {
                override fun onTransact(
                    code: Int,
                    data: android.os.Parcel,
                    reply: android.os.Parcel?,
                    flags: Int,
                ): Boolean {
                    if (code == android.os.IBinder.INTERFACE_TRANSACTION) {
                        return super.onTransact(code, data, reply, flags)
                    }
                    onNotify()
                    reply?.writeNoException()
                    return true
                }
            }
        return proxy(interfaceClass) { method, _ ->
            if (method.name == "asBinder") binder else null
        }
    }

    /**
     * Builds a Binder-backed implementation of a hidden callback interface. This is used for
     * `IActivityController`, whose callbacks cross from system_server and therefore cannot be
     * implemented as an in-process Java proxy alone.
     */
    fun binderCallback(
        interfaceClass: Class<*>,
        onCall: (Method, Array<Any?>) -> Any?,
    ): Any {
        val stubClass =
            checkNotNull(classOrNull("${interfaceClass.name}\$Stub")) {
                "the ${interfaceClass.name} Stub is missing"
            }
        val descriptor =
            stubClass.getDeclaredField("DESCRIPTOR").apply { isAccessible = true }.get(null)
                as String
        val calls =
            interfaceClass.methods
                .mapNotNull { method ->
                    val code =
                        try {
                            stubClass
                                .getDeclaredField("TRANSACTION_${method.name}")
                                .apply { isAccessible = true }
                                .getInt(null)
                        } catch (_: ReflectiveOperationException) {
                            null
                        }
                    code?.let { it to method }
                }
                .toMap()
        val binder =
            object : android.os.Binder() {
                override fun onTransact(
                    code: Int,
                    data: Parcel,
                    reply: Parcel?,
                    flags: Int,
                ): Boolean {
                    if (code == IBinder.INTERFACE_TRANSACTION) {
                        reply?.writeString(descriptor)
                        return true
                    }
                    val method = calls[code] ?: return super.onTransact(code, data, reply, flags)
                    data.enforceInterface(descriptor)
                    val arguments =
                        method.parameterTypes
                            .map { type -> readCallbackArgument(data, type) }
                            .toTypedArray()
                    val result = onCall(method, arguments)
                    reply?.writeNoException()
                    writeCallbackResult(reply, method.returnType, result)
                    return true
                }
            }
        return Proxy.newProxyInstance(interfaceClass.classLoader, arrayOf(interfaceClass)) {
            proxy,
            method,
            arguments ->
            when (method.name) {
                "asBinder" -> binder
                "toString" -> "apkrun-callback(${interfaceClass.simpleName})"
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === arguments?.firstOrNull()
                else -> onCall(method, arguments ?: emptyArray())
            }
        }
    }

    private fun readCallbackArgument(parcel: Parcel, type: Class<*>): Any? =
        when (type) {
            String::class.java -> parcel.readString()
            Int::class.javaPrimitiveType -> parcel.readInt()
            Long::class.javaPrimitiveType -> parcel.readLong()
            Boolean::class.javaPrimitiveType -> parcel.readInt() != 0
            else ->
                if (Parcelable::class.java.isAssignableFrom(type)) {
                    val creator = type.getField("CREATOR").get(null) as Parcelable.Creator<*>
                    parcel.readTypedObject(creator)
                } else {
                    throw IllegalArgumentException(
                        "the callback parameter ${type.name} is not supported"
                    )
                }
        }

    private fun writeCallbackResult(reply: Parcel?, type: Class<*>, value: Any?) {
        when (type) {
            Void.TYPE -> Unit
            Boolean::class.javaPrimitiveType -> reply?.writeInt(if (value == true) 1 else 0)
            Int::class.javaPrimitiveType -> reply?.writeInt((value as? Number)?.toInt() ?: 0)
            Long::class.javaPrimitiveType -> reply?.writeLong((value as? Number)?.toLong() ?: 0L)
            else ->
                if (Parcelable::class.java.isAssignableFrom(type)) {
                    reply?.writeTypedObject(value as? Parcelable, 0)
                } else {
                    throw IllegalArgumentException(
                        "the callback result ${type.name} is not supported"
                    )
                }
        }
    }

    /**
     * `SystemProperties.get(name)`, or null when the property is not readable from this process.
     */
    fun systemProperty(name: String): String? =
        try {
            classOrNull("android.os.SystemProperties")
                ?.getMethod("get", String::class.java)
                ?.invoke(null, name) as? String
        } catch (error: ReflectiveOperationException) {
            null
        }

    /**
     * Reads a public field, or the method `name()`, `getName()`, or `isName()` when there is no
     * such field.
     */
    fun read(target: Any, name: String): Any? {
        val field = target.javaClass.fields.firstOrNull { it.name == name }
        if (field != null) {
            return field.get(target)
        }
        val capitalized = name.replaceFirstChar { it.uppercase() }
        val getter =
            target.javaClass.methods.firstOrNull {
                it.parameterCount == 0 &&
                    (it.name == name || it.name == "get$capitalized" || it.name == "is$capitalized")
            }
        return getter?.invoke(target)
    }
}

/**
 * One hidden method that a wrapper needs. A method has one parameter list per Android release, so
 * the variants are tried in order, and the first one the interface declares is used
 * (guest-components.md §6.2). A parameter type is its `Class.getTypeName()`.
 */
class MethodRequirement(val name: String, val parameterVariants: List<List<String>>) {
    /**
     * The method of [interfaceClass] that matches one of the variants, or null when there is none.
     */
    fun resolve(interfaceClass: Class<*>): Method? {
        for (variant in parameterVariants) {
            val match =
                interfaceClass.methods.firstOrNull { method ->
                    method.name == name && method.parameterTypes.map { it.typeName } == variant
                }
            if (match != null) {
                return match
            }
        }
        return null
    }
}
