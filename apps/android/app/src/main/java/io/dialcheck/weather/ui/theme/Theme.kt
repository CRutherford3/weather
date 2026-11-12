package io.dialcheck.weather.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/// DopplerIQ purple, the same accent the iPhone app uses.
val Accent = Color(0xFF8B5CF6)
val CardBg = Color(0xFF1C1C22)
val ScreenBg = Color(0xFF0B0B10)

private val Scheme = darkColorScheme(
    primary = Accent,
    secondary = Color(0xFF59A6FF),
    background = ScreenBg,
    surface = ScreenBg,
    surfaceContainer = Color(0xFF15151B),
    onBackground = Color.White,
    onSurface = Color.White,
)

/// Always dark, like a radar screen.
@Composable
fun DopplerIQTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Scheme, typography = Typography, content = content)
}
