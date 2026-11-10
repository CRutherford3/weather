import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Model

/// One widget on a dashboard page. `kind` is a local widget key, a map product id, or a custom type.
struct DashWidget: Codable, Identifiable, Hashable {
    enum Size: String, Codable, CaseIterable { case small, medium, large, full
        var title: String { self == .full ? "Full width" : rawValue.capitalized }
        /// Same order as the website's s / m / l / xl.
        var code: Int {
            switch self { case .small: return 0; case .medium: return 1; case .large: return 2; case .full: return 3 }
        }
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
        DashWidget(kind: "hourly", size: .full), DashWidget(kind: "radar", size: .large),
        DashWidget(kind: "daily"), DashWidget(kind: "details"),
        DashWidget(kind: "spc_d1"), DashWidget(kind: "wpc_sfc"),
    ])
}

/// Widgets that use the selected place's forecast (everything else is a map product or custom).
enum LocalWidget: String, CaseIterable {
    case now, alerts, nowcast, hourly, daily, details, aqi, sun, radar, nwsloop, nwstext, afd, models
    case doppler
    case storms, spaghetti, modelLinks = "models_links", scales, buoycam, links
    var title: String {
        switch self {
        case .now: return "Current Conditions"
        case .alerts: return "Alerts"
        case .hourly: return "Hourly Forecast"
        case .daily: return "16-Day Forecast"
        case .details: return "Conditions Detail"
        case .sun: return "Sun & Moon"
        case .radar: return "Live Radar"
        case .nowcast: return "Next 3 Hours"
        case .doppler: return "Doppler Radar (pick any radar)"
        case .aqi: return "Air Quality"
        case .nwsloop: return "Local NWS Radar Loop"
        case .nwstext: return "NWS Forecast Text"
        case .afd: return "Forecast Discussion"
        case .models: return "Model Comparison"
        case .storms: return "Active Tropical Systems"
        case .spaghetti: return "Spaghetti Models"
        case .modelLinks: return "Model Shortcuts"
        case .scales: return "Reference Scales"
        case .buoycam: return "Live Buoy Camera (pick any)"
        case .links: return "Weather Links"
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
        case .nowcast: return "cloud.rain"
        case .doppler: return "dot.radiowaves.up.forward"
        case .aqi: return "aqi.medium"
        case .nwsloop: return "play.circle"
        case .nwstext: return "text.alignleft"
        case .afd: return "doc.text"
        case .models: return "chart.xyaxis.line"
        case .storms: return "hurricane"
        case .spaghetti: return "scribble.variable"
        case .modelLinks: return "link"
        case .scales: return "ruler"
        case .buoycam: return "video"
        case .links: return "globe"
        }
    }
}

