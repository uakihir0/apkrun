package io.apkrun.guest.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The variant selection of guest-components.md §6.2, checked against JDK interfaces. */
class MethodRequirementTest {
    @Test
    fun aRequirementResolvesTheFirstVariantThatTheInterfaceDeclares() {
        // `List.add` exists as add(int, Object) and as add(Object). The first declared variant
        // wins.
        val requirement =
            MethodRequirement(
                "add",
                listOf(listOf("int", "java.lang.Object"), listOf("java.lang.Object")),
            )
        val method = requirement.resolve(MutableList::class.java)
        assertEquals(listOf("int", "java.lang.Object"), method?.parameterTypes?.map { it.typeName })
    }

    @Test
    fun aMissingFirstVariantFallsBackToTheNextOne() {
        val requirement =
            MethodRequirement(
                "add",
                listOf(listOf("int", "java.lang.String"), listOf("java.lang.Object")),
            )
        val method = requirement.resolve(MutableList::class.java)
        assertEquals(listOf("java.lang.Object"), method?.parameterTypes?.map { it.typeName })
    }

    @Test
    fun aLaterVariantIsUsedWhenTheFirstIsMissing() {
        val requirement = MethodRequirement("size", listOf(listOf("int"), listOf()))
        val method = requirement.resolve(List::class.java)
        assertEquals(0, method?.parameterCount)
    }

    @Test
    fun aMissingMethodResolvesToNull() {
        assertNull(
            MethodRequirement("setForcedDisplayDensity", listOf(listOf("int")))
                .resolve(List::class.java)
        )
    }

    @Test
    fun aParameterTypeMustMatchExactly() {
        assertNull(
            MethodRequirement("add", listOf(listOf("java.lang.String")))
                .resolve(MutableList::class.java)
        )
    }
}
