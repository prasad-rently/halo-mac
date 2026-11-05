package app.halo.mobile.tools

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.mobile.Halo
import app.halo.mobile.HaloCard
import app.halo.mobile.SectionLabel
import app.halo.tools.CodeFormatter
import app.halo.tools.CodeLanguage
import app.halo.tools.CodeTheme
import app.halo.tools.FormatResult
import app.halo.tools.LanguageDetector
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CodeBeautifierScreen() {
    val vm: ToolsViewModel = viewModel()
    val s = vm.beautifier
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var preview by remember { mutableStateOf<Bitmap?>(null) }

    // Re-render shortly after the last change, off the main thread, so typing never waits on a bitmap.
    LaunchedEffect(s.code, s.language, s.theme, s.lineNumbers) {
        if (s.code.isBlank()) { preview = null; return@LaunchedEffect }
        delay(250)
        preview = withContext(Dispatchers.Default) { CodeImageRenderer.render(s.code, CodeImageRenderer.Options(s.language, s.theme, s.lineNumbers, scale = 1.5f)) }
    }

    val saveAs = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { uri ->
        if (uri != null) scope.launch {
            val ok = withContext(Dispatchers.IO) { ImageExport.writeTo(ctx, uri, CodeImageRenderer.render(s.code, CodeImageRenderer.Options(s.language, s.theme, s.lineNumbers))) }
            s.notice = if (ok) "Image saved." else "Couldn't save the image."
        }
    }

    var info by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        HaloCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SectionLabel("Code", Modifier.weight(1f))
                HaloIconButton(Icons.Filled.Info, "About Code Image", { info = true }, Modifier.testTag("tools.code.info"))
            }
            OutlinedTextField(s.code, { s.code = it.take(200_000) }, placeholder = { Text("Paste or type code") }, minLines = 4, maxLines = 10,
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp, color = Halo.Text),
                modifier = Modifier.fillMaxWidth().testTag("tools.code.input"))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = {
                    ToolsClipboard.read(ctx)?.let { s.code = it.take(200_000); s.language = LanguageDetector.detect(it); s.notice = "Detected ${s.language.label}" }
                        ?: kotlin.run { s.notice = "Clipboard empty or blocked" }
                }, modifier = Modifier.testTag("tools.code.paste")) { Text("Paste") }
                TextButton(onClick = { s.language = LanguageDetector.detect(s.code); s.notice = "Detected ${s.language.label}" }, enabled = s.code.isNotBlank()) { Text("Detect") }
                TextButton(onClick = { s.clear(); preview = null }, enabled = s.code.isNotEmpty()) { Text("Clear") }
                Spacer(Modifier.weight(1f))
                HaloPrimaryButton("Format", {
                    when (val r = CodeFormatter.format(s.code, s.language)) {
                        is FormatResult.Ok -> { s.code = r.text; s.notice = "Formatted" }
                        is FormatResult.Unsupported -> s.notice = "No formatter for ${s.language.label}"
                        is FormatResult.Invalid -> s.notice = r.reason
                    }
                }, enabled = s.code.isNotBlank(), modifier = Modifier.testTag("tools.code.format"))
            }
            s.notice?.let { Text(it, color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("tools.code.notice")) }
        }

        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CodeLanguage.values().forEach { l -> HaloChip(l.label, s.language == l, { s.language = l }, Modifier.testTag("tools.code.lang.${l.name}")) }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            CodeTheme.all.forEach { t ->
                val sel = t.id == s.theme.id
                Row(Modifier.size(width = 64.dp, height = 48.dp).clip(RoundedCornerShape(10.dp)).background(Color(t.backgroundFrom.toInt()))
                    .border(if (sel) 2.dp else 1.dp, if (sel) Halo.Accent else Halo.Border, RoundedCornerShape(10.dp))
                    .clickable(onClickLabel = "Use ${t.name} theme") { s.theme = t }.semantics { contentDescription = "${t.name} theme${if (sel) ", selected" else ""}" }.padding(8.dp),
                    horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                    listOf(t.keyword, t.string, t.function, t.number).forEach { Row(Modifier.size(8.dp).clip(CircleShape).background(Color(it.toInt()))) {} }
                }
            }
            Switch(checked = s.lineNumbers, onCheckedChange = { s.lineNumbers = it }, modifier = Modifier.semantics { contentDescription = "Line numbers" }.testTag("tools.code.lineNumbers"))
        }

        HaloCard {
            val bmp = preview
            if (bmp == null) HaloEmptyState(Icons.Filled.Build, "Paste code to preview")
            else {
                Image(bmp.asImageBitmap(), contentDescription = CodeImageRenderer.describe(s.code, s.language), contentScale = ContentScale.FillWidth,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).testTag("tools.code.preview"))
                Spacer(Modifier.height(10.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (ImageExport.canShare) HaloPrimaryButton("Share", {
                        scope.launch {
                            val uri = withContext(Dispatchers.IO) { ImageExport.saveToPictures(ctx, CodeImageRenderer.render(s.code, CodeImageRenderer.Options(s.language, s.theme, s.lineNumbers)), ImageExport.fileName("halo-code")) }
                            if (uri != null) ctx.startActivity(ImageExport.shareIntent(uri)) else s.notice = "Couldn't share"
                        }
                    }, modifier = Modifier.testTag("tools.code.share"))
                    TextButton(onClick = { saveAs.launch(ImageExport.fileName("halo-code")) }, modifier = Modifier.testTag("tools.code.saveAs")) { Text("Save as…") }
                    TextButton(onClick = { ToolsClipboard.copy(ctx, s.code, sensitive = false); s.notice = "Copied" }) { Text("Copy code") }
                }
            }
        }
    }

    if (info) HaloInfoSheet("Code Image", { info = false }) {
        InfoLine("Turns code into a themed image with the same eight themes as Halo on your Mac. Format re-indents JSON, XML, HTML, CSS, JavaScript and TypeScript; other languages are shown as you wrote them.")
        InfoLine("Formatting only changes whitespace. For JSON it refuses invalid input instead of guessing.")
        InfoLine("Long lines wrap at 100 columns and images stop after 300 lines, with a note saying how many were left out. Share saves the image in Pictures/Halo first (Android 10+); Save as… works everywhere.")
    }
}
