package io.dialcheck.weather

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import io.dialcheck.weather.data.AppState
import io.dialcheck.weather.ui.DashboardScreen
import io.dialcheck.weather.ui.RadarScreen
import io.dialcheck.weather.ui.SettingsScreen
import io.dialcheck.weather.ui.theme.DopplerIQTheme

class MainActivity : ComponentActivity() {
    /// Set when a widget tap opens the app, so it lands on the Dashboard.
    private var openTab by mutableIntStateOf(TAB_RADAR)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (intent.getBooleanExtra(EXTRA_DASHBOARD, false)) openTab = TAB_DASHBOARD
        setContent { DopplerIQTheme { Root(openTab) { openTab = it } } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(EXTRA_DASHBOARD, false)) openTab = TAB_DASHBOARD
    }

    companion object {
        const val EXTRA_DASHBOARD = "openDashboard"
        const val TAB_RADAR = 0
        const val TAB_DASHBOARD = 1
        const val TAB_SETTINGS = 2
    }
}

@Composable
private fun Root(tab: Int, setTab: (Int) -> Unit, state: AppState = viewModel()) {
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { state.refresh() }
    var asked by rememberSaveable { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        if (asked == 0) {
            asked = 1
            ask.launch(arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION))
        }
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(tab == MainActivity.TAB_RADAR, { setTab(MainActivity.TAB_RADAR) },
                    icon = { Icon(Icons.Filled.LocationOn, null) }, label = { Text("Radar") })
                NavigationBarItem(tab == MainActivity.TAB_DASHBOARD, { setTab(MainActivity.TAB_DASHBOARD) },
                    icon = { Icon(Icons.Filled.Home, null) }, label = { Text("Dashboard") })
                NavigationBarItem(tab == MainActivity.TAB_SETTINGS, { setTab(MainActivity.TAB_SETTINGS) },
                    icon = { Icon(Icons.Filled.Settings, null) }, label = { Text("Settings") })
            }
        },
    ) { pad ->
        val m = Modifier.padding(pad)
        when (tab) {
            MainActivity.TAB_DASHBOARD -> DashboardScreen(state, m)
            MainActivity.TAB_SETTINGS -> SettingsScreen(state, m)
            else -> RadarScreen(state, m)
        }
    }
}
