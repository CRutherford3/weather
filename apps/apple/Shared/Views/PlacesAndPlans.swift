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
