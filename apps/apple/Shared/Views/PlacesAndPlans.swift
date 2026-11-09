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
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

/// Free / Plus / Pro, bought through the App Store.
struct PlansView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    private let features: [Plan: [String]] = [
        .free: ["Live radar and satellite", "Forecasts and NWS alerts", "Weather map dashboard"],
        .plus: ["Everything in Free, no ads", "Every map layer, including lightning", "Hurricane tracker"],
        .pro: ["Everything in Plus", "iPad and Mac pro workspace", "Route weather with EV charging stops", "Hail history, marine and offshore", "Pro map collection"],
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Plan.allCases, id: \.self) { p in card(p) }
                    Button("Restore purchases") { Task { await store.restore() } }.padding(.top, 4)
                    Text("Subscriptions renew monthly until canceled in your App Store account settings.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let m = store.message { Text(m).font(.footnote).foregroundStyle(.orange) }
                }
                .padding()
            }
            .navigationTitle("Plans")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }

    private func card(_ p: Plan) -> some View {
        let current = store.effectivePlan == p
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.title2.bold())
                Spacer()
                Text(p == .free ? "Free" : store.product(for: p)?.displayPrice.appending("/mo") ?? (p == .plus ? "$2.99/mo" : "$9.99/mo")).font(.headline)
            }
            Text(p.blurb).foregroundStyle(.secondary)
            ForEach(features[p] ?? [], id: \.self) { f in Label(f, systemImage: "checkmark").font(.subheadline) }
            if p != .free {
                Button(current ? "Current plan" : "Get \(p.name)") { Task { await store.buy(p) } }
                    .buttonStyle(.borderedProminent).disabled(current).frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(p == .pro ? Color.purple : .clear, lineWidth: 2))
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @State private var showPlans = false

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
                if kind == .inline { Text("Every map layer, no ads. $2.99/mo").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: kind == .banner ? 50 : 90)
            .background(LinearGradient(colors: [.purple.opacity(0.25), .blue.opacity(0.15)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }
}
