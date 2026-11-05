package app.halo.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkGateTest {
    @Test fun offlineIsBlocked() {
        assertTrue(SpeedTestGate.decide(NetworkState(false, false, NetworkKind.NONE)) is SpeedTestGate.Blocked)
        assertTrue(SpeedTestGate.decide(NetworkState(true, false, NetworkKind.NONE)) is SpeedTestGate.Blocked)
    }
    @Test fun meteredOrCellularNeedsConfirmationAndStatesTheMegabytes() {
        for (n in listOf(NetworkState(true, true, NetworkKind.WIFI), NetworkState(true, false, NetworkKind.CELLULAR), NetworkState(true, true, NetworkKind.CELLULAR))) {
            val g = SpeedTestGate.decide(n); assertTrue("$n", g is SpeedTestGate.Confirm); assertTrue((g as SpeedTestGate.Confirm).message.contains("30 MB"))
        }
    }
    @Test fun unmeteredWifiAndEthernetGo() {
        assertEquals(SpeedTestGate.Go, SpeedTestGate.decide(NetworkState(true, false, NetworkKind.WIFI)))
        assertEquals(SpeedTestGate.Go, SpeedTestGate.decide(NetworkState(true, false, NetworkKind.ETHERNET)))
    }
    @Test fun theNoticeTracksThePlanSize() {
        assertTrue((SpeedTestGate.decide(NetworkState(true, true, NetworkKind.WIFI), SpeedPlan(downloadBytes = 100_000_000, uploadBytes = 20_000_000)) as SpeedTestGate.Confirm).message.contains("120 MB"))
    }
}
