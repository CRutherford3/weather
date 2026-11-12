package io.dialcheck.weather.data

import android.annotation.SuppressLint
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.dialcheck.weather.widget.GlanceWidget
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale
import kotlin.coroutines.resume

/// Saved settings, shared by the app and the widgets.
object Prefs {
    private fun sp(c: Context) = c.getSharedPreferences("doppleriq", Context.MODE_PRIVATE)

    fun imperial(c: Context): Boolean = sp(c).getBoolean("imperial", Locale.getDefault().country in setOf("US", "LR", "MM"))
    fun setImperial(c: Context, v: Boolean) = sp(c).edit().putBoolean("imperial", v).apply()

    fun followMe(c: Context): Boolean = sp(c).getBoolean("followMe", true)
    fun setFollowMe(c: Context, v: Boolean) = sp(c).edit().putBoolean("followMe", v).apply()

    /// The last place shown: a searched city, or the last known spot when following location.
    fun place(c: Context): Place? {
        val s = sp(c)
        if (!s.contains("lat")) return null
        return Place(s.getString("name", "") ?: "", s.getFloat("lat", 0f).toDouble(), s.getFloat("lon", 0f).toDouble())
    }
    fun setPlace(c: Context, p: Place) = sp(c).edit()
        .putString("name", p.name).putFloat("lat", p.lat.toFloat()).putFloat("lon", p.lon.toFloat()).apply()
}

/// The phone's location, without Google Play services.
object Locator {
    fun allowed(c: Context) =
        ContextCompat.checkSelfPermission(c, android.Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(c, android.Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission")
    suspend fun current(c: Context): Place? {
        if (!allowed(c)) return null
        val lm = c.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = lm.getProviders(true)
        val last = providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }
        val fresh = if (last != null && System.currentTimeMillis() - last.time < 10 * 60_000) last else
            withTimeoutOrNull(10_000) { fix(lm, providers) } ?: last
        val loc = fresh ?: return null
        return Place(townName(c, loc), loc.latitude, loc.longitude)
    }

    @SuppressLint("MissingPermission")
    private suspend fun fix(lm: LocationManager, providers: List<String>): Location? {
        val p = when {
            LocationManager.NETWORK_PROVIDER in providers -> LocationManager.NETWORK_PROVIDER
            LocationManager.GPS_PROVIDER in providers -> LocationManager.GPS_PROVIDER
            else -> return null
        }
        return suspendCancellableCoroutine { cont ->
            if (Build.VERSION.SDK_INT >= 30) {
                lm.getCurrentLocation(p, null, { it.run() }) { if (cont.isActive) cont.resume(it) }
            } else {
                @Suppress("DEPRECATION")
                lm.requestSingleUpdate(p, object : android.location.LocationListener {
                    override fun onLocationChanged(l: Location) { if (cont.isActive) cont.resume(l) }
                    @Deprecated("Android 10 still calls these")
                    override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
                    override fun onProviderEnabled(provider: String) {}
                    override fun onProviderDisabled(provider: String) {}
                }, android.os.Looper.getMainLooper())
            }
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun townName(c: Context, l: Location): String = withContext(Dispatchers.IO) {
        runCatching {
            val a = Geocoder(c, Locale.US).getFromLocation(l.latitude, l.longitude, 1)?.firstOrNull()
            a?.locality ?: a?.subAdminArea ?: a?.adminArea
        }.getOrNull() ?: "My Location"
    }
}

class AppState(app: Application) : AndroidViewModel(app) {
    private val ctx get() = getApplication<Application>()

    var place by mutableStateOf(Prefs.place(app) ?: Place("Atlanta, GA", 33.749, -84.388))
        private set
    var forecast by mutableStateOf<Forecast?>(null)
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var imperial by mutableStateOf(Prefs.imperial(app))
        private set
    var followMe by mutableStateOf(Prefs.followMe(app))
        private set

    fun refresh() = viewModelScope.launch {
        loading = true
        if (followMe) Locator.current(ctx)?.let { place = it; Prefs.setPlace(ctx, it) }
        runCatching { WeatherService.load(place, imperial) }
            .onSuccess { forecast = it; error = null }
            .onFailure { error = "Couldn't load the weather. Pull down to try again." }
        loading = false
        GlanceWidget.refreshAll(ctx)
    }

    fun choose(p: Place) {
        place = p; followMe = false
        Prefs.setPlace(ctx, p); Prefs.setFollowMe(ctx, false)
        refresh()
    }

    fun useMyLocation() {
        followMe = true; Prefs.setFollowMe(ctx, true)
        refresh()
    }

    fun setUnits(imperial: Boolean) {
        this.imperial = imperial; Prefs.setImperial(ctx, imperial)
        refresh()
    }
}
