package app.halo.photos

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * "No network use in the photo path." The app module legitimately has INTERNET (cloud sync), so the guarantee is made
 * structurally: neither the :halophotos module nor the app's `photos` package may import or mention any networking API,
 * and :halophotos has no dependencies at all beyond the test scope.
 */
class PhotoPathNoNetworkTest {
    private val banned = listOf(
        "java.net", "javax.net", "okhttp", "okio", "retrofit", "HttpURLConnection", "HttpsURLConnection", "java.nio.channels.SocketChannel",
        "android.net.http", "android.net.ConnectivityManager", "WebView", "ktor", "URLConnection", "app.halo.share", "app.halo.cloud", "app.halo.mobile.cloud",
    )

    private fun sources(prop: String): List<File> {
        val dir = File(System.getProperty(prop) ?: error("$prop not set"))
        return if (dir.exists()) dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList() else emptyList()
    }

    private fun scan(files: List<File>) {
        for (f in files) {
            // strip comments so the explanatory comments in this very feature can say "no network"
            val code = f.readText().replace(Regex("/\\*[\\s\\S]*?\\*/"), "").lines().joinToString("\n") { it.substringBefore("//") }
            for (b in banned) assertTrue("${f.name} mentions banned networking/cloud API '$b'", !code.contains(b))
        }
    }

    @Test fun `halophotos module touches no network or cloud API`() {
        val files = sources("halo.photosSrc")
        assertTrue("scan must not be vacuous", files.size >= 6)
        scan(files)
    }

    @Test fun `app photos package touches no network or cloud API`() {
        val files = sources("halo.appPhotosSrc")
        assertTrue("scan must not be vacuous - expected the Android photos package at app/src/main/kotlin/app/halo/mobile/photos", files.isNotEmpty())
        scan(files)
    }

    @Test fun `halophotos declares no runtime dependencies`() {
        val gradle = File(System.getProperty("halo.photosSrc")).parentFile.parentFile.resolve("build.gradle.kts").readText()
        val deps = gradle.lines().filter { it.trim().startsWith("implementation(") || it.trim().startsWith("api(") }
        assertTrue("runtime deps found: $deps", deps.isEmpty())
    }

    /**
     * Deletion is reachable only through TrashRequest (system dialog). Any other delete API in the photos package is a bug.
     * (`createDeleteRequest` is also out: it deletes permanently, with no Trash to recover from.)
     */
    @Test fun `no silent or permanent deletion API anywhere in the photos path`() {
        val forbidden = listOf(".delete(", "createDeleteRequest", "File(", "deleteRecursively", "unlink", "removeItem", "RecoverableSecurityException", "MANAGE_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE")
        for (f in sources("halo.appPhotosSrc") + sources("halo.photosSrc")) {
            val code = f.readText().replace(Regex("/\\*[\\s\\S]*?\\*/"), "").lines().joinToString("\n") { it.substringBefore("//") }
            for (b in forbidden) assertTrue("${f.name} uses '$b'", !code.contains(b))
        }
        val trash = sources("halo.appPhotosSrc").single { it.name == "TrashRequest.kt" }.readText()
        assertTrue(trash.contains("createTrashRequest"))
    }
}