/// Saved dashboard pages (kept on this device).
final class DashStore: ObservableObject {
    static let shared = DashStore()
    @Published var pages: [DashPage] {
        didSet {
            save()
            if !restoring, oldValue != pages {
                undoStack.append(oldValue); if undoStack.count > 60 { undoStack.removeFirst() }
                redoStack = []
            }
        }
    }
    private var undoStack: [[DashPage]] = []
    private var redoStack: [[DashPage]] = []
    private var restoring = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    func undo() { guard let last = undoStack.popLast() else { return }; redoStack.append(pages); restore(last) }
    func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(pages); restore(next) }
    private func restore(_ p: [DashPage]) {
        restoring = true; pages = p; restoring = false
        current = min(current, pages.count - 1)
        objectWillChange.send()
    }
    @Published var current = 0

    private static let key = "dashPagesV4"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode([DashPage].self, from: d), !p.isEmpty {
            pages = p
            // one-time update: "My Weather" is now "My Dashboard", with Weather Links full width along the bottom
            if !UserDefaults.standard.bool(forKey: "dashMig1") {
                for i in pages.indices {
                    if pages[i].name == "My Weather" { pages[i].name = "My Dashboard" }
                    if let j = pages[i].widgets.firstIndex(where: { $0.kind == "links" }) {
                        var w = pages[i].widgets.remove(at: j); w.size = .full; pages[i].widgets.append(w)
                    }
                }
                UserDefaults.standard.set(true, forKey: "dashMig1")
                save()
            }
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

    private var ci: Int { min(current, pages.count - 1) }
    func move(_ id: UUID, before target: UUID) {
        guard id != target, let from = pages[ci].widgets.firstIndex(where: { $0.id == id }) else { return }
        let w = pages[ci].widgets.remove(at: from)
        let to = pages[ci].widgets.firstIndex(where: { $0.id == target }) ?? pages[ci].widgets.count
        pages[ci].widgets.insert(w, at: to)
    }
    func moveToEdge(_ id: UUID, top: Bool) {
        guard let from = pages[ci].widgets.firstIndex(where: { $0.id == id }) else { return }
        let w = pages[ci].widgets.remove(at: from)
        pages[ci].widgets.insert(w, at: top ? 0 : pages[ci].widgets.count)
    }
    func setSize(_ id: UUID, _ s: DashWidget.Size) {
        if let i = pages[ci].widgets.firstIndex(where: { $0.id == id }) { pages[ci].widgets[i].size = s }
    }
    func remove(_ id: UUID) { pages[ci].widgets.removeAll { $0.id == id } }

    /// Copy a tile to another page (the original stays where it is).
    @discardableResult func copyWidget(_ id: UUID, toPage target: Int) -> String? {
        guard pages.indices.contains(target) else { return nil }
        for p in pages.indices {
            if let w = pages[p].widgets.first(where: { $0.id == id }) {
                var c = w; c.id = UUID()
                pages[target].widgets.append(c)
                return "Copied \(Self.title(w)) to \(pages[target].name)"
            }
        }
        return nil
    }

    func deletePage(_ i: Int) {
        guard pages.count > 1, pages.indices.contains(i) else { return }
        pages.remove(at: i)
        current = min(current >= i ? max(0, current - 1) : current, pages.count - 1)
    }

    /// Save a tile's own setting (a Doppler card's radar and product, e.g. "KMLB|N0S").
    func setCustom(_ id: UUID, _ value: String) {
        for p in pages.indices {
            if let i = pages[p].widgets.firstIndex(where: { $0.id == id }), pages[p].widgets[i].customURL != value {
                pages[p].widgets[i].customURL = value
            }
        }
    }

    /// Move a tile from whatever page it's on to another page (dropped on that page's tab).
    @discardableResult func moveWidget(_ id: UUID, toPage target: Int) -> String? {
        guard pages.indices.contains(target) else { return nil }
        for p in pages.indices {
            if let i = pages[p].widgets.firstIndex(where: { $0.id == id }) {
                guard p != target else { return nil }
                let w = pages[p].widgets.remove(at: i)
                pages[target].widgets.append(w)
                return "Moved \(Self.title(w)) to \(pages[target].name)"
            }
        }
        return nil
    }
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
    @State private var adding = false
    @State private var dropTab: Int?
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageBar
                if dash.page.widgets.isEmpty {
                    ContentUnavailableView("No widgets yet", systemImage: "square.grid.2x2", description: Text("Tap Edit to add widgets to this page."))
                }
                DashGridLayout(spacing: 14) {
                    ForEach(dash.page.widgets) { w in
                        WidgetCard(widget: w, bust: bust)
                            .layoutValue(key: TileSizeKey.self, value: w.size.code)
                            .draggable(w.id.uuidString) {
                                Label(DashStore.title(w), systemImage: "square.grid.2x2")
                                    .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first, let from = UUID(uuidString: s) else { return false }
                                withAnimation(.snappy) { dash.move(from, before: w.id) }
                                return true
                            }
                            .contextMenu { tileMenu(w) }
                    }
                }
                if !dash.page.widgets.isEmpty {
                    Text("Drag a tile to move it, or drop it on a page tab above to move it to that page. Long-press (or right-click) a tile to resize or remove it.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .refreshable { bust += 1; await state.refresh() }
        .navigationTitle(dash.page.name)
        .toolbar {
            ToolbarItem { NavigationLink { DashboardView() } label: { Label("All maps", systemImage: "map") } }
            ToolbarItem {
                Menu {
                    ForEach(Products.templates.indices, id: \.self) { i in
                        Button(Products.templates[i].name) { addTemplate(i) }
                    }
                } label: { Label("Layouts", systemImage: "rectangle.3.group") }
            }
            ToolbarItem {
                Button { withAnimation(.snappy) { dash.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!dash.canUndo).help("Undo (Cmd+Z)")
            }
            ToolbarItem {
                Button { withAnimation(.snappy) { dash.redo() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!dash.canRedo).help("Redo (Shift+Cmd+Z)")
            }
            ToolbarItem { Button { adding = true } label: { Label("Add widget", systemImage: "plus") } }
            ToolbarItem { Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") } }
        }
        .sheet(isPresented: $adding) { WidgetCatalog(dash: dash).environmentObject(store) }
        .sheet(isPresented: $editing) { DashEditor(dash: dash).environmentObject(store) }
        .onAppear { if dash.current >= DashStore.limit(store.effectivePlan) { dash.current = 0 } }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    @ViewBuilder private func tileMenu(_ w: DashWidget) -> some View {
        Picker("Size", selection: Binding(get: { w.size }, set: { dash.setSize(w.id, $0) })) {
            ForEach(DashWidget.Size.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Menu {
            ForEach(dash.pages.indices.filter { $0 != dash.current && $0 < DashStore.limit(store.effectivePlan) }, id: \.self) { i in
                Button(dash.pages[i].name) { if let m = dash.moveWidget(w.id, toPage: i) { showToast(m) } }
            }
        } label: { Label("Move to page", systemImage: "rectangle.portrait.and.arrow.right") }
        Menu {
            ForEach(dash.pages.indices.filter { $0 < DashStore.limit(store.effectivePlan) }, id: \.self) { i in
                Button(i == dash.current ? "\(dash.pages[i].name) (this page)" : dash.pages[i].name) { if let m = dash.copyWidget(w.id, toPage: i) { showToast(m) } }
            }
        } label: { Label("Copy to page", systemImage: "plus.square.on.square") }
        Button { dash.moveToEdge(w.id, top: true) } label: { Label("Move to top", systemImage: "arrow.up.to.line") }
        Button { dash.moveToEdge(w.id, top: false) } label: { Label("Move to bottom", systemImage: "arrow.down.to.line") }
        Button(role: .destructive) { withAnimation { dash.remove(w.id) } } label: { Label("Remove", systemImage: "trash") }
    }

    private func showToast(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if toast == m { toast = nil } }
    }

    /// Add one of the website's ready-made layouts as a new page.
    private func addTemplate(_ i: Int) {
        guard dash.pages.count < DashStore.limit(store.effectivePlan) else { showPlans = true; return }
        let t = Products.templates[i]
        dash.pages.append(DashPage(name: t.name, widgets: t.widgets.map { DashWidget(kind: $0.0, size: $0.1) }))
        dash.current = dash.pages.count - 1
    }

    private var pageBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<min(dash.pages.count, DashStore.limit(store.effectivePlan)), id: \.self) { i in
                    Button(dash.pages[i].name) { dash.current = i }
                        .buttonStyle(.bordered)
                        .tint(i == dash.current || dropTab == i ? Color.accentColor : Color.secondary)
                        .scaleEffect(dropTab == i ? 1.12 : 1)
                        .animation(.snappy, value: dropTab)
                        // drop a tile here to move it to this page
                        .dropDestination(for: String.self) { items, _ in
                            guard let s = items.first, let id = UUID(uuidString: s),
                                  let msg = withAnimation(.snappy, { dash.moveWidget(id, toPage: i) }) else { return false }
                            showToast(msg)
                            return true
                        } isTargeted: { on in
                            if on { dropTab = i } else if dropTab == i { dropTab = nil }
                        }
                        .contextMenu {
                            Button { dash.current = i; editing = true } label: { Label("Rename or edit", systemImage: "pencil") }
                            if dash.pages.count > 1 {
                                Button(role: .destructive) { withAnimation { dash.deletePage(i) }; showToast("Page deleted. Cmd+Z to undo.") } label: {
                                    Label("Delete page", systemImage: "trash")
                                }
                            }
                        }
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
            if (l == .storms || l == .spaghetti) && store.effectivePlan < .plus {
                Button { showPlans = true } label: { Label("Live hurricane tracking is part of Plus", systemImage: "lock.fill").frame(maxWidth: .infinity, minHeight: 100) }
                    .buttonStyle(.bordered)
            } else if let v = live(l) {
                v
            } else if l == .radar {
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
            RemoteImage(url: URL(string: "\(url)\(url.contains("?") ? "&" : "?")_=\(bust)"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Widgets that load their own live data.
    private func live(_ l: LocalWidget) -> AnyView? {
        let p = state.place
        switch l {
        case .nowcast: return AnyView(NowcastWidget(place: p))
        case .aqi: return AnyView(AQIWidget(place: p))
        case .nwsloop: return AnyView(NWSLoopWidget(place: p))
        case .doppler:
            return AnyView(DopplerWidget(place: p, saved: widget.customURL, onPick: { DashStore.shared.setCustom(widget.id, $0) })
                .frame(height: widget.size == .full || widget.size == .large ? 400 : 300))
        case .nwstext: return AnyView(NWSTextWidget(place: p))
        case .afd: return AnyView(AFDWidget(place: p))
        case .models: return AnyView(ModelsWidget(place: p, units: state.units))
        case .storms: return AnyView(StormsWidget())
        case .spaghetti: return AnyView(SpaghettiWidget())
        case .modelLinks: return AnyView(ModelLinksWidget())
        case .scales: return AnyView(ScalesWidget())
        case .buoycam: return AnyView(BuoyCamWidget(place: p, saved: widget.customURL, onPick: { DashStore.shared.setCustom(widget.id, $0) }))
        case .links: return AnyView(LinksWidget(place: p))
        default: return nil
        }
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
                            Text("\(f.hourly.precipitation_probability[i] ?? 0)%")
                                .font(.caption2).foregroundStyle(.blue)
                        }
                    }
                }
            }
        case .daily:
            let n = min(f.daily.time.count, widget.size == .small ? 7 : 16)   // all 16 days
            VStack(spacing: 6) {
                ForEach(0..<n, id: \.self) { i in
                    HStack {
                        Text(i == 0 ? "Today" : Fmt.weekday(f.daily.time[i], offset: off)).frame(width: 52, alignment: .leading)
                        Image(systemName: WX.symbol(f.daily.weather_code[i] ?? 3)).symbolRenderingMode(.multicolor).frame(width: 28)
                        Text("\(f.daily.precipitation_probability_max[i] ?? 0)%")
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
        default:
            EmptyView()
        }
    }
}

/// One NEXRAD radar on its own, with a Reflectivity / Velocity switch (the website's Doppler card).
/// Each card remembers its own radar, so you can add one card per radar you follow.
struct DopplerWidget: View {
    let place: Place
    var saved: String? = nil                 // "KMLB|N0B"; nil = nearest radar
    var onPick: (String) -> Void = { _ in }
    @StateObject private var radar = RadarController(raw: true)
    @State private var sites: [RadarService.Site] = []

    private var parts: [String] { (saved ?? "").components(separatedBy: "|") }
    private var savedId: String? { parts.first.flatMap { $0.isEmpty ? nil : $0 } }
    private var savedProduct: String { parts.count > 1 && parts[1] == "N0S" ? "N0S" : "N0B" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    Button("Nearest to \(place.name)") { Task { await choose(id: nil, product: savedProduct) } }
                    Divider()
                    ForEach(sites.prefix(60), id: \.id) { s in
                        Button("\(s.id) · \(s.name)") { Task { await choose(id: s.id, product: savedProduct) } }
                    }
                } label: {
                    Label(radar.site.map { "\($0.id) · \($0.name)" } ?? "Finding the radar…", image: "Radome")
                        .font(.caption).lineLimit(1)
                }
                .fixedSize()
                Spacer()
                Picker("", selection: Binding(get: { savedProduct == "N0S" }, set: { v in Task { await choose(id: savedId, product: v ? "N0S" : "N0B") } })) {
                    Text("Reflectivity").tag(false); Text("Velocity").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            RadarMap(radar: radar, center: radar.site.map { .init(latitude: $0.lat, longitude: $0.lon) } ?? place.coordinate,
                     recenterToken: radar.site.map { $0.id.hashValue } ?? 0, onCenterChange: { _ in })
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .task(id: "\(place.id)|\(saved ?? "")") { await apply() }
    }

    /// Radars sorted by distance from the selected place, for the picker.
    private func loadSites() async {
        guard sites.isEmpty else { return }
        let all = await LiveData.radarSites()
        let k = cos(place.lat * .pi / 180)
        sites = all.sorted { pow($0.lat - place.lat, 2) + pow(($0.lon - place.lon) * k, 2) < pow($1.lat - place.lat, 2) + pow(($1.lon - place.lon) * k, 2) }
    }

    private func apply() async {
        await loadSites()
        let s = savedId.flatMap { id in sites.first { $0.id == id } } ?? sites.first
        guard var s else { return }
        s.product = savedProduct
        if radar.site != s { radar.setSite(s) }
    }

    private func choose(id: String?, product: String) async {
        onPick(id.map { "\($0)|\(product)" } ?? "|\(product)")
    }
}

/// Small radar map for the dashboard. Shows the selected place; pan and zoom freely.
struct MiniRadar: View {
    @EnvironmentObject var state: AppState
    @StateObject private var radar = RadarController(raw: true)   // just the raw radar feed
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
                    Text("Drag to reorder. On wide screens tiles sit side by side like the website: small, medium, large (half) and full width.")
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
        .frame(width: 480, height: 620)
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
                        Button { add(DashWidget(kind: l.rawValue, size: [.hourly, .models, .afd, .spaghetti].contains(l) ? .full : [.radar, .daily, .nwstext, .storms, .scales].contains(l) ? .large : .medium)) } label: {
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
        .frame(width: 480, height: 640)
        #endif
    }

    private func add(_ w: DashWidget) { dash.add(w); dismiss() }
}

// MARK: - Grid like the website's (12 columns: small 3, medium 4, large 6, full 12)

struct TileSizeKey: LayoutValueKey { static let defaultValue = 1 }

/// Tiles flow left to right and wrap, each spanning columns by size. Narrower screens use wider spans,
/// the same breakpoints as the website. Each tile is as tall as its content (no empty stretched cards).
struct DashGridLayout: Layout {
    var spacing: CGFloat = 14

    private func span(_ code: Int, _ width: CGFloat) -> Int {
        if width >= 1000 { return [3, 4, 6, 12][min(max(code, 0), 3)] }
        if width >= 620 { return [6, 6, 12, 12][min(max(code, 0), 3)] }
        return 12
    }

    /// Rows of (subview index, x, width), plus each row's height. A row that doesn't use all 12 columns is
    /// widened to fill the screen, keeping the tiles' proportions, so there's no empty strip at the end.
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [(Int, CGFloat, CGFloat)], height: CGFloat)] {
        var groups: [[(Int, Int)]] = [], cur: [(Int, Int)] = [], used = 0
        for (i, sv) in subviews.enumerated() {
            let sp = span(sv[TileSizeKey.self], width)
            if used + sp > 12, !cur.isEmpty { groups.append(cur); cur = []; used = 0 }
            cur.append((i, sp)); used += sp
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups.map { g in
            let total = CGFloat(g.reduce(0) { $0 + $1.1 })
            let free = width - spacing * CGFloat(g.count - 1)
            var x: CGFloat = 0, h: CGFloat = 0
            var items: [(Int, CGFloat, CGFloat)] = []
            for (i, sp) in g {
                let w = free * CGFloat(sp) / total
                items.append((i, x, w))
                h = max(h, subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
                x += w + spacing
            }
            return (items, h)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let rows = arrange(width, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            for (i, x, w) in row.items {
                subviews[i].place(at: CGPoint(x: bounds.minX + x, y: y), anchor: .topLeading,
                                  proposal: ProposedViewSize(width: w, height: nil))
            }
            y += row.height + spacing
        }
    }
}
