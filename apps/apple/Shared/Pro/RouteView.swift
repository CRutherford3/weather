import SwiftUI
import MapKit

/// One checkpoint along a drive: where you'll be, when, and the forecast for that hour.
struct RouteStop: Identifiable {
    let id: Int
    let coord: CLLocationCoordinate2D
    let eta: Date
    var name: String
    var temp: Double?
    var pop: Int?
    var code: Int?
    var wind: Double?
    var gust: Double?

    /// 0 fine, 1 use caution, 2 hazardous. Gusts are compared in mph.
    func risk(_ units: Units) -> Int {
        let c = code ?? 0
        let g = (gust ?? 0) / (units == .metric ? 1.609 : 1)
        if [65, 66, 67, 75, 82, 86, 95, 96, 99, 56, 57].contains(c) || g >= 45 { return 2 }
        if (pop ?? 0) >= 50 || [45, 48, 51, 53, 55, 61, 63, 71, 73, 77, 80, 81, 85].contains(c) || g >= 30 { return 1 }
        return 0
    }
}

/// Plans a drive with Apple Maps and checks the forecast at each point for the time you'll be there.
@MainActor
final class RouteModel: ObservableObject {
    @Published var route: MKRoute?
    @Published var stops: [RouteStop] = []
    @Published var alerts: [WeatherAlert] = []
    @Published var loading = false
    @Published var error: String?

    func plan(from: CLLocationCoordinate2D, to: MKMapItem, depart: Date, units: Units) async {
        loading = true; error = nil; route = nil; stops = []; alerts = []
        defer { loading = false }

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = to
        req.transportType = .automobile
        req.departureDate = depart
        guard let r = try? await MKDirections(request: req).calculate().routes.first else {
            error = "Couldn't find a driving route. Try a different destination."
            return
        }
        route = r

        // checkpoints about every 30 minutes of driving (2 to 12 legs)
        let n = r.polyline.pointCount
        guard n >= 2 else { return }
        let pts = r.polyline.points()
        var cum = [0.0]
        for i in 1..<n { cum.append(cum[i - 1] + pts[i - 1].distance(to: pts[i])) }
        let total = max(cum[n - 1], 1)
        let legs = min(12, max(2, Int(r.expectedTravelTime / 1800) + 1))
        var out: [RouteStop] = []
        var j = 0
        for k in 0...legs {
            let frac = Double(k) / Double(legs)
            while j < n - 1 && cum[j + 1] < frac * total { j += 1 }
            out.append(RouteStop(id: k, coord: pts[j].coordinate, eta: depart.addingTimeInterval(frac * r.expectedTravelTime),
                                 name: k == 0 ? "Start" : (k == legs ? (to.name ?? "Destination") : "")))
        }
        stops = out

        // forecast for each checkpoint at its arrival hour
        await withTaskGroup(of: (Int, Hour?).self) { g in
            for s in out {
                let c = s.coord, t = s.eta
                g.addTask { (s.id, await Self.hour(lat: c.latitude, lon: c.longitude, at: t, units: units)) }
            }
            for await (i, h) in g {
                guard let h, stops.indices.contains(i) else { continue }
                stops[i].temp = h.temp; stops[i].pop = h.pop; stops[i].code = h.code; stops[i].wind = h.wind; stops[i].gust = h.gust
            }
        }

        // alerts anywhere along the way
        var seen = Set<String>(), found: [WeatherAlert] = []
        await withTaskGroup(of: [WeatherAlert].self) { g in
            for s in out {
                let c = s.coord
                g.addTask { await WeatherService.shared.alerts(for: Place(name: "", lat: c.latitude, lon: c.longitude)) }
            }
            for await list in g {
                for a in list where !seen.contains(a.id) { seen.insert(a.id); found.append(a) }
            }
        }
        alerts = found.sorted { ($0.isWarning ? 0 : 1) < ($1.isWarning ? 0 : 1) }

        // town names for the checkpoints in between (one at a time; Apple's geocoder is rate limited)
        for i in stops.indices where stops[i].name.isEmpty {
            let c = stops[i].coord
            stops[i].name = await WeatherService.shared.placeName(c.latitude, c.longitude)
        }
    }

    struct Hour: Sendable { var temp: Double?; var pop: Int?; var code: Int?; var wind: Double?; var gust: Double? }

    nonisolated static func hour(lat: Double, lon: Double, at t: Date, units: Units) async -> Hour? {
        struct R: Decodable {
            struct H: Decodable {
                let time: [Double]
                let temperature_2m: [Double?]
                let precipitation_probability: [Int?]
                let weather_code: [Int?]
                let wind_speed_10m: [Double?]
                let wind_gusts_10m: [Double?]
            }
            let hourly: H
        }
        var comp = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comp.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", lat)),
            .init(name: "longitude", value: String(format: "%.3f", lon)),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,wind_speed_10m,wind_gusts_10m"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "GMT"),
            .init(name: "forecast_days", value: "7"),
        ]
        if units == .imperial {
            comp.queryItems! += [.init(name: "temperature_unit", value: "fahrenheit"), .init(name: "wind_speed_unit", value: "mph")]
        }
        guard let url = comp.url,
              let res = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(R.self, from: res.0), !r.hourly.time.isEmpty else { return nil }
        let target = t.timeIntervalSince1970
        let h = r.hourly
        let i = h.time.indices.min { abs(h.time[$0] - target) < abs(h.time[$1] - target) } ?? 0
        func at<T>(_ a: [T?]) -> T? { a.indices.contains(i) ? a[i] : nil }
        return Hour(temp: at(h.temperature_2m), pop: at(h.precipitation_probability), code: at(h.weather_code),
                    wind: at(h.wind_speed_10m), gust: at(h.wind_gusts_10m))
    }
}

