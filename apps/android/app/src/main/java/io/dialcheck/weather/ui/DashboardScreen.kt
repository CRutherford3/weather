package io.dialcheck.weather.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.dialcheck.weather.data.AppState
import io.dialcheck.weather.data.Forecast
import io.dialcheck.weather.data.WxCode
import io.dialcheck.weather.data.aqiColor
import io.dialcheck.weather.data.aqiLabel
import io.dialcheck.weather.data.compass
import io.dialcheck.weather.data.deg
import io.dialcheck.weather.data.uvColor
import io.dialcheck.weather.data.uvLabel
import io.dialcheck.weather.ui.theme.CardBg
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.cos
import kotlin.math.sin

@Composable
fun DashboardScreen(state: AppState, modifier: Modifier = Modifier) {
    PullToRefreshBox(isRefreshing = state.loading, onRefresh = { state.refresh() }, modifier = modifier.fillMaxSize()) {
        val f = state.forecast
        if (f == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                if (state.error != null) Text(state.error ?: "", color = Color.White.copy(0.7f), modifier = Modifier.padding(24.dp))
                else CircularProgressIndicator()
            }
            return@PullToRefreshBox
        }
        val speed = if (state.imperial) "mph" else "km/h"
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { Now(state.place.name, state.followMe, f) }
            if (f.alerts.isNotEmpty()) item { Alerts(f) }
            item { Hourly(f) }
            item { Daily(f) }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Tile("AIR QUALITY", f.aqi?.toString() ?: "--", f.aqi?.let(::aqiLabel) ?: "No data",
                        Color(f.aqi?.let(::aqiColor) ?: 0xFF888888), Modifier.weight(1f))
                    Tile("UV INDEX", "${Math.round(f.uv)}", uvLabel(f.uv), Color(uvColor(f.uv)), Modifier.weight(1f))
                }
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Tile("WIND", "${Math.round(f.wind)}", "$speed ${compass(f.windDir)}, gusts ${Math.round(f.gust)}", null, Modifier.weight(1f))
                    Tile("FEELS LIKE", deg(f.feels), "Humidity ${Math.round(f.humidity)}%", null, Modifier.weight(1f))
                }
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Tile("PRESSURE", if (state.imperial) "%.2f".format(Locale.US, f.pressure) else "${Math.round(f.pressure)}",
                        if (state.imperial) "inHg" else "hPa", null, Modifier.weight(1f))
                    Tile("DEW POINT", deg(f.dew), "Visibility ${Math.round(f.visibility)} ${if (state.imperial) "mi" else "km"}", null, Modifier.weight(1f))
                }
            }
            item { Sun(f) }
            item { Spacer(Modifier.height(8.dp)) }
        }
    }
}

@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(CardBg).padding(14.dp)) { content() }
}

@Composable
private fun Label(t: String) = Text(t, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(0.55f))

/// Current conditions: the temperature ring with today's sky under it, the high and low beside it.
@Composable
private fun Now(place: String, located: Boolean, f: Forecast) {
    val next = f.next24()
    val peak = next.maxByOrNull { it.temp }
    val trough = next.minByOrNull { it.temp }
    Card {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Text((if (located) "➤ " else "") + place, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp),
                modifier = Modifier.padding(top = 8.dp)) {
                TempRing(f.temp, trough?.temp ?: f.lo ?: f.temp, peak?.temp ?: f.hi ?: f.temp, WxCode.emoji(f.code, f.isDay), 150.dp)
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Pill(deg(peak?.temp ?: f.hi), Color(0xFFFA7350))
                    Text("High ${clock(peak?.time)}", fontSize = 11.sp, color = Color.White.copy(0.6f))
                    Spacer(Modifier.height(10.dp))
                    Pill(deg(trough?.temp ?: f.lo), Color(0xFF599EFF))
                    Text("Low ${clock(trough?.time)}", fontSize = 11.sp, color = Color.White.copy(0.6f))
                }
            }
            Text(WxCode.words(f.code), fontSize = 18.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp))
            Text("Feels like ${deg(f.feels)}", fontSize = 13.sp, color = Color.White.copy(0.65f))
        }
    }
}

@Composable
fun Pill(text: String, color: Color) {
    Text(text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.clip(CircleShape).background(color.copy(0.38f)).padding(horizontal = 14.dp, vertical = 4.dp))
}

/// 270 degree ring, open at the bottom, cool to warm, with a dot at the current temperature.
@Composable
fun TempRing(temp: Double, lo: Double, hi: Double, sky: String, size: Dp) {
    val top = maxOf(hi, temp, lo + 1)
    val bottom = minOf(lo, temp)
    val frac = ((temp - bottom) / (top - bottom)).coerceIn(0.0, 1.0).toFloat()
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val lw = this.size.minDimension * 0.11f
            val r = (this.size.minDimension - lw) / 2
            val tl = Offset(center.x - r, center.y - r)
            val arc = androidx.compose.ui.geometry.Size(r * 2, r * 2)
            drawArc(Color.White.copy(0.12f), 135f, 270f, false, tl, arc, style = Stroke(lw, cap = StrokeCap.Round))
            drawArc(
                Brush.sweepGradient(
                    // The arc runs from 135° (bottom left, blue) over the top (yellow) to 45° (bottom right, red).
                    0f to Color(0xFFFA8550), 0.125f to Color(0xFFFA6650), 0.375f to Color(0xFF59A6FF),
                    0.75f to Color(0xFFFACC4D), 1f to Color(0xFFFA8550),
                    center = center,
                ),
                135f, 270f, false, tl, arc, style = Stroke(lw, cap = StrokeCap.Round),
            )
            val a = Math.toRadians(135.0 + 270.0 * frac)
            val dot = Offset(center.x + r * cos(a).toFloat(), center.y + r * sin(a).toFloat())
            drawCircle(Color.Black.copy(0.6f), lw * 0.72f, dot)
            drawCircle(Color.White, lw * 0.6f, dot)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(deg(temp), fontSize = (size.value * 0.26f).sp, fontWeight = FontWeight.Medium)
            Text(sky, fontSize = (size.value * 0.15f).sp)
        }
    }
}

