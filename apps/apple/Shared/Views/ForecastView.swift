import SwiftUI

/// Full forecast for the selected place: alerts, now, hourly, 16-day, details.
struct ForecastView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let f = state.forecast {
                    ForEach(state.alerts) { a in AlertRow(alert: a) }
                    hero(f)
                    if store.effectivePlan == .free { AdBanner(kind: .banner) }
                    section("Next 48 hours") { hourly(f) }
                    section("16-day forecast") { daily(f) }
                    section("Details") { details(f) }
                    Text("Forecast: Open-Meteo models (NOAA NBM, GFS, HRRR, ECMWF blend). Alerts: National Weather Service.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let e = state.error {
                    ContentUnavailableView("No forecast", systemImage: "cloud.slash", description: Text(e))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await state.refresh() }
        .navigationTitle(state.place.name)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            c()
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func hero(_ f: Forecast) -> some View {
        let c = f.current
        return HStack(spacing: 18) {
            Image(systemName: WX.symbol(c.weather_code, day: c.is_day == 1)).symbolRenderingMode(.multicolor).font(.system(size: 54))
            VStack(alignment: .leading) {
                Text(Fmt.temp(c.temperature_2m)).font(.system(size: 56, weight: .bold, design: .rounded))
                Text("\(WX.text(c.weather_code)) · feels \(Fmt.temp(c.apparent_temperature))").font(.headline)
                Text("High \(Fmt.temp(f.daily.temperature_2m_max.first ?? nil)) · Low \(Fmt.temp(f.daily.temperature_2m_min.first ?? nil))").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func hourly(_ f: Forecast) -> some View {
        let start = f.nowIndex, end = min(f.hourly.time.count, start + 48)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(start..<end, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text(i == start ? "Now" : Fmt.hour(f.hourly.time[i], offset: f.utc_offset_seconds)).font(.caption.bold())
                        Image(systemName: WX.symbol(f.hourly.weather_code[i] ?? 3, day: (f.hourly.is_day[i] ?? 1) == 1)).symbolRenderingMode(.multicolor)
                        Text(Fmt.temp(f.hourly.temperature_2m[i])).font(.callout.weight(.semibold))
                        Text("\(f.hourly.precipitation_probability[i] ?? 0)%").font(.caption2).foregroundStyle(.blue)
                    }
                    .frame(width: 44)
                }
            }
        }
    }

    private func daily(_ f: Forecast) -> some View {
        let all = f.daily.temperature_2m_max.compactMap { $0 } + f.daily.temperature_2m_min.compactMap { $0 }
        let lo = all.min() ?? 0, hi = all.max() ?? 1
        return VStack(spacing: 0) {
            ForEach(f.daily.time.indices, id: \.self) { d in
                HStack {
                    Text(d == 0 ? "Today" : Fmt.weekday(f.daily.time[d], offset: f.utc_offset_seconds)).frame(width: 52, alignment: .leading)
                    Image(systemName: WX.symbol(f.daily.weather_code[d] ?? 3)).symbolRenderingMode(.multicolor).frame(width: 30)
                    Text("\(f.daily.precipitation_probability_max[d] ?? 0)%").font(.caption).foregroundStyle(.blue).frame(width: 36)
                    Text(Fmt.temp(f.daily.temperature_2m_min[d])).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    GeometryReader { g in
                        let mn = f.daily.temperature_2m_min[d] ?? lo, mx = f.daily.temperature_2m_max[d] ?? hi
                        let x0 = (mn - lo) / max(1, hi - lo) * g.size.width, x1 = (mx - lo) / max(1, hi - lo) * g.size.width
                        Capsule().fill(.quaternary).frame(height: 5).overlay(alignment: .leading) {
                            Capsule().fill(LinearGradient(colors: [.cyan, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, x1 - x0), height: 5).offset(x: x0)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 20)
                    Text(Fmt.temp(f.daily.temperature_2m_max[d])).bold().frame(width: 40, alignment: .leading)
                }
                .padding(.vertical, 7)
                if d < f.daily.time.count - 1 { Divider() }
            }
        }
    }

    private func details(_ f: Forecast) -> some View {
        let c = f.current, u = state.units
        let rows: [(String, String)] = [
            ("Wind", "\(Fmt.compass(c.wind_direction_10m)) \(Int(c.wind_speed_10m ?? 0)) \(u.windLabel), gusts \(Int(c.wind_gusts_10m ?? 0))"),
            ("Humidity", "\(Int(c.relative_humidity_2m ?? 0))%"),
            ("Dew point", Fmt.temp(c.dew_point_2m)),
            ("Pressure", u == .imperial ? String(format: "%.2f in", (c.pressure_msl ?? 0) * 0.02953) : "\(Int(c.pressure_msl ?? 0)) mb"),
            ("UV index", String(format: "%.0f", c.uv_index ?? 0)),
            ("Sunrise", Fmt.time(f.daily.sunrise.first ?? "", offset: f.utc_offset_seconds)),
            ("Sunset", Fmt.time(f.daily.sunset.first ?? "", offset: f.utc_offset_seconds)),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Text(r.1).font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AlertRow: View {
    let alert: WeatherAlert
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { open.toggle() } } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(alert.event).bold()
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            if let h = alert.headline { Text(h).font(.subheadline) }
            if open {
                if let d = alert.description { Text(d).font(.callout) }
                if let i = alert.instruction { Text(i).font(.callout.bold()) }
            }
        }
        .padding()
        .foregroundStyle(.white)
        .background(alert.isWarning ? Color.red : Color.orange, in: RoundedRectangle(cornerRadius: 14))
    }
}
