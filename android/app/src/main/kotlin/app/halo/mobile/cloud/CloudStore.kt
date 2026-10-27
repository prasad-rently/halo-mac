package app.halo.mobile.cloud

import android.content.Context
import android.os.Build
import app.halo.cloud.CloudAuthCredential
import app.halo.cloud.FirebaseConfig
import app.halo.cloud.SyncState
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/**
 * Everything needed to reach the user's Firebase and read what is in it. [keyBase64] is the DERIVED data
 * key, not the passphrase: background sync has to work with the app closed, and keeping the derived key
 * (Keystore-sealed) means the passphrase itself is never stored anywhere on the phone.
 */
@Serializable
data class CloudProfile(
    val config: FirebaseConfig,
    val auth: CloudAuthCredential,
    val saltBase64: String,
    val iterations: Int,
    val keyBase64: String,
)

private val json = Json { ignoreUnknownKeys = true }

class CloudStore(private val ctx: Context) {
    private val file get() = File(ctx.filesDir, "cloud-profile.bin")
    private val prefs get() = ctx.getSharedPreferences("halo.cloud.identity", Context.MODE_PRIVATE)

    fun load(): CloudProfile? = try {
        if (!file.exists()) null else json.decodeFromString(CloudProfile.serializer(), String(SecretBox.open(file.readBytes()), Charsets.UTF_8))
    } catch (e: Exception) { null }       // an unreadable profile (Keystore reset, corrupt file) means "not paired"

    fun save(p: CloudProfile) { file.writeBytes(SecretBox.seal(json.encodeToString(CloudProfile.serializer(), p).toByteArray(Charsets.UTF_8))) }

    fun clear() { file.delete() }

    /** Stable across re-pairing so this phone's lines and messages stay under one `deviceId` in the cloud. */
    val deviceId: String get() = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("deviceId", it).apply() }

    var deviceName: String
        get() = prefs.getString("deviceName", null) ?: (Build.MODEL ?: "Android")
        set(v) { prefs.edit().putString("deviceName", v.trim().ifEmpty { Build.MODEL ?: "Android" }).apply() }
}

/** User choices + last-run facts. Nothing secret lives here. */
class CloudPrefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("halo.cloud.prefs", Context.MODE_PRIVATE)

    var smsEnabled: Boolean get() = p.getBoolean("smsEnabled", false); set(v) { p.edit().putBoolean("smsEnabled", v).apply() }
    var backfillDays: Int get() = p.getInt("backfillDays", 90); set(v) { p.edit().putInt("backfillDays", v).apply() }
    var allow: Set<String> get() = p.getStringSet("smsAllow", emptySet()) ?: emptySet(); set(v) { p.edit().putStringSet("smsAllow", v).apply() }
    var deny: Set<String> get() = p.getStringSet("smsDeny", emptySet()) ?: emptySet(); set(v) { p.edit().putStringSet("smsDeny", v).apply() }

    var clipboardEnabled: Boolean get() = p.getBoolean("clipEnabled", false); set(v) { p.edit().putBoolean("clipEnabled", v).apply() }
    var clipboardFilter: Boolean get() = p.getBoolean("clipFilter", false); set(v) { p.edit().putBoolean("clipFilter", v).apply() }

    /** The user's label / own number for a SIM when the carrier doesn't provide one (D20). */
    fun lineLabel(sub: Int): String? = p.getString("lineLabel.$sub", null)
    fun lineNumber(sub: Int): String? = p.getString("lineNumber.$sub", null)
    fun setLine(sub: Int, label: String, number: String) { p.edit().putString("lineLabel.$sub", label.trim()).putString("lineNumber.$sub", number.trim()).apply() }

    var lastSyncAt: Long get() = p.getLong("lastSyncAt", 0); set(v) { p.edit().putLong("lastSyncAt", v).apply() }
    var lastSyncSummary: String get() = p.getString("lastSyncSummary", "") ?: ""; set(v) { p.edit().putString("lastSyncSummary", v).apply() }
    var lastSyncError: String? get() = p.getString("lastSyncError", null); set(v) { p.edit().putString("lastSyncError", v).apply() }
    var lastReconcileAt: Long get() = p.getLong("lastReconcileAt", 0); set(v) { p.edit().putLong("lastReconcileAt", v).apply() }

    fun clearAll() { p.edit().clear().apply() }
}

/** The per-line high-water marks, kept across process death. */
class PrefsSyncState(ctx: Context) : SyncState {
    private val p = ctx.getSharedPreferences("halo.cloud.syncstate", Context.MODE_PRIVATE)
    override fun highWater(subscriptionId: Int): Long? = if (p.contains("hw.$subscriptionId")) p.getLong("hw.$subscriptionId", 0) else null
    override fun setHighWater(subscriptionId: Int, dateMs: Long) { p.edit().putLong("hw.$subscriptionId", dateMs).apply() }
    override fun clear() { p.edit().clear().apply() }
}
