import Foundation
import StoreKit

enum Plan: Int, Comparable, CaseIterable {
    case free = 0, plus, pro
    static func < (a: Plan, b: Plan) -> Bool { a.rawValue < b.rawValue }
    var name: String { ["Free", "Plus", "Pro"][rawValue] }
    var blurb: String {
        switch self {
        case .free: return "Radar, forecasts and alerts, with ads"
        case .plus: return "No ads, every map layer, alerts for your places"
        case .pro: return "Doppler radar, pro workspace, route weather, hail history, marine"
        }
    }
}

/// App Store subscriptions (StoreKit 2). Products are created in App Store Connect with the IDs in AppConfig.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var plan: Plan = .free
    /// Owns the one-time Pro Radar Pack.
    @Published private(set) var radarPack = false
    @Published var message: String?

    /// For testing before products exist in App Store Connect (Settings > Preview plan). Debug builds only.
    @Published var previewPlan: Plan? {
        didSet { UserDefaults.standard.set(previewPlan?.rawValue ?? -1, forKey: "previewPlan"); savePlanLevel() }
    }
    var effectivePlan: Plan { previewPlan ?? plan }

    private var updates: Task<Void, Never>?

    init() {
        #if DEBUG
        let v = UserDefaults.standard.integer(forKey: "previewPlan")
        if UserDefaults.standard.object(forKey: "previewPlan") != nil { previewPlan = v >= 0 ? Plan(rawValue: v) : nil }
        else { previewPlan = .pro }   // builds run from Xcode start on Pro for testing
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task { await load() }
    }

    func load() async {
        let ids = AppConfig.plusIDs.union(AppConfig.proIDs).union([AppConfig.radarPack])
        products = (try? await Product.products(for: ids))?.sorted { $0.price < $1.price } ?? []
        await refreshTrialEligibility()
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var best: Plan = .free
        var pack = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == AppConfig.radarPack { pack = true }
            if AppConfig.proIDs.contains(t.productID) { best = .pro }
            else if AppConfig.plusIDs.contains(t.productID), best < .plus { best = .plus }
        }
        plan = best
        radarPack = pack
        savePlanLevel()
    }

    /// Background alert checks read this instead of StoreKit.
    private func savePlanLevel() { UserDefaults.standard.set(effectivePlan.rawValue, forKey: "planLevel") }

    /// Map layers: open with the right plan. The Radar Pack opens only the Doppler (single radar site) layer.
    func canUse(_ l: MapLayer) -> Bool { effectivePlan >= l.tier || (radarPack && l.inRadarPack) }

    /// Doppler extras (tilts, dual-pol, VIL, echo tops, past and future radar): Pro or the Radar Pack.
    var hasDoppler: Bool { radarPack || effectivePlan >= .pro }

    /// Yearly plans start with a free trial (an introductory offer set in App Store Connect).
    @Published private(set) var trialEligible = true
    func refreshTrialEligibility() async {
        if let sub = products.first(where: { $0.id == AppConfig.plusYearly })?.subscription {
            trialEligible = await sub.isEligibleForIntroOffer
        }
    }
    /// "7-day free trial" from the product's intro offer, if the user can still get it.
    func trialText(_ p: Plan) -> String? {
        guard trialEligible, let offer = product(for: p, yearly: true)?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day: return "\(n)-day free trial"
        case .week: return n == 1 ? "7-day free trial" : "\(n)-week free trial"
        case .month: return "\(n)-month free trial"
        default: return "Free trial"
        }
    }

    var radarPackProduct: Product? { products.first { $0.id == AppConfig.radarPack } }

    func buyRadarPack() async {
        guard let product = radarPackProduct else {
            message = "The Radar Pack isn't set up in App Store Connect yet."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish(); await refreshEntitlements()
            case .success(.unverified): message = "The purchase couldn't be verified."
            case .pending: message = "Purchase pending approval."
            default: break
            }
        } catch { message = error.localizedDescription }
    }

    func product(for p: Plan, yearly: Bool = false) -> Product? {
        let id: String
        switch (p, yearly) {
        case (.pro, true): id = AppConfig.proYearly
        case (.pro, false): id = AppConfig.proMonthly
        case (_, true): id = AppConfig.plusYearly
        default: id = AppConfig.plusMonthly
        }
        return products.first { $0.id == id }
    }

    func buy(_ p: Plan, yearly: Bool = false) async {
        guard let product = product(for: p, yearly: yearly) else {
            message = "Subscriptions aren't set up in App Store Connect yet."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish(); await refreshEntitlements()
            case .success(.unverified): message = "The purchase couldn't be verified."
            case .pending: message = "Purchase pending approval."
            default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }
}
