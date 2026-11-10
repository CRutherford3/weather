import SwiftUI
import StoreKit

/// Search for a place, plus saved places.
struct SearchView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var q = ""
    @State private var results: [Place] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { Task { await state.useMyLocation(); dismiss() } } label: { Label("My location", systemImage: "location.fill") }
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { p in Button(p.name) { state.select(p); dismiss() } }
                    }
                }
                if !state.favorites.isEmpty {
                    Section("My places") {
                        ForEach(state.favorites) { p in Button { state.select(p); dismiss() } label: { Label(p.name, systemImage: "star.fill") } }
                            .onDelete { state.favorites.remove(atOffsets: $0) }
                    }
                }
            }
            .searchable(text: $q, prompt: "City, town or ZIP")
            .task(id: q) {
                let term = q.trimmingCharacters(in: .whitespaces)
                guard term.count >= 2 else { results = []; return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                results = await WeatherService.shared.search(term)
            }
            .navigationTitle("Places")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 440, height: 540)
        #endif
    }
}

/// Free / Plus / Pro, bought through the App Store.
struct PlansView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("billYearly") private var yearly = true

    private let features: [Plan: [String]] = [
        .free: ["Live radar and satellite", "Forecasts and NWS alerts", "Home Screen widgets", "Weather map dashboard"],
        .plus: ["Everything in Free, no ads", "Every map layer: lightning, rain rate, echo tops, road weather", "Severe weather and rain alerts for your places", "Hurricane tracker"],
        .pro: ["Everything in Plus", "Doppler radar at any site: 4 tilts, velocity, dual-pol, VIL", "iPad and Mac pro workspace", "Route weather with EV charging stops", "Hail history, marine and offshore", "Pro map collection"],
    ]
    private let fallback: [Plan: (month: String, year: String)] = [.plus: ("$2.99", "$24.99"), .pro: ("$9.99", "$59.99")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Billing", selection: $yearly) {
                        Text("Monthly").tag(false)
                        Text("Yearly (save up to 50%)").tag(true)
                    }
                    .pickerStyle(.segmented)
                    ForEach(Plan.allCases, id: \.self) { p in card(p) }
                    radarPackCard
                    Button("Restore purchases") { Task { await store.restore() } }.padding(.top, 4)
                    Text("Subscriptions renew each month or year until canceled in your App Store account settings. A free trial turns into a paid yearly plan unless canceled at least 24 hours before it ends. The Radar Pack is a one-time purchase.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let m = store.message { Text(m).font(.footnote).foregroundStyle(.orange) }
                }
                .padding()
            }
            .navigationTitle("Plans")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 500, height: 700)
        #endif
    }

    private var radarPackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pro Radar Pack", systemImage: "dot.radiowaves.left.and.right").font(.title2.bold())
                Spacer()
                Text(store.radarPackProduct?.displayPrice ?? "$6.99").font(.headline)
            }
            Text("One-time purchase. Doppler radar tools forever, no subscription.").foregroundStyle(.secondary)
            ForEach(["Any NEXRAD radar site, at 4 tilt angles", "Velocity for spotting rotation",
                     "Dual-pol: hail and debris, precipitation type, VIL, echo tops", "Past 48 hours and future radar", "Works on iPhone, iPad and Mac"], id: \.self) {
                Label($0, systemImage: "checkmark").font(.subheadline)
            }
            Button(store.radarPack ? "Purchased" : "Buy once") { Task { await store.buyRadarPack() } }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(store.radarPack).frame(maxWidth: .infinity)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange, lineWidth: 2))
    }

    private func card(_ p: Plan) -> some View {
        let current = store.effectivePlan == p
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.title2.bold())
                Spacer()
                Text(priceText(p)).font(.headline)
            }
            if p != .free, let note = savingsText(p) {
                Text(note).font(.caption.bold()).foregroundStyle(.green)
            }
            Text(p.blurb).foregroundStyle(.secondary)
            ForEach(features[p] ?? [], id: \.self) { f in Label(f, systemImage: "checkmark").font(.subheadline) }
            if p != .free {
                Button(current ? "Current plan" : (yearly ? (store.trialText(p).map { "Start \($0)" } ?? "Get \(p.name) yearly") : "Get \(p.name)")) { Task { await store.buy(p, yearly: yearly) } }
                    .buttonStyle(.borderedProminent).disabled(current).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(p == .pro ? Color.purple : .clear, lineWidth: 2))
    }

    private func priceText(_ p: Plan) -> String {
        guard p != .free, let fb = fallback[p] else { return "Free" }
        if yearly { return (store.product(for: p, yearly: true)?.displayPrice ?? fb.year) + "/yr" }
        return (store.product(for: p)?.displayPrice ?? fb.month) + "/mo"
    }

    /// "About $2.08/mo, save 30%" for yearly; "or $24.99/yr and save 30%" for monthly.
    private func savingsText(_ p: Plan) -> String? {
        guard let fb = fallback[p] else { return nil }
        let m = store.product(for: p)?.price ?? Decimal(string: String(fb.month.dropFirst())) ?? 0
        let y = store.product(for: p, yearly: true)?.price ?? Decimal(string: String(fb.year.dropFirst())) ?? 0
        let mD = NSDecimalNumber(decimal: m).doubleValue, yD = NSDecimalNumber(decimal: y).doubleValue
        guard mD > 0, yD > 0 else { return nil }
        let pct = Int(((1 - yD / (mD * 12)) * 100).rounded())
        if yearly {
            let per = (store.product(for: p, yearly: true)?.priceFormatStyle).map { (y / 12).formatted($0) } ?? String(format: "$%.2f", yD / 12)
            return ["About \(per)/mo, save \(pct)%", store.trialText(p)].compactMap { $0 }.joined(separator: " · ")
        }
        return "or \(store.product(for: p, yearly: true)?.displayPrice ?? fb.year)/yr and save \(pct)%"
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @State private var showPlans = false
    @State private var alertsOn = AlertMonitor.isOn
    @State private var alertsDenied = false

    var body: some View {
        Form {
            Section("Plan") {
                Button { showPlans = true } label: { LabeledContent("DopplerIQ \(store.effectivePlan.name)", value: "Plans") }
                #if DEBUG
                Picker("Preview plan (testing)", selection: Binding(get: { store.previewPlan ?? store.plan }, set: { store.previewPlan = $0 })) {
                    ForEach(Plan.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                #endif
            }
            Section {
                Toggle(isOn: Binding(get: { alertsOn && store.effectivePlan >= .plus }, set: { on in
                    if store.effectivePlan < .plus { showPlans = true; return }
                    if on { Task { alertsOn = await AlertMonitor.enable(); if !alertsOn { alertsDenied = true } } }
                    else { AlertMonitor.disable(); alertsOn = false }
                })) {
                    HStack { Text("Severe weather and rain alerts"); TierBadge(plan: .plus) }
                }
                if alertsDenied { Text("Notifications are off for DopplerIQ. Turn them on in System Settings > Notifications.").font(.footnote).foregroundStyle(.orange) }
            } header: { Text("Alerts") } footer: {
                Text("Warnings for your location and saved places (tornado, severe thunderstorm, flash flood, hurricane, winter storm and more), plus a heads-up before rain starts.")
            }
            Section("Appearance") {
                Picker("Appearance", selection: $state.appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Units") {
                Picker("Units", selection: $state.units) {
                    Text("°F, mph").tag(Units.imperial)
                    Text("°C, km/h").tag(Units.metric)
                }
                .pickerStyle(.segmented)
            }
            Section("About") {
                Link("Website", destination: AppConfig.webBase)
                Link("Privacy", destination: AppConfig.privacyURL)
                Text("Data: National Weather Service, NOAA (NHC, SPC, WPC, NESDIS), Iowa Environmental Mesonet, Open-Meteo. Not for life-safety decisions; always follow official warnings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }
}

/// Ad slot. Shows a house ad until Google AdMob is connected (iPhone/iPad only; AdMob doesn't support Mac).
struct AdBanner: View {
    enum Kind { case banner, inline }
    var kind: Kind
    @EnvironmentObject var store: Store
    @State private var showPlans = false
    var body: some View {
        Button { showPlans = true } label: {
            VStack(spacing: 2) {
                Text("ADVERTISEMENT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text("Go ad-free with DopplerIQ Plus").font(.subheadline.bold())
                if kind == .inline { Text("Every map layer, no ads. From $24.99/yr").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: kind == .banner ? 50 : 90)
            .background(LinearGradient(colors: [.purple.opacity(0.25), .blue.opacity(0.15)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }
}
