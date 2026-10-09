package io.apkrun.guest.daemon

import io.apkrun.guest.runtime.SystemServices

/**
 * Reports which system service wrappers resolve on this image (guest-components.md §6.2, #072
 * acceptance). The host runs it with `app_process` in the same way as the daemon, so the check sees
 * the same hidden APIs. One line per wrapper: `service=<name> available=<true|false>
 * missing=<methods>`.
 */
object ServiceCheck {
    @JvmStatic
    fun main(args: Array<String>) {
        // `--methods <interface> <text>` lists the methods of a hidden interface whose name
        // contains the text. It is the
        // way to read the signatures of an image when a wrapper reports a missing method (R-18).
        if (args.size == 3 && args[0] == "--methods") {
            val methods = Class.forName(args[1]).methods.filter { it.name.contains(args[2]) }
            for (method in methods) {
                println(
                    "${method.name}(${method.parameterTypes.joinToString(",") { it.typeName }})"
                )
            }
            return
        }
        for (wrapper in SystemServices.all) {
            println(
                "service=${wrapper.serviceName} available=${wrapper.available} " +
                    "missing=${wrapper.missingMethods.joinToString(",")}"
            )
        }
    }
}
