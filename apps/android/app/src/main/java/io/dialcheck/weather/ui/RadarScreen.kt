package io.dialcheck.weather.ui

import android.content.Context
import android.graphics.Color as AColor
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import io.dialcheck.weather.data.AppState
import io.dialcheck.weather.data.WxCode
import io.dialcheck.weather.data.deg
import kotlinx.coroutines.delay
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.MapTileProviderBasic
import org.osmdroid.tileprovider.tilesource.XYTileSource
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import org.osmdroid.views.overlay.TilesOverlay

/// Dark base map from CARTO (OpenStreetMap data).
private val darkBase = XYTileSource(
    "CartoDark", 0, 19, 256, ".png",
    arrayOf("https://a.basemaps.cartocdn.com/dark_all/", "https://b.basemaps.cartocdn.com/dark_all/", "https://c.basemaps.cartocdn.com/dark_all/"),
    "© OpenStreetMap contributors © CARTO",
)

/// Latest NEXRAD base reflectivity mosaic from the Iowa Environmental Mesonet (updated every 5 minutes).
private val nexrad = XYTileSource(
    "NEXRAD-N0Q", 0, 16, 256, ".png",
    arrayOf("https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/nexrad-n0q-900913/"),
    "Radar: Iowa Environmental Mesonet",
)

private fun makeMap(ctx: Context): Pair<MapView, MapTileProviderBasic> {
    Configuration.getInstance().apply {
        userAgentValue = ctx.packageName
        expirationOverrideDuration = 5 * 60 * 1000L   // radar tiles go stale fast
    }
    val map = MapView(ctx).apply {
        setTileSource(darkBase)
        setMultiTouchControls(true)
        zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
        isTilesScaledToDpi = true
        minZoomLevel = 3.0
        maxZoomLevel = 14.0
        controller.setZoom(7.5)
        setBackgroundColor(AColor.BLACK)
    }
    val radarTiles = MapTileProviderBasic(ctx, nexrad)
    val radar = TilesOverlay(radarTiles, ctx).apply {
        setLoadingBackgroundColor(AColor.TRANSPARENT)
        setLoadingLineColor(AColor.TRANSPARENT)
    }
    map.overlays.add(radar)
    return map to radarTiles
}

@Composable
fun RadarScreen(state: AppState, modifier: Modifier = Modifier) {
    val ctx = LocalContext.current
    val (map, radarTiles) = remember { makeMap(ctx) }
    val pin = remember { Marker(map).apply { setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_BOTTOM); title = "" } }

    // Keep the map's own lifecycle in step with the screen.
    val owner = LocalLifecycleOwner.current
    DisposableEffect(owner) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_RESUME -> map.onResume()
                Lifecycle.Event.ON_PAUSE -> map.onPause()
                else -> {}
            }
        }
        owner.lifecycle.addObserver(obs)
        map.onResume()
        onDispose { owner.lifecycle.removeObserver(obs); map.onPause() }
    }

    // Center on the place being shown.
    LaunchedEffect(state.place) {
        val p = GeoPoint(state.place.lat, state.place.lon)
        map.controller.setCenter(p)
        pin.position = p
        if (pin !in map.overlays) map.overlays.add(pin)
        map.invalidate()
    }

    // Pull fresh radar every 5 minutes while the screen is open.
    LaunchedEffect(Unit) {
        if (state.forecast == null) state.refresh()
        while (true) {
            delay(5 * 60 * 1000L)
            radarTiles.clearTileCache()
            map.invalidate()
        }
    }

    Box(modifier.fillMaxSize()) {
        AndroidView(factory = { map }, modifier = Modifier.fillMaxSize())

        Text("NEXRAD Radar", fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.statusBarsPadding().padding(12.dp).clip(RoundedCornerShape(10.dp))
                .background(Color.Black.copy(0.55f)).padding(horizontal = 10.dp, vertical = 5.dp))

        RadarLegend(Modifier.align(Alignment.BottomCenter).padding(bottom = 104.dp))

        // Weather card along the bottom; tap to recenter on the place.
        val f = state.forecast
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp).fillMaxWidth()
                .clip(RoundedCornerShape(18.dp)).background(Color(0xE61C1C22))
                .clickable { map.controller.animateTo(GeoPoint(state.place.lat, state.place.lon)) }
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            Text(if (f != null) WxCode.emoji(f.code, f.isDay) else "…", fontSize = 30.sp)
            Column(Modifier.weight(1f)) {
                Text(state.place.name, fontWeight = FontWeight.SemiBold, maxLines = 1)
                Text(if (f != null) "${WxCode.words(f.code)} · H:${deg(f.hi)} L:${deg(f.lo)}" else if (state.loading) "Loading…" else state.error ?: "",
                    fontSize = 13.sp, color = Color.White.copy(0.7f), maxLines = 1)
            }
            Text(deg(f?.temp), fontSize = 34.sp, fontWeight = FontWeight.Medium)
        }
    }
}

/// Light to heavy, matching the NEXRAD reflectivity colors.
@Composable
private fun RadarLegend(modifier: Modifier) {
    val colors = listOf(0xFF04E9E7, 0xFF019FF4, 0xFF02FD02, 0xFF01C501, 0xFF008E00, 0xFFFDF802, 0xFFE5BC00, 0xFFFD9500, 0xFFFD0000, 0xFFBC0000, 0xFFF800FD)
    Row(verticalAlignment = Alignment.CenterVertically,
        modifier = modifier.clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(0.55f)).padding(horizontal = 10.dp, vertical = 5.dp)) {
        Text("Light ", fontSize = 10.sp, color = Color.White.copy(0.8f))
        colors.forEach { Box(Modifier.padding(horizontal = 0.5.dp).background(Color(it)).padding(horizontal = 7.dp, vertical = 4.dp)) }
        Text(" Heavy", fontSize = 10.sp, color = Color.White.copy(0.8f))
    }
}
