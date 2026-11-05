package app.halo.mobile.design

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * A full-screen destination that is NOT a bottom-bar tab (Tools hub, a tool, Spend...): a back arrow + title row, then [content]
 * filling the rest. System Back also calls [onBack]. The bottom bar stays put around it. [content] scrolls itself.
 */
@Composable
fun HaloSubScreen(title: String, onBack: () -> Unit, modifier: Modifier = Modifier, backDescription: String = "Back", backTag: String = "sub.back", titleTag: String = "sub.title", content: @Composable () -> Unit) {
    BackHandler(onBack = onBack)
    Column(modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            HaloIconButton(Icons.Filled.ArrowBack, backDescription, onBack, Modifier.testTag(backTag), tint = HaloColors.Text)
            Text(title, style = HaloType.Title, color = HaloColors.Text, modifier = Modifier.semantics { heading() }.testTag(titleTag))
        }
        Box(Modifier.weight(1f).fillMaxWidth()) { content() }
    }
}
