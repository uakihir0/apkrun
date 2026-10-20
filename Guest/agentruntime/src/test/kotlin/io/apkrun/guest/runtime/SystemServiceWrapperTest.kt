package io.apkrun.guest.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The isolation of a system service wrapper (guest-components.md §6.2, #73 acceptance): a method
 * that the image does not have makes only its own call unusable, and the other wrappers and calls
 * keep working. The service objects are JDK collections, so the checks run without a framework.
 */
class SystemServiceWrapperTest {
    private fun wrapper(
        serviceName: String,
        vararg names: String,
        service: Any? = ArrayList<Any>(),
    ): SystemServiceWrapper =
        SystemServiceWrapper(
            serviceName = serviceName,
            interfaceName = "java.util.List",
            requirements = names.map { MethodRequirement(it, listOf(listOf())) },
            lookup = { _, _ -> service },
        )

    @Test
    fun aMissingMethodMakesOnlyItsOwnCallUnusable() {
        val wrapper = wrapper("fixture", "size", "noSuchFrameworkMethod")
        assertFalse(wrapper.available)
        assertEquals(listOf("noSuchFrameworkMethod"), wrapper.missingMethods)
        assertEquals(0, wrapper.call("size"))
        assertThrows(ServiceMethodMissing::class.java) { wrapper.call("noSuchFrameworkMethod") }
    }

    @Test
    fun aWrapperThatResolvesCompletelyIsAvailable() {
        val wrapper = wrapper("fixture", "size", "isEmpty")
        assertTrue(wrapper.available)
        assertEquals(emptyList<String>(), wrapper.missingMethods)
        assertEquals(true, wrapper.call("isEmpty"))
    }

    @Test
    fun aMissingMethodOfOneWrapperDoesNotChangeAnother() {
        val broken = wrapper("broken", "size", "noSuchFrameworkMethod")
        val healthy = wrapper("healthy", "size")
        assertFalse(broken.available)
        assertTrue(healthy.available)
        assertEquals(0, healthy.call("size"))
    }

    @Test
    fun anUnregisteredServiceFailsEveryCallOfItsWrapperOnly() {
        val absent = wrapper("absent", "size", service = null)
        assertFalse(absent.available)
        assertEquals(listOf("size"), absent.missingMethods)
        assertThrows(ServiceMethodMissing::class.java) { absent.call("size") }
        assertEquals(0, wrapper("present", "size").call("size"))
    }
}
