package app.halo.cloud

import java.text.Normalizer

/**
 * Decision logic for the "type it twice" step of first pairing (D-01 / H-12).
 *
 * [KeyCheck.verify] can only vouch for a passphrase when the database already holds something encrypted.
 * On a database that holds nothing (NO_SAMPLE) a mistyped passphrase is accepted, the phone then uploads
 * under the wrong key, and the Mac silently drops every undecryptable row. The only defence left is to
 * make the user type it twice — so a typo has to be made identically both times to get through.
 */
object PairingConfirmation {
    /** Shown on the confirm step. Wording agreed with the owner. */
    const val NOTICE = "This database has no encrypted data yet, so the passphrase could not be verified. Use exactly the passphrase you set on your Mac."

    /** A second entry is needed only when there was nothing to verify against. MATCH is proven; MISMATCH is refused before this step. */
    fun required(result: KeyCheck.Result): Boolean = result == KeyCheck.Result.NO_SAMPLE

    /**
     * True when both entries are the same passphrase *as the key derivation sees it*: NFC-normalised, and
     * otherwise exact — a trailing space, a case difference or a different character is a different key.
     */
    fun matches(a: String, b: String): Boolean = nfc(a) == nfc(b)

    private fun nfc(s: String) = Normalizer.normalize(s, Normalizer.Form.NFC)
}
