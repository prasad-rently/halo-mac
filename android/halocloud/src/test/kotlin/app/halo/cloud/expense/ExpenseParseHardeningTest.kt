package app.halo.cloud.expense

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Beyond the shared fixtures: the money-handling edges that must not regress. */
class ExpenseParseHardeningTest {
    private val pack = PatternPack.indiaDefault
    private fun ok(sender: String, body: String) = (TransactionParser.parse(sender, body, "x", 0, pack) as ParseOutcome.Ok).txn
    private fun pipeline(sender: String, body: String) = TransactionPipeline.run(listOf(SmsInput("m", sender, body, 1_000_000, SmsClassifier.classify(sender, body, pack))), pack).transactions

    @Test fun `Indian digit grouping parses as a single amount`() {
        assertEquals(125000.0, ok("VK-HDFCBK-T", "Rs 1,25,000.00 debited from A/C XX4521").amount, 0.0)
        assertEquals(10000000.0, ok("VK-HDFCBK-T", "INR 1,00,00,000 debited from A/C XX4521").amount, 0.0)
    }

    @Test fun `an OTP that mentions Rs and a transaction is never counted`() {
        for (b in listOf("Your OTP is 482913 for txn of Rs 2500. Do not share.", "Use 556677 to approve Rs.9999 debit. Never share", "123456 is your OTP. Rs 10 debited for verification"))
            assertTrue("'$b' must not become a transaction", pipeline("VM-HDFCBK-S", b).isEmpty())
    }

    @Test fun `promo and offer amounts never become spend`() {
        for ((s, b) in listOf("VM-AXISBK-P" to "Rs.999 debited", "VK-HDFCBK-T" to "Pre-approved loan offer Rs 5,00,000 debited? Apply now", "AD-MYNTRA-T" to "Spend Rs 1999 and get Rs 500 voucher. Sale!", "BZ-PAYZAP-S" to "Flat Rs 100 cashback. Click here"))
            assertTrue("'$b' must not become a transaction", pipeline(s, b).isEmpty())
    }

    @Test fun `balance figures are never the amount`() {
        assertEquals(1250.0, ok("VK-HDFCBK-T", "Rs.1250.00 debited from A/C XX4521. Avl Bal Rs.8420.10").amount, 0.0)
        assertEquals(1250.0, ok("VK-HDFCBK-T", "Avl Bal Rs.8420.10. Rs.1250 debited from A/C XX4521").amount, 0.0)
    }

    @Test fun `a credit is Income and never a spend category`() {
        val t = pipeline("VK-HDFCBK-T", "Rs.500 credited to A/C XX4521 by UPI from ZOMATO").single()
        assertEquals("Income", t.category); assertEquals(Direction.CREDIT, t.direction)
    }

    @Test fun `non-ASCII and empty input do not throw`() {
        TransactionParser.parse("", "", "x", 0, pack); SmsClassifier.classify("", "", pack)
        assertTrue(pipeline("VK-HDFCBK-T", "₹500 debited from A/C XX4521 😀 ñandú").single().amount == 500.0)
    }
}
