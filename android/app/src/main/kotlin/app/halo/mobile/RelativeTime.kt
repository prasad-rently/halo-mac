package app.halo.mobile

/** Small, pure time formatting for glanceable surfaces (unit-tested; no Android dependencies). */
object RelativeTime {
    private const val MIN = 60_000L; private const val HOUR = 60 * MIN; private const val DAY = 24 * HOUR

    /** "now", "2m", "3h", "5d" — for list rows and tiles. A future timestamp (clock skew) reads as "now". */
    fun compact(nowMs: Long, thenMs: Long): String {
        val d = nowMs - thenMs
        return when {
            d < MIN -> "now"
            d < HOUR -> "${d / MIN}m"
            d < DAY -> "${d / HOUR}h"
            else -> "${d / DAY}d"
        }
    }

    /** "just now", "2 min ago", "3 h ago", "5 d ago" — for sentences. */
    fun ago(nowMs: Long, thenMs: Long): String {
        val c = compact(nowMs, thenMs)
        return when {
            c == "now" -> "just now"
            c.endsWith("m") -> "${c.dropLast(1)} min ago"
            c.endsWith("h") -> "${c.dropLast(1)} h ago"
            else -> "${c.dropLast(1)} d ago"
        }
    }
}
