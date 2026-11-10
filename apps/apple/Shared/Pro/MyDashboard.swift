import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Model

/// One widget on a dashboard page. `kind` is a local widget key, a map product id, or a custom type.
struct DashWidget: Codable, Identifiable, Hashable {
    enum Size: String, Codable, CaseIterable { case small, medium, large
        var title: String { rawValue.capitalized }
    }
    var id = UUID()
    var kind: String
    var size: Size = .medium
    var customTitle: String?
    var customURL: String?
}

struct DashPage: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var widgets: [DashWidget]

    static let starter = DashPage(name: "My Dashboard", widgets: [
        DashWidget(kind: "now"), DashWidget(kind: "alerts"),
        DashWidget(kind: "hourly", size: .large), DashWidget(kind: "radar", size: .large),
        DashWidget(kind: "daily"), DashWidget(kind: "details"),
        DashWidget(kind: "spc_d1"), DashWidget(kind: "wpc_sfc"),
    ])
}

/// Widgets that use the selected place's forecast (everything else is a map product or custom).
enum LocalWidget: String, CaseIterable {
    case now, alerts, hourly, daily, details, sun, radar
    var title: String {
        switch self {
        case .now: return "Current Conditions"
        case .alerts: return "Alerts"
        case .hourly: return "Hourly Forecast"
        case .daily: return "16-Day Forecast"
        case .details: return "Conditions Detail"
        case .sun: return "Sun & Moon"
        case .radar: return "Live Radar"
        }
    }
    var icon: String {
        switch self {
        case .now: return "thermometer.sun"
        case .alerts: return "exclamationmark.triangle"
        case .hourly: return "clock"
        case .daily: return "calendar"
        case .details: return "list.bullet.rectangle"
        case .sun: return "sunrise"
        case .radar: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Saved dashboard pages (kept on this device).
final class DashStore: ObservableObject {
    static let shared = DashStore()
    @Published var pages: [DashPage] { didSet { save() } }
    @Published var current = 0

    private static let key = "dashPagesV2"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode([DashPage].self, from: d), !p.isEmpty {
            pages = p
        } else {
            pages = Self.websiteLayout()
        }
    }
    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(pages), forKey: Self.key) }

    /// The website's dashboard pages. iPad and Mac get all of them; iPhone starts with "My Weather".
    static func websiteLayout() -> [DashPage] {
        let all = Products.templates.map { t in
            DashPage(name: t.name, widgets: t.widgets.map { DashWidget(kind: $0.0, size: $0.1) })
        }
        #if os(macOS)
        return all
        #else
        if UIDevice.current.userInterfaceIdiom == .pad { return all }
        var mine = all.first ?? .starter
        mine.widgets.insert(DashWidget(kind: "details"), at: min(4, mine.widgets.count))
        mine.widgets.append(DashWidget(kind: "sun", size: .small))
        return [mine]
        #endif
    }

    func resetToWebsite() { pages = Self.websiteLayout(); current = 0 }

    var page: DashPage { pages[min(current, pages.count - 1)] }

    static func limit(_ p: Plan) -> Int { p == .pro ? 99 : p == .plus ? 5 : 1 }

    static func product(_ kind: String) -> MapProduct? { Products.sections.flatMap(\.products).first { $0.id == kind } }

    static func title(_ w: DashWidget) -> String {
        if let t = w.customTitle, !t.isEmpty { return t }
        if let l = LocalWidget(rawValue: w.kind) { return l.title }
        if let p = product(w.kind) { return p.title }
        return w.kind == "custom_link" ? "Link" : "Image"
    }

    func add(_ w: DashWidget) { let i = min(current, pages.count - 1); pages[i].widgets.append(w) }
}

// MARK: - Dashboard screen

