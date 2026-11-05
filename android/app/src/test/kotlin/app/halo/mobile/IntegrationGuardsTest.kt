package app.halo.mobile

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Source-level guards for the properties the integrated app must keep (they cross several merged features, so no single feature's
 * own tests own them). Each reads the real source tree, asserts it found it (a vacuous pass is a failure), and was mutation-checked.
 */
class IntegrationGuardsTest {
    private val main = File(System.getProperty("user.dir"), "src/main/kotlin/app/halo/mobile").also { assertTrue("sources not found at $it", it.isDirectory) }
    private fun kt(sub: String) = main.resolve(sub).walkTopDown().filter { it.isFile && it.extension == "kt" }.toList().also { assertTrue("no sources in $sub", it.isNotEmpty()) }

    @Test fun `the Messages OTP copy chip is flagged sensitive and never goes through the syncing copy path`() {
        val src = main.resolve("CloudScreens.kt").readText()
        assertTrue(src.contains("copySensitive(ctx, code)"))
        assertFalse("an OTP must not be copied with copyToClipboard", Regex("copyToClipboard\\([^\\n]*otp", RegexOption.IGNORE_CASE).containsMatchIn(src))
    }

    @Test fun `Similar Photos and the spending screen add no network path`() {
        val banned = listOf("java.net", "javax.net", "okhttp", "HttpURLConnection", "URL(", "app.halo.cloud.Rtdb", "SmsSyncEngine", "app.halo.share", "WebView")
        val offenders = (kt("photos") + kt("expense")).flatMap { f -> f.readLines().filter { l -> banned.any { it in l } && !l.trimStart().startsWith("//") && !l.trimStart().startsWith("*") }.map { "${f.name}: ${it.trim()}" } }
        assertTrue("network references: $offenders", offenders.isEmpty())
    }

    @Test fun `the clipboard is read only from a tap - no lifecycle or composition effect calls a reader`() {
        // Every non-definition reader call must be on a line that is an onClick handler / button action, not in an effect or a lifecycle callback.
        val readers = listOf("readClipboard(", "ToolsClipboard.read(")
        val hits = kt(".").flatMap { f -> val lines = f.readLines(); lines.withIndex().filter { (_, l) -> readers.any { it in l } && !l.contains("fun ") }.map { (i, l) -> Triple(f.name, i + 1, (lines.getOrElse(i - 1) { "" } + l)) } }
        assertTrue("expected to find the paste / send-clipboard call sites", hits.size >= 3)
        val bad = hits.filter { (n, _, l) -> n != "Clipboard.kt" && n != "CloudViewModel.kt" && !(l.contains("onClick") || l.contains("HaloGhostButton(") || l.contains("HaloPrimaryButton(")) }
        assertTrue("clipboard read outside a tap handler: $bad", bad.isEmpty())
        val effects = kt(".").filter { f -> Regex("(LaunchedEffect|LifecycleEventEffect|DisposableEffect)[^\\n]*(readClipboard|ToolsClipboard\\.read)").containsMatchIn(f.readText()) }
        assertTrue("clipboard read inside an effect: ${effects.map { it.name }}", effects.isEmpty())
    }

    @Test fun `the bottom bar has exactly five destinations and no tab for Tools, Spend or Photos`() {
        val src = main.resolve("HomeScreen.kt").readText()
        val enumLine = Regex("enum class HaloDestination \\{([^}]*)\\}").find(src)!!.groupValues[1].split(",").map { it.trim() }.filter { it.isNotEmpty() }
        assertTrue("destinations: $enumLine", enumLine == listOf("Home", "Messages", "Clipboard", "Share", "Settings"))
        val app = main.resolve("Screens.kt").readText()
        assertTrue(Regex("NavItem\\(dest == HaloDestination").findAll(app).count() == 5)
        for (tag in listOf("home.more.tools", "home.more.spend")) assertTrue("$tag must be a Home -> More entry", app.contains(tag))
    }

    @Test fun `no temporary stand-ins from the merged branches survive`() {
        val names = main.walkTopDown().filter { it.isFile }.map { it.name }.toSet()
        for (gone in listOf("ToolsLauncherStub.kt", "HaloShim.kt")) assertFalse("$gone must be deleted", gone in names)
        assertFalse("a second ToolsRegistry (the photos stub) exists", main.resolve("ToolsRegistry.kt").exists())
        assertTrue(main.resolve("tools/ToolsRegistry.kt").readText().contains("Tool(\"photos\""))
    }
}
