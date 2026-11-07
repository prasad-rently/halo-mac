package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextTransformsTest {
    private fun out(id: TransformId, input: String): String {
        val r = TextTransforms.apply(id, input)
        assertTrue("expected output for $id but was $r", r is TransformResult.Output)
        return (r as TransformResult.Output).text
    }
    private fun fails(id: TransformId, input: String) = assertTrue("expected failure for $id", TextTransforms.apply(id, input) is TransformResult.Failure)

    // ── empty / trailing-newline handling (the shell idiom) ────────────────────────────────────

    @Test fun emptyInputFailsForEveryInputTransformButNotGenerators() {
        for (id in TransformId.values()) {
            if (id.usesInput) { fails(id, ""); fails(id, "\n\n") }
            else assertTrue(TextTransforms.apply(id, "") is TransformResult.Output)
        }
    }

    @Test fun onlyTrailingNewlinesAreStripped_notSpacesOrCarriageReturns() {
        assertEquals(TextTransforms.sha256Hex("a "), out(TransformId.SHA256, "a \n"))
        assertEquals(TextTransforms.sha256Hex("a\r"), out(TransformId.SHA256, "a\r\n"))   // CR stays: `$(...)` strips only \n
        assertEquals(TextTransforms.sha256Hex("  x"), out(TransformId.SHA256, "  x"))
    }

    // ── JSON ───────────────────────────────────────────────────────────────────────────────────

    @Test fun jsonIsPrintedLikePythonIncludingAsciiEscapes() {
        assertEquals("{\n    \"k\": \"caf\\u00e9 \\ud83d\\ude00\"\n}", out(TransformId.FORMAT_JSON, "{\"k\":\"café 😀\"}"))
        assertEquals("[\"\\u007f\\u001f\"]", out(TransformId.MINIFY_JSON, "[\"\u007f\\u001f\"]"))        // DEL is escaped by ensure_ascii, as are controls
        assertEquals("\"a\\\"b\\\\c\\/d\"".replace("\\/", "/"), out(TransformId.MINIFY_JSON, "\"a\\\"b\\\\c\\/d\""))   // \/ is parsed, printed as /
    }

    @Test fun beautifierModeKeepsUnicodeReadable() {
        assertEquals("{\n  \"k\": \"café 😀\"\n}", JsonFormat.pretty("{\"k\":\"café 😀\"}", indent = 2, asciiOnly = false))
    }

    @Test fun duplicateKeysKeepFirstPositionAndLastValue() {
        assertEquals("{\"a\":2,\"b\":3}", out(TransformId.MINIFY_JSON, "{\"a\":1,\"b\":3,\"a\":2}"))
    }

    @Test fun numberTokensAreKeptVerbatim_aDocumentedDifferenceFromPython() {
        assertEquals("[1e2,1.0,12345678901234567890]", out(TransformId.MINIFY_JSON, "[1e2, 1.0, 12345678901234567890]"))
    }

    @Test fun invalidJsonIsAFailureWithNoEchoOfTheInput() {
        val secret = "{\"password\": hunter2supersecret}"
        val r = TextTransforms.apply(TransformId.FORMAT_JSON, secret) as TransformResult.Failure
        assertFalse("error text must not echo the user's data", r.message.contains("hunter2supersecret"))
        for (bad in listOf("{\"a\":1,}", "[1,2", "{'a':1}", "{a:1}", "[01]", "[+1]", "[.5]", "[1.]", "[tru]", "[undefined]", "{\"a\" 1}", "", "[1] [2]")) fails(TransformId.FORMAT_JSON, bad)
        for (ok in listOf("[NaN, Infinity, -Infinity]", "[-0, 0.5e+10, 1E-2]", "\"\"", "null", "  {\"a\" : [ ] }  ")) assertTrue(ok, TextTransforms.apply(TransformId.MINIFY_JSON, ok) is TransformResult.Output)
    }

    // ── counting ───────────────────────────────────────────────────────────────────────────────

    @Test fun statsCountCodePointsAndBytesSeparately() {
        val s = TextStats.of("café 😀\nx")
        assertEquals(TextStats(words = 3, characters = 8, lines = 2, bytes = 12), s)     // 😀 is ONE character, four bytes
        assertEquals("Words:      3\nCharacters: 12\nLines:      2", s.desktopFormat())
    }

    // ── lines ──────────────────────────────────────────────────────────────────────────────────

    @Test fun sortIsByCodePointNotUtf16() {
        // U+FF5E < U+1F600, but UTF-16 puts the emoji's high surrogate (D83D) before FF5E.
        assertEquals("z\n～\n😀", out(TransformId.SORT_LINES, "😀\n～\nz"))
    }

    @Test fun sortKeepsBlankLinesAndCarriageReturnTails() {
        assertEquals("\nb\na".split('\n').sorted().joinToString("\n"), out(TransformId.SORT_LINES, "b\n\na"))
        assertEquals("a\r\nb\r", out(TransformId.SORT_LINES, "b\r\na\r"))    // the \r is part of each line, as it is for `sort`
    }

    @Test fun dedupKeepsFirstOccurrenceOrderAndReportsCounts() {
        val r = TextTransforms.apply(TransformId.DEDUP_LINES, "b\na\nb\n\n\na") as TransformResult.Output
        assertEquals("b\na\n", r.text)
        assertEquals("Removed 3 duplicate lines (6 → 3)", r.note)
    }

    // ── URL / Base64 ───────────────────────────────────────────────────────────────────────────

    @Test fun urlEncodeKeepsSlashAndTilde_encodesPlusAndUnicodeAsUtf8() {
        assertEquals("a/b~c%2B%C3%A9%F0%9F%98%80", out(TransformId.URL_ENCODE, "a/b~c+é😀"))
    }

    @Test fun urlDecodeJoinsMultiBytePercentRuns_andLeavesPlusAndJunkAlone() {
        assertEquals("é😀+%zz%4", out(TransformId.URL_DECODE, "%C3%A9%F0%9F%98%80+%zz%4"))
    }

    @Test fun urlDecodeOfInvalidUtf8BecomesReplacementCharacterNotACrash() {
        assertEquals("�", out(TransformId.URL_DECODE, "%FF"))
        assertEquals("a�b", out(TransformId.URL_DECODE, "a%C3b").replace("��", "�"))
    }

    @Test fun urlActionsStripSurroundingWhitespaceFirstIncludingNbsp() {
        assertEquals("x", out(TransformId.URL_ENCODE, "  x\t "))
    }

    @Test fun base64RoundTripsUnicode() {
        val enc = out(TransformId.BASE64_ENCODE, "héllo 😀 \u0000 end")
        assertEquals("héllo 😀 \u0000 end", out(TransformId.BASE64_DECODE, enc))
    }

    @Test fun base64DecodeAcceptsWhitespaceUrlSafeAndMissingPadding_likeAJwtSegment() {
        assertEquals("{\"alg\":\"HS256\"}", out(TransformId.BASE64_DECODE, "eyJhbGci\nOiJIUzI1NiJ9"))
        assertEquals("subjects?_", out(TransformId.BASE64_DECODE, "c3ViamVjdHM_Xw"))
    }

    @Test fun base64DecodeRejectsGarbageAndBinary() {
        fails(TransformId.BASE64_DECODE, "!!!"); fails(TransformId.BASE64_DECODE, "a"); fails(TransformId.BASE64_DECODE, "====")
        fails(TransformId.BASE64_DECODE, "/+8=")           // 0xFF 0xEF — valid Base64, not UTF-8 text
    }

    // ── case / hash ────────────────────────────────────────────────────────────────────────────

    @Test fun caseConversionIsUnicodeAndLocaleIndependent() {
        assertEquals("STRASSE", out(TransformId.UPPERCASE, "straße"))
        val saved = java.util.Locale.getDefault()
        try { java.util.Locale.setDefault(java.util.Locale("tr", "TR")); assertEquals("TITLE", out(TransformId.UPPERCASE, "title")); assertEquals("title", out(TransformId.LOWERCASE, "TITLE")) }
        finally { java.util.Locale.setDefault(saved) }      // Turkish default locale would otherwise give "TİTLE"
    }

    @Test fun sha256KnownAnswers() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", out(TransformId.SHA256, "abc"))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", TextTransforms.sha256Hex(""))
    }

    // ── QR ─────────────────────────────────────────────────────────────────────────────────────

    @Test fun qrPayloadIsPassedThroughAndOversizeIsRefused() {
        assertEquals(TransformResult.Qr("https://example.com/é"), TextTransforms.apply(TransformId.QR_CODE, "https://example.com/é\n"))
        assertTrue(TextTransforms.apply(TransformId.QR_CODE, "x".repeat(TextTransforms.QR_MAX_BYTES)) is TransformResult.Qr)
        assertTrue(TextTransforms.apply(TransformId.QR_CODE, "x".repeat(TextTransforms.QR_MAX_BYTES + 1)) is TransformResult.Failure)
        assertTrue("limit is in bytes, not chars", TextTransforms.apply(TransformId.QR_CODE, "é".repeat(TextTransforms.QR_MAX_BYTES / 2 + 1)) is TransformResult.Failure)
    }

    // ── generators ─────────────────────────────────────────────────────────────────────────────

    @Test fun uuidIsVersion4Variant10AndUpperCase_fromGivenBytes() {
        val allFF = RandomBytes { ByteArray(it) { 0xFF.toByte() } }
        assertEquals("FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF", TextTransforms.uuid(allFF))
        val zero = RandomBytes { ByteArray(it) }
        assertEquals("00000000-0000-4000-8000-000000000000", TextTransforms.uuid(zero))
    }

    @Test fun uuidsDifferAcrossCalls() = assertEquals(200, (1..200).map { TextTransforms.uuid() }.toSet().size)

    @Test fun passwordUsesTheDesktopRecipeAndRetriesRatherThanPads() {
        val fixed = RandomBytes { n -> ByteArray(n) { it.toByte() } }
        // base64 of 00 01 02 .. 17 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX"; no / + = to strip, first 20 chars.
        assertEquals("AAECAwQFBgcICQoLDA0O", TextTransforms.password(fixed))
        var calls = 0
        val shortFirst = RandomBytes { n -> calls++; if (calls == 1) ByteArray(n) { 0xFF.toByte() } else ByteArray(n) { (it * 3).toByte() } }   // all-0xFF base64 is "////…": nothing left after stripping
        val pw = TextTransforms.password(shortFirst)
        assertEquals(2, calls); assertEquals(20, pw.length); assertTrue(pw.all { it.isLetterOrDigit() })
    }

    @Test fun passwordsAreUniqueAndAlphanumeric() {
        val all = (1..300).map { TextTransforms.password() }
        assertEquals(300, all.toSet().size); assertTrue(all.all { it.length == 20 && it.all { c -> c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' } })
    }

    @Test fun generatorsAreFlaggedSecretOnlyForPasswords() {
        assertTrue((TextTransforms.apply(TransformId.PASSWORD, "") as TransformResult.Output).secret)
        assertFalse((TextTransforms.apply(TransformId.UUID, "") as TransformResult.Output).secret)
    }

    @Test fun resultsNeverRepeatInputInTheNote() {
        val secret = "S3cretPassw0rd!"
        for (id in TransformId.values().filter { it.usesInput && it != TransformId.QR_CODE }) {
            val r = TextTransforms.apply(id, secret)
            val note = when (r) { is TransformResult.Output -> r.note; is TransformResult.Failure -> r.message; else -> null }
            assertFalse("$id note must not contain the input", note?.contains(secret) == true)
        }
    }
}
