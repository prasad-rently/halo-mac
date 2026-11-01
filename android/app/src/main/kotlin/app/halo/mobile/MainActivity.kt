package app.halo.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import app.halo.mobile.background.ReceiverHost

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()
    private val cloud: app.halo.mobile.cloud.CloudViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HaloTheme { HaloApp(vm, cloud) } }
        debugPairing(intent)
        if (savedInstanceState == null) handleShare(intent)      // a rotation re-delivers the original intent: don't re-stage what was already sent or discarded
    }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); debugPairing(intent); handleShare(intent) }

    /** F-055 FR-B3: files shared to Halo are staged, never sent until a device is chosen and Send is tapped. */
    private fun handleShare(i: android.content.Intent?) {
        if (i?.action != android.content.Intent.ACTION_SEND && i?.action != android.content.Intent.ACTION_SEND_MULTIPLE) return
        val uris = app.halo.mobile.background.SharedUris.extract(i)
        if (uris.isNotEmpty()) vm.stageShared(uris)
    }

    /**
     * Debug builds only: `adb shell am start -n app.halo.mobile/.MainActivity --es pairingCode <code>` submits a
     * pairing code without typing 500 characters through `adb input`, which drops keystrokes. Compiled out of
     * release behaviour by the BuildConfig.DEBUG guard.
     */
    private fun debugPairing(i: android.content.Intent?) {
        if (BuildConfig.DEBUG) i?.getStringExtra("pairingCode")?.let { cloud.submitCode(it) }
    }

    // Listen while visible. With "Keep receiving in the background" on (F-055, default off) the foreground service
    // keeps the same receiver alive when the screen goes away; otherwise it stops with the screen, as before.
    override fun onStart() { super.onStart(); ReceiverHost.uiVisible = true; vm.startServer(); vm.syncBackgroundState() }
    override fun onStop() { ReceiverHost.uiVisible = false; vm.stopServer(); super.onStop() }
}
