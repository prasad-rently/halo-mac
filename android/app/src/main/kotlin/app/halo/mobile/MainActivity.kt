package app.halo.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()
    private val cloud: app.halo.mobile.cloud.CloudViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HaloTheme { HaloApp(vm, cloud) } }
        debugPairing(intent)
    }

    override fun onNewIntent(intent: android.content.Intent) { super.onNewIntent(intent); debugPairing(intent) }

    /**
     * Debug builds only: `adb shell am start -n app.halo.mobile/.MainActivity --es pairingCode <code>` submits a
     * pairing code without typing 500 characters through `adb input`, which drops keystrokes. Compiled out of
     * release behaviour by the BuildConfig.DEBUG guard.
     */
    private fun debugPairing(i: android.content.Intent?) {
        if (BuildConfig.DEBUG) i?.getStringExtra("pairingCode")?.let { cloud.submitCode(it) }
    }

    // Listen while visible. Android could keep listening in the background with a foreground service;
    // that is a later milestone (requirements MR-OS-2), so for now this mirrors iOS.
    override fun onStart() { super.onStart(); vm.startServer() }
    override fun onStop() { vm.stopServer(); super.onStop() }
}
