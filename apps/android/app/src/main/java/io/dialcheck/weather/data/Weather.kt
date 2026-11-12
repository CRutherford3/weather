package io.dialcheck.weather.data

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.LocalDate
import java.time.LocalDateTime
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

/// A place to show weather for: a searched city or the phone's location.
data class Place(val name: String, val lat: Double, val lon: Double)

data class Hour(val time: LocalDateTime, val temp: Double, val code: Int, val isDay: Boolean, val pop: Int, val wind: Double)

data class Day(
    val date: LocalDate, val hi: Double, val lo: Double, val code: Int, val pop: Int,
    val uvMax: Double, val sunrise: LocalDateTime?, val sunset: LocalDateTime?, val windMax: Double,
)

data class Alert(val event: String, val headline: String, val severity: String, val description: String)

data class Forecast(
    val temp: Double, val feels: Double, val humidity: Double, val dew: Double, val code: Int, val isDay: Boolean,
    val wind: Double, val windDir: Double, val gust: Double, val pressure: Double, val uv: Double, val visibility: Double,
    val hours: List<Hour>, val days: List<Day>,
    val aqi: Int? = null,
    val alerts: List<Alert> = emptyList(),
) {
    val hi: Double? get() = days.firstOrNull()?.hi
    val lo: Double? get() = days.firstOrNull()?.lo
    /// The next 24 hours, starting with the current hour.
    fun next24(): List<Hour> {
        val now = LocalDateTime.now().withMinute(0).withSecond(0).withNano(0)
        return hours.filter { !it.time.isBefore(now) }.take(24)
    }
}

/// The free public weather services the iPhone app uses too: Open-Meteo (forecast, air quality, search)
/// and the National Weather Service (alerts).
object WeatherService {
    private const val UA = "DopplerIQ-Android/1.0 (support@dialcheck.io)"

