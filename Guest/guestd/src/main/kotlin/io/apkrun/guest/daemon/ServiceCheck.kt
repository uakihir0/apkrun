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
        for (wrapper in SystemServices.all) {
            println(
                "service=${wrapper.serviceName} available=${wrapper.available} " +
                    "missing=${wrapper.missingMethods.joinToString(",")}"
            )
        }
    }
}
