import SwiftUI

// Extra layer pages (Layers > Overlays) and the power outage details sheet.

// MARK: - Road Weather

enum RoadView: String, CaseIterable {
    case radius, screen
    var title: String { self == .radius ? "60 mile radius" : "Area on screen" }
    var detail: String {
        self == .radius ? "Road conditions in a 60-mile radius around your location."
                        : "Road conditions across whatever part of the map you're looking at."
    }
}

struct RoadWeatherPage: View {
    @ObservedObject var radar: RadarController
    @AppStorage("roadView") private var viewRaw = RoadView.radius.rawValue

    var body: some View {
        KitPage(title: "Road Weather") {
            KitSectionHeader(text: "Default Road Weather view")
            KitPills(options: RoadView.allCases.map { (value: $0.rawValue, title: $0.title) }, selection: $viewRaw)
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Kit.row)
            KitFooter(text: (RoadView(rawValue: viewRaw) ?? .radius).detail)
            KitSectionHeader(text: "Legend")
            ForEach([RoadWeather.dry, .wet, .slush, .snow, .ice, .frost], id: \.label) { s in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4).fill(Color(s.color)).frame(width: 26, height: 14)
                    Text(s.label)
                }
                .kitRow()
            }
            KitFooter(text: "Estimated from the last few hours of temperature, rain and snow. Not official road reports.")
        }
        .onChange(of: viewRaw) { _, _ in reload() }
    }

    /// Redraw the road points with the new setting.
    private func reload() {
        guard radar.layers.contains(.road) else { return }
        radar.layers.remove(.road)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { radar.layers.insert(.road) }
    }
}

// MARK: - Aviation

struct AviationPage: View {
    @ObservedObject var radar: RadarController
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store

    /// Shown on this page instead of in the Overlays list.
    static let layers: [MapLayer] = [.aviation, .sigmets, .airmets, .tfrs, .echoTops, .vfrChart]

    var body: some View {
        KitPage(title: "Aviation") {
            KitSectionHeader(text: "Weather")
            row(.aviation, "Flight categories", "VFR, MVFR, IFR and LIFR at airports (zoom in)")
            row(.sigmets, "SIGMETs", "Convective, severe turbulence and icing")
            row(.airmets, "AIRMETs", "Moderate turbulence, icing, IFR and mountain obscuration")
            row(.echoTops, "Echo Tops", "How tall the storms are")
            KitSectionHeader(text: "Airspace")
            row(.tfrs, "Temporary Flight Restrictions", "Active TFRs from the FAA")
            KitSectionHeader(text: "Charts")
            row(.vfrChart, "VFR Sectional Chart", "FAA sectional as the map background")
            KitFooter(text: "Not for in-flight navigation. Always get an official briefing before you fly.")
        }
    }

    private func row(_ l: MapLayer, _ title: String, _ sub: String) -> some View {
        let locked = !store.canUse(l)
        return KitToggleRow(title: title, subtitle: sub, badge: locked ? l.tier : nil, isOn: Binding(
            get: { radar.layers.contains(l) && !locked },
            set: { on in
                if locked { showPlans = true; return }
                if on { radar.layers.insert(l) } else { radar.layers.remove(l) }
            }))
    }
}

// MARK: - Power outage details

/// A county with an outage, from tapping it on the map.
struct OutageArea: Identifiable, Equatable {
    let county: String
    let state: String
    let affected: Int
    var id: String { "\(county)|\(state)" }

    /// "Duval County", without doubling up "County" or "Parish".
    var name: String {
        let low = county.lowercased()
        if low.hasSuffix("county") || low.hasSuffix("parish") || low.hasSuffix("borough") || low.hasSuffix("city") { return county }
        return state.lowercased().hasPrefix("louisiana") || state == "LA" ? "\(county) Parish" : "\(county) County"
    }
}

struct OutageSheet: View {
    let area: OutageArea
    var body: some View {
        KitSheet { OutagePage(area: area) }
    }
}

private struct OutagePage: View {
    let area: OutageArea
    @Environment(\.kitClose) private var close
    @State private var records: [[String: Any]] = []
    @State private var loaded = false

