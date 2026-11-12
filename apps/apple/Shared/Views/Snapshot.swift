import SwiftUI
import MapKit

// Radar snapshot: a picture of the map (radar and layers included) with a DopplerIQ tag in the corner,
// ready to save or share. Free for everyone; every shared picture shows the app's name.

extension RadarMap {
    /// Picture of the map exactly as it looks on screen.
    static func capture(_ v: MKMapView) -> CGImage? {
        #if os(iOS)
        let r = UIGraphicsImageRenderer(bounds: v.bounds)
        return r.image { _ in v.drawHierarchy(in: v.bounds, afterScreenUpdates: false) }.cgImage
        #else
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
        #endif
    }
}

struct SnapItem: Identifiable {
    let id = UUID()
    let image: CGImage
    let place: String
}

struct SnapshotSheet: View {
    let item: SnapItem
    @State private var final: CGImage?

    var body: some View {
        KitSheet {
            KitPage(title: "Radar Snapshot", root: true) {
                VStack(spacing: 18) {
                    if let final {
                        Image(decorative: final, scale: 1).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        let pic = Image(decorative: final, scale: 1)
                        ShareLink(item: pic, preview: SharePreview("DopplerIQ radar: \(item.place)", image: pic)) {
                            Label("Share or Save", systemImage: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Kit.green, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView().frame(height: 200)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .task { final = Self.tag(item.image, place: item.place) }
    }

    /// The snapshot with the logo, app name, place and time in the corner.
    @MainActor static func tag(_ cg: CGImage, place: String) -> CGImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let u = max(12, w * 0.032)   // scales the tag with the picture
        let view = ZStack(alignment: .bottomTrailing) {
            Image(decorative: cg, scale: 1).resizable().frame(width: w, height: h)
            HStack(spacing: u * 0.5) {
                Image("Radome").resizable().scaledToFit().frame(width: u * 1.8, height: u * 1.8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("DopplerIQ").font(.system(size: u * 1.1, weight: .bold))
                    Text("\(place) · \(Date().formatted(date: .abbreviated, time: .shortened))").font(.system(size: u * 0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, u * 0.8).padding(.vertical, u * 0.5)
            .background(Color.black.opacity(0.55), in: Capsule())
            .padding(u)
        }
        .frame(width: w, height: h)
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.cgImage
    }
}

/// Radar color scale: light rain on the left to hail on the right.
struct RadarLegend: View {
    private static let colors: [Color] = [
        Color(red: 0.39, green: 0.92, blue: 0.45), Color(red: 0.13, green: 0.70, blue: 0.20), Color(red: 0.05, green: 0.48, blue: 0.10),
        Color(red: 0.98, green: 0.92, blue: 0.10), Color(red: 0.98, green: 0.62, blue: 0.08), Color(red: 0.93, green: 0.13, blue: 0.10),
        Color(red: 0.70, green: 0.05, blue: 0.10), Color(red: 0.88, green: 0.20, blue: 0.85), Color(red: 0.55, green: 0.25, blue: 0.85),
        Color(white: 0.95),
    ]
    var body: some View {
        HStack(spacing: 6) {
            Text("Light").font(.caption2).foregroundStyle(.secondary)
            LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing)
                .frame(height: 5)
                .clipShape(Capsule())
            Text("Hail").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
