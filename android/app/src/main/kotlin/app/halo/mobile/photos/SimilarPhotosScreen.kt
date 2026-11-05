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

    LaunchedEffect(Unit) { vm.onPermissionsChanged(grantedNow(ctx)) }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        askedOnce = true
        vm.onPermissionsChanged(grantedNow(ctx))
    }
    val trashLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { vm.systemDialogResult() }
    LaunchedEffect(sysDialog) {
        sysDialog?.let { trashLauncher.launch(IntentSenderRequest.Builder(it).build()); vm.systemDialogLaunched() }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Text("Similar Photos", color = Halo.Text, fontSize = 30.sp, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() }.testTag("photos.title"))
        Text("Finds photos that look alike — the same shot saved twice, a burst, a screenshot of a screenshot. Everything happens on this phone; no photo or hash ever leaves it.", color = Halo.Text3, fontSize = 12.sp)
        Spacer(Modifier.height(12.dp))

        when (ui.access) {
            MediaAccess.NONE -> PermissionCard(askedOnce, onAllow = { permLauncher.launch(PhotoPermissions.toRequest(Build.VERSION.SDK_INT).toTypedArray()) }, onSettings = { openAppSettings(ctx) })
            else -> {
                if (ui.access == MediaAccess.PARTIAL) PartialBanner(onMore = { permLauncher.launch(PhotoPermissions.toRequest(Build.VERSION.SDK_INT).toTypedArray()) }, onSettings = { openAppSettings(ctx) })
                ScanControls(ui, vm)
                if (ui.phase == Phase.READY || ui.phase == Phase.DELETING) Results(ui, vm)
            }
        }
    }

    ui.confirm?.let { req ->
        AlertDialog(
            onDismissRequest = vm::cancelConfirm, containerColor = Halo.Background,
            title = { Text("Move ${req.plan.count} photo${if (req.plan.count == 1) "" else "s"} to Trash?", color = Halo.Text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("photos.confirm.title")) },
            text = {
                Column {
                    Text("${req.plan.count} photo${if (req.plan.count == 1) "" else "s"} · ${formatBytes(req.plan.totalBytes)}", color = Halo.Text2, modifier = Modifier.testTag("photos.confirm.summary"))
                    Spacer(Modifier.height(8.dp))
                    Text("Android will ask you to confirm once more. Photos go to your Gallery's Trash, where they can be restored for a limited time. At least one photo from every group stays.", color = Halo.Text3, fontSize = 12.sp)
                }
            },
            confirmButton = { Button(onClick = vm::confirmDelete, colors = ButtonDefaults.buttonColors(containerColor = Halo.Red), modifier = Modifier.testTag("photos.confirm.ok")) { Text("Continue") } },
            dismissButton = { TextButton(onClick = vm::cancelConfirm, modifier = Modifier.testTag("photos.confirm.cancel")) { Text("Cancel", color = Halo.Text2) } },
        )
    }
}

