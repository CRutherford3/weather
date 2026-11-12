package io.dialcheck.weather.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.dialcheck.weather.BuildConfigInfo
import io.dialcheck.weather.data.AppState
import io.dialcheck.weather.data.Place
import io.dialcheck.weather.data.WeatherService
import kotlinx.coroutines.delay

@Composable
fun SettingsScreen(state: AppState, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Place>>(emptyList()) }
    LaunchedEffect(query) {
        if (query.trim().length < 2) { results = emptyList(); return@LaunchedEffect }
        delay(350)   // wait for typing to pause
        results = WeatherService.search(query.trim())
    }

    LazyColumn(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("Settings", fontSize = 28.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 16.dp)) }

        item {
            Card {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Location", fontWeight = FontWeight.SemiBold)
                    Text(if (state.followMe) "Following your location: ${state.place.name}" else "Showing ${state.place.name}",
                        fontSize = 13.sp, color = Color.White.copy(0.7f))
                    if (!state.followMe) {
                        Text("➤ Use my location", color = MaterialAccent, fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.clickable { state.useMyLocation() }.padding(vertical = 4.dp))
                    }
                    OutlinedTextField(query, { query = it }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("Search a city or ZIP code") })
                }
            }
        }
        items(results) { p ->
            Text(p.name, modifier = Modifier.fillMaxWidth().clickable { state.choose(p); query = ""; results = emptyList() }
                .padding(horizontal = 8.dp, vertical = 10.dp))
            HorizontalDivider(color = Color.White.copy(0.08f))
        }

        item {
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Units", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    SingleChoiceSegmentedButtonRow {
                        SegmentedButton(state.imperial, { state.setUnits(true) }, SegmentedButtonDefaults.itemShape(0, 2)) { Text("°F") }
                        SegmentedButton(!state.imperial, { state.setUnits(false) }, SegmentedButtonDefaults.itemShape(1, 2)) { Text("°C") }
                    }
                }
            }
        }

        item {
            Card {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Data", fontWeight = FontWeight.SemiBold)
                    Text("Forecast and air quality: Open-Meteo. Alerts: National Weather Service. Radar: NOAA NEXRAD via the Iowa Environmental Mesonet. Map: © OpenStreetMap contributors © CARTO.",
                        fontSize = 12.sp, color = Color.White.copy(0.65f))
                }
            }
        }

        item {
            Text("DopplerIQ for Android v${BuildConfigInfo.VERSION}", fontSize = 12.sp, color = Color.White.copy(0.45f),
                modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp))
            Spacer(Modifier.padding(8.dp))
        }
    }
}

private val MaterialAccent = io.dialcheck.weather.ui.theme.Accent
