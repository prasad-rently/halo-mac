package app.halo.mobile.expense

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import app.halo.cloud.SimLine
import app.halo.cloud.expense.MonthSummary
import app.halo.cloud.expense.ParsedTransaction
import app.halo.mobile.cloud.AndroidSmsSource
import app.halo.mobile.cloud.CloudPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.YearMonth

data class LineToggle(val line: SimLine, val enabled: Boolean)

data class ExpenseUi(
    val enabled: Boolean = false,
    val month: YearMonth = YearMonth.now(),
    val summary: MonthSummary? = null,
    val excluded: List<ParsedTransaction> = emptyList(),
    val scanning: Boolean = false,
    val status: String? = null,
    val error: String? = null,
    val lines: List<LineToggle> = emptyList(),
)

/** Reads the local sealed ledger and runs (cancellable) incremental scans of the inbox. No network anywhere. */
class ExpenseViewModel(app: Application) : AndroidViewModel(app) {
    private val prefs = ExpensePrefs(app)
    private val _ui = MutableStateFlow(ExpenseUi(enabled = prefs.enabled))
    val ui: StateFlow<ExpenseUi> = _ui.asStateFlow()
    private var scanJob: Job? = null

    init { refresh(); if (prefs.enabled) scan() }

    fun setEnabled(on: Boolean) {
        prefs.enabled = on
        _ui.update { it.copy(enabled = on, error = null) }
        if (on) scan() else cancelScan()
    }

    /** Re-read the ledger for the selected month (cheap; off the main thread because the first read decrypts a file). */
    fun refresh() {
        viewModelScope.launch(Dispatchers.Default) {
            val l = ExpenseRuntime.ledger(getApplication())
            val m = _ui.value.month
            val summary = l.month(m)
            val excluded = l.excludedTransactions()
            val lines = try { AndroidSmsSource(getApplication(), CloudPrefs(getApplication())).lines().map { LineToggle(it, it.subscriptionId !in prefs.disabledLines) } }
                        catch (e: Exception) { emptyList() }                       // no READ_SMS yet, or no phone-state permission
            _ui.update { it.copy(summary = summary, excluded = excluded, lines = lines) }
        }
    }

    fun scan() = launchScan { ExpenseRuntime.scan(getApplication(), it) }
    fun scanOlder(days: Int) = launchScan { ExpenseRuntime.extend(getApplication(), days, it) }
    fun cancelScan() { scanJob?.cancel() }

    private fun launchScan(block: (isCancelled: () -> Boolean) -> app.halo.cloud.expense.IngestReport) {
        if (scanJob?.isActive == true) return
        scanJob = viewModelScope.launch(Dispatchers.Default) {
            val me = coroutineContext[Job]
            _ui.update { it.copy(scanning = true, error = null) }
            val rep = try { block { me?.isActive == false } } catch (e: Exception) { app.halo.cloud.expense.IngestReport(error = e.message ?: "Scan failed.") }
            _ui.update {
                it.copy(scanning = false, error = rep.error,
                    status = if (rep.error != null) null else buildString {
                        append(if (rep.cancelled) "Stopped" else "Scanned"); append(" ${rep.scanned} message${if (rep.scanned == 1) "" else "s"}")
                        if (rep.parsed > 0) append(", ${rep.parsed} transaction${if (rep.parsed == 1) "" else "s"}")
                        if (rep.skippedLines > 0) append(" (${rep.skippedLines} SIM off)")
                    })
            }
            refresh()
        }
    }

    fun stepMonth(delta: Int) { _ui.update { it.copy(month = it.month.plusMonths(delta.toLong())) }; refresh() }
    fun exclude(id: String) { viewModelScope.launch(Dispatchers.Default) { ExpenseRuntime.ledger(getApplication()).exclude(id); refresh() } }
    fun unexclude(id: String) { viewModelScope.launch(Dispatchers.Default) { ExpenseRuntime.ledger(getApplication()).unexclude(id); refresh() } }
    fun setCategory(id: String, category: String) { viewModelScope.launch(Dispatchers.Default) { ExpenseRuntime.ledger(getApplication()).setCategory(id, category); refresh() } }

    fun setLineEnabled(subscriptionId: Int, enabled: Boolean) {
        prefs.disabledLines = if (enabled) prefs.disabledLines - subscriptionId else prefs.disabledLines + subscriptionId
        refresh()
    }

    val categoryNames: List<String> get() = app.halo.cloud.expense.PatternPack.indiaDefault.allCategoryNames

    /** Forget everything this feature stored on the phone. */
    fun wipe() {
        cancelScan()
        viewModelScope.launch(Dispatchers.Default) { ExpenseRuntime.wipe(getApplication()); prefs.enabled = false; _ui.update { ExpenseUi(enabled = false) } }
    }
}
