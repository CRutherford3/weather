import SwiftUI
import StoreKit

/// Upgrade screen: pick Plus or Pro, see what's included, start the free trial or subscribe.
/// The one-time Radar Pack sits below. Bought through the App Store.
struct PlansView: View {
    @EnvironmentObject var store: Store
    /// Plan shown first (Plus unless someone already has it).
    var start: Plan = .plus

    var body: some View {
        KitSheet { PlansPage(start: start).environmentObject(store) }
    }
}

private struct PlansPage: View {
    @EnvironmentObject var store: Store
    let start: Plan
    @State private var plan: Plan = .plus

    private let features: [Plan: [String]] = [
        .plus: ["Ad-free", "Every map layer: lightning, rain rate, echo tops", "Road weather", "Severe weather and rain alerts",
                "Hurricane tracker"],
        .pro: ["Everything in Plus", "Doppler radar at any site: 4 tilts, velocity, dual-pol, VIL", "Past 48 hours and future radar",
               "iPad and Mac pro workspace", "Route weather with EV charging stops", "Marine, buoys and nautical charts"],
    ]
    private let fallback: [Plan: (month: String, year: String)] = [.plus: ("$2.99", "$24.99"), .pro: ("$9.99", "$59.99")]
    private static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        KitPage(title: "Unlock Premium Features", root: true) {
            VStack(spacing: 18) {
                hero
                KitPills(options: [(Plan.plus, "Plus"), (.pro, "Pro")], selection: $plan)
                checklist
                purchase
                radarPack
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .onAppear { plan = store.effectivePlan >= .plus ? .pro : start }
    }

    private var hero: some View {
        ZStack {
            LinearGradient(colors: [Kit.purple.opacity(0.9), Color(red: 0.08, green: 0.05, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Image("Radome").resizable().scaledToFit().frame(width: 64, height: 64).foregroundStyle(.white)
                Text("Unlock Premium Features").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                Text("You'll get access to the following features.").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(features[plan] ?? [], id: \.self) { f in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.title3)
                    Text(f).font(.title3.weight(.medium))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var current: Bool { store.effectivePlan == plan }
    private var yearPrice: String { store.product(for: plan, yearly: true)?.displayPrice ?? fallback[plan]?.year ?? "" }
    private var monthPrice: String { store.product(for: plan)?.displayPrice ?? fallback[plan]?.month ?? "" }

    @ViewBuilder private var purchase: some View {
        VStack(spacing: 12) {
            if current {
                Text("You're on \(plan.name). Thank you!").font(.headline)
            } else {
                if let trial = store.trialText(plan) {
                    Text("Free Trial").font(.title2)
                    Text("\(trial.prefix(1).uppercased() + trial.dropFirst()). Renews at \(yearPrice)/year.").multilineTextAlignment(.center)
                } else if let save = savings {
                    Text("Save \(save)% with yearly").font(.headline).foregroundStyle(Kit.green)
                }
            }
            KitBigButton(title: current ? "Current Plan" : (store.trialText(plan) != nil ? "Start Trial" : "Subscribe \(yearPrice) / year"),
                         disabled: current) {
                Task { await store.buy(plan, yearly: true) }
            }
            if !current {
                KitBigButton(title: "Subscribe", subtitle: "\(monthPrice) / month", primary: false) {
                    Task { await store.buy(plan, yearly: false) }
                }
            }
            if let m = store.message { Text(m).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
        }
        .padding(.top, 6)
    }

    /// Percent saved by paying yearly instead of monthly.
    private var savings: Int? {
        func value(_ s: String) -> Double { Double(s.filter { "0123456789.".contains($0) }) ?? 0 }
        let m = store.product(for: plan).map { NSDecimalNumber(decimal: $0.price).doubleValue } ?? value(fallback[plan]?.month ?? "")
        let y = store.product(for: plan, yearly: true).map { NSDecimalNumber(decimal: $0.price).doubleValue } ?? value(fallback[plan]?.year ?? "")
        guard m > 0, y > 0 else { return nil }
        let pct = Int(((1 - y / (m * 12)) * 100).rounded())
        return pct > 0 ? pct : nil
    }

    private var radarPack: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Pro Radar Pack", image: "Radome").font(.title3.bold())
                Spacer()
                Text(store.radarPackProduct?.displayPrice ?? "$6.99").font(.headline)
            }
            Text("One-time purchase. Doppler radar tools forever, no subscription.").font(.subheadline).foregroundStyle(.secondary)
            ForEach(["Any NEXRAD radar site, at 4 tilt angles", "Velocity for spotting rotation",
                     "Dual-pol: hail and debris, precipitation type, VIL, echo tops", "Past 48 hours and future radar"], id: \.self) {
                Label($0, systemImage: "checkmark").font(.subheadline)
            }
            KitBigButton(title: store.radarPack ? "Purchased" : "Buy Once", primary: false, disabled: store.radarPack) {
                Task { await store.buyRadarPack() }
            }
        }
        .padding(18)
        .background(Kit.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Kit.amber, lineWidth: 2))
        .padding(.top, 10)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Button("Restore previous purchases") { Task { await store.restore() } }
                .buttonStyle(.plain).underline().font(.headline)
            HStack(spacing: 6) {
                Link("Terms of Use", destination: Self.terms).underline()
                Text("and")
                Link("Privacy Policy", destination: AppConfig.privacyURL).underline()
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            Text("Subscriptions renew each month or year until canceled in your App Store account settings. A free trial turns into a paid yearly plan unless canceled at least 24 hours before it ends. The Radar Pack is a one-time purchase.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }
}
