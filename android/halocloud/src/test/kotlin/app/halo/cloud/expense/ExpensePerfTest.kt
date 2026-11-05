package app.halo.cloud.expense

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.time.ZoneId
import java.util.Random

/**
 * NFR: a 10 000-message inbox parses in < 10 s. THIS IS A JVM MEASUREMENT (the dev machine's JIT, software AES-GCM,
 * a tmp file) — NOT the emulator and not a real phone's CPU/Keystore/flash. It bounds the algorithm; it does not
 * prove the on-device number.
 */
class ExpensePerfTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun inbox(n: Int): List<app.halo.cloud.SmsRecord> {
        val r = Random(42); val base = 1_780_000_000_000L
        val shops = listOf("SWIGGY", "ZOMATO", "BLINKIT", "UBER", "APOLLO PHARMACY", "NETFLIX", "BIGBASKET", "INDIAN OIL PETROL PUMP")
        return (1..n).map { i ->
            val t = base + i * 60_000L; val amt = 10 + r.nextInt(5000)
            when (i % 10) {
                0, 1, 2 -> sms(i.toLong(), "VK-HDFCBK-T", "Rs.$amt.00 debited from A/C XX4521 to ${shops[r.nextInt(shops.size)]} on 09-06-26 via UPI Ref ${600000000000L + i}. Avl Bal Rs.${r.nextInt(90000)}.50", t)
                3 -> sms(i.toLong(), "VM-HDFCBK-S", "Your OTP is ${100000 + r.nextInt(899999)} for txn of Rs $amt. Do not share it with anyone.", t)
                4 -> sms(i.toLong(), "VM-AXISBK-P", "Flat Rs $amt cashback! Offer valid till Sunday. T&C apply. Click here http://x.in/$i", t)
                5 -> sms(i.toLong(), "VK-SBIINB-T", "Rs.$amt.00 credited to A/C XX1234 by NEFT-ACME on 09-06-26", t)
                6 -> sms(i.toLong(), "VK-HDFCBK-T", "Avl Bal in A/C XX4521 is Rs ${r.nextInt(90000)}.00 as on 12-Jun-26", t)
                7 -> sms(i.toLong(), "+9198765${10000 + r.nextInt(89999)}", "hey are we meeting at 6? bring Rs $amt", t)
                8 -> sms(i.toLong(), "AX-AMZNIN-S", "Your order $i has been delivered. Thank you for shopping", t)
                else -> sms(i.toLong(), "VK-ICICIB-T", "Rs.$amt spent on card XX9981 at ${shops[r.nextInt(shops.size)]} on 11-Jun-26. Avl limit Rs.45000", t)
            }
        }
    }

    @Test fun `10000 messages parse and seal in under 10 seconds, and a second run is near-instant`() {
        val rows = inbox(10_000)
        val src = FakeSmsSource(rows)
        val ledger = ExpenseLedger(File(tmp.root, "perf.bin"), AesGcmSealer(), zone = ZoneId.of("UTC"))
        val now = rows.last().dateMs + 1000
        val t0 = System.nanoTime()
        val rep = ExpenseIngest(src, ledger, ExpenseSettings(backfillDays = { 36500 }), clock = { now }).run()
        val ms1 = (System.nanoTime() - t0) / 1_000_000
        val t1 = System.nanoTime()
        val again = ExpenseIngest(src, ledger, ExpenseSettings(backfillDays = { 36500 }), clock = { now }).run()
        val ms2 = (System.nanoTime() - t1) / 1_000_000
        println("EXPENSE-PERF (JVM, not emulator): 10000 messages -> ${rep.parsed} txns, ${rep.unreadable} unreadable, ${ledger.all().size} after pipeline; first scan ${ms1} ms (incl. 20 sealed checkpoints), re-scan ${ms2} ms (read ${again.scanned} rows)")
        assertEquals(10_000, rep.scanned)
        assertTrue("expected ~50% of the inbox to be real transactions, got ${rep.parsed}", rep.parsed in 3000..6000)
        assertTrue("first scan took ${ms1} ms", ms1 < 10_000)
        assertTrue("incremental re-scan took ${ms2} ms and read ${again.scanned} rows", again.scanned <= 2 && ms2 < 2_000)
    }
}
