package app.halo.cloud

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** H-15: a pairing code's database host is checked against Firebase's own hosts; anything else is warned about. */
class FirebaseHostsTest {
    @Test fun `real Firebase database addresses are accepted, classic and regional`() {
        assertTrue(FirebaseHosts.isFirebaseDatabase("https://my-proj-default-rtdb.firebaseio.com"))
        assertTrue(FirebaseHosts.isFirebaseDatabase("https://my-proj-default-rtdb.europe-west1.firebasedatabase.app/"))
        assertTrue(FirebaseHosts.isFirebaseDatabase("https://MY-PROJ.FIREBASEIO.COM"))
        assertNull(FirebaseHosts.warning("https://my-proj-default-rtdb.asia-southeast1.firebasedatabase.app"))
    }

    @Test fun `look-alike and foreign hosts are warned about`() {
        for (u in listOf("https://evil-firebaseio.com", "https://firebaseio.com.evil.io", "https://firebaseio.com", "https://evil.example/x.firebaseio.com",
                         "https://user@evil.io/.firebaseio.com", "https://my-proj.firebaseio.com.attacker.net", "http://10.0.2.2:9199", "not a url", "")) {
            assertFalse("should not be trusted: $u", FirebaseHosts.isFirebaseDatabase(u))
            assertNotNull("should warn: $u", FirebaseHosts.warning(u))
        }
        assertTrue(FirebaseHosts.warning("https://evil.example")!!.contains("evil.example"))
    }
}