/// Customizable dashboard like the website: pages of widgets you add, remove, resize and reorder.
struct MyDashboard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @ObservedObject private var dash = DashStore.shared
    @State private var editing = false
    @State private var showPlans = false
    @State private var bust = Int(Date().timeIntervalSince1970 / 600)

    private enum Block: Identifiable {
        case grid([DashWidget]), wide(DashWidget)
        var id: String {
            switch self {
            case .grid(let w): return "g" + (w.first?.id.uuidString ?? "")
            case .wide(let w): return "w" + w.id.uuidString
            }
        }
    }

    /// Large widgets take a full row; small and medium ones flow in a grid between them.
    private var blocks: [Block] {
        var out: [Block] = [], run: [DashWidget] = []
        for w in dash.page.widgets {
            if w.size == .large {
                if !run.isEmpty { out.append(.grid(run)); run = [] }
                out.append(.wide(w))
            } else { run.append(w) }
        }
        if !run.isEmpty { out.append(.grid(run)) }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageBar
                if dash.page.widgets.isEmpty {
                    ContentUnavailableView("No widgets yet", systemImage: "square.grid.2x2", description: Text("Tap Edit to add widgets to this page."))
                }
                ForEach(blocks) { b in
                    switch b {
                    case .wide(let w): WidgetCard(widget: w, bust: bust)
                    case .grid(let ws):
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14, alignment: .top)], spacing: 14) {
                            ForEach(ws) { w in WidgetCard(widget: w, bust: bust) }
                        }
                    }
                }
            }
            .padding()
        }
        .refreshable { bust += 1; await state.refresh() }
        .navigationTitle(dash.page.name)
        .toolbar {
            ToolbarItem { NavigationLink { DashboardView() } label: { Label("All maps", systemImage: "map") } }
            ToolbarItem { Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") } }
        }
        .sheet(isPresented: $editing) { DashEditor(dash: dash).environmentObject(store) }
        .onAppear { if dash.current >= DashStore.limit(store.effectivePlan) { dash.current = 0 } }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    private var pageBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<min(dash.pages.count, DashStore.limit(store.effectivePlan)), id: \.self) { i in
                    Button(dash.pages[i].name) { dash.current = i }
                        .buttonStyle(.bordered)
                        .tint(i == dash.current ? Color.accentColor : Color.secondary)
                }
                Button {
                    if dash.pages.count < DashStore.limit(store.effectivePlan) {
                        dash.pages.append(DashPage(name: "Page \(dash.pages.count + 1)", widgets: []))
                        dash.current = dash.pages.count - 1
                        editing = true
                    } else { showPlans = true }
                } label: { Label("New page", systemImage: "plus") }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Widget card

