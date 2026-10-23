package app.halo.share

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

private fun File.write(text: String) = also { writeText(text) }

class LoopbackTest {

    @Test fun aTextFileArrivesIntact() = Rig().use { rig ->
        val src = makeFile("hello.txt", 0).write("hello, halo")
        assertEquals(SendOutcome.Completed, rig.client.send(listOf(OutgoingFile.fromFile(src)), rig.peer))
        assertEquals("hello, halo", File(rig.dir, "hello.txt").readText())
        assertTrue(waitUntil { rig.log.completed.get() == 1 })
    }

    @Test fun aBinaryFileThatIsNotValidUtf8ArrivesByteForByte() = Rig().use { rig ->
        val src = makeFile("blob.bin", 3L shl 20)
        assertEquals(SendOutcome.Completed, rig.client.send(listOf(OutgoingFile.fromFile(src)), rig.peer))
        assertEquals(sha256(src), sha256(File(rig.dir, "blob.bin")))
    }

    @Test fun aNinetySixMegabyteFileStreamsThroughIntact() = Rig().use { rig ->
        val src = makeFile("big.bin", 96L shl 20)
        assertEquals(SendOutcome.Completed, rig.client.send(listOf(OutgoingFile.fromFile(src)), rig.peer))
        assertEquals(sha256(src), sha256(File(rig.dir, "big.bin")))
    }

    @Test fun severalFilesInOneSessionCompleteOnce() = Rig().use { rig ->
        val dir = java.nio.file.Files.createTempDirectory("hsk-multi").toFile()
        val files = listOf("a.bin", "b.bin", "c.bin").mapIndexed { i, n -> OutgoingFile.fromFile(makeFile(n, 100_000L + i * 777, dir)) }
        assertEquals(SendOutcome.Completed, rig.client.send(files, rig.peer))
        assertEquals(listOf("a.bin", "b.bin", "c.bin"), rig.filesOnDisk())
        assertTrue(waitUntil { rig.log.completed.get() == 1 })
    }

    @Test fun progressEndsAtTheFullSizeAndNeverGoesBackwards() = Rig().use { rig ->
        val size = 6L shl 20
        val seen = java.util.concurrent.CopyOnWriteArrayList<SendProgress>()
        rig.client.send(listOf(OutgoingFile.fromFile(makeFile("p.bin", size))), rig.peer, progress = { seen.add(it) })
        assertEquals(size, seen.last().sent); assertEquals(size, seen.last().overallTotal)
        assertTrue("progress went backwards", seen.zipWithNext().all { (a, b) -> a.sent <= b.sent })
        assertTrue(waitUntil { rig.log.completed.get() == 1 })
        assertTrue("only ${rig.log.progress.size} receiver progress events", rig.log.progress.size >= 3)
        assertEquals(size, rig.log.progress.last())
    }

    @Test fun aSubFolderInTheFileNameIsPreservedInsideTheDestination() = Rig().use { rig ->
        val out = OutgoingFile.fromFile(makeFile("x.txt", 10), name = "trip/2026/x.txt")
        assertEquals(SendOutcome.Completed, rig.client.send(listOf(out), rig.peer))
        assertEquals(listOf("trip/2026/x.txt"), rig.filesOnDisk())
    }

    @Test fun aFileThatAlreadyExistsIsNotOverwritten() = Rig().use { rig ->
        File(rig.dir, "doc.txt").writeText("original")
        rig.client.send(listOf(OutgoingFile.fromFile(makeFile("doc.txt", 5))), rig.peer)
        assertEquals("original", File(rig.dir, "doc.txt").readText())
        assertEquals(listOf("doc (1).txt", "doc.txt"), rig.filesOnDisk())
    }

    @Test fun aHostileFileNameCannotEscapeTheDestination() = Rig().use { rig ->
        val outside = File(rig.dir.parentFile, "victim-${System.nanoTime()}.txt").write("do not touch")
        try {
            val evil = OutgoingFile.fromFile(makeFile("s.txt", 5), name = "../${outside.name}")
            assertEquals(SendOutcome.Completed, rig.client.send(listOf(evil), rig.peer))
            assertEquals("the sender wrote outside the folder", "do not touch", outside.readText())
            assertEquals(listOf(outside.name), rig.filesOnDisk())
        } finally { outside.delete() }
    }