@Composable
private fun Alerts(f: Forecast) {
    Card {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("⚠️ Weather Alerts", fontWeight = FontWeight.Bold, color = Color(0xFFFF6B5B))
            f.alerts.take(4).forEach { a ->
                Text(a.event, fontWeight = FontWeight.SemiBold)
                Text(a.headline, fontSize = 12.sp, color = Color.White.copy(0.7f), maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun Hourly(f: Forecast) {
    Card {
        Column {
            Label("NEXT 24 HOURS")
            LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.padding(top = 10.dp)) {
                items(f.next24()) { h ->
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(clock(h.time).replaceFirstChar { it.uppercase() }, fontSize = 12.sp, color = Color.White.copy(0.7f))
                        Text(WxCode.emoji(h.code, h.isDay), fontSize = 22.sp, modifier = Modifier.padding(vertical = 4.dp))
                        Text(deg(h.temp), fontWeight = FontWeight.SemiBold)
                        Text(if (h.pop >= 10) "${h.pop}%" else " ", fontSize = 11.sp, color = Color(0xFF59A6FF))
                    }
                }
            }
        }
    }
}

@Composable
private fun Daily(f: Forecast) {
    val days = f.days.take(10)
    val lowest = days.minOfOrNull { it.lo } ?: 0.0
    val highest = days.maxOfOrNull { it.hi } ?: 1.0
    Card {
        Column {
            Label("${days.size}-DAY FORECAST")
            days.forEachIndexed { i, d ->
                if (i > 0) HorizontalDivider(color = Color.White.copy(0.08f))
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 8.dp)) {
                    Text(if (d.date == LocalDate.now()) "Today" else d.date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.US),
                        modifier = Modifier.width(54.dp), fontWeight = FontWeight.SemiBold)
                    Text(WxCode.emoji(d.code), fontSize = 20.sp, modifier = Modifier.width(34.dp))
                    Text(if (d.pop >= 10) "${d.pop}%" else "", fontSize = 12.sp, color = Color(0xFF59A6FF), modifier = Modifier.width(38.dp))
                    Text(deg(d.lo), color = Color.White.copy(0.6f), modifier = Modifier.width(38.dp))
                    RangeBar(d.lo, d.hi, lowest, highest, Modifier.weight(1f))
                    Text(deg(d.hi), fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 8.dp).width(38.dp))
                }
            }
        }
    }
}

@Composable
private fun RangeBar(lo: Double, hi: Double, min: Double, max: Double, modifier: Modifier) {
    Canvas(modifier.height(6.dp)) {
        val span = (max - min).coerceAtLeast(1.0)
        val x0 = (((lo - min) / span) * size.width).toFloat()
        val x1 = (((hi - min) / span) * size.width).toFloat()
        drawLine(Color.White.copy(0.1f), Offset(0f, center.y), Offset(size.width, center.y), size.height, StrokeCap.Round)
        drawLine(Brush.horizontalGradient(listOf(Color(0xFF59A6FF), Color(0xFFFACC4D), Color(0xFFFA6650))),
            Offset(x0, center.y), Offset(maxOf(x1, x0 + 1f), center.y), size.height, StrokeCap.Round)
    }
}

@Composable
private fun Tile(title: String, value: String, sub: String, color: Color?, modifier: Modifier) {
    Box(modifier.clip(RoundedCornerShape(18.dp)).background(CardBg).padding(14.dp)) {
        Column {
            Label(title)
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
                if (color != null) Box(Modifier.size(10.dp).clip(CircleShape).background(color))
                if (color != null) Spacer(Modifier.width(8.dp))
                Text(value, fontSize = 30.sp)
            }
            Text(sub, fontSize = 12.sp, color = Color.White.copy(0.7f), maxLines = 2)
        }
    }
}

@Composable
private fun Sun(f: Forecast) {
    val today = f.days.firstOrNull() ?: return
    val fmt = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    Card {
        Row {
            Column(Modifier.weight(1f)) { Label("SUNRISE"); Text(today.sunrise?.format(fmt) ?: "--", fontSize = 20.sp) }
            Column(Modifier.weight(1f)) { Label("SUNSET"); Text(today.sunset?.format(fmt) ?: "--", fontSize = 20.sp) }
        }
    }
}

/// "3p", "6a", or "now" for the current hour.
fun clock(t: java.time.LocalDateTime?): String {
    t ?: return ""
    val now = java.time.LocalDateTime.now()
    if (!t.isAfter(now.plusMinutes(45)) && !t.isBefore(now.minusMinutes(45))) return "now"
    val h = t.hour % 12
    return "${if (h == 0) 12 else h}${if (t.hour < 12) "a" else "p"}"
}
