package app.halo.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HomeStateTest {
    private fun health(paired: Boolean = true, problem: Boolean = false, sms: Boolean = true, clip: Boolean = false, syncing: Boolean = false, last: Long = 1L, err: String? = null, q: Int = 0) =
        cloudHealth(paired, problem, sms, clip, syncing, last, err, q)

    @Test fun `a profile problem outranks everything - the safety card must show`() {
        assertEquals(CloudHealth.NEEDS_ATTENTION, health(paired = false, problem = true))
        assertEquals(CloudHealth.NEEDS_ATTENTION, health(problem = true, syncing = true, err = "x"))
    }
    @Test fun `unpaired and everything off`() {
        assertEquals(CloudHealth.NOT_PAIRED, health(paired = false))
        assertEquals(CloudHealth.OFF, health(sms = false, clip = false))
    }
    @Test fun `quarantined messages and errors are never reported as OK`() {
        assertEquals(CloudHealth.OK, health())
        assertEquals(CloudHealth.WARNING, health(q = 2))
        assertEquals(CloudHealth.ERROR, health(err = "boom", q = 2))
        assertEquals(CloudHealth.NEVER, health(last = 0L))
        assertEquals(CloudHealth.SYNCING, health(syncing = true, err = "boom"))
    }
    @Test fun `clipboard only still counts as on`() = assertEquals(CloudHealth.OK, health(sms = false, clip = true))

    @Test fun `relative time`() {
        val now = 10_000_000_000L
        assertEquals("now", RelativeTime.compact(now, now - 30_000)); assertEquals("now", RelativeTime.compact(now, now + 5_000))
        assertEquals("2m", RelativeTime.compact(now, now - 2 * 60_000)); assertEquals("3h", RelativeTime.compact(now, now - 3 * 3_600_000))
        assertEquals("5d", RelativeTime.compact(now, now - 5 * 86_400_000))
        assertEquals("just now", RelativeTime.ago(now, now)); assertEquals("2 min ago", RelativeTime.ago(now, now - 120_000)); assertEquals("3 h ago", RelativeTime.ago(now, now - 3 * 3_600_000))
    }

    @Test fun `otp codes are found next to a code word only`() {
        assertEquals("482913", OtpCode.find("Your verification code is 482913. Do not share it."))
        assertEquals("123456", OtpCode.find("G-123456 is your Google verification code"))
        assertEquals("123456", OtpCode.find("OTP: 123 456"))
        assertNull(OtpCode.find("Your order 482913 has shipped"))              // a number without a code word is not a code
        assertNull(OtpCode.find("Your code is 12"))                            // too short
        assertNull(OtpCode.find("code: 1234567890123"))                        // too long: a phone/account number
        assertNull(OtpCode.find("Your PIN balance is 1,234.56"))
    }

    @Test fun `clip kinds`() {
        assertEquals(ClipKind.URL, ClipKind.of("url", "https://example.com"))
        assertEquals(ClipKind.CODE, ClipKind.of("text", "func a() {\n  return 1\n}"))
        assertEquals(ClipKind.TEXT, ClipKind.of("text", "see you at 5, bring snacks"))
    }
}
