package app.halo.mobile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.halo.cloud.CheckItem
import app.halo.cloud.CheckStatus
import app.halo.cloud.DatabaseCheck
import app.halo.cloud.DatabaseCheckReport
import app.halo.cloud.LiveDatabaseProbeTransport
import app.halo.mobile.cloud.CloudProfile
import app.halo.mobile.cloud.DebugEndpoints
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// F-057 FR-S1, phone side: "Check my database". The engine is in :halocloud (DatabaseCheck.kt, JVM-tested);
// this is only the button and the report. It signs in with the stored credential and probes meta, devices,
// sms and clipboard. The report text contains no token, password or key (engine guarantee, tested).
//
// NOT run on screen — compiled only.

@Composable
fun DatabaseCheckSection(profile: CloudProfile) {
    var running by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<DatabaseCheckReport?>(null) }
    val scope = rememberCoroutineScope()

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Database check")
        Text("Tests that your Firebase database lets this phone read, write and delete under every folder Halo uses — before a sync fails.", color = Halo.Text3, fontSize = 11.sp)
        Button(onClick = {
            running = true
            scope.launch {
                val result = withContext(Dispatchers.IO) {
                    val insecure = DebugEndpoints.applies(profile.config.databaseURL)
                    val transport = LiveDatabaseProbeTransport(profile.config, profile.auth, DebugEndpoints.auth(profile.config.databaseURL), insecure)
                    DatabaseCheck(transport, profile.config.databaseURL, insecure).run()
                }
                report = result; running = false
            }
        }, enabled = !running, modifier = Modifier.testTag("dbcheck.run")) {
            if (running) { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = Halo.Text); Spacer(Modifier.width(8.dp)) }
            Text(if (running) "Checking…" else "Check my database")
        }
        report?.let { r ->
            Text(when (r.overall) { CheckStatus.PASS -> "Everything works."; CheckStatus.WARN -> "Works, with something to fix."; else -> "Something needs fixing." },
                color = colorOf(r.overall), fontSize = 13.sp, modifier = Modifier.testTag("dbcheck.overall"))
            r.items.forEach { CheckRow(it) }
        }
    }
}

private fun colorOf(s: CheckStatus) = when (s) { CheckStatus.PASS -> Halo.Green; CheckStatus.WARN -> Halo.Amber; CheckStatus.FAIL -> Halo.Red; CheckStatus.SKIPPED -> Halo.Text3 }

@Composable
private fun CheckRow(i: CheckItem) {
    Row(verticalAlignment = Alignment.Top, modifier = Modifier.testTag("dbcheck.row.${i.kind}")) {
        Text(when (i.status) { CheckStatus.PASS -> "✓"; CheckStatus.WARN -> "!"; CheckStatus.FAIL -> "✗"; CheckStatus.SKIPPED -> "–" }, color = colorOf(i.status), fontSize = 14.sp, modifier = Modifier.width(18.dp))
        Column {
            Text(i.title, color = Halo.Text, fontSize = 13.sp)
            Text(i.detail, color = Halo.Text2, fontSize = 12.sp)
            i.fix?.let { Spacer(Modifier.height(2.dp)); Text("Fix: $it", color = Halo.Amber, fontSize = 12.sp) }
        }
    }
}
