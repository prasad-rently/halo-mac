package app.halo.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingConfirmationTest {
    @Test fun `only an unverifiable database needs a second entry`() {
        assertTrue(PairingConfirmation.required(KeyCheck.Result.NO_SAMPLE))
        assertFalse(PairingConfirmation.required(KeyCheck.Result.MATCH))
        assertFalse(PairingConfirmation.required(KeyCheck.Result.MISMATCH))
    }

    @Test fun `identical entries match`() = assertTrue(PairingConfirmation.matches("Correct-Horse-9", "Correct-Horse-9"))

    @Test fun `composed and decomposed accents match, as they derive the same key`() {
        val composed = "café-Horse-9"; val decomposed = "café-Horse-9"
        assertTrue(composed != decomposed)
        assertTrue(PairingConfirmation.matches(composed, decomposed))
        // ...and that really is the same key, so accepting it is correct.
        val salt = ByteArray(16) { it.toByte() }
        assertTrue(CryptoService.deriveKey(composed, salt, CryptoService.MINIMUM_ITERATIONS).contentEquals(CryptoService.deriveKey(decomposed, salt, CryptoService.MINIMUM_ITERATIONS)))
    }

    @Test fun `a trailing space is a different passphrase`() {
        assertFalse(PairingConfirmation.matches("Correct-Horse-9", "Correct-Horse-9 "))
        assertFalse(PairingConfirmation.matches(" Correct-Horse-9", "Correct-Horse-9"))
    }

    @Test fun `case and typos do not match`() {
        assertFalse(PairingConfirmation.matches("Correct-Horse-9", "correct-horse-9"))
        assertFalse(PairingConfirmation.matches("Correct-Horse-9", "Correct-Horse-8"))
    }

    @Test fun `the notice carries the agreed wording`() =
        assertEquals("This database has no encrypted data yet, so the passphrase could not be verified. Use exactly the passphrase you set on your Mac.", PairingConfirmation.NOTICE)
}
