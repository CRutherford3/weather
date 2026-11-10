import SwiftUI

/// A weather map product (NOAA / NHC / SPC image), like the website's dashboard widgets.
struct MapProduct: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let link: String
    var pro = false
}

struct ProductSection: Identifiable {
    let id: String
    let products: [MapProduct]
}

/// Map products: the full list and the ready-made pages are generated from the website (ProductsGenerated.swift).
enum Products {}

/// Grid of live weather maps. iPhone shows one column; iPad and Mac show several.
struct DashboardView: View {
    @EnvironmentObject var store: Store
    var only: String? = nil          // show one section (pro workspace sidebar)
    @State private var bust = Int(Date().timeIntervalSince1970 / 600)
    @State private var zoom: MapProduct?
    @State private var showPlans = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Products.sections.filter { only == nil || $0.id == only }) { s in
                    Text(s.id).font(.title3.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(s.products) { p in tile(p) }
                    }
                    .padding(.horizontal)
                    if store.effectivePlan == .free { AdBanner(kind: .inline).padding(.horizontal) }
                }
            }
            .padding(.vertical)
        }
        .refreshable { bust += 1 }
        .navigationTitle(only ?? "All Maps")
        .sheet(item: $zoom) { p in ZoomedProduct(product: p, bust: bust) }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    @ViewBuilder private func tile(_ p: MapProduct) -> some View {
        let locked = p.pro && store.effectivePlan < .pro
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.title).font(.headline).lineLimit(1)
                if p.pro { TierBadge(plan: .pro) }
                Spacer()
            }
            if locked {
                Button { showPlans = true } label: {
                    Label("Unlock with Pro", systemImage: "lock.fill").frame(maxWidth: .infinity, minHeight: 160)
                }
                .buttonStyle(.bordered)
            } else {
                Button { zoom = p } label: {
                    AsyncImage(url: URL(string: "\(p.url)\(p.url.contains("?") ? "&" : "?")_=\(bust)")) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFit()
                        case .failure: Label("Image unavailable", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 160)
                        default: ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ZoomedProduct: View {
    let product: MapProduct
    let bust: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                AsyncImage(url: URL(string: "\(product.url)\(product.url.contains("?") ? "&" : "?")_=\(bust)")) { i in i.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(minWidth: 320)
            }
            .navigationTitle(product.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let u = URL(string: product.link) { ToolbarItem { Link("Source", destination: u) } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 700, minHeight: 520)
        #endif
    }
}
