package app.halo.mobile.tools

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.mobile.Halo
import app.halo.mobile.design.HaloEmptyState
import app.halo.mobile.design.HaloIconButton
import app.halo.mobile.design.HaloInfo
import app.halo.mobile.design.HaloInfoSheet
import app.halo.mobile.design.HaloListRow
import app.halo.mobile.design.HaloPrimaryButton
import app.halo.mobile.design.HaloStatusBadge
import app.halo.mobile.HaloCard
import app.halo.mobile.SectionLabel
import app.halo.mobile.cloud.ClipboardHistory
import app.halo.tools.TextTransforms
import app.halo.tools.TransformId
import app.halo.tools.TransformResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val DISPLAY_CAP = 20_000

/** Transform: a big input card, a row of transform chips, a result card with Copy / Send. Explanations live behind (i). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TransformScreen() {
    val vm: ToolsViewModel = viewModel()
    val s = vm.transform
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val history by ClipboardHistory.get(ctx).items.collectAsStateWithLifecycle()
    var showHistory by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf(false) }
    val qr: Bitmap? = remember(s.result) { (s.result as? TransformResult.Qr)?.let { QrImage.bitmap(it.payload) } }     // derived, so a rotation redraws it
    val saveAs = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { uri ->
        val bmp = qr
        if (uri != null && bmp != null) scope.launch { val ok = withContext(Dispatchers.IO) { ImageExport.writeTo(ctx, uri, bmp) }; s.notice = if (ok) "Saved" else "Couldn't save" }
    }
    fun transformNow(id: TransformId) { s.selected = id; s.notice = null; s.result = TextTransforms.apply(id, s.input) }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel("Input", Modifier.weight(1f))
                HaloIconButton(Icons.Filled.Info, "About Transform", { info = true }, Modifier.testTag("tools.transform.info"))
            }
            OutlinedTextField(s.input, { s.load(it) }, placeholder = { Text("Text to transform") }, minLines = 4, maxLines = 8,
                modifier = Modifier.fillMaxWidth().testTag("tools.transform.input"))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { ToolsClipboard.read(ctx)?.let { s.load(it) } ?: kotlin.run { s.notice = "Clipboard empty or blocked" } }, modifier = Modifier.testTag("tools.transform.paste")) { Text("Paste") }
                TextButton(onClick = { showHistory = !showHistory }, enabled = history.isNotEmpty(), modifier = Modifier.testTag("tools.transform.history")) { Text("History") }
                TextButton(onClick = { s.clear() }, enabled = s.input.isNotEmpty() || s.result != null) { Text("Clear") }
            }
            s.notice?.let { Text(it, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("tools.transform.notice")) }
            if (showHistory) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                history.take(20).forEach { item -> HaloListRow(item.text.replace('\n', ' '), Modifier.testTag("tools.transform.historyItem"), onClick = { s.load(item.text); showHistory = false }) }
            }
        }

        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TransformId.values().forEach { id ->
                HaloChip(id.title, s.selected == id, { transformNow(id) }, Modifier.testTag("tools.transform.${id.name}"), enabled = !id.usesInput || s.input.isNotEmpty())
            }
        }

        when (val r = s.result) {
            is TransformResult.Failure -> HaloCard { Text(r.message, color = Halo.Red, fontSize = 14.sp, modifier = Modifier.testTag("tools.transform.error")) }
            is TransformResult.Qr -> HaloCard {
                if (qr == null) Text("Can't make a QR code from this", color = Halo.Red, fontSize = 14.sp)
                qr?.let { bmp ->
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Image(bmp.asImageBitmap(), contentDescription = "QR code of your text", contentScale = ContentScale.Fit, filterQuality = FilterQuality.None,
                            modifier = Modifier.size(240.dp).background(Color.White).testTag("tools.transform.qr"))
                    }
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (ImageExport.canShare) HaloPrimaryButton("Share", {
                            scope.launch {
                                val uri = withContext(Dispatchers.IO) { ImageExport.saveToPictures(ctx, bmp, ImageExport.fileName("halo-qr")) }
                                if (uri != null) ctx.startActivity(ImageExport.shareIntent(uri)) else s.notice = "Couldn't share"
                            }
                        })
                        TextButton(onClick = { saveAs.launch(ImageExport.fileName("halo-qr")) }) { Text("Save as…") }
                    }
                }
            }
            is TransformResult.Output -> ResultCard(r, vm)
            null -> {}
        }
    }

    if (info) HaloInfoSheet(HaloInfo("Transform", "Runs on this phone; nothing is sent unless you tap Send. Paste reads your clipboard only when you tap it, and History lists items synced from your Mac.", listOf("Same results as Halo on your Mac for JSON, Base64, URL, sort, de-duplicate, hash and case. Differences: numbers in JSON keep how you typed them, upper/lower case understands accents, and Base64 decode also accepts URL-safe text.", "Format JSON escapes non-ASCII as \\uXXXX, exactly like the Mac action. QR codes are limited to about 2.3 KB of text.", "Passwords are marked sensitive when copied. If automatic clipboard sync is on, any copy is also sent to your Mac.")), { info = false })
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ResultCard(r: TransformResult.Output, vm: ToolsViewModel) {
    val ctx = LocalContext.current
    var note by remember(r) { mutableStateOf<String?>(null) }
    HaloCard {
        SectionLabel("Result", Modifier.padding(bottom = 8.dp))
        SelectionContainer {
            Text(if (r.text.length > DISPLAY_CAP) r.text.take(DISPLAY_CAP) + "…" else r.text, color = Halo.Text, fontSize = 14.sp, fontFamily = FontFamily.Monospace,
                modifier = Modifier.fillMaxWidth().heightIn(max = 320.dp).verticalScroll(rememberScrollState()).testTag("tools.transform.result"))
        }
        r.note?.let { Text(it, color = Halo.Text3, fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp)) }
        if (r.text.length > DISPLAY_CAP) Text("Showing first ${DISPLAY_CAP / 1000}k of ${r.text.length} characters; Copy takes all", color = Halo.Text3, fontSize = 11.sp)
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            HaloPrimaryButton("Copy", { ToolsClipboard.copy(ctx, r.text, r.secret); note = "Copied" }, Modifier.testTag("tools.transform.copy"))
            HaloIconButton(Icons.Filled.Send, "Send to Mac", { ToolsClipboard.sendToMac(ctx, r.text) { note = it } }, Modifier.testTag("tools.transform.send"), tint = Halo.Accent)
            TextButton(onClick = { vm.transform.load(r.text) }, enabled = !r.secret) { Text("Use as input") }
        }
        note?.let { Text(it, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp).testTag("tools.transform.resultNote")) }
        if (r.secret) HaloStatusBadge("Auto-sync would also send this", Halo.Amber, Modifier.padding(top = 6.dp))
    }
}
