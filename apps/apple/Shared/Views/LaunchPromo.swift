import SwiftUI

/// Free plan only: a full-screen "support DopplerIQ" page when the app opens, at most once a day.
/// Shows on the first launch, then again after 24 hours. Always skippable.
struct LaunchPromoModifier: ViewModifier {
    @EnvironmentObject var store: Store
    @AppStorage("promoLastShown") private var lastShown: Double = 0
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .task {
                // let StoreKit finish checking purchases (and the location prompt settle) first
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await store.refreshEntitlements()
                guard store.effectivePlan == .free, !store.radarPack,
                      Date().timeIntervalSince1970 - lastShown > 24 * 3600 else { return }
                lastShown = Date().timeIntervalSince1970
                show = true
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $show) { LaunchPromo().environmentObject(store) }
            #else
            .sheet(isPresented: $show) { LaunchPromo().environmentObject(store).frame(width: 480, height: 680) }
            #endif
    }
}

extension View {
    func launchPromo() -> some View { modifier(LaunchPromoModifier()) }
}

struct LaunchPromo: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showPlans = false
    private static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    private var yearPrice: String { store.product(for: .plus, yearly: true)?.displayPrice ?? "$24.99" }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Kit.purple.opacity(0.85), Color(red: 0.07, green: 0.04, blue: 0.16), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer(minLength: 20)
                Image("Radome").resizable().scaledToFit().frame(width: 96, height: 96).foregroundStyle(.white)
                Text("DopplerIQ is free because of ads. They keep the radar running and pay for new features.")
                    .font(.title.weight(.medium))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                Text("Go ad-free and unlock every map layer and weather alerts with Plus.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 10)

                KitBigButton(title: store.trialText(.plus) != nil ? "Start Free Trial" : "Go Ad-Free") {
                    Task {
                        await store.buy(.plus, yearly: true)
                        if store.effectivePlan >= .plus { dismiss() }
                    }
                }
                KitBigButton(title: "See All Plans", primary: false) { showPlans = true }
                Button("Continue without upgrading") { dismiss() }
                    .buttonStyle(.plain).underline().font(.headline).padding(.top, 4)

                Text(trialLine).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.85))
                if let m = store.message { Text(m).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
                HStack(spacing: 6) {
                    Link("Terms of Use", destination: Self.terms).underline()
                    Text("and")
                    Link("Privacy Policy", destination: AppConfig.privacyURL).underline()
                }
                .font(.subheadline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            .frame(maxWidth: 560)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
        .onChange(of: store.effectivePlan) { _, p in if p >= .plus { dismiss() } }
    }

    private var trialLine: String {
        if let t = store.trialText(.plus) { return "\(t.prefix(1).uppercased() + t.dropFirst()). Renews at \(yearPrice)/year." }
        return "Plus is \(yearPrice)/year. Cancel anytime in your App Store settings."
    }
}