    @Test fun decliningWritesNothingCreatesNoSessionAndReportsDeclined() = Rig(ConsentDecision.DECLINE).use { rig ->
        assertEquals(SendOutcome.Declined, rig.client.send(listOf(OutgoingFile.fromFile(makeFile("no.bin", 1000))), rig.peer))
        assertTrue(rig.filesOnDisk().isEmpty())
        assertEquals(1, rig.log.offers.size)
        assertEquals("no session may exist after a decline", 404,
            Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=x&fileId=y&token=z", "x".toByteArray()).status)
    }

    @Test fun theConsentHandlerSeesWhoIsSendingWhat() = Rig().use { rig ->
        rig.client.send(listOf(OutgoingFile.fromFile(makeFile("a.jpg", 1000)), OutgoingFile.fromFile(makeFile("b.pdf", 2000))), rig.peer)
        val offer = rig.log.offers.first()
        assertEquals("Sender", offer.sender.alias); assertEquals(listOf("a.jpg", "b.pdf"), offer.files.map { it.fileName }); assertEquals(3000L, offer.totalBytes)
    }

    @Test fun cancellingTheSendStopsTheUploadAndTellsTheReceiver() {
        // Loopback is far too fast to cancel a real upload; this receiver stops reading, so the sender
        // blocks in write() — which only the connection-closing cancel callback can end.
        StallingReceiver().use { slow ->
            val client = HaloShareClient(DeviceIdentity("Sender", DeviceIdentity.randomFingerprint()))
            val peer = client.probe("127.0.0.1", slow.port, timeoutMs = 5000)!!
            val src = makeFile("huge.bin", 64L shl 20)
            val cancel = CancelToken()
            var failure: Throwable? = null
            val done = AtomicBoolean(false)
            val t = Thread {
                try { client.send(listOf(OutgoingFile.fromFile(src)), peer, cancel); } catch (e: Throwable) { failure = e }
                done.set(true)
            }.apply { start() }

            assertTrue("the upload never reached the receiver", waitUntil(15_000) { slow.uploadStarted })
            Thread.sleep(300)
            cancel.cancel()
            assertTrue("the blocked send never returned after cancel", waitUntil(10_000) { done.get() })
            t.join()
            assertTrue("got $failure", failure is HaloShareException.Cancelled)
            assertTrue("the receiver was never told to discard the session", waitUntil(10_000) { slow.cancelRequests.get() == 1 })
        }
    }

    @Test fun aCancelArrivingMidUploadDiscardsThePartialFileAndEndsTheSession() = Rig().use { rig ->
        val d = FileDescriptor("f", "half.bin", 4L shl 20, "x")
        val prep = Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json")
        val resp = parseResponse(prep.text)
        Socket().use { s ->
            s.connect(InetSocketAddress("127.0.0.1", rig.port), 5000)
            val head = "POST /api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]} HTTP/1.1\r\nHost: x\r\nContent-Length: ${4 shl 20}\r\n\r\n"
            s.getOutputStream().write(head.toByteArray() + ByteArray(300_000) { 9 }); s.getOutputStream().flush()
            assertTrue("the upload never started streaming", waitUntil { rig.filesOnDisk().any { it.endsWith(".halopart") } })

            assertEquals(200, Raw.post(rig.port, "/api/localsend/v2/cancel?sessionId=${resp.sessionId}", ByteArray(0)).status)
            assertTrue("partial survived the cancel: ${rig.filesOnDisk()}", waitUntil { rig.filesOnDisk().isEmpty() })
            assertTrue(waitUntil { rig.log.cancelled.get() == 1 })
        }
    }

    @Test fun aWrongTokenIsRefusedAndWritesNothing() = Rig().use { rig ->
        val d = FileDescriptor("f1", "t.bin", 10)
        val resp = parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json").text)
        assertEquals(403, Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f1&token=WRONG", ByteArray(10) { 1 }).status)
        assertTrue(rig.filesOnDisk().isEmpty())
        assertEquals(200, Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f1&token=${resp.files["f1"]}", ByteArray(10) { 1 }).status)
    }

    @Test fun tokensAreUniquePerFileAndPerSession() = Rig().use { rig ->
        val descs = (1..3).map { FileDescriptor("f$it", "f$it", 1) }.toTypedArray()
        val all = (0 until 2).flatMap { parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(*descs), "application/json").text).files.values }
        assertEquals(6, all.toSet().size); assertTrue(all.all { it.length >= 24 })
    }

    @Test fun aFileUploadedTwiceInOneSessionIsRefusedTheSecondTime() = Rig().use { rig ->
        val resp = parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(FileDescriptor("a", "a", 3), FileDescriptor("b", "b", 3)), "application/json").text)
        val path = "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=a&token=${resp.files["a"]}"
        assertEquals(200, Raw.post(rig.port, path, "abc".toByteArray()).status)
        assertEquals(409, Raw.post(rig.port, path, "xyz".toByteArray()).status)
        assertEquals("abc", File(rig.dir, "a").readText())
    }

    @Test fun sha256IsVerifiedWhenSuppliedAMismatchIs422AndDeletesTheFile() = Rig().use { rig ->
        val payload = "checksummed".toByteArray()
        for ((name, digest, expected) in listOf(Triple("ok.txt", sha256(payload), 200), Triple("bad.txt", "0".repeat(64), 422))) {
            val d = FileDescriptor("f", name, payload.size.toLong(), "text/plain", sha256 = digest)
            val resp = parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json").text)
            assertEquals(name, expected, Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}", payload).status)
        }
        assertEquals("a corrupt file was kept", listOf("ok.txt"), rig.filesOnDisk())
    }

    @Test fun aSessionCapReturns429() = Rig(maxSessions = 1).use { rig ->
        val d = FileDescriptor("f", "f", 1)
        assertEquals(200, Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json").status)
        assertEquals(429, Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json").status)
    }

    @Test fun theClientReportsABusyReceiverAsSuch() = Rig(maxSessions = 1).use { rig ->
        Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(FileDescriptor("f", "f", 1)), "application/json")
        try { rig.client.send(listOf(OutgoingFile.fromFile(makeFile("late.txt", 10))), rig.peer); fail("expected Busy") }
        catch (e: HaloShareException.Busy) { /* expected */ }
    }

    @Test fun probingNobodyFailsFastAndProbingYourselfFindsNothing() = Rig().use { rig ->
        assertNull(rig.client.probe("127.0.0.1", 1, timeoutMs = 1000))
        val selfClient = HaloShareClient(DeviceIdentity("Receiver", rig.peer.info.fingerprint))
        assertNull(selfClient.probe("127.0.0.1", rig.port, timeoutMs = 2000))
    }
}