    private fun get(url: String): String {
        val c = URL(url).openConnection() as HttpURLConnection
        c.setRequestProperty("User-Agent", UA)
        c.setRequestProperty("Accept", "application/geo+json, application/json")
        c.connectTimeout = 15000; c.readTimeout = 20000
        try {
            if (c.responseCode !in 200..299) error("HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().use { it.readText() }
        } finally { c.disconnect() }
    }

    suspend fun load(p: Place, imperial: Boolean): Forecast = coroutineScope {
        val aqi = async(Dispatchers.IO) { runCatching { airQuality(p) }.getOrNull() }
        val alerts = async(Dispatchers.IO) { runCatching { alerts(p) }.getOrDefault(emptyList()) }
        val f = withContext(Dispatchers.IO) { forecast(p, imperial) }
        f.copy(aqi = aqi.await(), alerts = alerts.await())
    }

    private fun forecast(p: Place, imperial: Boolean): Forecast {
        var url = "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&timezone=auto&forecast_days=10".format(java.util.Locale.US, p.lat, p.lon) +
            "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m,wind_direction_10m,wind_gusts_10m,pressure_msl,uv_index,dew_point_2m,visibility" +
            "&hourly=temperature_2m,precipitation_probability,weather_code,is_day,wind_speed_10m" +
            "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max,wind_speed_10m_max"
        if (imperial) url += "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"
        val j = JSONObject(get(url))
        val cur = j.getJSONObject("current")
        val h = j.getJSONObject("hourly")
        val d = j.getJSONObject("daily")

        val ht = h.getJSONArray("time")
        val hours = (0 until ht.length()).map { i ->
            Hour(
                time = LocalDateTime.parse(ht.getString(i)),
                temp = h.getJSONArray("temperature_2m").num(i),
                code = h.getJSONArray("weather_code").num(i).toInt(),
                isDay = h.getJSONArray("is_day").num(i) > 0,
                pop = h.getJSONArray("precipitation_probability").num(i).toInt(),
                wind = h.getJSONArray("wind_speed_10m").num(i),
            )
        }
        val dt = d.getJSONArray("time")
        val days = (0 until dt.length()).map { i ->
            Day(
                date = LocalDate.parse(dt.getString(i)),
                hi = d.getJSONArray("temperature_2m_max").num(i),
                lo = d.getJSONArray("temperature_2m_min").num(i),
                code = d.getJSONArray("weather_code").num(i).toInt(),
                pop = d.getJSONArray("precipitation_probability_max").num(i).toInt(),
                uvMax = d.getJSONArray("uv_index_max").num(i),
                sunrise = d.getJSONArray("sunrise").optString(i).takeIf { it.isNotEmpty() && it != "null" }?.let(LocalDateTime::parse),
                sunset = d.getJSONArray("sunset").optString(i).takeIf { it.isNotEmpty() && it != "null" }?.let(LocalDateTime::parse),
                windMax = d.getJSONArray("wind_speed_10m_max").num(i),
            )
        }
        val hpa = cur.optDouble("pressure_msl", 1013.0)
        val visM = cur.optDouble("visibility", 16000.0)
        return Forecast(
            temp = cur.optDouble("temperature_2m"), feels = cur.optDouble("apparent_temperature"),
            humidity = cur.optDouble("relative_humidity_2m"), dew = cur.optDouble("dew_point_2m"),
            code = cur.optInt("weather_code"), isDay = cur.optInt("is_day", 1) > 0,
            wind = cur.optDouble("wind_speed_10m"), windDir = cur.optDouble("wind_direction_10m"), gust = cur.optDouble("wind_gusts_10m"),
            pressure = if (imperial) hpa * 0.02953 else hpa,
            uv = cur.optDouble("uv_index", 0.0),
            visibility = if (imperial) visM / 1609.34 else visM / 1000,
            hours = hours, days = days,
        )
    }

    private fun airQuality(p: Place): Int? {
        val j = JSONObject(get("https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.4f&longitude=%.4f&current=us_aqi".format(java.util.Locale.US, p.lat, p.lon)))
        val v = j.optJSONObject("current")?.optDouble("us_aqi") ?: return null
        return if (v.isNaN()) null else v.toInt()
    }

    private fun alerts(p: Place): List<Alert> {
        val j = JSONObject(get("https://api.weather.gov/alerts/active?point=%.4f,%.4f".format(java.util.Locale.US, p.lat, p.lon)))
        val f = j.optJSONArray("features") ?: return emptyList()
        return (0 until f.length()).map { i ->
            val pr = f.getJSONObject(i).getJSONObject("properties")
            Alert(pr.optString("event"), pr.optString("headline"), pr.optString("severity"), pr.optString("description"))
        }
    }

    /// City, town or ZIP search.
    suspend fun search(q: String): List<Place> = withContext(Dispatchers.IO) {
        runCatching {
            val j = JSONObject(get("https://geocoding-api.open-meteo.com/v1/search?count=8&language=en&name=" + URLEncoder.encode(q, "UTF-8")))
            val r = j.optJSONArray("results") ?: JSONArray()
            (0 until r.length()).map { i ->
                val o = r.getJSONObject(i)
                val cc = o.optString("country_code")
                val region = if (cc == "US") stateAbbrev(o.optString("admin1")) else cc
                val name = o.optString("name")
                Place(if (region.isEmpty()) name else "$name, $region", o.getDouble("latitude"), o.getDouble("longitude"))
            }
        }.getOrDefault(emptyList())
    }

    private fun JSONArray.num(i: Int): Double = if (isNull(i)) 0.0 else optDouble(i, 0.0)

    private val states = mapOf(
        "Alabama" to "AL", "Alaska" to "AK", "Arizona" to "AZ", "Arkansas" to "AR", "California" to "CA", "Colorado" to "CO",
        "Connecticut" to "CT", "Delaware" to "DE", "Florida" to "FL", "Georgia" to "GA", "Hawaii" to "HI", "Idaho" to "ID",
        "Illinois" to "IL", "Indiana" to "IN", "Iowa" to "IA", "Kansas" to "KS", "Kentucky" to "KY", "Louisiana" to "LA",
        "Maine" to "ME", "Maryland" to "MD", "Massachusetts" to "MA", "Michigan" to "MI", "Minnesota" to "MN", "Mississippi" to "MS",
        "Missouri" to "MO", "Montana" to "MT", "Nebraska" to "NE", "Nevada" to "NV", "New Hampshire" to "NH", "New Jersey" to "NJ",
        "New Mexico" to "NM", "New York" to "NY", "North Carolina" to "NC", "North Dakota" to "ND", "Ohio" to "OH", "Oklahoma" to "OK",
        "Oregon" to "OR", "Pennsylvania" to "PA", "Rhode Island" to "RI", "South Carolina" to "SC", "South Dakota" to "SD",
        "Tennessee" to "TN", "Texas" to "TX", "Utah" to "UT", "Vermont" to "VT", "Virginia" to "VA", "Washington" to "WA",
        "West Virginia" to "WV", "Wisconsin" to "WI", "Wyoming" to "WY", "District of Columbia" to "DC", "Puerto Rico" to "PR",
    )
    fun stateAbbrev(s: String) = states[s] ?: s
}

/// WMO weather codes in plain words, with an emoji to stand in for the iPhone app's symbols.
object WxCode {
    fun words(c: Int): String = when (c) {
        0 -> "Clear"; 1 -> "Mostly Clear"; 2 -> "Partly Cloudy"; 3 -> "Cloudy"
        45, 48 -> "Fog"
        51, 53, 55 -> "Drizzle"; 56, 57 -> "Freezing Drizzle"
        61 -> "Light Rain"; 63 -> "Rain"; 65 -> "Heavy Rain"; 66, 67 -> "Freezing Rain"
        71 -> "Light Snow"; 73 -> "Snow"; 75 -> "Heavy Snow"; 77 -> "Snow Grains"
        80, 81 -> "Showers"; 82 -> "Heavy Showers"; 85, 86 -> "Snow Showers"
        95 -> "Thunderstorms"; 96, 99 -> "Storms with Hail"
        else -> "--"
    }

