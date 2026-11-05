package app.halo.mobile.design

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Halo design tokens for Android — the colours are the EXACT desktop values (Halo/DesignSystem/DesignSystem.swift,
 * docs/DESIGN_SYSTEM.md). Dark-only by design: there is no light scheme and nothing here adapts to the system theme.
 *
 * Two deliberate deviations, both for contrast (WCAG AA against the dark surfaces), documented in android/DESIGN.md:
 *  - [text3] is lighter than desktop's #4a5568 (2.5:1 on the surface — fails AA for any text).
 *  - Everything else (background, surfaces, accents, semantic colours, text, text2) is byte-identical to desktop.
 */
object HaloColors {
    val Background = Color(0xFF080C14)
    val Surface = Color(0xFF0D1220)
    val Surface2 = Color(0xFF131928)
    val Border = Color.White.copy(alpha = 0.07f)
    val Border2 = Color.White.copy(alpha = 0.12f)
    val Text = Color(0xFFF0F2F8)
    val Text2 = Color(0xFF8892A8)
    /** Desktop is #4a5568 (2.5:1, fails AA). Android uses #7A86A0 (5.1:1 on Surface). */
    val Text3 = Color(0xFF7A86A0)
    val Accent = Color(0xFF4F7CFF)
    val Accent2 = Color(0xFF7B5EA7)
    val Green = Color(0xFF22D97A)
    val Amber = Color(0xFFF5A623)
    val Red = Color(0xFFFF4D6A)
    /** URLs on the clipboard. */
    val Cyan = Color(0xFF00D4E8)
    /** Code on the clipboard. */
    val Purple = Color(0xFFB06CFF)

    /** The accent gradient used by primary buttons and the ring tip (accent → accent2, top-left to bottom-right). */
    val AccentGradient: Brush get() = Brush.linearGradient(listOf(Accent, Accent2))
}

object HaloShapes {
    val Card = RoundedCornerShape(14.dp)
    val Tile = RoundedCornerShape(12.dp)
    val Button = RoundedCornerShape(12.dp)
    val Chip = RoundedCornerShape(50)
}

object HaloSpacing {
    val ScreenH = 16.dp
    val Gap = 12.dp
    val GapSmall = 8.dp
    val CardPad = 14.dp
    /** Minimum touch target (Android accessibility guideline). */
    val MinTouch = 48.dp
}

/** Typography: system sans (Roboto) for UI and display, monospace for code. Sizes are `sp`, so they follow font scale. */
object HaloType {
    val Display = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 30.sp, lineHeight = 36.sp)
    val Title = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, lineHeight = 22.sp)
    val Body = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp)
    val Caption = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp)
    /** Small caps section label (rendered uppercase by HaloSectionHeader). */
    val Label = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 1.4.sp)
    val Number = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.ExtraBold, fontSize = 26.sp, lineHeight = 30.sp)
    val Mono = TextStyle(fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp)
}

private val HaloTypography = Typography(
    displayLarge = HaloType.Display, headlineLarge = HaloType.Display, headlineMedium = HaloType.Title,
    titleLarge = HaloType.Title, titleMedium = HaloType.Title.copy(fontSize = 15.sp), bodyLarge = HaloType.Body,
    bodyMedium = HaloType.Body, bodySmall = HaloType.Caption, labelLarge = HaloType.Body.copy(fontWeight = FontWeight.SemiBold),
    labelMedium = HaloType.Caption, labelSmall = HaloType.Label,
)

/** The Material3 dark-only scheme every Halo screen sits in. Wrap the activity content in this once. */
@Composable
fun HaloTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = HaloColors.Accent, onPrimary = Color.White,
            secondary = HaloColors.Accent2, onSecondary = Color.White,
            tertiary = HaloColors.Cyan,
            background = HaloColors.Background, onBackground = HaloColors.Text,
            surface = HaloColors.Surface, onSurface = HaloColors.Text,
            surfaceVariant = HaloColors.Surface2, onSurfaceVariant = HaloColors.Text2,
            surfaceContainer = HaloColors.Surface, surfaceContainerHigh = HaloColors.Surface2, surfaceContainerHighest = HaloColors.Surface2,
            error = HaloColors.Red, onError = Color.White,
            outline = HaloColors.Border2, outlineVariant = HaloColors.Border,
        ),
        typography = HaloTypography,
        content = content,
    )
}
