package app.halo.mobile.cloud

import android.content.Context
import app.halo.cloud.AuthEndpoints
import app.halo.cloud.CryptoService
import app.halo.cloud.FirebaseRtdbClient
import app.halo.mobile.BuildConfig
import java.util.Base64

/** A signed-in connection plus the data key, ready for the sync engines. */
class CloudSession(val profile: CloudProfile, val rtdb: FirebaseRtdbClient, val crypto: CryptoService, val deviceId: String, val deviceName: String)

/**
 * Debug builds only: a database at `http://10.0.2.2:<port>` (the emulator's name for the host Mac) is allowed
 * and its auth endpoints are served from the same host, so the whole sync path can be driven against a local
 * stand-in without a Firebase project. A release build ignores this entirely — it never talks to a non-https
 * database and never sends credentials anywhere but Google.
 */
object DebugEndpoints {
    private const val PREFIX = "http://10.0.2.2:"
    fun applies(databaseUrl: String) = BuildConfig.DEBUG && databaseUrl.startsWith(PREFIX)
    fun auth(databaseUrl: String): AuthEndpoints = if (applies(databaseUrl)) {
        val origin = "http://" + databaseUrl.substringAfter("://").substringBefore("/")
        AuthEndpoints("$origin/identitytoolkit/v1", "$origin/securetoken/v1")
    } else AuthEndpoints.GOOGLE
}

fun newRtdbClient(p: CloudProfile): FirebaseRtdbClient =
    FirebaseRtdbClient(p.config, p.auth, DebugEndpoints.auth(p.config.databaseURL), allowInsecureDatabase = DebugEndpoints.applies(p.config.databaseURL))

fun newRtdbClient(config: app.halo.cloud.FirebaseConfig, auth: app.halo.cloud.CloudAuthCredential): FirebaseRtdbClient =
    FirebaseRtdbClient(config, auth, DebugEndpoints.auth(config.databaseURL), allowInsecureDatabase = DebugEndpoints.applies(config.databaseURL))

/** One process-wide session: workers, the accessibility service and the UI all share a single sign-in. */
object CloudRuntime {
    private var cached: CloudSession? = null
    private var cachedFor: CloudProfile? = null

    /** Blocking (it may sign in). Returns null when the phone isn't paired. */
    @Synchronized fun session(ctx: Context): CloudSession? {
        val app = ctx.applicationContext
        val store = CloudStore(app)
        val profile = store.load() ?: run { cached = null; cachedFor = null; return null }
        cached?.let { if (cachedFor == profile) return it }
        val client = newRtdbClient(profile)
        client.signIn()
        val s = CloudSession(profile, client, CryptoService(Base64.getDecoder().decode(profile.keyBase64)), store.deviceId, store.deviceName)
        cached = s; cachedFor = profile
        return s
    }

    @Synchronized fun reset() { cached = null; cachedFor = null }
}
