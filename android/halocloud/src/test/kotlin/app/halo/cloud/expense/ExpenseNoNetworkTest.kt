package app.halo.cloud.expense

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.jar.JarFile

/**
 * FR-E3: "no network call in the parse path". The expense package must not even be ABLE to reach the network: no
 * sockets, no HTTP, no Rtdb / cloud-sync types. Checked against the compiled bytecode of the whole package (what
 * actually ships) and, belt and braces, against its source. Mutation check: make any file in the package
 * `import java.net.URL` (or touch `Rtdb`) and this goes red.
 */
class ExpenseNoNetworkTest {
    private val forbidden = listOf("java/net/", "javax/net/", "java/nio/channels/SocketChannel", "okhttp", "org/apache/http", "HttpURLConnection",
        "app/halo/cloud/Rtdb", "app/halo/cloud/RtdbException", "app/halo/cloud/SmsSyncEngine", "app/halo/cloud/CryptoService")

    private fun classBytes(): Map<String, ByteArray> {
        val loc = File(PatternPack::class.java.protectionDomain.codeSource.location.toURI())
        val out = LinkedHashMap<String, ByteArray>()
        if (loc.isDirectory) {
            loc.resolve("app/halo/cloud/expense").walkTopDown().filter { it.extension == "class" }.forEach { out[it.name] = it.readBytes() }
        } else JarFile(loc).use { jar -> jar.entries().asSequence().filter { it.name.startsWith("app/halo/cloud/expense/") && it.name.endsWith(".class") }.forEach { e -> out[e.name] = jar.getInputStream(e).readBytes() } }
        return out
    }

    @Test fun `no class in the expense package references a network or cloud type`() {
        val classes = classBytes()
        assertTrue("expected to find the expense classes, found ${classes.size}", classes.size >= 15)
        val hits = ArrayList<String>()
        for ((name, bytes) in classes) {
            val text = String(bytes, Charsets.ISO_8859_1)             // constant-pool names are plain ASCII
            for (f in forbidden) if (text.contains(f)) hits += "$name references $f"
        }
        assertTrue("network/cloud references in the parse path:\n" + hits.joinToString("\n"), hits.isEmpty())
    }

    @Test fun `no source file in the expense package imports a network or cloud type`() {
        val files = File(System.getProperty("halo.expenseSrc")!!).listFiles { f -> f.extension == "kt" }!!
        assertTrue(files.size >= 6)
        val bad = files.flatMap { f -> f.readLines().filter { it.trimStart().startsWith("import ") }
            .filter { l -> listOf("java.net", "javax.net", "okhttp", "Rtdb", "SmsSyncEngine", "CryptoService").any { l.contains(it) } }.map { "${f.name}: $it" } }
        assertTrue(bad.joinToString("\n"), bad.isEmpty())
    }
}
