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
    @State private var added: String?
    @ObservedObject private var dash = DashStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Label("Right-click or long-press any map to add it to your dashboard.", systemImage: "hand.tap")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                ForEach(Products.sections.filter { only == nil || $0.id == only }) { s in
                    Text(s.id).font(.title3.bold()).padding(.horizontal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(s.products) { p in
                            tile(p).contextMenu { addMenu(p) }
                        }
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
        .overlay(alignment: .bottom) {
            if let added {
                Label(added, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: added)
    }

    /// "Add to dashboard" for the page you're on, plus a list of every page and a size choice.
    @ViewBuilder private func addMenu(_ p: MapProduct) -> some View {
        let pages = Array(dash.pages.prefix(DashStore.limit(store.effectivePlan)).enumerated())
        if p.pro && store.effectivePlan < .pro {
            Button { showPlans = true } label: { Label("Unlock with Pro to add", systemImage: "lock.fill") }
        } else {
            Button { add(p, page: min(dash.current, dash.pages.count - 1), size: .medium) } label: {
                Label("Add to \(dash.page.name)", systemImage: "plus.square.on.square")
            }
            Menu {
                ForEach(pages, id: \.offset) { item in
                    Button(item.element.name) { add(p, page: item.offset, size: .medium) }
                }
            } label: { Label("Add to page", systemImage: "square.grid.2x2") }
            Menu {
                ForEach(DashWidget.Size.allCases, id: \.self) { sz in
                    Button(sz.title) { add(p, page: min(dash.current, dash.pages.count - 1), size: sz) }
                }
            } label: { Label("Add at size", systemImage: "arrow.up.left.and.arrow.down.right") }
            Divider()
            Button { zoom = p } label: { Label("Open full size", systemImage: "arrow.up.left.and.arrow.down.right.magnifyingglass") }
            if let u = URL(string: p.link) { Link(destination: u) { Label("Open source website", systemImage: "safari") } }
        }
    }

    private func add(_ p: MapProduct, page i: Int, size: DashWidget.Size) {
        guard dash.pages.indices.contains(i) else { return }
        dash.pages[i].widgets.append(DashWidget(kind: p.id, size: size))
        added = "Added \(p.title) to \(dash.pages[i].name)"
        let msg = added
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { if added == msg { added = nil } }
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
                    RemoteImage(url: URL(string: "\(p.url)\(p.url.contains("?") ? "&" : "?")_=\(bust)"), minHeight: 160)
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
                RemoteImage(url: URL(string: "\(product.url)\(product.url.contains("?") ? "&" : "?")_=\(bust)"), minHeight: 300)
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