    private static let source = URL(string: "https://openenergyhub.ornl.gov/explore/dataset/odin-real-time-outages-county/")!

    var body: some View {
        VStack(spacing: 0) {
            KitHeader(title: "Power Outage", back: nil, close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    VStack(alignment: .leading, spacing: 18) {
                        Text(summary).font(.title3)
                        if let updated { section("Updated") { pair("Time", updated) } }
                        section("Counts") {
                            pair("Affected", affected.formatted())
                            if let t = tracked { pair("Tracked", t.formatted()) }
                        }
                        if records.count > 1 {
                            section("Utilities") {
                                ForEach(records.indices, id: \.self) { i in
                                    let r = records[i]
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(Self.text(r, keys: ["utility", "utility_name", "utilityname", "name"]) ?? "Utility \(i + 1)").font(.headline)
                                        pair("Affected", (Self.number(r, keys: ["metersaffected", "customers_out", "customersout"]) ?? 0).formatted())
                                        if let t = Self.number(r, keys: ["meterstotal", "totalmeters", "customers_tracked", "customerstracked", "total"]) {
                                            pair("Tracked", t.formatted())
                                        }
                                    }
                                }
                            }
                        }
                        if !loaded { ProgressView() }
                        Link("Power outage data: ORNL ODIN (Open Energy Data Initiative)", destination: Self.source)
                            .font(.footnote)
                    }
                    .padding(20)
                }
            }
        }
        .background(Kit.page.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task { await load() }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.06)], startPoint: .topTrailing, endPoint: .bottomLeading)
            Image(systemName: "bolt.fill").font(.system(size: 120)).foregroundStyle(.white.opacity(0.12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
            Text("\(area.name) Outage").font(.largeTitle.weight(.medium)).foregroundStyle(.white).padding(20)
            ShareLink(item: summary + " (\(area.name), \(area.state))") {
                Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(.white).padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(height: 220)
        .overlay(alignment: .top) { HazardStripe().frame(height: 14) }
    }

    // values from the detailed records, falling back to what the map already had
    private var affected: Int {
        let sum = records.compactMap { Self.number($0, keys: ["metersaffected", "customers_out", "customersout"]) }.reduce(0, +)
        return records.isEmpty ? area.affected : max(sum, area.affected)
    }
    private var tracked: Int? {
        let t = records.compactMap { Self.number($0, keys: ["meterstotal", "totalmeters", "customers_tracked", "customerstracked", "total"]) }
        return t.isEmpty ? nil : t.reduce(0, +)
    }
    private var updated: String? {
        guard let s = records.compactMap({ Self.text($0, keys: ["runstarttime", "lastupdated", "last_updated", "updated", "timestamp", "date"]) }).first else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d.formatted(date: .abbreviated, time: .shortened) }
        return s
    }
    private var summary: String {
        let n = affected.formatted()
        if let t = tracked, t > 0 {
            let pct = Double(affected) / Double(t) * 100
            return "There are \(n) customers affected by this outage (\(String(format: "%.1f", pct))% of the total customers)."
        }
        return "There are \(n) customers affected by this outage."
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2)
            VStack(alignment: .leading, spacing: 8) { content() }.padding(.leading, 10)
        }
    }
    private func pair(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(v)
        }
        .font(.title3)
    }

    // ODIN field names vary a little, so look up a few likely names (any case).
    private static func value(_ r: [String: Any], _ keys: [String]) -> Any? {
        for k in keys { if let v = r.first(where: { $0.key.lowercased() == k })?.value, !(v is NSNull) { return v } }
        return nil
    }
    static func number(_ r: [String: Any], keys: [String]) -> Int? {
        let v = value(r, keys)
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let d = Double(s) { return Int(d) }
        return nil
    }
    static func text(_ r: [String: Any], keys: [String]) -> String? {
        let v = value(r, keys)
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private func load() async {
        defer { loaded = true }
        let esc: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "\\\"") }
        let q = "county=\"\(esc(area.county))\" and state=\"\(esc(area.state))\""
        var c = URLComponents(string: "https://openenergyhub.ornl.gov/api/explore/v2.1/catalog/datasets/odin-real-time-outages-county/records")!
        c.queryItems = [.init(name: "where", value: q), .init(name: "limit", value: "50")]
        guard let url = c.url, let data = try? await URLSession.shared.data(from: url).0,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = j["results"] as? [[String: Any]] else { return }
        records = results
    }
}

