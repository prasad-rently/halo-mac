package app.halo.mobile.photos

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.halo.mobile.HaloCard
import app.halo.mobile.Halo
import app.halo.mobile.SectionLabel
import app.halo.mobile.formatBytes
import app.halo.mobile.ToolEntry
import app.halo.photos.Clustering
import app.halo.photos.DeleteMode
import app.halo.photos.HashedPhoto
import app.halo.photos.MediaAccess
import app.halo.photos.PhotoGroup
import app.halo.photos.PhotoPermissions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/** The single registration with the Tools hub. */
object SimilarPhotosTool {
    val entry = ToolEntry(id = "similar-photos", title = "Similar Photos", icon = null) { SimilarPhotosScreen() }
}

private val decodeGate = Semaphore(3)     // at most three display-thumbnail decodes in flight

private fun grantedNow(ctx: android.content.Context): Set<String> =
    (PhotoPermissions.toRequest(Build.VERSION.SDK_INT)).filter { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }.toSet()

@Composable
fun SimilarPhotosScreen(vm: PhotosViewModel = viewModel()) {
    val ctx = LocalContext.current
    val ui by vm.ui.collectAsStateWithLifecycle()
    val sysDialog by vm.systemDialog.collectAsStateWithLifecycle()
    var askedOnce by remember { mutableStateOf(false) }
    var info by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.onPermissionsChanged(grantedNow(ctx)) }
    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        askedOnce = true
        vm.onPermissionsChanged(grantedNow(ctx))
    }
    val askPermission = { permLauncher.launch(PhotoPermissions.toRequest(Build.VERSION.SDK_INT).toTypedArray()) }
    val trashLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { vm.systemDialogResult() }
    LaunchedEffect(sysDialog) {
        sysDialog?.let { trashLauncher.launch(IntentSenderRequest.Builder(it).build()); vm.systemDialogLaunched() }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(PhotosStrings.TITLE, color = Halo.Text, fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f).semantics { heading() }.testTag("photos.title"))
            HaloIconButton(Icons.Filled.Info, PhotosStrings.INFO, { info = true }, Modifier.testTag("photos.info"))
        }
        Spacer(Modifier.height(8.dp))

        if (ui.access == MediaAccess.NONE) {
            HaloCard {
                HaloEmptyState(PhotosStrings.EMPTY_NO_ACCESS, PhotosStrings.ALLOW, { askPermission() }, Modifier.testTag("photos.allow"))
                if (askedOnce) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { HaloChip(PhotosStrings.SETTINGS, accent = Halo.Amber) { openAppSettings(ctx) } }
            }
        } else {
            SummaryCard(ui, vm)
            if (ui.access == MediaAccess.PARTIAL) {
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    HaloChip(PhotosStrings.PARTIAL_CHIP, selected = true, accent = Halo.Amber, modifier = Modifier.testTag("photos.partial")) { info = true }
                    HaloChip(PhotosStrings.MORE) { askPermission() }
                }
            }
            if (ui.scannedOnce && ui.phase != Phase.SCANNING) {
                Spacer(Modifier.height(8.dp))
                ThresholdRow(ui, vm)
            }
            ui.message?.let { Text(it, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp).testTag("photos.message")) }
            Spacer(Modifier.height(8.dp))
            Box(Modifier.weight(1f)) {
                if (ui.scannedOnce && ui.phase != Phase.SCANNING) {
                    if (ui.groups.isEmpty()) HaloEmptyState(PhotosStrings.EMPTY_NONE_FOUND, null, null)
                    else LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) { items(ui.groups, key = { it.id }) { g -> GroupStrip(g, ui.rev, vm) } }
                }
            }
            if (ui.scannedOnce && ui.groups.isNotEmpty() && ui.phase != Phase.SCANNING) {
                Column(Modifier.padding(vertical = 10.dp)) {
                    if (ui.deleteMode == DeleteMode.DISABLED_BEFORE_API_30) HaloChip(PhotosStrings.DELETE_UNAVAILABLE, accent = Halo.Amber, modifier = Modifier.testTag("photos.deleteDisabled")) { info = true }
                    else HaloPrimaryButton(if (ui.marked > 0) "${PhotosStrings.REVIEW} · ${ui.marked}" else PhotosStrings.REVIEW, vm::requestDelete, Modifier.testTag("photos.delete"), enabled = ui.marked > 0 && ui.phase == Phase.READY, destructive = true)
                }
            }
        }
    }

    if (info) HaloInfoSheet(PhotosStrings.INFO, PhotosStrings.INFO_LINES) { info = false }

    ui.confirm?.let { req ->
        AlertDialog(
            onDismissRequest = vm::cancelConfirm, containerColor = Halo.Background,
            title = { Text("Move ${req.plan.count} photo${if (req.plan.count == 1) "" else "s"} to Trash?", color = Halo.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("photos.confirm.title")) },
            text = { Text("${req.plan.count} photo${if (req.plan.count == 1) "" else "s"} · ${formatBytes(req.plan.totalBytes)}", color = Halo.Text2, fontSize = 15.sp, modifier = Modifier.testTag("photos.confirm.summary")) },
            confirmButton = { Button(onClick = vm::confirmDelete, colors = ButtonDefaults.buttonColors(containerColor = Halo.Red), modifier = Modifier.testTag("photos.confirm.ok")) { Text("Continue") } },
            dismissButton = { TextButton(onClick = vm::cancelConfirm, modifier = Modifier.testTag("photos.confirm.cancel")) { Text("Cancel", color = Halo.Text2) } },
        )
    }
}

