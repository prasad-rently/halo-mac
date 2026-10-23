package app.halo.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { HaloTheme { HaloApp(vm) } }
    }

    // Listen while visible. Android could keep listening in the background with a foreground service;
    // that is a later milestone (requirements MR-OS-2), so for now this mirrors iOS.
    override fun onStart() { super.onStart(); vm.startServer() }
    override fun onStop() { vm.stopServer(); super.onStop() }
}
