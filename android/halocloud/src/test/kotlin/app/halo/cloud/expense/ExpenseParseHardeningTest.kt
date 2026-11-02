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
        // Balance sits NEARER the verb than the real amount, so only the balance-prefix filter keeps it out.
        assertEquals(1250.0, ok("VK-HDFCBK-T", "Debited from A/C XX4521. Avl Bal Rs.8420.10; txn amt Rs.1250").amount, 0.0)
        assertEquals(1250.0, ok("VK-HDFCBK-T", "Debited. Available balance INR 99,000.00 after txn of INR 1,250").amount, 0.0)
    }

    @Test fun `a credit is Income and never a spend category`() {
        val t = pipeline("VK-HDFCBK-T", "Rs.500 credited to A/C XX4521 by UPI from ZOMATO").single()
        assertEquals("Income", t.category); assertEquals(Direction.CREDIT, t.direction)
    }

    @Test fun `non-ASCII and empty input do not throw`() {
        TransactionParser.parse("", "", "x", 0, pack); SmsClassifier.classify("", "", pack)
        assertTrue(pipeline("VK-HDFCBK-T", "₹500 debited from A/C XX4521 😀 ñandú").single().amount == 500.0)
    }

    // ---- Follow-up: parser false positives (pack v2). Each of these was a wrong number or a wrong category on v1. ----
    private fun outcome(sender: String, body: String) = TransactionParser.parse(sender, body, "x", 0, pack)

    @Test fun `a balance-only alert never counts the balance as the debit - it is unreadable`() {
        for (b in listOf(
            "Your A/C XX1234 has been debited. Available balance in your account is INR 5,000.00",
            "Dear customer, A/C XX4521 was debited on 12-Jun. Avl bal after txn: Rs. 14,200.50",
            "A/C XX1234 debited today. Rs 5,000.00 is your available balance",
            "A/C XX1234 debited. Rs.5,000/- Avl Bal",
            "Debited. Closing balance is Rs 77,000",
        )) assertEquals("'$b'", ParseOutcome.Unreadable, outcome("VK-HDFCBK-T", b))
    }

    @Test fun `a balance word in an earlier sentence or for an earlier amount does not drop the real amount`() {
        assertEquals(700.0, ok("VK-HDFCBK-T", "Low avl bal alert. Rs 700 debited from A/C XX1234 at SHOPX on 10-06").amount, 0.0)
        assertEquals(200.0, ok("VK-HDFCBK-T", "Avl bal Rs 9,000 Rs 200 debited from A/C XX1234").amount, 0.0)
        assertEquals(40.0, ok("VK-HDFCBK-T", "Rs 40 debited. Your balance is Rs 5,000").amount, 0.0)       // the balance AFTER the verb still loses
    }

    @Test fun `a balance word that is only part of another word does not count`() {
        // "GLOBAL" contains BAL but does not start with it; the old substring rule would have dropped the amount.
        assertEquals(300.0, ok("VK-HDFCBK-T", "Debited at GLOBAL MART Rs 300 from A/C XX1234").amount, 0.0)
    }

    @Test fun `credit-card bill-payment acknowledgements are not transactions, a purchase on the card still is`() {
        for (b in listOf("Payment of Rs 1,200 received towards your credit card XX4321", "We have received your payment of Rs 1,200 towards your ICICI credit card XX4321. Thank you",
            "Thank you for the payment of Rs 8,500 on your SBI Card XX2210", "Payment of Rs.500 posted to your HDFC Bank Credit Card XX1111"))
            assertEquals("'$b'", ParseOutcome.NotTransaction, outcome("VK-HDFCBK-S", b))
        assertEquals(1200.0, ok("VK-HDFCBK-T", "Rs 1,200 spent on HDFC Bank Credit Card XX4321 at AMAZON on 12-Jun-26.").amount, 0.0)
        // incoming UPI money is not a card-bill payment
        assertEquals(Direction.CREDIT, ok("VK-HDFCBK-T", "Rs.500 credited to A/C XX1234 by UPI from RAHUL").direction)
    }

    @Test fun `delivery and shipping notices are not transactions, a delivery fee is`() {
        for (b in listOf("Your order has been delivered. Rs 799 paid via UPI", "Your order is out for delivery. Rs 499 paid via UPI", "Parcel shipped. Rs 250 paid via UPI", "Order dispatched, Rs 250 paid"))
            assertEquals("'$b'", ParseOutcome.NotTransaction, outcome("AX-FLPKRT-S", b))
        assertEquals(40.0, ok("VK-HDFCBK-T", "Rs 40 paid for delivery fee to SWIGGY via UPI").amount, 0.0)
    }

    @Test fun `short category triggers match whole words only`() {
        fun cat(m: String?, b: String) = pack.category(m, b, Direction.DEBIT)
        assertEquals("Transfers", cat(null, "Rs.500 debited from A/C XX1234 and credited to A/C XX9999 IMPS"))   // not Financial via CRED
        assertEquals("Other", cat("PUBLIC LIBRARY", "spent")); assertEquals("Other", cat("COLA POINT", "spent"))
        assertEquals("Other", cat("GOSSIP CORNER", "spent")); assertEquals("Other", cat("DECAFE ROASTERS", "spent"))
        assertEquals("Financial", cat("CRED", "paid")); assertEquals("Transport", cat("OLA", "paid")); assertEquals("Food & Dining", cat("CAFE COFFEE DAY", "spent"))
        assertEquals("Financial", cat("LIC", "premium paid")); assertEquals("Financial", cat(null, "Rs.500 debited for SIP e-mandate"))
        assertEquals("Transport", cat("OLACABS", "paid")); assertEquals("Food & Dining", cat("OFFICE CAFETERIA", "spent"))
    }

    @Test fun `containsWord needs a non-letter on both sides and finds a later valid occurrence`() {
        assertTrue(PatternPack.containsWord("PAID TO CRED.", "CRED")); assertTrue(PatternPack.containsWord("CRED", "CRED"))
        assertTrue(PatternPack.containsWord("1CRED2", "CRED"))                   // digits are not letters
        assertTrue(!PatternPack.containsWord("CREDITED", "CRED")); assertTrue(!PatternPack.containsWord("SCRED", "CRED"))
        assertTrue(PatternPack.containsWord("COLA POINT, OLA CABS", "OLA"))
    }

    @Test fun `the new reject patterns and balance regexes cannot be made to backtrack on hostile input`() {
        val hostile = "PAYMENT RECEIVED ".repeat(3000) + "CREDIT CARD " + "RS 1 ".repeat(2000) + "A".repeat(20_000)
        val t0 = System.nanoTime()
        outcome("VK-HDFCBK-T", hostile); outcome("VK-HDFCBK-T", "DEBITED " + "RS 5 BAL ".repeat(5000))
        assertTrue("took ${(System.nanoTime() - t0) / 1_000_000} ms", (System.nanoTime() - t0) / 1_000_000 < 3000)
    }
}
