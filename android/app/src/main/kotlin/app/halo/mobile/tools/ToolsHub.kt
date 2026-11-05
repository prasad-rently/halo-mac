package app.halo.mobile.tools

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import app.halo.mobile.design.HaloCard
import app.halo.mobile.design.HaloColors
import app.halo.mobile.design.HaloIconBadge
import app.halo.mobile.design.HaloSubScreen
import app.halo.mobile.design.HaloType

/**
 * The Tools hub is not a bottom-bar tab: the bar is already five wide (Material's guidance is three to five). It is reached from
 * Home -> More -> Tools, and from "Transform…" on a Clipboard history item, drawn *in place of* the current tab's body so the bar
 * stays put. Back / any tab press closes it.
 */
@Composable
fun ToolsHost(vm: ToolsViewModel) {
    val tool = ToolsRegistry.byId(vm.toolId)
    HaloSubScreen(tool?.title ?: "Tools", vm::back, backDescription = if (tool == null) "Close tools" else "Back to tools", backTag = "tools.back", titleTag = "tools.title") {
        if (tool == null) ToolsList(vm) else tool.content()
    }
}

@Composable
private fun ToolsList(vm: ToolsViewModel) {
    // A tile grid like the desktop's Actions screen: icon + a title of up to three words, one tap to open.
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ToolsRegistry.tools.chunked(2).forEach { row ->
            Row(Modifier.height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { t ->
                    HaloCard(Modifier.weight(1f).fillMaxHeight().testTag("tools.item.${t.id}"), onClick = { vm.open(t.id) }) {
                        HaloIconBadge(t.icon, HaloColors.Accent, size = 40.dp, iconSize = 22.dp)
                        Spacer(Modifier.height(12.dp))
                        Text(t.title, color = HaloColors.Text, style = HaloType.Title)
                        Text(t.subtitle, color = HaloColors.Text2, style = HaloType.Caption)
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}