private fun openAppSettings(ctx: android.content.Context) {
    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

@Composable
private fun PermissionCard(askedOnce: Boolean, onAllow: () -> Unit, onSettings: () -> Unit) {
    HaloCard {
        SectionLabel("Photo access")
        Spacer(Modifier.height(8.dp))
        Text("To compare your photos, Halo needs to read them. It only reads small previews to work out what looks alike, and it can't change or delete anything unless you confirm in Android's own dialog.", color = Halo.Text2, fontSize = 13.sp)
        if (Build.VERSION.SDK_INT >= 34) Text("On Android 14+ you can allow just some photos; Halo will then compare only those.", color = Halo.Text3, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
        Spacer(Modifier.height(10.dp))
        Button(onClick = onAllow, modifier = Modifier.testTag("photos.allow")) { Text("Allow photo access") }
        if (askedOnce) {
            Text("Still no access. If Android no longer shows the prompt, enable Photos in the app's settings.", color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
            TextButton(onClick = onSettings) { Text("Open app settings", color = Halo.Accent) }
        }
    }
}

@Composable
private fun PartialBanner(onMore: () -> Unit, onSettings: () -> Unit) {
    HaloCard {
        Text("Only the photos you selected are being scanned", color = Halo.Amber, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.testTag("photos.partial"))
        Text("You gave Halo access to selected photos only, so near-duplicates of photos you did not select can't be found.", color = Halo.Text3, fontSize = 12.sp)
        Row { TextButton(onClick = onMore) { Text("Choose more photos", color = Halo.Accent) }; TextButton(onClick = onSettings) { Text("Allow all", color = Halo.Accent) } }
    }
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun ScanControls(ui: PhotosUi, vm: PhotosViewModel) {
    HaloCard {
        when (ui.phase) {
            Phase.SCANNING -> {
                Text("Scanning ${ui.done} of ${ui.total}", color = Halo.Text, fontSize = 14.sp, modifier = Modifier.testTag("photos.progress"))
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(progress = { if (ui.total == 0) 0f else ui.done.toFloat() / ui.total }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Scan progress ${ui.done} of ${ui.total}" })
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = vm::cancelScan, modifier = Modifier.testTag("photos.cancel")) { Icon(Icons.Filled.Close, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text("Cancel") }
            }
            else -> {
                Button(onClick = vm::scan, enabled = ui.phase != Phase.DELETING, modifier = Modifier.testTag("photos.scan")) { Text(if (ui.scannedOnce) "Scan again" else "Scan photos") }
                Spacer(Modifier.height(10.dp))
                SectionLabel("Similarity")
                Text("Match photos up to ${ui.threshold} of 64 bits different", color = Halo.Text2, fontSize = 12.sp, modifier = Modifier.testTag("photos.thresholdLabel"))
                Slider(
                    value = ui.threshold.toFloat(), onValueChange = { vm.setThresholdLive(it.toInt()) }, onValueChangeFinished = { vm.regroup(ui.threshold) },
                    valueRange = Clustering.MIN_THRESHOLD.toFloat()..Clustering.MAX_THRESHOLD.toFloat(), steps = Clustering.MAX_THRESHOLD - Clustering.MIN_THRESHOLD - 1,
                    enabled = ui.scannedOnce, colors = SliderDefaults.colors(thumbColor = Halo.Accent, activeTrackColor = Halo.Accent),
                    modifier = Modifier.semantics { contentDescription = "Similarity threshold, ${ui.threshold} of 64 bits. Lower is stricter." }.testTag("photos.threshold"),
                )
                Text("Lower = only near-identical photos. Higher = also loosely similar ones (more false matches).", color = Halo.Text3, fontSize = 11.sp)
            }
        }
    }
    Spacer(Modifier.height(8.dp))
}

@Composable
private fun ColumnScope.Results(ui: PhotosUi, vm: PhotosViewModel) {
    val sdk = Build.VERSION.SDK_INT
    Text(
        "${ui.groups.size} group${if (ui.groups.size == 1) "" else "s"} · scanned ${ui.scanned} photos" +
            (if (ui.failed > 0) " · ${ui.failed} couldn't be read" else "") + (if (ui.ignored > 0) " · ${ui.ignored} skipped" else ""),
        color = Halo.Text2, fontSize = 13.sp, modifier = Modifier.testTag("photos.summary"),
    )
    ui.truncatedFrom?.let { Text("Your library has $it photos; only the newest ${Clustering.MAX_PHOTOS} were scanned.", color = Halo.Amber, fontSize = 12.sp) }
    ui.message?.let { Text(it, color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp).testTag("photos.message")) }
    Spacer(Modifier.height(6.dp))

    Box(Modifier.weight(1f)) {
        if (ui.groups.isEmpty()) {
            Text(if (ui.scanned == 0) "No photos to compare." else "No similar photos found at this setting. Try a higher similarity number.", color = Halo.Text3, fontSize = 13.sp, modifier = Modifier.padding(top = 24.dp))
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(ui.groups, key = { it.id }) { g -> GroupCard(g, ui.rev, vm) }
            }
        }
    }

    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
        if (ui.deleteMode == DeleteMode.DISABLED_BEFORE_API_30) {
            Text(PhotoPermissions.deleteExplanation(sdk).orEmpty(), color = Halo.Amber, fontSize = 12.sp, modifier = Modifier.testTag("photos.deleteDisabled"))
        } else {
            Button(
                onClick = vm::requestDelete, enabled = ui.marked > 0 && ui.phase == Phase.READY,
                colors = ButtonDefaults.buttonColors(containerColor = Halo.Red), modifier = Modifier.fillMaxWidth().testTag("photos.delete"),
            ) { Icon(Icons.Filled.Delete, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)); Text(if (ui.marked == 0) "Nothing selected" else "Move ${ui.marked} (${formatBytes(ui.markedBytes)}) to Trash…") }
        }
    }
}

@Composable
private fun GroupCard(g: PhotoGroup, rev: Int, vm: PhotosViewModel) {
    val session = vm.session
    HaloCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("${g.items.size} similar photos", color = Halo.Text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("${formatBytes(g.wastedBytes)} could be freed", color = Halo.Text3, fontSize = 11.sp)
            }
            TextButton(onClick = { vm.keepBest(g.id) }, modifier = Modifier.testTag("photos.keepBest.${g.id}")) { Icon(Icons.Filled.Check, null, Modifier.size(14.dp)); Spacer(Modifier.width(4.dp)); Text("Keep best", color = Halo.Accent, fontSize = 12.sp) }
            TextButton(onClick = { vm.ignore(g.id) }, modifier = Modifier.testTag("photos.skip.${g.id}")) { Text("Skip", color = Halo.Text2, fontSize = 12.sp) }
        }
        Spacer(Modifier.height(8.dp))
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
    val desc = "${p.name}, ${formatBytes(p.sizeBytes)}, ${"%.1f".format(p.megapixels)} megapixels" + if (best) ", suggested to keep" else ""
    val shape = RoundedCornerShape(10.dp)
    Column(Modifier.width(112.dp)) {
        Box(
            Modifier.size(112.dp).clip(shape).background(Halo.Surface2)
                .border(BorderStroke(2.dp, if (marked) Halo.Red else Halo.Green), shape)
                .clickable(onClick = onToggle, role = Role.Checkbox)
                .semantics { contentDescription = desc; stateDescription = if (marked) "Will be moved to Trash. Tap to keep." else "Kept. Tap to select for Trash." }
                .testTag("photos.tile.${p.id}"),
        ) {
            bmp?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = if (marked) 0.45f else 1f) }
            Text(
                if (marked) "TRASH" else if (best) "BEST · KEEP" else "KEEP", color = Halo.Text, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.align(Alignment.BottomStart).padding(4.dp).background((if (marked) Halo.Red else Halo.Green).copy(alpha = 0.85f), RoundedCornerShape(5.dp)).padding(horizontal = 5.dp, vertical = 1.dp),
            )
        }
        Text("${formatBytes(p.sizeBytes)} · ${"%.1f".format(p.megapixels)} MP", color = Halo.Text3, fontSize = 10.sp, maxLines = 1)
    }
}