struct WidgetCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    let widget: DashWidget
    let bust: Int
    @State private var zoom: MapProduct?
    @State private var showPlans = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(DashStore.title(widget).uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary).lineLimit(1)
                if let p = DashStore.product(widget.kind), p.pro { TierBadge(plan: .pro) }
                Spacer()
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(item: $zoom) { p in ZoomedProduct(product: p, bust: bust) }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    @ViewBuilder private var content: some View {
        if let l = LocalWidget(rawValue: widget.kind) {
            if l == .radar {
                MiniRadar().frame(height: widget.size == .large ? 340 : 240).clipShape(RoundedRectangle(cornerRadius: 12))
            } else if l == .alerts {
                alerts
            } else if let f = state.forecast {
                local(l, f)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        } else if let p = DashStore.product(widget.kind) {
            if p.pro && store.effectivePlan < .pro {
                Button { showPlans = true } label: { Label("Unlock with Pro", systemImage: "lock.fill").frame(maxWidth: .infinity, minHeight: 140) }
                    .buttonStyle(.bordered)
            } else {
                image(p.url) { zoom = p }
            }
        } else if widget.kind == "custom_link" {
            if let s = widget.customURL, let u = URL(string: s) {
                Link(destination: u) { Label(u.host() ?? s, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading) }
            } else { Text("No link set").foregroundStyle(.secondary) }
        } else {
            if let s = widget.customURL {
                image(s) { zoom = MapProduct(id: widget.id.uuidString, title: DashStore.title(widget), url: s, link: s) }
            } else { Text("No image set").foregroundStyle(.secondary) }
        }
    }

    private func image(_ url: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            AsyncImage(url: URL(string: "\(url)\(url.contains("?") ? "&" : "?")_=\(bust)")) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Label("Image unavailable", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 140)
                default: ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var alerts: some View {
        if state.alerts.isEmpty {
            Label("No alerts for \(state.place.name)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else {
            VStack(spacing: 8) { ForEach(state.alerts) { a in AlertRow(alert: a) } }
        }
    }

    @ViewBuilder private func local(_ l: LocalWidget, _ f: Forecast) -> some View {
        let c = f.current, off = f.utc_offset_seconds, u = state.units
        switch l {
        case .now:
            HStack(spacing: 14) {
                Image(systemName: WX.symbol(c.weather_code, day: c.is_day == 1)).symbolRenderingMode(.multicolor).font(.system(size: 44))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Fmt.temp(c.temperature_2m)).font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("\(WX.text(c.weather_code)) · feels \(Fmt.temp(c.apparent_temperature))").font(.subheadline)
                    Text(state.place.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .hourly:
            let start = f.nowIndex, end = min(f.hourly.time.count, start + 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(start..<end, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text(i == start ? "Now" : Fmt.hour(f.hourly.time[i], offset: off)).font(.caption.bold())
                            Image(systemName: WX.symbol(f.hourly.weather_code[i] ?? 3, day: (f.hourly.is_day[i] ?? 1) == 1)).symbolRenderingMode(.multicolor)
                            Text(Fmt.temp(f.hourly.temperature_2m[i])).font(.callout.weight(.semibold))
                            Text((f.hourly.precipitation_probability[i] ?? 0) >= 10 ? "\(f.hourly.precipitation_probability[i] ?? 0)%" : " ")
                                .font(.caption2).foregroundStyle(.blue)
                        }
                    }
                }
            }
        case .daily:
            let n = min(f.daily.time.count, widget.size == .small ? 5 : 10)
            VStack(spacing: 6) {
                ForEach(0..<n, id: \.self) { i in
                    HStack {
                        Text(i == 0 ? "Today" : Fmt.weekday(f.daily.time[i], offset: off)).frame(width: 52, alignment: .leading)
                        Image(systemName: WX.symbol(f.daily.weather_code[i] ?? 3)).symbolRenderingMode(.multicolor).frame(width: 28)
                        Text((f.daily.precipitation_probability_max[i] ?? 0) >= 10 ? "\(f.daily.precipitation_probability_max[i] ?? 0)%" : "")
                            .font(.caption).foregroundStyle(.blue).frame(width: 36)
                        Spacer()
                        Text(Fmt.temp(f.daily.temperature_2m_min[i])).foregroundStyle(.secondary)
                        Text(Fmt.temp(f.daily.temperature_2m_max[i])).bold().frame(width: 40, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        case .details:
            let rows: [(String, String)] = [
                ("Wind", "\(Fmt.compass(c.wind_direction_10m)) \(Int(c.wind_speed_10m ?? 0)) \(u.windLabel)"),
                ("Gusts", "\(Int(c.wind_gusts_10m ?? 0)) \(u.windLabel)"),
                ("Humidity", "\(Int(c.relative_humidity_2m ?? 0))%"),
                ("Dew point", Fmt.temp(c.dew_point_2m)),
                ("Pressure", u == .imperial ? String(format: "%.2f in", (c.pressure_msl ?? 0) * 0.02953) : "\(Int(c.pressure_msl ?? 0)) mb"),
                ("UV index", String(format: "%.0f", c.uv_index ?? 0)),
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(rows.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rows[i].0).font(.caption).foregroundStyle(.secondary)
                        Text(rows[i].1).font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .sun:
            let m = Moon.phase(Date())
            VStack(alignment: .leading, spacing: 8) {
                Label("Sunrise \(Fmt.time(f.daily.sunrise.first ?? "", offset: off))", systemImage: "sunrise.fill").symbolRenderingMode(.multicolor)
                Label("Sunset \(Fmt.time(f.daily.sunset.first ?? "", offset: off))", systemImage: "sunset.fill").symbolRenderingMode(.multicolor)
                Label("\(m.name), \(m.illum)% lit", systemImage: m.symbol)
            }
        case .alerts, .radar:
            EmptyView()
        }
    }
}

/// Small radar map for the dashboard. Shows the selected place; pan and zoom freely.
struct MiniRadar: View {
    @EnvironmentObject var state: AppState
    @StateObject private var radar = RadarController()
    var body: some View {
        RadarMap(radar: radar, center: state.place.coordinate, recenterToken: 0) { _ in }
            .task { await radar.load() }
    }
}

/// Moon phase from the average lunar cycle (accurate to about a day).
enum Moon {
    static func phase(_ d: Date) -> (name: String, illum: Int, symbol: String) {
        let synodic = 29.530588853
        let ref = Date(timeIntervalSince1970: 947_182_440) // new moon, Jan 6 2000 18:14 UTC
        var age = d.timeIntervalSince(ref) / 86400
        age = age.truncatingRemainder(dividingBy: synodic); if age < 0 { age += synodic }
        let illum = Int(((1 - cos(2 * .pi * age / synodic)) / 2 * 100).rounded())
        let i = Int((age / synodic * 8).rounded()) % 8
        let names = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous", "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
        let syms = ["moonphase.new.moon", "moonphase.waxing.crescent", "moonphase.first.quarter", "moonphase.waxing.gibbous", "moonphase.full.moon", "moonphase.waning.gibbous", "moonphase.last.quarter", "moonphase.waning.crescent"]
        return (names[i], illum, syms[i])
    }
}

// MARK: - Editor

struct DashEditor: View {
    @ObservedObject var dash: DashStore
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    private var i: Int { min(dash.current, dash.pages.count - 1) }

    var body: some View {
        NavigationStack {
            List {
                Section("Page name") {
                    TextField("Name", text: $dash.pages[i].name)
                }
                Section {
                    ForEach($dash.pages[i].widgets) { $w in
                        HStack {
                            Text(DashStore.title(w))
                            Spacer()
                            Picker("Size", selection: $w.size) {
                                ForEach(DashWidget.Size.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .onMove { dash.pages[i].widgets.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { dash.pages[i].widgets.remove(atOffsets: $0) }
                    Button { showAdd = true } label: { Label("Add widget", systemImage: "plus.circle.fill") }
                } header: {
                    Text("Widgets")
                } footer: {
                    Text("Drag to reorder. Large widgets take a full row.")
                }
                Section {
                    Button("Reset to the website's layout") { dash.resetToWebsite() }
                } footer: { Text("Replaces your pages with the website's ready-made pages.") }
                if dash.pages.count > 1 {
                    Section {
                        Button("Delete this page", role: .destructive) {
                            let idx = i
                            dash.current = max(0, idx - 1)
                            dash.pages.remove(at: idx)
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Edit dashboard")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showAdd) { WidgetCatalog(dash: dash).environmentObject(store) }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

struct WidgetCatalog: View {
    @ObservedObject var dash: DashStore
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var customKind: String?
    @State private var customTitle = ""
    @State private var customURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Your location") {
                    ForEach(LocalWidget.allCases, id: \.self) { l in
                        Button { add(DashWidget(kind: l.rawValue, size: l == .hourly || l == .radar ? .large : .medium)) } label: {
                            Label(l.title, systemImage: l.icon)
                        }
                    }
                }
                ForEach(Products.sections) { s in
                    Section(s.id) {
                        ForEach(s.products) { p in
                            Button { add(DashWidget(kind: p.id)) } label: {
                                HStack { Label(p.title, systemImage: "photo"); if p.pro { TierBadge(plan: .pro) } }
                            }
                        }
                    }
                }
                Section {
                    Button { customKind = "custom_image" } label: { Label("Custom image or loop", systemImage: "photo.badge.plus") }
                    Button { customKind = "custom_link" } label: { Label("Custom link", systemImage: "link.badge.plus") }
                    if customKind != nil {
                        TextField("Title", text: $customTitle)
                        TextField(customKind == "custom_link" ? "https://..." : "Image URL (https://...)", text: $customURL)
                            #if os(iOS)
                            .keyboardType(.URL).textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Button("Add") {
                            add(DashWidget(kind: customKind ?? "custom_image", customTitle: customTitle, customURL: customURL.trimmingCharacters(in: .whitespaces)))
                        }
                        .disabled(URL(string: customURL)?.scheme?.hasPrefix("http") != true)
                    }
                } header: { Text("Custom") }
            }
            .navigationTitle("Add a widget")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func add(_ w: DashWidget) { dash.add(w); dismiss() }
}
