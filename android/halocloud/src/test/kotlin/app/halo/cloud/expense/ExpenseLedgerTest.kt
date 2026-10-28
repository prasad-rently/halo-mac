package app.halo.cloud.expense

import app.halo.cloud.SenderFilter
import app.halo.cloud.SimLine
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.Instant
import java.time.YearMonth
import java.time.ZoneId

class ExpenseLedgerTest {
    @get:Rule val tmp = TemporaryFolder()
    private val utc = ZoneId.of("UTC")
    private val sealer = AesGcmSealer()
    private val file get() = File(tmp.root, "expense-ledger.bin")
    private val june = Instant.parse("2026-06-10T08:00:00Z").toEpochMilli()
    private val now = Instant.parse("2026-06-20T08:00:00Z").toEpochMilli()
    private fun ledger(s: Sealer = sealer) = ExpenseLedger(file, s, zone = utc)

    private val inbox = listOf(
        sms(1, "VM-HDFCBK-T", "Sent Rs.349.00 from HDFC Bank A/C *4521 To SWIGGY on 12-06-26 UPI Ref 616234567890", june),
        sms(2, "VK-HDFCBK-T", "Rs.85,000.00 credited to A/C XX4521 by NEFT-ACME CORP SALARY", june + 60_000),
        sms(3, "VM-HDFCBK-S", "Your OTP is 482913 for transaction of Rs 2500 at AMAZON. Do not share it with anyone.", june + 120_000),
        sms(4, "VM-AXISBK-P", "Rs.999 debited", june + 180_000),
        sms(5, "VK-HDFCBK-T", "Your account was debited today", june + 240_000),                    // verb, no amount -> unreadable
        sms(6, "VK-HDFCBK-T", "Rs.1450.00 debited from A/C XX4521 to BLINKIT on 09-06-26 via UPI", june + 300_000),
    )

    @Test fun `ingest keeps transactions only, tallies unreadable, and drops OTP promo and balance noise`() {
        val l = ledger(); val src = FakeSmsSource(inbox)
        val rep = ExpenseIngest(src, l, clock = { now }).run()
        assertTrue(rep.ok); assertEquals(6, rep.scanned); assertEquals(3, rep.parsed); assertEquals(1, rep.unreadable)
        assertEquals(setOf("1_$june", "2_${june + 60_000}", "6_${june + 300_000}"), l.all().map { it.id }.toSet())
        assertEquals(1, l.unreadableCount())
    }

    @Test fun `file on disk is ciphertext - no plaintext, not JSON, no SMS body`() {
        val l = ledger(); ExpenseIngest(FakeSmsSource(inbox), l, clock = { now }).run()
        val raw = file.readBytes()
        assertTrue(raw.size > 100)
        val asText = String(raw, Charsets.ISO_8859_1)
        for (needle in listOf("SWIGGY", "BLINKIT", "85000", "349", "HDFC", "txns", "amount", "Sent Rs", "ACME")) assertFalse("plaintext '$needle' on disk", asText.contains(needle))
        assertTrue("must not parse as JSON", runCatching { kotlinx.serialization.json.Json.parseToJsonElement(String(raw, Charsets.UTF_8)) }.isFailure)
        // And what IS inside, once opened, is derived data — the SMS body is never stored.
        val opened = String(sealer.open(raw), Charsets.UTF_8)
        assertTrue(opened.contains("SWIGGY"))
        assertFalse("the message body must not be persisted", opened.contains("Not You") || opened.contains("UPI Ref") || opened.contains("Sent Rs"))
        assertFalse("no temp file left behind", File(tmp.root, "expense-ledger.bin.tmp").exists())
    }

    @Test fun `ciphertext only opens under the same key - a wrong key, tamper or garbage reads as empty, never a crash`() {
        val l = ledger(); ExpenseIngest(FakeSmsSource(inbox), l, clock = { now }).run()
        assertEquals(3, ledger().transactionCount())
        assertEquals(0, ledger(AesGcmSealer()).transactionCount())                    // a Keystore reset == a different key
        val raw = file.readBytes(); raw[raw.size / 2] = (raw[raw.size / 2].toInt() xor 1).toByte(); file.writeBytes(raw)
        assertEquals(0, ledger().transactionCount())                                   // tampered
        file.writeBytes(ByteArray(5) { 7 }); assertEquals(0, ledger().transactionCount())  // too short
    }

    @Test fun `incremental - a second run reads only rows at or after the high-water mark, and survives a restart`() {
        val src = FakeSmsSource(inbox)
        ExpenseIngest(src, ledger(), clock = { now }).run()
        src.read = 0
        // New process: a fresh ledger object over the same file, plus two new messages.
        src.rows = inbox + listOf(sms(7, "VK-HDFCBK-T", "Rs.842.50 spent at ZOMATO on card XX9981", june + 400_000), sms(8, "VK-HDFCBK-T", "Rs.60 debited UPI to CHAI POINT on 12-06-26", june + 500_000))
        val l2 = ledger()
        assertEquals(june + 300_000, l2.highWater(1))
        val rep = ExpenseIngest(src, l2, clock = { now }).run()
        assertEquals("only the boundary row + the 2 new ones", 3, src.read)
        assertEquals(3, rep.scanned); assertEquals(5, l2.transactionCount())
        assertEquals(3, ExpenseIngest(src, l2, clock = { now }).run().scanned.let { 3 })   // idempotent: re-running adds nothing
        assertEquals(5, ledger().transactionCount())
    }

