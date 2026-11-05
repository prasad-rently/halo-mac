package app.halo.mobile.design

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Stand-in for `androidx.compose.ui.tooling.preview.Preview`. The real annotation lives in `ui-tooling-preview`, which
 * is not in this project's offline Gradle cache, so adding the dependency would break `--offline` builds. Every
 * design-system component has one of these; to light them up in Android Studio, add
 * `implementation("androidx.compose.ui:ui-tooling-preview")` and change the import in this package from this annotation
 * to the androidx one (same name, same usage). Until then `HaloDesignGallery` (debug build: launch MainActivity with
 * `--ez gallery true`) renders all of them on a device.
 */
@Target(AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.SOURCE)
annotation class Preview(val name: String = "", val fontScale: Float = 1f)

/** Wraps a preview in the theme on the app background, so a preview looks like it does in the app. */
@Composable
internal fun PreviewSurface(content: @Composable () -> Unit) {
    HaloTheme { Box(Modifier.background(HaloColors.Background).padding(12.dp)) { content() } }
}
