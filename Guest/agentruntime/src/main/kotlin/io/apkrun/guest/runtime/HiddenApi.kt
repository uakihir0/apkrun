package io.apkrun.guest.runtime

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
