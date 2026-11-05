package app.halo.mobile.tools

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Build
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.halo.mobile.Halo
import app.halo.mobile.HaloCard

/**
 * The Tools hub is not a bottom-bar tab. The bar is already five wide, and Material's guidance is three to five
 * destinations — a sixth would shrink every label on a phone and give the Photos tool the same problem. Instead the hub
 * is reached from two places that already sit next to the work (the Clipboard tab, where "Transform…" on a history item
 * also lands here, and Settings), drawn *in place of* the current tab's body so the bar stays put, and Back / any tab press closes it.
 */
@Composable
fun ToolsHost(vm: ToolsViewModel) {
    val tool = ToolsRegistry.byId(vm.toolId)
    BackHandler { vm.back() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = vm::back, modifier = Modifier.testTag("tools.back")) { Icon(Icons.Filled.ArrowBack, contentDescription = if (tool == null) "Close tools" else "Back to tools", tint = Halo.Text) }
            Text(tool?.title ?: "Tools", color = Halo.Text, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.testTag("tools.title"))
        }
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if (tool == null) ToolsList(vm) else tool.content()
        }
    }
}

@Composable
private fun ToolsList(vm: ToolsViewModel) {
    // A tile grid like the desktop's Actions screen: icon + a title of up to three words, one tap to open.
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ToolsRegistry.tools.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { t ->
                    Column(Modifier.weight(1f).heightIn(min = 112.dp).clip(RoundedCornerShape(14.dp)).background(Halo.Surface)
                        .clickable(role = Role.Button, onClickLabel = "Open ${t.title}") { vm.open(t.id) }.padding(16.dp).testTag("tools.item.${t.id}"), verticalArrangement = Arrangement.SpaceBetween) {
                        Icon(t.icon, contentDescription = null, tint = Halo.Accent, modifier = Modifier.size(28.dp))
                        Column { Text(t.title, color = Halo.Text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold); Text(t.subtitle, color = Halo.Text3, fontSize = 12.sp) }
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** The card that opens the hub. Dropped into the Clipboard and Settings tabs. */
@Composable
fun ToolsEntryCard(vm: ToolsViewModel, modifier: Modifier = Modifier) {
    HaloCard(modifier.clickable(role = Role.Button, onClickLabel = "Open tools") { vm.openHub() }.testTag("tools.entry")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Build, contentDescription = null, tint = Halo.Accent, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text("Tools", color = Halo.Text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Text("Transform · Code Image · Speed Test", color = Halo.Text3, fontSize = 11.sp)
            }
        }
    }
}