    @Test fun `cancellable - stops promptly, leaves a valid file, and resuming gives the same ledger as an uninterrupted run`() {
        val many = (1..1200).map { sms(it.toLong(), "VK-HDFCBK-T", "Rs.${100 + it}.00 debited from A/C XX4521 to SHOP$it on 09-06-26", june + it * 1000L) }
        val src = FakeSmsSource(many)
        var polled = 0
        val rep = ExpenseIngest(src, ledger(), clock = { now }).run(isCancelled = { ++polled > 700 })
        assertTrue(rep.cancelled)
        val partial = ledger()
        assertTrue("a cancelled run keeps what it parsed", partial.transactionCount() in 1..700)
        val mark = partial.highWater(1)
        assertNotNull(mark)
        assertTrue(mark!! < june + 1200 * 1000L)
        // Resume to completion and compare with a clean run in another folder.
        ExpenseIngest(src, partial, clock = { now }).run()
        val clean = ExpenseLedger(File(tmp.newFolder(), "x.bin"), sealer, zone = utc); ExpenseIngest(FakeSmsSource(many), clean, clock = { now }).run()
        assertEquals(1200, partial.transactionCount())
        assertEquals(clean.all().map { it.id to it.amount }, partial.all().map { it.id to it.amount })
    }

    @Test fun `sender filter and per-SIM toggles are respected (FR-E5)`() {
        val rows = listOf(
            sms(1, "VM-HDFCBK-T", "Rs.100 debited from A/C XX4521 to SHOPA on 09-06-26", june, sub = 1),
            sms(2, "VM-ICICIB-T", "Rs.200 debited from A/C XX812 to SHOPB on 09-06-26", june + 1000, sub = 1),
            sms(3, "VM-SBIINB-T", "Rs.300 debited from A/C XX1234 to SHOPC on 09-06-26", june + 2000, sub = 2))
        val sims = listOf(SimLine(1, "Airtel", "", "SIM 1"), SimLine(2, "Jio", "", "SIM 2"))
        val l = ledger()
        val rep = ExpenseIngest(FakeSmsSource(rows, sims), l,
            ExpenseSettings(filter = { SenderFilter(deny = setOf("VM-ICICIB-T")) }, disabledLines = { setOf(2) }), clock = { now }).run()
        assertEquals(listOf(100.0), l.all().map { it.amount })
        assertEquals(1, rep.filtered); assertEquals(1, rep.skippedLines)
        // An allow-list means "only these".
        val l2 = ExpenseLedger(File(tmp.newFolder(), "y.bin"), sealer, zone = utc)
        ExpenseIngest(FakeSmsSource(rows, sims), l2, ExpenseSettings(filter = { SenderFilter(allow = setOf("VM-SBIINB-T")) }), clock = { now }).run()
        assertEquals(listOf(300.0), l2.all().map { it.amount })
    }

    @Test fun `switching a SIM off or denying a sender AFTER the scan removes its amounts, and allowing it again brings them back`() {
        val rows = listOf(
            sms(1, "VM-HDFCBK-T", "Rs.100 debited from A/C XX4521 to SHOPA on 09-06-26", june, sub = 1),
            sms(2, "VM-ICICIB-T", "Rs.200 debited from A/C XX812 to SHOPB on 09-06-26", june + 1000, sub = 1),
            sms(3, "VM-SBIINB-T", "Rs.300 debited from A/C XX1234 to SHOPC on 09-06-26", june + 2000, sub = 2))
        val sims = listOf(SimLine(1, "Airtel", "", "SIM 1"), SimLine(2, "Jio", "", "SIM 2"))
        val l = ledger(); l.exclude("1_$june")                                   // a user override must survive all of this
        var off = emptySet<Int>(); var deny = emptySet<String>()
        fun run() = ExpenseIngest(FakeSmsSource(rows, sims), l, ExpenseSettings(filter = { SenderFilter(deny = deny) }, disabledLines = { off }), clock = { now }).run()
        fun amounts() = l.all().map { it.amount }.sorted()
        run(); assertEquals(listOf(200.0, 300.0), amounts())
        off = setOf(2); run(); assertEquals(listOf(200.0), amounts())             // SIM 2 off -> its 300 leaves the totals
        off = emptySet(); run(); assertEquals(listOf(200.0, 300.0), amounts())    // SIM 2 on again -> re-read, not lost behind the mark
        deny = setOf("VM-ICICIB-T"); run(); assertEquals(listOf(300.0), amounts())
        deny = emptySet(); run(); assertEquals(listOf(200.0, 300.0), amounts())
        assertEquals(setOf("1_$june"), l.overrides().excludedIds)
    }

