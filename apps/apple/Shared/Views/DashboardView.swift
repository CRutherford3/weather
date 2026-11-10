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

enum Products {
    static let nesdis = "https://cdn.star.nesdis.noaa.gov/GOES19/ABI"
    static let wpc = "https://www.wpc.ncep.noaa.gov"
    static let spc = "https://www.spc.noaa.gov"

    static let sections: [ProductSection] = [
        .init(id: "Radar & Satellite", products: [
            .init(id: "radar_conus", title: "US Radar Loop", url: "https://radar.weather.gov/ridge/standard/CONUS-LARGE_loop.gif", link: "https://radar.weather.gov"),
            .init(id: "goes_conus", title: "US Satellite Loop", url: "\(nesdis)/CONUS/GEOCOLOR/GOES19-CONUS-GEOCOLOR-625x375.gif", link: "https://www.star.nesdis.noaa.gov/GOES/"),
            .init(id: "goes_ir", title: "US Infrared", url: "\(nesdis)/CONUS/13/1250x750.jpg", link: "https://www.star.nesdis.noaa.gov/GOES/"),
            .init(id: "goes_glm", title: "US Lightning", url: "https://cdn.star.nesdis.noaa.gov/GOES19/GLM/CONUS/EXTENT3/1250x750.jpg", link: "https://www.star.nesdis.noaa.gov/GOES/"),
            .init(id: "goes_se", title: "Southeast Loop", url: "\(nesdis)/SECTOR/se/GEOCOLOR/GOES19-SE-GEOCOLOR-600x600.gif", link: "https://www.star.nesdis.noaa.gov/GOES/"),
        ]),
        .init(id: "Tropics", products: [
            .init(id: "nhc_atl7", title: "Atlantic 7-Day Outlook", url: "https://www.nhc.noaa.gov/xgtwo/two_atl_7d0.png", link: "https://www.nhc.noaa.gov"),
            .init(id: "nhc_epac7", title: "East Pacific 7-Day Outlook", url: "https://www.nhc.noaa.gov/xgtwo/two_pac_7d0.png", link: "https://www.nhc.noaa.gov"),
            .init(id: "taw", title: "Tropical Atlantic Loop", url: "\(nesdis)/SECTOR/taw/GEOCOLOR/GOES19-TAW-GEOCOLOR-900x540.gif", link: "https://www.star.nesdis.noaa.gov/GOES/"),
            .init(id: "shear", title: "Wind Shear (CIMSS)", url: "https://tropic.ssec.wisc.edu/real-time/atlantic/winds/wg8shr.GIF", link: "https://tropic.ssec.wisc.edu", pro: true),
            .init(id: "steer", title: "Steering Currents (CIMSS)", url: "https://tropic.ssec.wisc.edu/real-time/atlantic/winds/wg8dlm1.GIF", link: "https://tropic.ssec.wisc.edu", pro: true),
            .init(id: "ohc", title: "Hurricane Heat Potential", url: "https://www.ospo.noaa.gov/data/ocean/ohc/images/h20_naQG3_ddc.gif", link: "https://www.ospo.noaa.gov", pro: true),
        ]),
        .init(id: "Severe Weather", products: [
            .init(id: "spc_d1", title: "SPC Day 1 Outlook", url: "\(spc)/partners/outlooks/national/swody1.png", link: "\(spc)/products/outlook/"),
            .init(id: "spc_d2", title: "SPC Day 2 Outlook", url: "\(spc)/partners/outlooks/national/swody2.png", link: "\(spc)/products/outlook/"),
            .init(id: "spc_rpt", title: "Today's Storm Reports", url: "\(spc)/climo/reports/today.gif", link: "\(spc)/climo/reports/today.html"),
            .init(id: "haz", title: "NWS Hazards Map", url: "https://forecast.weather.gov/wwamap/png/US.png", link: "https://www.weather.gov"),
            .init(id: "scp", title: "Supercell Composite", url: "\(spc)/exper/mesoanalysis/s19/scp/scp.gif", link: "\(spc)/exper/mesoanalysis/", pro: true),
        ]),
        .init(id: "Rain, Snow & Fronts", products: [
            .init(id: "sfc", title: "Fronts & Pressure", url: "\(wpc)/basicwx/92fndfd.gif", link: "\(wpc)"),
            .init(id: "qpf7", title: "7-Day Rain Forecast", url: "\(wpc)/qpf/p168i.gif", link: "\(wpc)/qpf/qpf2.shtml"),
            .init(id: "ero", title: "Flash Flood Risk Today", url: "\(wpc)/qpf/94ewbg.gif", link: "\(wpc)/qpf/excessive_rainfall_outlook_ero.php"),
            .init(id: "snow1", title: "Chance of 4\"+ Snow: Day 1", url: "\(wpc)/wwd/day1_psnow_gt_04_conus.gif", link: "\(wpc)/wwd/winter_wx.shtml"),
            .init(id: "snowamt", title: "NWS Snowfall Forecast", url: "https://graphical.weather.gov/images/conus/SnowAmt1_conus.png", link: "https://graphical.weather.gov"),
            .init(id: "cpc610", title: "6-10 Day Temperature", url: "https://www.cpc.ncep.noaa.gov/products/predictions/610day/610temp.new.gif", link: "https://www.cpc.ncep.noaa.gov"),
        ]),
        .init(id: "Marine & Space", products: [
            .init(id: "opc", title: "Atlantic Surface Analysis", url: "https://ocean.weather.gov/A_sfc_full_ocean_color.png", link: "https://ocean.weather.gov", pro: true),
            .init(id: "aurora", title: "Aurora Forecast", url: "https://services.swpc.noaa.gov/images/animations/ovation/north/latest.jpg", link: "https://www.swpc.noaa.gov"),
            .init(id: "sun", title: "The Sun Right Now", url: "https://sdo.gsfc.nasa.gov/assets/img/latest/latest_1024_0193.jpg", link: "https://sdo.gsfc.nasa.gov"),
        ]),
    ]
}

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
