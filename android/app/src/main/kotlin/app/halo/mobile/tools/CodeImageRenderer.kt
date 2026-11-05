package app.halo.mobile.tools

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import app.halo.tools.CodeLanguage
import app.halo.tools.CodeLayout
import app.halo.tools.CodeTheme
import app.halo.tools.TokenType

/**
 * Draws a code screenshot like the desktop's: theme gradient backdrop, a card, window dots, optional line numbers, token
 * colours. The layout rules (wrapping at 100 columns, 300-line cap with a "N more lines" footer) live in the pure
 * [CodeLayout]; this class only paints. The bitmap is shrunk (never cropped) until it is at most [MAX_PIXELS], so a 300-line
 * image can't ask the system for a 100 MB allocation.
 */
internal object CodeImageRenderer {
    private const val MAX_PIXELS = 9_000_000
    private const val FONT_PX = 13f
    private const val LINE_PX = 20f
    private const val PAD = 20f
    private const val MARGIN = 28f
    private const val CHROME = 36f

    data class Options(val language: CodeLanguage, val theme: CodeTheme, val lineNumbers: Boolean = true, val windowChrome: Boolean = true, val scale: Float = 2f)

    fun render(code: String, o: Options): Bitmap {
        val layout = CodeLayout.build(code, o.language)
        val rows = layout.lines
        val footer = if (layout.omittedLines > 0) "… ${layout.omittedLines} more line${if (layout.omittedLines == 1) "" else "s"} not shown" else null

        fun paint(scale: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.MONOSPACE; textSize = FONT_PX * scale }
        // Measure at scale 1 and size the canvas from that; draw with a canvas scale, so the layout is resolution independent.
        val m = paint(1f)
        val charW = m.measureText("M")
        val gutterChars = if (o.lineNumbers) maxOf(2, (layout.sourceLines.coerceAtMost(CodeLayout.DEFAULT_MAX_LINES)).toString().length) else 0
        val gutterW = if (o.lineNumbers) gutterChars * charW + 14f else 0f
        var widest = 0f
        for (r in rows) widest = maxOf(widest, r.segments.sumOf { m.measureText(it.text).toDouble() }.toFloat())
        footer?.let { widest = maxOf(widest, m.measureText(it)) }
        val cardW = PAD * 2 + gutterW + maxOf(widest, charW * 12)
        val bodyRows = rows.size + if (footer != null) 1 else 0
        val cardH = (if (o.windowChrome) CHROME else 0f) + PAD * 2 + maxOf(bodyRows, 1) * LINE_PX
        val w = cardW + MARGIN * 2; val h = cardH + MARGIN * 2

        var scale = o.scale
        while (w * scale * h * scale > MAX_PIXELS && scale > 0.5f) scale -= 0.25f
        val bmp = Bitmap.createBitmap(maxOf(1, (w * scale).toInt()), maxOf(1, (h * scale).toInt()), Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp); c.scale(scale, scale)

        val bg = Paint().apply { shader = LinearGradient(0f, 0f, w, h, o.theme.backgroundFrom.toInt(), o.theme.backgroundTo.toInt(), Shader.TileMode.CLAMP) }
        c.drawRect(0f, 0f, w, h, bg)
        val card = RectF(MARGIN, MARGIN, MARGIN + cardW, MARGIN + cardH)
        c.drawRoundRect(card, 12f, 12f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xE61E1E2E.toInt() })
        c.drawRoundRect(card, 12f, 12f, Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1f; color = 0x14FFFFFF })

        var y = MARGIN
        if (o.windowChrome) {
            val dot = Paint(Paint.ANTI_ALIAS_FLAG)
            intArrayOf(0xFFFF5F57.toInt(), 0xFFFEBC2E.toInt(), 0xFF28C840.toInt()).forEachIndexed { i, col -> dot.color = col; c.drawCircle(MARGIN + 18f + i * 20f, MARGIN + CHROME / 2, 6f, dot) }
            y += CHROME
        }
        val text = paint(1f); val num = paint(1f).apply { color = o.theme.lineNumber.toInt(); textAlign = Paint.Align.RIGHT }
        val baseline = LINE_PX * 0.72f
        y += PAD
        val x0 = MARGIN + PAD
        for (r in rows) {
            if (o.lineNumbers && r.number != null) c.drawText(r.number.toString(), x0 + gutterW - 14f, y + baseline, num)
            var x = x0 + gutterW
            for (seg in r.segments) {
                text.color = o.theme.color(seg.type).toInt()
                c.drawText(seg.text, x, y + baseline, text); x += text.measureText(seg.text)
            }
            y += LINE_PX
        }
        footer?.let { text.color = o.theme.comment.toInt(); c.drawText(it, x0 + gutterW, y + baseline, text) }
        return bmp
    }

    /** What a screen reader says about the preview. Describes the shape, never the code (which may be a secret). */
    fun describe(code: String, language: CodeLanguage): String {
        val n = code.replace("\r\n", "\n").trimEnd('\n').let { if (it.isEmpty()) 0 else it.count { c -> c == '\n' } + 1 }
        return "Preview of the code image: $n line${if (n == 1) "" else "s"} of ${language.label}"
    }
}
