# Halo Android — design system

Dark-only, card-based, glanceable **utility** — the Halo desktop app, not an information screen. Code: `app/src/main/kotlin/app/halo/mobile/design/`.
Reference: `docs/DESIGN_SYSTEM.md`, `Halo/DesignSystem/DesignSystem.swift`.

## Use it

```kotlin
import app.halo.mobile.design.*
HaloScreen("Clipboard") {                     // title, 16dp gutters, 12dp rhythm, scrolls
    HaloCard(accentTop = HaloColors.Green) { HaloListRow("Synced", subtitle = "2 min ago", icon = Icons.Filled.Check) }
    HaloPrimaryButton("Send clipboard", onClick = { … }, icon = Icons.Filled.Send)
}
```
`HaloTheme { … }` wraps the activity once (already done in `MainActivity`). The old `app.halo.mobile.Halo` / `HaloCard` / `SectionLabel`
in `Theme.kt` are thin compatibility aliases; new code uses `HaloColors` and the design package.
See every component live: debug build, `adb shell am start -n app.halo.mobile/.MainActivity --ez gallery true`.

## Tokens (`HaloTokens.kt`) — exact desktop values
| Token | Hex | Use |
|---|---|---|
| Background | `#080c14` | screen |
| Surface | `#0d1220` | nested tiles, sheets, nav bar |
| Surface2 | `#131928` | cards |
| Accent / Accent2 | `#4f7cff` / `#7b5ea7` | primary actions (gradient pair) |
| Green / Amber / Red | `#22d97a` / `#f5a623` / `#ff4d6a` | healthy / warning / problem — always with a word or icon too |
| Cyan / Purple | `#00d4e8` / `#b06cff` | URL / code clipboard items |
| Text / Text2 | `#f0f2f8` / `#8892a8` | primary / secondary |
| Text3 | `#7a86a0` | tertiary. **Deviation:** desktop's `#4a5568` is 2.5:1 on the surface (fails AA); this is 5.1:1 |

Border = white 7%. Card corners 14dp, tiles 12dp, buttons 12dp, chips pill. Min touch target 48dp. All sizes `sp`/`dp`; nothing adapts to the system theme.

## Components
`HaloCard` · `HaloMetricTile` · `HaloRing` · `HaloSparkline` · `HaloSectionHeader` · `HaloChip` · `HaloPrimaryButton` (+`HaloGhostButton`) · `HaloIconButton` ·
`HaloListRow` · `HaloEmptyState` · `HaloInfoSheet` (+`HaloInfo`, `HaloInfoButton`) · `HaloStatusBadge`. Extras: `HaloScreen`, `HaloBanner`, `HaloToggleRow`, `HaloSwitch`, `HaloAvatar`, `HaloIconBadge`.
Every component has a `@Preview` (a local stand-in annotation — `ui-tooling-preview` is not in the offline Gradle cache; see `HaloPreview.kt` for the one-line switch).

## Copy rules
- Titles <= 3 words. Subtitle = one short line. Numbers and icons over sentences. No paragraphs on a primary surface.
- Long explanations, permission rationale, battery notes -> `HaloInfo` behind an (i) (`HaloInfoButton`) -> bottom sheet. **Never delete an honest limit; move it.**
- Empty state = icon + title + <= 1 line + <= 1 action (`HaloEmptyState`).
- Problems = `HaloBanner` (one line + one action; long reason in its (i)). State colour always paired with a word.
- Strings for the restyled screens live in `HaloCopy.kt`; don't scatter new literals through views.

## Do / don't
- DO one `HaloPrimaryButton` per card/screen; secondary = `HaloGhostButton`; icon-only = `HaloIconButton` with a `description` (TalkBack).
- DO keep `Modifier.testTag(...)` on anything a test or `uiautomator` script needs; restyling must not drop tags.
- DO let key numbers wrap (`HaloMetricTile` allows two lines) rather than truncate; check at font scale 1.3.
- DON'T use `Color(...)` literals in screens; DON'T add a light theme; DON'T use alpha-faded gradients to mean "disabled".
- DON'T show colour alone for state (colour-blind users): pair with text/icon.
