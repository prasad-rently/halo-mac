package app.halo.mobile.tools

import com.google.zxing.BinaryBitmap
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ToolsGuardsTest {
    private val dir = listOf("src/main/kotlin/app/halo/mobile/tools", "app/src/main/kotlin/app/halo/mobile/tools").map(::File).first { it.exists() }
    private val sources = dir.listFiles { f -> f.extension == "kt" }!!.associate { it.name to it.readText() }

    private fun decode(payload: String): String {
        val m = QrImage.matrix(payload)!!
        val px = IntArray(m.width * m.height) { if (m[it % m.width, it / m.width]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
        return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(m.width, m.height, px)))).text
    }

    @Test fun qrRoundTripsAsciiUnicodeAndLongText() {
        for (t in listOf("https://example.com/a?b=c", "héllo wörld ☃ 😀", "x".repeat(1200), "line1\nline2")) assertEquals(t, decode(t))
    }

    @Test fun qrBeyondCapacityIsNullNotACrash() = assertNull(QrImage.matrix("x".repeat(4000)))

    @Test fun nothingInTheHubLogsOrPrints() {
        // Transform results, pasted code and clipboard text pass through these files; none of it may reach logcat.
        val bad = Regex("""\b(Log\.[a-z]\(|println\(|print\(|Timber\.|Sentry|Toast\.makeText\([^)]*(text|result|code))""")
        for ((name, src) in sources) assertFalse("$name logs or prints: ${bad.find(src)?.value}", bad.containsMatchIn(src))
    }

    @Test fun theClipboardIsOnlyReadFromAButtonHandler() {
        // Each read must sit within a couple of lines of an `onClick =` (the Paste buttons), never in an effect or at composition time.
        val reads = sources.flatMap { (n, s) -> val ls = s.lines(); ls.indices.filter { ls[it].contains("ToolsClipboard.read(") }.map { i -> n to ls.subList(maxOf(0, i - 2), i + 1).joinToString("\n") } }
        assertTrue("expected the Paste buttons", reads.size >= 2)
        for ((n, ctx) in reads) assertTrue("$n reads the clipboard outside an onClick: $ctx", ctx.contains("onClick"))
        for ((n, s) in sources) assertFalse("$n must not read the clipboard in an effect", Regex("""LaunchedEffect[^\n]*\{[^}]*ToolsClipboard\.read""").containsMatchIn(s))
    }

    @Test fun onlyTheClipboardHelperTouchesTheClipboardManager() {
        for ((n, s) in sources) if (n != "ToolsClipboard.kt") assertFalse("$n uses ClipboardManager directly", s.contains("ClipboardManager"))
    }

    @Test fun registryIdsAreUniqueAndTitlesAreShort() {
        val tools = ToolsRegistry.tools
        assertEquals(tools.size, tools.map { it.id }.toSet().size)
        for (t in tools) assertTrue("'${t.title}' should be at most 3 words", t.title.split(' ').size <= 3)
        assertNotNull(ToolsRegistry.byId("transform")); assertNull(ToolsRegistry.byId("nope"))
    }

    @Test fun theRegistryLivesInItsOwnFileSoAnotherToolIsAOneLineMerge() {
        val reg = sources.getValue("ToolsRegistry.kt")
        assertEquals("one Tool( entry per line", ToolsRegistry.tools.size, reg.lines().count { it.trim().startsWith("Tool(\"") && !it.trim().startsWith("*") })
    }

    @Test fun speedTestOnlyEverTalksHttps() {
        assertFalse(sources.values.any { it.contains("allowCleartext = true") })
        assertTrue(app.halo.tools.SpeedEndpoints().let { listOf(it.ping, it.download, it.upload).all { u -> u.startsWith("https://") } })
    }
}
