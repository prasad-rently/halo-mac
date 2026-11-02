package app.halo.mobile.background

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Why background receiving was switched off for the user instead of started. Persisted so a refusal made while the app was closed is still explained on next open. */
enum class BackgroundRefusal(val stored: String) {
    /** Android would hide the persistent "Halo is listening" notification (permission denied, app or channel notifications off). */
    NOTIFICATIONS_OFF("notifications");
    companion object { fun from(s: String?) = values().firstOrNull { it.stored == s } }
}

/** Key/value storage behind [BackgroundSettings] — SharedPreferences on Android, a map in tests. */
interface SettingsBacking {
    fun getBoolean(key: String, default: Boolean): Boolean
    fun putBoolean(key: String, value: Boolean)
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

/**
 * The user's background-receiving choices as ONE process-wide, observable object. The Settings switch, the service and the
 * notification's Stop button all go through the same instance, so a change made by any of them is visible to the others
 * at once — before this, Stop wrote SharedPreferences and the switch only noticed on the next `onStart`.
 */
class BackgroundSettings(private val backing: SettingsBacking) {
    private val _enabled = MutableStateFlow(backing.getBoolean(KEY_ENABLED, false))
    private val _paused = MutableStateFlow(backing.getBoolean(KEY_PAUSED, false))
    private val _refusal = MutableStateFlow(BackgroundRefusal.from(backing.getString(KEY_REFUSAL)))

    /** The "Keep receiving in the background" switch. Default off (FR-B2). */
    val enabled: StateFlow<Boolean> = _enabled
    /** Android ended the service (e.g. the Android 15 six-hour `dataSync` limit); the UI says so. */
    val pausedBySystem: StateFlow<Boolean> = _paused
    /** Set when enabling was refused (or undone) because the persistent notification could not be shown. */
    val refusal: StateFlow<BackgroundRefusal?> = _refusal

    fun setEnabled(v: Boolean) { backing.putBoolean(KEY_ENABLED, v); _enabled.value = v }
    fun setPausedBySystem(v: Boolean) { backing.putBoolean(KEY_PAUSED, v); _paused.value = v }
    fun setRefusal(r: BackgroundRefusal?) { backing.putString(KEY_REFUSAL, r?.stored); _refusal.value = r }

    companion object {
        private const val KEY_ENABLED = "keepReceiving"
        private const val KEY_PAUSED = "pausedBySystem"
        private const val KEY_REFUSAL = "refusal"
        @Volatile private var instance: BackgroundSettings? = null
        fun get(ctx: Context): BackgroundSettings = instance ?: synchronized(this) {
            instance ?: BackgroundSettings(object : SettingsBacking {
                private val p = ctx.applicationContext.getSharedPreferences("halo.background", Context.MODE_PRIVATE)
                override fun getBoolean(key: String, default: Boolean) = p.getBoolean(key, default)
                override fun putBoolean(key: String, value: Boolean) { p.edit().putBoolean(key, value).apply() }
                override fun getString(key: String): String? = p.getString(key, null)
                override fun putString(key: String, value: String?) { p.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply() }
            }).also { instance = it }
        }
    }
}

/** Can the persistent "Halo is listening" notification actually be shown? */
fun interface NotificationGate { fun canShowPersistentNotice(): Boolean }

/**
 * The rules for turning background receiving on, with no Android types so they run in JVM tests.
 *
 * FR-B1 requires a persistent, explanatory notification. A foreground service whose notification Android hides is a
 * listener the user cannot see or stop, so **enabling is refused — not silently allowed — when it cannot be shown**:
 * the switch stays off, no service is started, and [BackgroundSettings.refusal] says why. The same check runs again
 * inside the service, because the permission can be revoked after the switch was turned on.
 */
class BackgroundController(private val settings: BackgroundSettings) {
    enum class Enable { STARTED, NEEDS_PERMISSION, REFUSED }

    /**
     * The user flipped the switch on. [canAskForPermission]: the system permission dialog can still be shown (API 33+, not yet granted).
     * STARTED ⇒ the caller starts the service. NEEDS_PERMISSION ⇒ explain, ask, then call this again. REFUSED ⇒ nothing was enabled.
     */
    fun requestEnable(gate: NotificationGate, canAskForPermission: Boolean): Enable {
        if (gate.canShowPersistentNotice()) {
            settings.setRefusal(null); settings.setPausedBySystem(false); settings.setEnabled(true)
            return Enable.STARTED
        }
        if (canAskForPermission) return Enable.NEEDS_PERMISSION
        refuse(); return Enable.REFUSED
    }

    /** The system permission dialog returned. A grant re-runs the normal path; a denial refuses (and the switch stays off). */
    fun onPermissionResult(gate: NotificationGate): Enable = requestEnable(gate, canAskForPermission = false)

    fun disable() { settings.setEnabled(false); settings.setRefusal(null) }

    /**
     * Called by the service once it is in the foreground. @return whether it may carry on running. False when the user
     * turned the switch off while it was starting, or when the notice cannot be shown (then the switch is turned off and the refusal recorded).
     */
    fun onServiceStarting(gate: NotificationGate): Boolean {
        if (!settings.enabled.value) return false
        if (!gate.canShowPersistentNotice()) { refuse(); return false }
        settings.setPausedBySystem(false); settings.setRefusal(null)
        return true
    }

    /** The notification's Stop button. Goes through the same observable settings the switch is bound to, so it flips at once. */
    fun stopRequested() { settings.setEnabled(false) }

    /** The app came to the front with the switch on. @return whether the caller should (re)start the service. */
    fun shouldStartOnForeground(gate: NotificationGate, serviceActive: Boolean): Boolean {
        if (settings.refusal.value != null && gate.canShowPersistentNotice()) settings.setRefusal(null)       // the user fixed it in Android settings
        if (!settings.enabled.value || settings.pausedBySystem.value || serviceActive) return false
        if (!gate.canShowPersistentNotice()) { refuse(); return false }
        return true
    }

    private fun refuse() { settings.setEnabled(false); settings.setRefusal(BackgroundRefusal.NOTIFICATIONS_OFF) }
}

/** The real check: notifications enabled for the app (this covers the API 33+ runtime permission) and the service channel not blocked. */
class AndroidNotificationGate(private val ctx: Context) : NotificationGate {
    override fun canShowPersistentNotice(): Boolean {
        val nm = ctx.applicationContext.getSystemService(android.app.NotificationManager::class.java) ?: return false
        Notifications.ensureChannels(ctx.applicationContext)
        if (!nm.areNotificationsEnabled()) return false
        val ch = nm.getNotificationChannel(Notifications.CHANNEL_SERVICE)
        return ch == null || ch.importance != android.app.NotificationManager.IMPORTANCE_NONE
    }

    companion object {
        /** The system dialog can still be shown: API 33+ and the runtime permission is not granted. (A permanently denied permission returns "denied" at once; the caller then refuses.) */
        fun canAskForPermission(ctx: Context): Boolean = android.os.Build.VERSION.SDK_INT >= 33 &&
            androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
    }
}