    fun emoji(c: Int, day: Boolean = true): String = when (c) {
        0 -> if (day) "☀️" else "🌙"
        1 -> if (day) "🌤️" else "🌙"
        2 -> if (day) "⛅" else "☁️"
        3 -> "☁️"
        45, 48 -> "🌫️"
        51, 53, 55, 56, 57, 61, 63, 66, 80, 81 -> "🌦️"
        65, 67, 82 -> "🌧️"
        71, 73, 75, 77, 85, 86 -> "🌨️"
        95, 96, 99 -> "⛈️"
        else -> "☁️"
    }
}

fun aqiLabel(v: Int) = when {
    v <= 50 -> "Good"; v <= 100 -> "Moderate"; v <= 150 -> "Unhealthy for Some"
    v <= 200 -> "Unhealthy"; v <= 300 -> "Very Unhealthy"; else -> "Hazardous"
}
fun uvLabel(v: Double) = when { v < 3 -> "Low"; v < 6 -> "Moderate"; v < 8 -> "High"; v < 11 -> "Very High"; else -> "Extreme" }
fun aqiColor(v: Int): Long = when {
    v <= 50 -> 0xFF34C759; v <= 100 -> 0xFFFFCC00; v <= 150 -> 0xFFFF9500
    v <= 200 -> 0xFFFF3B30; v <= 300 -> 0xFFAF52DE; else -> 0xFF801A33
}
fun uvColor(v: Double): Long = when { v < 3 -> 0xFF34C759; v < 6 -> 0xFFFFCC00; v < 8 -> 0xFFFF9500; v < 11 -> 0xFFFF3B30; else -> 0xFFAF52DE }
fun deg(v: Double?): String = if (v == null || v.isNaN()) "--" else "${Math.round(v)}°"
fun compass(d: Double): String = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[((d + 22.5) / 45).toInt().mod(8)]
