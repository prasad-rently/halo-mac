package app.halo.share

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/**
 * Kotlin ⇄ Swift. Drives this implementation against `halosharecli`, the command-line peer built
 * from `ios/HaloShareKit` — a *separate* implementation of the same protocol. Opt-in:
 *
 *     (cd ios/HaloShareKit && swift build)
 *     HALO_SHARE_CLI=$PWD/ios/HaloShareKit/.build/debug/halosharecli ./gradlew :haloshare:test
 */
class CrossImplementationTest {
    private val cli: File? = System.getenv("HALO_SHARE_CLI")?.let(::File)?.takeIf { it.canExecute() }

    private fun runCli(vararg args: String, timeoutSec: Long = 90): Pair<Int, String> {
        val p = ProcessBuilder(listOf(cli!!.path) + args).redirectErrorStream(true).start()
        val out = p.inputStream.readBytes()
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) { p.destroyForcibly(); return -1 to String(out) }
        return p.exitValue() to String(out)
    }

    @Test fun kotlinClientSendsToTheSwiftReceiver() {
        assumeTrue("HALO_SHARE_CLI not set", cli != null)
        val dest = Files.createTempDirectory("xi-rx").toFile()
        val ready = File.createTempFile("xi-ready", ".txt").apply { delete() }
        val port = 53951
        val rx = ProcessBuilder(cli!!.path, "receive", "--dir", dest.path, "--port", "$port", "--ready-file", ready.path, "--timeout", "120")
            .redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.DISCARD).start()
        try {
            assertTrue("the Swift receiver never came up", waitUntil(15_000) { ready.exists() })
            val client = HaloShareClient(DeviceIdentity("Kotlin", DeviceIdentity.randomFingerprint()))
            val peer = client.probe("127.0.0.1", port, timeoutMs = 5000)
            assertNotNull("Kotlin could not probe the Swift server", peer)

            val dir = Files.createTempDirectory("xi-src").toFile()
            val text = File(dir, "note.txt").apply { writeText("from kotlin") }
            val bin = makeFile("photo.bin", 300_000, dir)
            val big = makeFile("big.bin", 24L shl 20, dir)
            val outcome = client.send(listOf(text, bin, big).map { OutgoingFile.fromFile(it) }, peer!!)
            assertEquals(SendOutcome.Completed, outcome)

            assertEquals("from kotlin", File(dest, "note.txt").readText())
            assertEquals(sha256(bin), sha256(File(dest, "photo.bin")))
            assertEquals("24 MB file differs", sha256(big), sha256(File(dest, "big.bin")))
        } finally { rx.destroyForcibly(); dest.deleteRecursively() }
    }

    @Test fun theSwiftSenderSendsToTheKotlinServer() = Rig().use { rig ->
        assumeTrue("HALO_SHARE_CLI not set", cli != null)
        val dir = Files.createTempDirectory("xi-src").toFile()
        val bin = makeFile("fromswift.bin", 700_000, dir)
        val text = File(dir, "swift.txt").apply { writeText("from swift") }
        val big = makeFile("swiftbig.bin", 24L shl 20, dir)

        val (code, out) = runCli("send", "--to", "127.0.0.1:${rig.port}", bin.path, text.path, big.path)
        assertEquals(out, 0, code)
        assertEquals(sha256(bin), sha256(File(rig.dir, "fromswift.bin")))
        assertEquals("from swift", File(rig.dir, "swift.txt").readText())
        assertEquals(sha256(big), sha256(File(rig.dir, "swiftbig.bin")))
    }

    @Test fun aDeclineOnTheKotlinServerIsReportedByTheSwiftSender() = Rig(ConsentDecision.DECLINE).use { rig ->
        assumeTrue("HALO_SHARE_CLI not set", cli != null)
        val (code, out) = runCli("send", "--to", "127.0.0.1:${rig.port}", makeFile("no.bin", 5000).path)
        assertEquals("expected exit 3 (declined): $out", 3, code)
        assertTrue(rig.filesOnDisk().isEmpty())
    }
}