private fun openAppSettings(ctx: android.content.Context) {
    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Ring = scan progress while scanning; afterwards the metric tiles. One glanceable card, no sentences. */
@Composable
private fun SummaryCard(ui: PhotosUi, vm: PhotosViewModel) {
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            val scanning = ui.phase == Phase.SCANNING
            val frac = if (ui.total == 0) 0f else ui.done.toFloat() / ui.total
            HaloRing(if (scanning) frac else if (ui.scannedOnce) 1f else 0f, if (scanning) "${(frac * 100).toInt()}%" else if (ui.scannedOnce) "${ui.groups.size}" else "–",
                color = if (scanning) Halo.Accent else Halo.Green, modifier = Modifier.testTag("photos.ring"))
            if (ui.scannedOnce && !scanning) {
                val free = ui.groups.sumOf { it.wastedBytes }
                Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    HaloMetricTile(PhotosStrings.TILE_GROUPS, "${ui.groups.size}", Modifier.weight(1f).testTag("photos.summary"), Halo.Accent)
                    HaloMetricTile(PhotosStrings.TILE_FREE, formatBytes(free), Modifier.weight(1f), Halo.Green)
                }
            } else {
                Text(if (scanning) "${ui.done} / ${ui.total}" else PhotosStrings.EMPTY_IDLE, color = Halo.Text2, fontSize = 15.sp, modifier = Modifier.weight(1f).testTag("photos.progress"))
            }
        }
        Spacer(Modifier.height(12.dp))
        if (ui.phase == Phase.SCANNING) HaloPrimaryButton(PhotosStrings.CANCEL, vm::cancelScan, Modifier.testTag("photos.cancel"))
        else HaloPrimaryButton(if (ui.scannedOnce) PhotosStrings.RESCAN else PhotosStrings.SCAN, vm::scan, Modifier.testTag("photos.scan"), enabled = ui.phase != Phase.DELETING)
        if (ui.scannedOnce && (ui.failed > 0 || ui.truncatedFrom != null)) {
            Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (ui.failed > 0) HaloChip("${ui.failed} unreadable", accent = Halo.Amber)
                ui.truncatedFrom?.let { HaloChip("Newest ${Clustering.MAX_PHOTOS} of $it", accent = Halo.Amber) }
            }
        }
    }
}

