package app.halo.mobile

import app.halo.mobile.background.Notifications
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafeAliasTest {
    @Test fun `a sender cannot reorder our notification text with bidi overrides or isolates`() {
        assertEquals("Mac", Notifications.safeAlias("‮Mac‬"))
        assertEquals("Mac", Notifications.safeAlias("⁦Mac⁩"))
        assertEquals("gpj", Notifications.safeAlias("‮gpj‬"))
        for (c in listOf('‪', '‫', '‭', '⁧', '⁨', '‎', '‏', '؜'))
            assertFalse("U+${c.code.toString(16)}", Notifications.safeAlias("a${c}b").any { it == c })
    }

    @Test fun `controls go, length is bounded, and an alias that is all hostile characters becomes a neutral name`() {
        assertEquals("ab", Notifications.safeAlias("a\u0007\nb"))
        assertTrue(Notifications.safeAlias("x".repeat(500)).length <= 40)
        assertEquals("A device", Notifications.safeAlias("‮⁦ \u0000"))
        assertEquals("A device", Notifications.safeAlias(""))
        assertEquals("שלום", Notifications.safeAlias("שלום"))
    }
}