/// Route Weather (Pro): pick a destination and departure time, see the weather along the drive.
struct RouteView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @StateObject private var model = RouteModel()
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var dest: MKMapItem?
    @State private var depart = Date()
    @State private var camera: MapCameraPosition = .automatic
    @State private var showPlans = false

    var body: some View {
        Group {
            if store.effectivePlan < .pro { locked } else { planner }
        }
        .navigationTitle("Route Weather")
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    private var locked: some View {
        VStack(spacing: 14) {
            Image(systemName: "car.fill").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Route Weather").font(.title2.bold())
            Text("See the forecast for every stretch of your drive, for the time you'll be there, plus any warnings along the way.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { showPlans = true } label: { Label("Get Pro", systemImage: "lock.open.fill") }.buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var planner: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                form
                if model.loading { ProgressView("Checking the weather along your route…").frame(maxWidth: .infinity).padding() }
                if let e = model.error { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let r = model.route { result(r) }
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("From \(state.place.name)", systemImage: "location.fill").font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "mappin.and.ellipse")
                TextField("Where to? Address, city or place", text: $query)
                    .onSubmit(search)
                    .autocorrectionDisabled()
                if !query.isEmpty { Button("Search", action: search).buttonStyle(.bordered) }
            }
            if let d = dest, results.isEmpty {
                Label(d.name ?? "Destination", systemImage: "flag.checkered").font(.headline)
            }
            ForEach(results.indices, id: \.self) { i in
                let m = results[i]
                Button {
                    dest = m; query = m.name ?? query; results = []
                } label: {
                    VStack(alignment: .leading) {
                        Text(m.name ?? "Place").font(.callout.weight(.semibold))
                        if let t = m.placemark.title { Text(t).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
            }
            DatePicker("Leave", selection: $depart, in: Date().addingTimeInterval(-3600)..., displayedComponents: [.date, .hourAndMinute])
            Button {
                guard let d = dest else { return }
                Task {
                    await model.plan(from: state.place.coordinate, to: d, depart: depart, units: state.units)
                    camera = .automatic
                }
            } label: {
                Label("Check route weather", systemImage: "car.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(dest == nil || model.loading)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: state.place.coordinate, latitudinalMeters: 800_000, longitudinalMeters: 800_000)
        Task {
            let r = try? await MKLocalSearch(request: req).start()
            results = Array((r?.mapItems ?? []).prefix(6))
        }
    }

    private func color(_ risk: Int) -> Color { risk == 2 ? .red : risk == 1 ? .orange : .green }

    @ViewBuilder private func result(_ r: MKRoute) -> some View {
        let u = state.units
        let dist = Measurement(value: r.distance, unit: UnitLength.meters).converted(to: u == .imperial ? .miles : .kilometers)
        let worst = model.stops.max { $0.risk(u) < $1.risk(u) }

        Map(position: $camera) {
            MapPolyline(r.polyline).stroke(.blue, lineWidth: 5)
            ForEach(model.stops) { s in
                Annotation(s.name, coordinate: s.coord) {
                    Image(systemName: WX.symbol(s.code ?? 3)).symbolRenderingMode(.multicolor)
                        .padding(6).background(color(s.risk(u)).opacity(0.85), in: Circle())
                }
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 6) {
            Text("\(Int(dist.value.rounded())) \(u == .imperial ? "mi" : "km") · \(Self.duration(r.expectedTravelTime))").font(.headline)
            if let w = worst, w.risk(u) > 0 {
                Label("\(WX.text(w.code ?? 0)) near \(w.name.isEmpty ? "your route" : w.name) around \(w.eta.formatted(date: .omitted, time: .shortened))",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(color(w.risk(u)))
            } else if !model.stops.isEmpty && model.stops.allSatisfy({ $0.code != nil }) {
                Label("Looks good the whole way", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
        }

        ForEach(model.alerts) { a in AlertRow(alert: a) }

        VStack(spacing: 0) {
            ForEach(model.stops) { s in
                HStack(spacing: 10) {
                    Circle().fill(color(s.risk(u))).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.eta.formatted(date: .omitted, time: .shortened)).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(s.name.isEmpty ? "…" : s.name).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    if let c = s.code { Image(systemName: WX.symbol(c)).symbolRenderingMode(.multicolor) }
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.temp(s.temp)).font(.callout.bold())
                        Text("\((s.pop ?? 0))% · \(Int(s.gust ?? 0)) \(u.windLabel) gusts").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
        .padding(.horizontal)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        Text("Driving route: Apple Maps. Forecast: Open-Meteo. Alerts: National Weather Service. Times are estimates.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .short
        return f.string(from: s) ?? ""
    }
}
