import Foundation
import StoreKit

enum Plan: Int, Comparable, CaseIterable {
    case free = 0, plus, pro
    static func < (a: Plan, b: Plan) -> Bool { a.rawValue < b.rawValue }
    var name: String { ["Free", "Plus", "Pro"][rawValue] }
    var blurb: String {
        switch self {
        case .free: return "Radar, forecasts and alerts, with ads"
        case .plus: return "No ads, every map layer, hurricane tracker"
        case .pro: return "Pro workspace, route weather, hail history, marine"
        }
    }
}

/// App Store subscriptions (StoreKit 2). Products are created in App Store Connect with the IDs in AppConfig.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var plan: Plan = .free
    @Published var message: String?

    /// For testing before products exist in App Store Connect (Settings > Preview plan). Debug builds only.
    @Published var previewPlan: Plan? {
        didSet { UserDefaults.standard.set(previewPlan?.rawValue ?? -1, forKey: "previewPlan") }
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
        products = (try? await Product.products(for: [AppConfig.plusMonthly, AppConfig.proMonthly]))?.sorted { $0.price < $1.price } ?? []
        await refreshEntitlements()
    }

    func refreshEntitlements() async {
        var best: Plan = .free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil else { continue }
            if t.productID == AppConfig.proMonthly { best = .pro }
            else if t.productID == AppConfig.plusMonthly, best < .plus { best = .plus }
        }
        plan = best
    }

    func product(for p: Plan) -> Product? {
        products.first { $0.id == (p == .pro ? AppConfig.proMonthly : AppConfig.plusMonthly) }
    }

    func buy(_ p: Plan) async {
        guard let product = product(for: p) else {
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
