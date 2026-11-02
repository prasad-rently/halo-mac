package app.halo.mobile

import app.halo.mobile.background.BackgroundController
import app.halo.mobile.background.BackgroundController.Enable
import app.halo.mobile.background.BackgroundRefusal
import app.halo.mobile.background.BackgroundSettings
import app.halo.mobile.background.NotificationGate
import app.halo.mobile.background.SettingsBacking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** F-055 FR-B1/B5 follow-ups: the persistent notification is required, and the Settings switch tells the truth. */
class BackgroundControlTest {
    private class MapBacking : SettingsBacking {
        val m = HashMap<String, Any?>()
        override fun getBoolean(key: String, default: Boolean) = m[key] as? Boolean ?: default
        override fun putBoolean(key: String, value: Boolean) { m[key] = value }
        override fun getString(key: String) = m[key] as? String
        override fun putString(key: String, value: String?) { if (value == null) m.remove(key) else m[key] = value }
    }
    private class Gate(var ok: Boolean) : NotificationGate { override fun canShowPersistentNotice() = ok }
    private fun rig(): Triple<MapBacking, BackgroundSettings, BackgroundController> {
        val b = MapBacking(); val s = BackgroundSettings(b); return Triple(b, s, BackgroundController(s))
    }

    // ── FR-B1: no silent start without the notification ─────────────────────────────────────────

    @Test fun `enabling with notifications available turns it on and clears any old refusal`() {
        val (b, s, c) = rig(); s.setRefusal(BackgroundRefusal.NOTIFICATIONS_OFF)
        assertEquals(Enable.STARTED, c.requestEnable(Gate(true), canAskForPermission = true))
        assertTrue(s.enabled.value); assertNull(s.refusal.value); assertEquals(true, b.m["keepReceiving"])
    }

    @Test fun `with the permission missing but askable it asks first and enables nothing yet`() {
        val (b, s, c) = rig()
        assertEquals(Enable.NEEDS_PERMISSION, c.requestEnable(Gate(false), canAskForPermission = true))
        assertFalse("not enabled before the person has answered", s.enabled.value); assertEquals(null, b.m["keepReceiving"] as Boolean?)
        assertNull(s.refusal.value)
    }

    @Test fun `a denial refuses - the switch stays off, no service may start, and the reason is recorded`() {
        val (_, s, c) = rig()
        c.requestEnable(Gate(false), canAskForPermission = true)
        assertEquals(Enable.REFUSED, c.onPermissionResult(Gate(false)))
        assertFalse(s.enabled.value); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, s.refusal.value)
        // and a later grant (the person fixed it in Android settings) works through the same path
        assertEquals(Enable.STARTED, c.onPermissionResult(Gate(true)))
        assertTrue(s.enabled.value); assertNull(s.refusal.value)
    }

    @Test fun `when the permission cannot be asked for (blocked app or channel, permanent denial) enabling is refused outright`() {
        val (_, s, c) = rig()
        assertEquals(Enable.REFUSED, c.requestEnable(Gate(false), canAskForPermission = false))
        assertFalse(s.enabled.value); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, s.refusal.value)
    }

    @Test fun `the service re-checks - permission revoked after the switch was on means it does not run and the switch is turned off`() {
        val (b, s, c) = rig(); c.requestEnable(Gate(true), false); assertTrue(s.enabled.value)
        val mayRun = c.onServiceStarting(Gate(false))                       // revoked since
        assertFalse("must not carry on listening with the notice hidden", mayRun)
        assertFalse(s.enabled.value); assertEquals(false, b.m["keepReceiving"]); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, s.refusal.value)
    }

    @Test fun `the service runs when the notice can be shown, and a toggle turned off in flight stops it`() {
        val (_, s, c) = rig(); c.requestEnable(Gate(true), false); s.setPausedBySystem(true)
        assertTrue(c.onServiceStarting(Gate(true))); assertFalse("a successful start clears the system-paused note", s.pausedBySystem.value)
        c.disable()
        assertFalse(c.onServiceStarting(Gate(true)))
        assertNull("turning it off by hand is not a refusal", s.refusal.value)
    }

    @Test fun `coming to the front restarts the service only when it is wanted, not paused, not already running, and allowed`() {
        val (_, s, c) = rig()
        assertFalse("off", c.shouldStartOnForeground(Gate(true), serviceActive = false))
        c.requestEnable(Gate(true), false)
        assertTrue(c.shouldStartOnForeground(Gate(true), serviceActive = false))
        assertFalse("already running", c.shouldStartOnForeground(Gate(true), serviceActive = true))
        s.setPausedBySystem(true); assertFalse("Android paused it: the person re-enables", c.shouldStartOnForeground(Gate(true), false)); s.setPausedBySystem(false)
        assertFalse("allowed? no: it refuses instead of starting", c.shouldStartOnForeground(Gate(false), false))
        assertFalse(s.enabled.value); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, s.refusal.value)
    }

    @Test fun `notifications turned off while the service is already running stop it on the next foreground, and say why`() {
        val (_, s, c) = rig(); c.requestEnable(Gate(true), false)
        assertFalse("still allowed: leave it running", c.shouldStopOnForeground(Gate(true), serviceActive = true))
        assertTrue(s.enabled.value)
        assertFalse("not running: nothing to stop", c.shouldStopOnForeground(Gate(false), serviceActive = false))
        assertTrue("running with the notice hidden: stop it", c.shouldStopOnForeground(Gate(false), serviceActive = true))
        assertFalse(s.enabled.value); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, s.refusal.value)
        assertFalse("already off: no repeat", c.shouldStopOnForeground(Gate(false), serviceActive = true))
    }

    @Test fun `a stale refusal clears itself once the person has fixed notifications`() {
        val (_, s, c) = rig(); s.setRefusal(BackgroundRefusal.NOTIFICATIONS_OFF)
        c.shouldStartOnForeground(Gate(true), false)
        assertNull(s.refusal.value)
    }

    @Test fun `a refusal made while the app was closed is still there when it next opens`() {
        val (b, _, c) = rig(); c.requestEnable(Gate(true), false); c.onServiceStarting(Gate(false))
        val reopened = BackgroundSettings(b)                                  // new process, same storage
        assertFalse(reopened.enabled.value); assertEquals(BackgroundRefusal.NOTIFICATIONS_OFF, reopened.refusal.value)
    }

    // ── the notification's Stop button vs the Settings switch ───────────────────────────────────

    @Test fun `Stop from the notification flips the observable switch state at once`() {
        val (b, s, c) = rig(); c.requestEnable(Gate(true), false)
        val seen = ArrayList<Boolean>()
        // what the ViewModel exposes to the switch is this very flow; read it the way a collector would
        seen.add(s.enabled.value)
        c.stopRequested()
        seen.add(s.enabled.value)
        assertEquals(listOf(true, false), seen)
        assertEquals("and it is persisted", false, b.m["keepReceiving"])
    }

    @Test fun `every writer shares one object, so the service's Stop is visible to the screen without a restart`() {
        val b = MapBacking(); val shared = BackgroundSettings(b)
        val screenView = shared.enabled                                       // the ViewModel holds this StateFlow
        BackgroundController(shared).requestEnable(Gate(true), false)
        assertTrue(screenView.value)
        BackgroundController(shared).stopRequested()                          // the service constructs its own controller over the same settings
        assertFalse(screenView.value)
    }
}
