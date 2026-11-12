package io.dialcheck.weather.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SweepGradient
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import io.dialcheck.weather.MainActivity
import io.dialcheck.weather.data.Forecast
import io.dialcheck.weather.data.Prefs
import io.dialcheck.weather.data.WeatherService
import io.dialcheck.weather.data.WxCode
import io.dialcheck.weather.data.aqiColor
import io.dialcheck.weather.data.deg
import io.dialcheck.weather.data.uvColor
import io.dialcheck.weather.ui.clock
import kotlin.math.cos
import kotlin.math.sin

/// Home Screen "Glance" widget: the temperature ring with today's sky in it, the high and low on the right,
/// and AQI and UV along the bottom. Tapping it opens the Dashboard.
class GlanceWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val place = Prefs.place(context)
        val f: Forecast? = place?.let { runCatching { WeatherService.load(it, Prefs.imperial(context)) }.getOrNull() }
        val open = Intent(context, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_DASHBOARD, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

        provideContent {
            Box(
                GlanceModifier.fillMaxSize().cornerRadius(22.dp).background(Color(0xFF16161A))
                    .clickable(actionStartActivity(open)).padding(10.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (f == null || place == null) {
                    Text("Open DopplerIQ to load the weather", style = TextStyle(color = white(0.8f), fontSize = 12.sp, textAlign = TextAlign.Center))
                } else {
                    val next = f.next24()
                    val peak = next.maxByOrNull { it.temp }
                    val trough = next.minByOrNull { it.temp }
                    val hi = peak?.temp ?: f.hi ?: f.temp
                    val lo = trough?.temp ?: f.lo ?: f.temp
                    Column(GlanceModifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("➤ " + place.name, maxLines = 1,
                            style = TextStyle(color = white(0.9f), fontSize = 12.sp, fontWeight = FontWeight.Medium))
                        Spacer(GlanceModifier.height(4.dp))
                        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Box(GlanceModifier.size(76.dp), contentAlignment = Alignment.Center) {
                                Image(ImageProvider(ring(f.temp, lo, hi)), contentDescription = null, modifier = GlanceModifier.size(76.dp))
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Text(deg(f.temp), style = TextStyle(color = white(1f), fontSize = 20.sp, fontWeight = FontWeight.Medium))
                                    Text(WxCode.emoji(f.code, f.isDay), style = TextStyle(fontSize = 13.sp))
                                }
                            }
                            Spacer(GlanceModifier.width(6.dp))
                            Column(GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                                Pill(deg(hi), Color(0xFFFA7350))
                                Text(clock(peak?.time), style = TextStyle(color = white(0.6f), fontSize = 10.sp))
                                Spacer(GlanceModifier.height(4.dp))
                                Pill(deg(lo), Color(0xFF599EFF))
                                Text(clock(trough?.time), style = TextStyle(color = white(0.6f), fontSize = 10.sp))
                            }
                        }
                        Spacer(GlanceModifier.height(6.dp))
                        Row(GlanceModifier.fillMaxWidth()) {
                            Chip("AQI", f.aqi?.toString() ?: "--", Color(f.aqi?.let(::aqiColor) ?: 0xFF888888), GlanceModifier.defaultWeight())
                            Spacer(GlanceModifier.width(6.dp))
                            Chip("UV", "${Math.round(f.uv)}", Color(uvColor(f.uv)), GlanceModifier.defaultWeight())
                        }
                    }
                }
            }
        }
    }

    companion object {
        /// Redraw every Glance widget, e.g. after the app loads fresh weather.
        suspend fun refreshAll(c: Context) = runCatching { GlanceWidget().updateAll(c) }
    }
}

class GlanceWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = GlanceWidget()
}

private fun white(a: Float) = ColorProvider(Color.White.copy(alpha = a))

@androidx.compose.runtime.Composable
private fun Pill(text: String, color: Color) {
    Box(GlanceModifier.width(52.dp).cornerRadius(12.dp).background(color.copy(alpha = 0.38f)).padding(vertical = 3.dp),
        contentAlignment = Alignment.Center) {
        Text(text, style = TextStyle(color = white(1f), fontSize = 15.sp, fontWeight = FontWeight.Bold))
    }
}

@androidx.compose.runtime.Composable
private fun Chip(label: String, value: String, color: Color, modifier: GlanceModifier) {
    Box(modifier.cornerRadius(10.dp).background(color.copy(alpha = 0.4f)).padding(vertical = 2.dp), contentAlignment = Alignment.Center) {
        Text("$label  $value", style = TextStyle(color = white(1f), fontSize = 12.sp, fontWeight = FontWeight.Bold))
    }
}

/// The ring is drawn as a picture, since widgets can't draw arcs themselves.
private fun ring(temp: Double, lo: Double, hi: Double): Bitmap {
    val s = 228
    val bmp = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888)
    val c = Canvas(bmp)
    val lw = s * 0.11f
    val r = (s - lw) / 2
    val box = RectF(s / 2f - r, s / 2f - r, s / 2f + r, s / 2f + r)
    val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = lw; strokeCap = Paint.Cap.ROUND }
    p.color = android.graphics.Color.argb(31, 255, 255, 255)
    c.drawArc(box, 135f, 270f, false, p)
    p.shader = SweepGradient(s / 2f, s / 2f,
        intArrayOf(0xFFFA8550.toInt(), 0xFFFA6650.toInt(), 0xFF59A6FF.toInt(), 0xFFFACC4D.toInt(), 0xFFFA8550.toInt()),
        floatArrayOf(0f, 0.125f, 0.375f, 0.75f, 1f))
    c.drawArc(box, 135f, 270f, false, p)

    val top = maxOf(hi, temp, lo + 1)
    val bottom = minOf(lo, temp)
    val frac = ((temp - bottom) / (top - bottom)).coerceIn(0.0, 1.0)
    val a = Math.toRadians(135.0 + 270.0 * frac)
    val x = s / 2f + r * cos(a).toFloat()
    val y = s / 2f + r * sin(a).toFloat()
    val dot = Paint(Paint.ANTI_ALIAS_FLAG)
    dot.color = android.graphics.Color.argb(153, 0, 0, 0); c.drawCircle(x, y, lw * 0.72f, dot)
    dot.color = android.graphics.Color.WHITE; c.drawCircle(x, y, lw * 0.6f, dot)
    return bmp
}