/// Yellow and black caution stripes.
struct HazardStripe: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.96, green: 0.65, blue: 0.14)))
            let w = size.height * 1.4
            var x = -size.height
            var p = Path()
            while x < size.width + size.height {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + w / 2, y: 0))
                p.addLine(to: CGPoint(x: x + w / 2, y: size.height))
                p.closeSubpath()
                x += w
            }
            ctx.fill(p, with: .color(.black))
        }
    }
}

// MARK: - Map Options (background picker)

struct MapOptionsSheet: View {
    @ObservedObject var radar: RadarController
    @EnvironmentObject var store: Store
    var body: some View {
        KitSheet { MapOptionsPage(radar: radar, root: true).environmentObject(store) }
    }
}

struct MapOptionsPage: View {
    @ObservedObject var radar: RadarController
    var root = false
    @EnvironmentObject var store: Store
    @AppStorage("mapLabels") private var labels = true
    @AppStorage("mapRoads") private var roads = false
    @AppStorage("mapBorders") private var borders = true
    @AppStorage("mapCounties") private var counties = true
    @State private var showPlans = false

    private let cols = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    private var picked: Basemap { radar.basemap }

    var body: some View {
        KitPage(title: "Map Options", root: root) {
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(Basemap.allCases) { b in card(b) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            KitSectionHeader(text: "Show on the map")
            KitToggleRow(title: "Place Labels", subtitle: hasLabels ? nil : "This background has its own labels", isOn: $labels)
                .disabled(!hasLabels).opacity(hasLabels ? 1 : 0.5)
            KitToggleRow(title: "Roads", subtitle: hasOwnRoads ? "This background has its own roads" : "Highways and major roads over the radar", isOn: $roads)
                .disabled(hasOwnRoads).opacity(hasOwnRoads ? 0.5 : 1)
            KitToggleRow(title: "State and US borders", isOn: $borders)
            KitToggleRow(title: "County lines", subtitle: "Shown when zoomed in to about one state", isOn: $counties)
            KitFooter(text: "Maps © Esri, © CARTO, © OpenStreetMap contributors, FAA and Apple.")
        }
        .sheet(isPresented: $showPlans) { PlansView(start: .pro).environmentObject(store) }
    }

    private var resolved: Basemap { picked == .auto ? .dark : picked }
    private var hasLabels: Bool { resolved.tiles?.labels != nil }
    private var hasOwnRoads: Bool { [.roads, .topo, .vfr, .apple, .satellite].contains(resolved) }

    private func card(_ b: Basemap) -> some View {
        let locked = store.effectivePlan < b.tier
        let selected = picked == b
        return Button {
            if locked { showPlans = true } else { radar.basemap = b }
        } label: {
            ZStack(alignment: .bottomLeading) {
                thumb(b)
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .clipped()
                HStack {
                    Text(b.title).font(.headline).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    if locked { Image(systemName: "lock.fill").foregroundStyle(Kit.green) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.55))
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Kit.purple : Kit.line, lineWidth: selected ? 3 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func thumb(_ b: Basemap) -> some View {
        if let u = b.thumb {
            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.2) }
        } else {
            ZStack {
                switch b {
                case .auto: LinearGradient(colors: [Color(white: 0.12), Color(white: 0.85)], startPoint: .leading, endPoint: .trailing)
                case .satellite: LinearGradient(colors: [Color(red: 0.1, green: 0.25, blue: 0.15), Color(red: 0.1, green: 0.2, blue: 0.4)], startPoint: .top, endPoint: .bottom)
                default: LinearGradient(colors: [Color(red: 0.85, green: 0.9, blue: 0.85), Color(red: 0.7, green: 0.82, blue: 0.95)], startPoint: .top, endPoint: .bottom)
                }
                Image(systemName: b == .auto ? "circle.lefthalf.filled" : b == .satellite ? "globe.americas.fill" : "map.fill")
                    .font(.system(size: 30)).foregroundStyle(.white).shadow(radius: 3)
            }
        }
    }
}
