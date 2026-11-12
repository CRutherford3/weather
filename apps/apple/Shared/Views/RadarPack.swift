import SwiftUI

// The one-time Pro Radar Pack: every radar layer, nothing else. Pack owners still see ads, and the
// subscriptions are still offered for everything else.

/// Card at the bottom of the Loops tab (free users only).
struct RadarPackCard: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(spacing: 14) {
            Image("Radome").resizable().scaledToFit().frame(width: 44, height: 44).foregroundStyle(.white)
                .padding(12)
                .background(LinearGradient(colors: [Kit.amber, .orange], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Pro Radar Pack").font(.headline)
                Text("Every radar layer, one time: \(store.radarPackProduct?.displayPrice ?? "$6.99"). No subscription.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Kit.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Kit.amber, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// What the Radar Pack includes, with the buy button.
struct RadarPackPage: View {
    @EnvironmentObject var store: Store

    private let loops: [(String, String)] = [
        ("Past 48 Hours", "Replay the last two days of radar"),
        ("Future Radar", "Short-term radar forecast from the HRRR model"),
    ]
    private let layers: [(String, String)] = [
        ("Echo Tops", "How tall the storms are"),
        ("Rain Rate", "How hard it's raining right now"),
        ("Past Hour Rain", "Rain that fell in the last hour"),
        ("Rain Totals", "Rain over the last 24 hours and 3 days"),
    ]

    var body: some View {
        KitPage(title: "Pro Radar Pack") {
            VStack(spacing: 10) {
                Image("Radome").resizable().scaledToFit().frame(width: 60, height: 60).foregroundStyle(.white)
                Text("Every radar layer, yours to keep").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("One-time purchase: \(store.radarPackProduct?.displayPrice ?? "$6.99"). Works on iPhone, iPad and Mac.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [Kit.amber, Color(red: 0.45, green: 0.2, blue: 0.05)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16).padding(.top, 8)

            KitSectionHeader(text: "Every NEXRAD radar")
            item("About 160 radar sites", "Pick any radar in the US from the Radars tab or the map")
            item("4 tilt angles", "Look low near the ground or higher up into the storm")

            KitSectionHeader(text: "Doppler products")
            ForEach(RadarService.SiteProduct.allCases) { p in item(p.title, p.detail) }

            KitSectionHeader(text: "Radar loops")
            ForEach(loops.indices, id: \.self) { i in item(loops[i].0, loops[i].1) }

            KitSectionHeader(text: "Radar layers")
            ForEach(layers.indices, id: \.self) { i in item(layers[i].0, layers[i].1) }

            VStack(spacing: 12) {
                KitBigButton(title: store.radarPack ? "Purchased" : "Buy Once \(store.radarPackProduct?.displayPrice ?? "$6.99")",
                             disabled: store.radarPack) {
                    Task { await store.buyRadarPack() }
                }
                Button("Restore previous purchases") { Task { await store.restore() } }
                    .buttonStyle(.plain).underline().font(.subheadline)
                if let m = store.message { Text(m).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            }
            .padding(.horizontal, 20).padding(.top, 22)

            KitFooter(text: "The Radar Pack covers radar only. Ads stay on, and other map layers, alerts and the dashboard come with Plus or Pro.")
        }
    }

    private func item(_ title: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Kit.green)
            KitLabel(title: title, subtitle: sub)
        }
        .kitRow()
    }
}
