import SwiftUI

/// MyRadar-style card over the map. Follows the crosshair; minimizes to a small temperature pill.
struct WeatherCard: View {
    @EnvironmentObject var state: AppState
    var onHome: () -> Void

    private var place: Place { state.center ?? state.place }
    private var f: Forecast? { state.center != nil ? state.centerForecast : state.forecast }
    private var away: Bool { state.center != nil }

    var body: some View {
        Group {
            if state.cardCollapsed { pill } else { card }
        }
        .animation(.snappy, value: state.cardCollapsed)
    }

    private var pill: some View {
        Button { state.cardCollapsed = false } label: {
            HStack(spacing: 8) {
                Text(Fmt.temp(f?.current.temperature_2m)).font(.title3.bold())
                if let c = f?.current { Image(systemName: WX.symbol(c.weather_code, day: c.is_day == 1)).symbolRenderingMode(.multicolor) }
                if away { Image(systemName: "scope").foregroundStyle(.tint) }
                Text(place.name).lineLimit(1)
                Image(systemName: "plus").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(spacing: 10) {
            HStack {
                if away {
                    Button(action: onHome) { Image(systemName: "house.fill") }.help("Back to \(state.place.name)")
                } else {
                    Button { Task { await state.useMyLocation() } } label: { Image(systemName: "location.fill") }.help("Use my location")
                }
                Spacer()
                HStack(spacing: 6) {
                    if away { Image(systemName: "scope").foregroundStyle(.tint) }
                    Text(place.name).font(.headline).lineLimit(1)
                }
                Spacer()
                Button { state.toggleFavorite(place) } label: { Image(systemName: state.isFavorite(place) ? "star.fill" : "star") }
                Button { state.cardCollapsed = true } label: { Image(systemName: "minus") }.help("Minimize")
            }
            .buttonStyle(.borderless)

            if let f {
                let c = f.current, i = f.nowIndex
                let next24 = Array(f.hourly.temperature_2m.dropFirst(i).prefix(24)).compactMap { $0 }
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 0) {
                        Text(Fmt.temp(c.temperature_2m)).font(.system(size: 46, weight: .bold, design: .rounded))
                        Text("feels \(Fmt.temp(c.apparent_temperature))").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Label(WX.text(c.weather_code), systemImage: WX.symbol(c.weather_code, day: c.is_day == 1))
                            .symbolRenderingMode(.multicolor).font(.subheadline.weight(.semibold))
                        Text("H \(Fmt.temp(next24.max()))  L \(Fmt.temp(next24.min()))").font(.subheadline)
                        if let p = f.daily.precipitation_probability_max.first ?? nil {
                            Label("\(p)% rain today", systemImage: "drop.fill").font(.caption).foregroundStyle(.blue)
                        }
                    }
                    Spacer(minLength: 0)
                    ForEach(1..<min(3, f.daily.time.count), id: \.self) { d in
                        VStack(spacing: 4) {
                            Text(Fmt.weekday(f.daily.time[d], offset: f.utc_offset_seconds)).font(.caption.bold()).foregroundStyle(.secondary)
                            Image(systemName: WX.symbol(f.daily.weather_code[d] ?? 3)).symbolRenderingMode(.multicolor)
                            Text("\(Fmt.temp(f.daily.temperature_2m_max[d])) \(Fmt.temp(f.daily.temperature_2m_min[d]))").font(.caption)
                        }
                    }
                }
            } else {
                ProgressView().frame(height: 70)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}
