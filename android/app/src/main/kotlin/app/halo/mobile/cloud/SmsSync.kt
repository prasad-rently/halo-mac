package app.halo.mobile.cloud

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import app.halo.cloud.SenderFilter
import app.halo.cloud.SmsSyncEngine
import app.halo.cloud.SyncReport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.TimeUnit

/** Runs one SMS sync pass and records what happened. The worker, the receiver and "Sync now" all come here. */
object SmsSyncRunner {
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running
    private val _tick = MutableStateFlow(0)
    /** Bumped after every run so the UI re-reads the last-sync facts. */
    val tick: StateFlow<Int> = _tick

    private const val RECONCILE_EVERY_MS = 6 * 3_600_000L

    @Synchronized fun run(ctx: Context, forceReconcile: Boolean = false): SyncReport {
        val prefs = CloudPrefs(ctx)
        if (!prefs.smsEnabled) return SyncReport(error = "SMS sync is off.")
        _running.value = true
        try {
            val session = try { CloudRuntime.session(ctx) } catch (e: Exception) { return finish(prefs, SyncReport.fromFailure(e)) }
                ?: return finish(prefs, SyncReport(error = "This phone isn't paired yet."))
            val engine = SmsSyncEngine(
                rtdb = session.rtdb, crypto = session.crypto, deviceId = session.deviceId, deviceName = session.deviceName,
                source = AndroidSmsSource(ctx, prefs), state = PrefsSyncState(ctx),
                filter = { SenderFilter(prefs.allow, prefs.deny) }, backfillDays = { prefs.backfillDays },
                pairingEpoch = session.profile.epoch,
            )
            var report = try { engine.sync() } catch (e: Exception) { SyncReport.fromFailure(e) }
            if (report.error == null && (forceReconcile || System.currentTimeMillis() - prefs.lastReconcileAt > RECONCILE_EVERY_MS)) {
                val r = try { engine.reconcile() } catch (e: Exception) { SyncReport.fromFailure(e) }
                if (r.error == null) prefs.lastReconcileAt = System.currentTimeMillis()
                report = report.copy(removedFromCloud = r.removedFromCloud, failed = report.failed + r.failed, error = report.error ?: r.error, retryable = report.retryable || r.retryable)
            }
            return finish(prefs, report)
        } finally { _running.value = false }
    }

    /** "Sync older history" — widen the window, then run. */
    fun extend(ctx: Context, days: Int): SyncReport {
        val prefs = CloudPrefs(ctx)
        // Everything here can throw (sign-in over a bad network, READ_SMS revoked since the screen opened), and the
        // caller is a bare viewModelScope.launch — an escaped exception would take the whole app down.
        return try {
            val session = CloudRuntime.session(ctx) ?: return SyncReport(error = "This phone isn't paired yet.")
            prefs.backfillDays = days
            SmsSyncEngine(session.rtdb, session.crypto, session.deviceId, session.deviceName, AndroidSmsSource(ctx, prefs), PrefsSyncState(ctx), pairingEpoch = session.profile.epoch).extendBackfill(days)
            run(ctx)
        } catch (e: Exception) { SyncReport.fromFailure(e) }
    }

    private fun finish(prefs: CloudPrefs, r: SyncReport): SyncReport {
        prefs.lastSyncAt = System.currentTimeMillis()
        prefs.lastSyncError = r.error ?: if (r.failed > 0) "${r.failed} message(s) couldn't be uploaded — will retry." else null
        prefs.lastSyncSummary = buildString {
            append("${r.uploaded} uploaded")
            if (r.skippedByFilter > 0) append(", ${r.skippedByFilter} filtered")
            if (r.skippedDisabledLines > 0) append(", ${r.skippedDisabledLines} line(s) off")
            if (r.removedFromCloud > 0) append(", ${r.removedFromCloud} removed")
        }
        _tick.value = _tick.value + 1
        return r
    }
}

class SmsSyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val r = SmsSyncRunner.run(applicationContext)
        // Retry with backoff only for transient trouble (failed uploads, a dropped connection); a missing
        // permission or an unpaired phone won't fix itself. A pass that died on an exception used to return
        // success here, so a live SMS that met a flaky network waited for the 15-minute safety-net pass.
        return if ((r.failed > 0 && r.error == null) || r.retryable) Result.retry() else Result.success()
    }
}

object SyncScheduler {
    private const val PERIODIC = "halo.sms.periodic"
    private const val SOON = "halo.sms.soon"
    private val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Safety net + on-open: WorkManager's floor for periodic work is 15 minutes (D8). */
    fun schedulePeriodic(ctx: Context) {
        val req = PeriodicWorkRequestBuilder<SmsSyncWorker>(15, TimeUnit.MINUTES).setConstraints(network)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        WorkManager.getInstance(ctx).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, req)
    }

    /**
     * Real-time path. The delay is not cosmetic (D16): SMS_RECEIVED can fire before the row is queryable through
     * the provider, so syncing immediately would routinely miss the very message that woke us.
     */
    fun enqueueSoon(ctx: Context, delayMs: Long = 1_200) {
        val req = OneTimeWorkRequestBuilder<SmsSyncWorker>().setInitialDelay(delayMs, TimeUnit.MILLISECONDS).setConstraints(network)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        WorkManager.getInstance(ctx).enqueueUniqueWork(SOON, ExistingWorkPolicy.REPLACE, req)
    }

    fun cancelAll(ctx: Context) { WorkManager.getInstance(ctx).cancelUniqueWork(PERIODIC); WorkManager.getInstance(ctx).cancelUniqueWork(SOON) }
}