/** Preset chips (Strict / Normal / Loose) plus a bare slider for the exact 1-20 value. */
@Composable
private fun ThresholdRow(ui: PhotosUi, vm: PhotosViewModel) {
    Column {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            listOf(PhotosStrings.STRICT to 4, PhotosStrings.NORMAL to Clustering.DEFAULT_THRESHOLD, PhotosStrings.LOOSE to 14).forEach { (label, t) ->
                HaloChip(label, selected = ui.threshold == t, modifier = Modifier.testTag("photos.preset.$t")) { vm.setThresholdLive(t); vm.regroup(t) }
            }
            Text("≤ ${ui.threshold}", color = Halo.Text3, fontSize = 12.sp, modifier = Modifier.testTag("photos.thresholdLabel"))
        }
        Slider(
            value = ui.threshold.toFloat(), onValueChange = { vm.setThresholdLive(it.toInt()) }, onValueChangeFinished = { vm.regroup(ui.threshold) },
            valueRange = Clustering.MIN_THRESHOLD.toFloat()..Clustering.MAX_THRESHOLD.toFloat(), steps = Clustering.MAX_THRESHOLD - Clustering.MIN_THRESHOLD - 1,
            colors = SliderDefaults.colors(thumbColor = Halo.Accent, activeTrackColor = Halo.Accent),
            modifier = Modifier.semantics { contentDescription = "Similarity threshold, ${ui.threshold} of 64 bits. Lower is stricter." }.testTag("photos.threshold"),
        )
    }
}

@Composable
private fun GroupStrip(g: PhotoGroup, rev: Int, vm: PhotosViewModel) {
    val session = vm.session
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("${g.items.size} · ${formatBytes(g.wastedBytes)}", color = Halo.Text2, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            HaloChip("Keep best", accent = Halo.Green, modifier = Modifier.testTag("photos.keepBest.${g.id}")) { vm.keepBest(g.id) }
            Spacer(Modifier.width(6.dp))
            HaloIconButton(Icons.Filled.Close, "Skip this group", { vm.ignore(g.id) }, Modifier.testTag("photos.skip.${g.id}"))
        }
        if (g.chained) Text(PhotosStrings.chained(g.diameter), color = Halo.Amber, fontSize = 11.sp, modifier = Modifier.padding(top = 4.dp).testTag("photos.chained.${g.id}"))
        Spacer(Modifier.height(6.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(g.items, key = { it.photo.id }) { item ->
                val marked = rev >= 0 && session.isMarked(g.id, item.photo.id)
                PhotoTile(item, marked, best = item.photo.id == g.recommendedKeepId, vm = vm) { vm.toggle(g.id, item.photo.id) }
            }
        }
    }
}

@Composable
private fun PhotoTile(item: HashedPhoto, marked: Boolean, best: Boolean, vm: PhotosViewModel, onToggle: () -> Unit) {
    val p = item.photo
    val bmp by produceState(vm.thumbs.peek(p.id)?.asImageBitmap(), p.id) {
        if (value == null) value = decodeGate.withPermit { withContext(Dispatchers.IO) { vm.thumbs.load(p) } }?.asImageBitmap()
    }
    val desc = "${p.name}, ${formatBytes(p.sizeBytes)}, ${"%.1f".format(p.megapixels)} megapixels" + if (best) ", best" else ""
    val shape = RoundedCornerShape(12.dp)
    Box(
        Modifier.size(104.dp).clip(shape).background(Halo.Surface2)
            .border(BorderStroke(2.dp, if (marked) Halo.Red else Color.Transparent), shape)
            .clickable(onClick = onToggle, role = Role.Checkbox)
            .semantics { contentDescription = desc; stateDescription = if (marked) "Will be moved to Trash. Tap to keep." else "Kept. Tap to select for Trash." }
            .testTag("photos.tile.${p.id}"),
    ) {
        bmp?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = if (marked) 0.4f else 1f) }
        if (best) Text(PhotosStrings.BEST, color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.align(Alignment.TopStart).padding(6.dp).background(Halo.Green.copy(alpha = 0.9f), RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 2.dp))
        if (marked) Icon(Icons.Filled.Delete, null, tint = Halo.Red, modifier = Modifier.align(Alignment.Center).size(28.dp))
    }
}