class IndependentClientTest {

    @Test fun headersAndABinaryBodyInOneWriteAreAccepted() = Rig().use { rig ->
        val payload = ByteArray(2048) { (it * 37 + 129).toByte() }
        assertNull(String(payload, Charsets.UTF_8).takeIf { false })      // (fixture is high-byte data)
        val d = FileDescriptor("f", "one.bin", payload.size.toLong())
        val prep = Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(d), "application/json")
        assertEquals("prepare-upload JSON sharing a write with its headers", 200, prep.status)
        val resp = parseResponse(prep.text)
        assertEquals(200, Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}", payload).status)
        assertArrayEquals(payload, File(rig.dir, "one.bin").readBytes())
    }

    @Test fun headersAndBodyInSeparateWritesAreAccepted() = Rig().use { rig ->
        val payload = ByteArray(5000) { 0xC3.toByte() }
        val prep = Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(FileDescriptor("f", "two.bin", payload.size.toLong())), "application/json", splitAfterHead = true)
        val resp = parseResponse(prep.text)
        assertEquals(200, Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}", payload, splitAfterHead = true).status)
        assertArrayEquals(payload, File(rig.dir, "two.bin").readBytes())
    }

    @Test fun aTruncatedUploadIsNotAcknowledgedAndLeavesNoFileOrPartial() = Rig().use { rig ->
        val resp = parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(FileDescriptor("f", "cut.bin", 5000)), "application/json").text)
        val up = Raw.post(rig.port, "/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}", ByteArray(1200) { 7 }, declaredLength = 5000)
        assertNotEquals(200, up.status)
        assertTrue("left behind: ${rig.filesOnDisk()}", waitUntil { rig.filesOnDisk().isEmpty() })
    }

    @Test fun chunkedTransferEncodingIsRefusedWith411() = Rig().use { rig ->
        assertEquals(411, Raw.post(rig.port, "/api/localsend/v2/prepare-upload", "{}".toByteArray(), "application/json", extraHeaders = "Transfer-Encoding: chunked\r\n").status)
    }

    @Test fun unknownRoutesAre404AndGarbageIs400() = Rig().use { rig ->
        assertEquals(404, Raw.post(rig.port, "/nope", ByteArray(0)).status)
        assertEquals(400, Raw.post(rig.port, "/api/localsend/v2/prepare-upload", "not json".toByteArray(), "application/json").status)
    }

    @Test fun aConnectionThatStallsMidRequestIsDroppedAfterTheIdleTimeout() = Rig(idleTimeoutMs = 1000).use { rig ->
        Socket().use { s ->
            s.connect(InetSocketAddress("127.0.0.1", rig.port), 5000); s.soTimeout = 6000
            s.getOutputStream().write("POST /api/localsend/v2/upload?sess".toByteArray()); s.getOutputStream().flush()   // never finishes
            val started = System.currentTimeMillis()
            val n = try { s.getInputStream().read() } catch (e: java.net.SocketTimeoutException) { 99 }
            assertTrue("the server should have closed the stalled connection", n <= 0)
            assertTrue("took ${System.currentTimeMillis() - started} ms", System.currentTimeMillis() - started < 5000)
        }
    }

    @Test fun curlGetInfoReturnsTheReceiversIdentity() = Rig().use { rig ->
        assumeTrue(curlAvailable)
        val (status, body) = curl("http://127.0.0.1:${rig.port}/api/localsend/v2/info")
        assertEquals(200, status)
        val info = HaloJson.decodeFromString(DeviceInfo.serializer(), body)
        assertEquals("Receiver", info.alias); assertEquals(rig.peer.info.fingerprint, info.fingerprint)
    }

    @Test fun curlFullPrepareUploadAndBinaryUploadRoundTrip() = Rig().use { rig ->
        assumeTrue(curlAvailable)
        val src = makeFile("curl.bin", 40_000)
        val bodyFile = File.createTempFile("hsk-prep", ".json").apply { writeBytes(prepareBody(FileDescriptor("f", "curl.bin", 40_000))) }
        val (ps, pb) = curl("-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@${bodyFile.path}", "http://127.0.0.1:${rig.port}/api/localsend/v2/prepare-upload")
        assertEquals(200, ps)
        val resp = HaloJson.decodeFromString(PrepareUploadResponse.serializer(), pb)
        val (us, _) = curl("-X", "POST", "-H", "Content-Type: application/octet-stream", "--data-binary", "@${src.path}",
            "http://127.0.0.1:${rig.port}/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}")
        assertEquals(200, us)
        assertEquals(sha256(src), sha256(File(rig.dir, "curl.bin")))
    }

    @Test fun curlThreeMegabyteUploadWithExpect100ContinueIsHonoured() = Rig().use { rig ->
        assumeTrue(curlAvailable)
        val size = 3L shl 20
        val src = makeFile("expect.bin", size)
        val resp = parseResponse(Raw.post(rig.port, "/api/localsend/v2/prepare-upload", prepareBody(FileDescriptor("f", "expect.bin", size)), "application/json").text)
        val (status, _) = curl("-X", "POST", "-H", "Expect: 100-continue", "-H", "Content-Type: application/octet-stream", "--data-binary", "@${src.path}",
            "http://127.0.0.1:${rig.port}/api/localsend/v2/upload?sessionId=${resp.sessionId}&fileId=f&token=${resp.files["f"]}")
        assertEquals(200, status)
        assertEquals(sha256(src), sha256(File(rig.dir, "expect.bin")))
    }
}

class DiscoveryTest {
    @Test fun scanningAnExplicitHostListFindsThePeerOnceHoweverManyAddressesReachIt() = Rig().use { rig ->
        val peers = SubnetScanner(rig.client, rig.port, concurrency = 8, timeoutMs = 2000)
            .scan(listOf("127.0.0.1", "127.0.0.2", "127.0.0.3", "127.0.0.4"))
        assertEquals(1, peers.size); assertEquals("Receiver", peers.first().alias)
    }

    @Test fun aDeadHostListFindsNothingAndReturnsPromptly() {
        val client = HaloShareClient(DeviceIdentity("S", "s"))
        val started = System.currentTimeMillis()
        val peers = SubnetScanner(client, 1, concurrency = 16, timeoutMs = 500).scan((1..20).map { "127.0.0.$it" })
        assertTrue(peers.isEmpty()); assertTrue(System.currentTimeMillis() - started < 5000)
    }
}
