package app.halo.mobile.expense

import android.content.Context
import app.halo.cloud.SenderFilter
import app.halo.cloud.expense.ExpenseIngest
import app.halo.cloud.expense.ExpenseLedger
import app.halo.cloud.expense.ExpenseSettings
import app.halo.cloud.expense.IngestReport
import app.halo.cloud.expense.Sealer
import app.halo.mobile.cloud.AndroidSmsSource
import app.halo.mobile.cloud.CloudPrefs
import app.halo.mobile.cloud.SecretBox
import java.io.File

/**
 * The expense ledger is sealed with the SAME Keystore seam as the cloud profile ([SecretBox]): the file on disk is
 * ciphertext and the key never leaves the Keystore. Nothing in this package talks to the network (FR-E3).
 */
object SecretBoxSealer : Sealer {
    override fun seal(plain: ByteArray): ByteArray = SecretBox.seal(plain)
    override fun open(blob: ByteArray): ByteArray = SecretBox.open(blob)
}

/** User choices for expense tracking. Nothing secret lives here (the amounts are in the sealed ledger, not here). */
class ExpensePrefs(ctx: Context) {
    private val p = ctx.getSharedPreferences("halo.expense.prefs", Context.MODE_PRIVATE)
    var enabled: Boolean get() = p.getBoolean("enabled", false); set(v) { p.edit().putBoolean("enabled", v).apply() }
    var backfillDays: Int get() = p.getInt("backfillDays", 90); set(v) { p.edit().putInt("backfillDays", v).apply() }
    /** SIM subscription ids switched OFF for expense tracking (FR-E5). */
    var disabledLines: Set<Int>
        get() = (p.getStringSet("disabledLines", emptySet()) ?: emptySet()).mapNotNull { it.toIntOrNull() }.toSet()
        set(v) { p.edit().putStringSet("disabledLines", v.map { it.toString() }.toSet()).apply() }
}

object ExpenseRuntime {
    private var ledger: ExpenseLedger? = null

    @Synchronized fun ledger(ctx: Context): ExpenseLedger =
        ledger ?: ExpenseLedger(File(ctx.applicationContext.filesDir, "expense-ledger.bin"), SecretBoxSealer).also { ledger = it }

    /** Blocking; call off the main thread. One scan at a time. */
    @Synchronized fun scan(ctx: Context, isCancelled: () -> Boolean): IngestReport {
        val app = ctx.applicationContext
        val prefs = ExpensePrefs(app); val cloud = CloudPrefs(app)
        val settings = ExpenseSettings(
            // FR-E5: the same sender allow/deny list as SMS sync, plus per-SIM toggles of its own.
            filter = { SenderFilter(cloud.allow, cloud.deny) },
            disabledLines = { prefs.disabledLines },
            backfillDays = { prefs.backfillDays })
        return ExpenseIngest(AndroidSmsSource(app, cloud), ledger(app), settings).run(isCancelled)
    }

    /** "Scan older history": widen the window and re-read. Idempotent by message id. */
    @Synchronized fun extend(ctx: Context, days: Int, isCancelled: () -> Boolean): IngestReport {
        val app = ctx.applicationContext
        val prefs = ExpensePrefs(app); val cloud = CloudPrefs(app)
        prefs.backfillDays = days
        ExpenseIngest(AndroidSmsSource(app, cloud), ledger(app), ExpenseSettings(backfillDays = { days })).extendBackfill(days)
        return scan(app, isCancelled)
    }

    @Synchronized fun wipe(ctx: Context) {
        ledger(ctx).resetScan()
        File(ctx.applicationContext.filesDir, "expense-ledger.bin").delete()
        ledger = null
    }
}