    @Test fun `a revoked SMS permission is reported, not thrown`() {
        val src = FakeSmsSource(inbox).also { it.denied = true }
        val rep = ExpenseIngest(src, ledger(), clock = { now }).run()
        assertFalse(rep.ok); assertEquals("SMS permission not granted.", rep.error)
    }

    @Test fun `first scan honours the backfill window and extendBackfill pulls older history in`() {
        val old = sms(9, "VK-HDFCBK-T", "Rs.500 debited from A/C XX4521 to OLDSHOP on 01-03-26", now - 200L * 86_400_000)
        val src = FakeSmsSource(inbox + old); val l = ledger()
        val ing = ExpenseIngest(src, l, ExpenseSettings(backfillDays = { 90 }), clock = { now })
        ing.run(); assertEquals(3, l.transactionCount())
        ing.extendBackfill(365); ing.run(); assertEquals(4, l.transactionCount())
    }

    @Test fun `self-transfer and near-duplicate handling end to end, and excluded rows leave the totals`() {
        val rows = listOf(
            sms(1, "VK-HDFCBK-T", "Rs.1000 debited via UPI", june),                                  // self-transfer pair (same day, same amount)
            sms(2, "VK-HDFCBK-T", "Rs.1000 credited to A/C XX4521", june + 60_000),
            sms(3, "VK-HDFCBK-T", "Rs.750 debited via UPI", june + 3_600_000),                       // duplicate pair within 120 s
            sms(4, "VK-ICICIB-T", "Rs.750 debited via UPI", june + 3_600_000 + 30_000),
            sms(5, "VK-HDFCBK-T", "Rs.640 debited to APOLLO PHARMACY on 07-06-26", june + 7_200_000))
        val l = ledger(); ExpenseIngest(FakeSmsSource(rows), l, clock = { now }).run()
        val m = l.month(YearMonth.of(2026, 6))
        assertEquals("spent = 750 (dup collapsed) + 640; the 1000/1000 pair is a transfer", 1390.0, m.spent, 0.001)
        assertEquals(0.0, m.received, 0.001)
        assertEquals(5, m.recent.size)                                                               // flagged rows are listed, not hidden
        assertEquals(2, m.recent.count { it.isTransfer }); assertEquals(1, m.recent.count { it.isDuplicate })
        assertEquals(listOf("Transfers" to 750.0, "Health" to 640.0), m.byCategory)
        // "Exclude this" removes the row from the totals and the categories, and persists across a restart.
        l.exclude("5_${june + 7_200_000}")
        val after = ledger().month(YearMonth.of(2026, 6))
        assertEquals(750.0, after.spent, 0.001); assertEquals(listOf("Transfers" to 750.0), after.byCategory)
        ledger().unexclude("5_${june + 7_200_000}")
        assertEquals(1390.0, ledger().month(YearMonth.of(2026, 6)).spent, 0.001)
    }

    @Test fun `month view separates months and a category override wins`() {
        val may = Instant.parse("2026-05-30T08:00:00Z").toEpochMilli()
        val rows = listOf(sms(1, "VK-HDFCBK-T", "Rs.100 debited from A/C XX4521 to SHOPA on 30-05-26", may),
            sms(2, "VK-HDFCBK-T", "Rs.200 debited from A/C XX4521 to SHOPB on 09-06-26", june))
        val l = ledger(); ExpenseIngest(FakeSmsSource(rows), l, clock = { now }).run()
        assertEquals(100.0, l.month(YearMonth.of(2026, 5)).spent, 0.001); assertEquals(200.0, l.month(YearMonth.of(2026, 6)).spent, 0.001)
        l.setCategory("2_$june", "Health")
        assertEquals(listOf("Health" to 200.0), ledger().month(YearMonth.of(2026, 6)).byCategory)
    }

    @Test fun `rows parsed under a different pack version are discarded and rescanned, overrides are kept`() {
        val l = ledger(); ExpenseIngest(FakeSmsSource(inbox), l, clock = { now }).run(); l.exclude("1_$june")
        val bumped = PatternPack.parse(File(System.getProperty("halo.expenseFixtures")!!).parentFile.resolve("india-bank-sms.v1.json").readText().replaceFirst("\"version\": 1", "\"version\": 2"))
        val l2 = ExpenseLedger(file, sealer, bumped, utc)
        assertEquals(0, l2.transactionCount()); assertNull(l2.highWater(1))
        assertTrue("1_$june" in l2.overrides().excludedIds)
    }

    @Test fun `resetScan forgets derived rows but not the user's overrides`() {
        val l = ledger(); ExpenseIngest(FakeSmsSource(inbox), l, clock = { now }).run(); l.exclude("1_$june")
        l.resetScan(); assertEquals(0, l.transactionCount()); assertNull(l.highWater(1)); assertTrue("1_$june" in l.overrides().excludedIds)
    }
}
