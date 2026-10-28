package app.halo.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SimAttributionTest {
    @Test fun `a row naming an active SIM belongs to that line only`() {
        assertTrue(SimAttribution.owns(2, 2, setOf(1, 2)))
        assertFalse(SimAttribution.owns(1, 2, setOf(1, 2)))
    }

    @Test fun `a single-SIM phone that leaves sub_id unset still syncs its messages`() {
        // sub_id = -1 on every row is a real provider behaviour; with the one line being SIM 3, dropping them loses everything.
        assertTrue(SimAttribution.owns(3, -1, setOf(3)))
    }

    @Test fun `a row from a SIM that is no longer in the phone is not pinned on the current one`() {
        assertFalse(SimAttribution.owns(3, 7, setOf(3)))
    }

    @Test fun `with several SIMs an unattributed row is not guessed`() {
        assertFalse(SimAttribution.owns(1, -1, setOf(1, 2))); assertFalse(SimAttribution.owns(2, -1, setOf(1, 2)))
    }

    @Test fun `with no SIM list everything is the one synthetic line`() {
        assertTrue(SimAttribution.owns(-1, -1, emptySet())); assertTrue(SimAttribution.owns(-1, 5, emptySet()))
    }
}
