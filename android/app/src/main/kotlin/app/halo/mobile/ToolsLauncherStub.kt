package app.halo.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.layout.Column

/**
 * TEMPORARY entry point so a registered tool is reachable on this branch before the android-tools "Tools" hub lands.
 * Not a hub: a card that lists [ToolsRegistry.entries] and opens one full-screen. Delete this file and its single call in
 * SettingsScreen when the real hub is merged.
 */
@Composable
fun ToolsLauncherStub() {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    HaloCard {
        SectionLabel("Tools")
        Spacer(Modifier.height(8.dp))
        ToolsRegistry.entries.forEach { e ->
            OutlinedButton(onClick = { open = e.id }, modifier = Modifier.fillMaxWidth().padding(bottom = 6.dp)) { Text(e.title) }
        }
    }
    ToolsRegistry.entries.firstOrNull { it.id == open }?.let { e ->
        Dialog(onDismissRequest = { open = null }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            Box(Modifier.fillMaxSize().background(Halo.Background)) {
                Column(Modifier.fillMaxSize().padding(top = 8.dp)) {
                    TextButton(onClick = { open = null }) { Text("‹ Back", color = Halo.Accent) }
                    Box(Modifier.fillMaxSize()) { e.content() }
                }
            }
        }
    }
}
