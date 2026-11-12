import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings tab (iPhone) and Settings item (iPad, Mac).
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: Store
    @State private var showPlans = false

    var body: some View {
        KitPage(title: "Settings", root: true) {
            planCard.padding(.horizontal, 16).padding(.top, 8)

            if store.effectivePlan < .pro {
                KitNavRow(title: "Pro Radar Pack", value: store.radarPack ? "Owned" : (store.radarPackProduct?.displayPrice ?? "$6.99"), icon: "dot.radiowaves.left.and.right") {
                    RadarPackPage()
                }
                .padding(.top, 12)
            }

            KitSectionHeader(text: "Alerts")
            KitNavRow(title: "Notifications", value: AlertMonitor.isOn && store.effectivePlan >= .plus ? "On" : "Off", icon: "bell.badge.fill") {
                NotificationsPage(showPlans: $showPlans)
            }

            KitSectionHeader(text: "Display")
            KitNavRow(title: "Appearance", value: state.appearance.title, icon: "circle.lefthalf.filled") { AppearancePage() }
            KitNavRow(title: "Units", value: state.units == .imperial ? "°F, mph" : "°C, km/h", icon: "ruler") { UnitsPage() }
            KitNavRow(title: "Advanced Settings", icon: "slider.horizontal.3") { AdvancedPage() }

            KitSectionHeader(text: "About")
            Link(destination: AppConfig.webBase) { linkRow("Website", icon: "globe") }.buttonStyle(.plain)
            Link(destination: AppConfig.supportURL) { linkRow("Support", icon: "questionmark.circle") }.buttonStyle(.plain)
            Link(destination: AppConfig.privacyURL) { linkRow("Privacy Policy", icon: "hand.raised") }.buttonStyle(.plain)
            KitFooter(text: "Data: National Weather Service, NOAA (NHC, SPC, WPC, NESDIS), Iowa Environmental Mesonet, Open-Meteo. Not for life-safety decisions; always follow official warnings.")
            Text("\(AppConfig.displayName) v\(AppConfig.version)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

            #if DEBUG
            KitSectionHeader(text: "Testing")
            ForEach(Plan.allCases, id: \.self) { p in
                KitCheckRow(title: "Preview \(p.name)", selected: (store.previewPlan ?? store.plan) == p) { store.previewPlan = p }
            }
            #endif
        }
        .sheet(isPresented: $showPlans) { PlansView().environmentObject(store) }
    }

    private func linkRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Kit.purple)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .kitRow()
    }

    private var planCard: some View {
        Button { showPlans = true } label: {
            HStack(spacing: 14) {
                Image("Radome").resizable().scaledToFit().frame(width: 34, height: 34).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DopplerIQ \(store.effectivePlan.name)").font(.headline).foregroundStyle(.white)
                    Text(store.effectivePlan == .pro ? "Every feature is unlocked" : "Unlock premium features")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(18)
            .background(LinearGradient(colors: [Kit.purple, Color(red: 0.25, green: 0.12, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Notifications

struct NotificationsPage: View {
    @Binding var showPlans: Bool
    @EnvironmentObject var store: Store
    @ObservedObject private var prefs = AlertSettings.shared
    @Environment(\.openURL) private var openURL
    @State private var alertsOn = AlertMonitor.isOn
    @State private var denied = false

    private var allowed: Bool { store.effectivePlan >= .plus }

    var body: some View {
        KitPage(title: "Notifications") {
            if !allowed {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Weather alerts are part of Plus").font(.headline)
                    Text("Warnings for your location and saved places, plus a heads-up before rain starts.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    KitBigButton(title: "See Plans") { showPlans = true }
                }
                .padding(16)
                .background(Kit.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 8)
            }

            KitSectionHeader(text: "General")
            KitToggleRow(title: "All Notifications", badge: allowed ? nil : .plus, isOn: Binding(
                get: { alertsOn && allowed },
                set: { on in
                    if !allowed { showPlans = true; return }
                    if on { Task { alertsOn = await AlertMonitor.enable(); denied = !alertsOn } }
                    else { AlertMonitor.disable(); alertsOn = false }
                }))
            if denied {
                KitFooter(text: "Notifications are off for DopplerIQ in your device settings. Turn them on there, then try again.")
            }
            KitButtonRow(title: "Open Notification Settings", icon: "gear") { openSystemSettings() }
            KitNavRow(title: "Quiet Hours", value: prefs.quietOn ? "\(clock(prefs.quietFrom)) to \(clock(prefs.quietTo))" : "Off", icon: "moon.fill") {
                QuietHoursPage()
            }
            KitFooter(text: "Life-threatening warnings always come through, even during quiet hours.")

            KitSectionHeader(text: "Rain")
            KitNavRow(title: "Rain Alerts", value: prefs.rainLevel.title, icon: "cloud.rain.fill") { RainLevelPage() }
            KitFooter(text: "A heads-up when rain is expected at your location within about 45 minutes.")

            KitSectionHeader(text: "NWS Weather Alerts (USA)")
            ForEach(AlertCategory.allCases) { c in
                KitNavToggleRow(title: c.title, value: prefs.category(c) ? prefs.summary(c) : nil,
                                isOn: Binding(get: { prefs.category(c) }, set: { prefs.setCategory(c, $0) })) {
                    CategoryPage(category: c)
                }
            }
            KitFooter(text: "For your location and up to 9 saved places. Checked every few minutes while the app is open, and in the background on iPhone and iPad.")
        }
    }

    private func openSystemSettings() {
        #if os(iOS)
        if let u = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(u) }
        #else
        if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { openURL(u) }
        #endif
    }
}

/// "10:00 PM" from minutes after midnight.
func clock(_ minutes: Int) -> String {
    let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    return d.formatted(date: .omitted, time: .shortened)
}

private struct CategoryPage: View {
    let category: AlertCategory
    @ObservedObject private var prefs = AlertSettings.shared

    var body: some View {
        KitPage(title: category.title) {
            KitSectionHeader(text: "Alerts")
            KitToggleRow(title: "All \(category.title)", isOn: Binding(get: { prefs.category(category) }, set: { prefs.setCategory(category, $0) }))
            KitSectionHeader(text: "Alert types")
            ForEach(category.events, id: \.self) { e in
                KitToggleRow(title: e, subtitle: AlertPrefs.breakThrough.contains(e) ? "Comes through during quiet hours" : nil,
                             isOn: Binding(get: { prefs.event(e) }, set: { prefs.setEvent(e, $0) }))
            }
            .disabled(!prefs.category(category))
            .opacity(prefs.category(category) ? 1 : 0.45)
        }
    }
}

private struct QuietHoursPage: View {
    @ObservedObject private var prefs = AlertSettings.shared

    var body: some View {
        KitPage(title: "Quiet Hours") {
            KitSectionHeader(text: "Schedule")
            KitToggleRow(title: "Quiet Hours", isOn: Binding(get: { prefs.quietOn }, set: { prefs.quietOn = $0 }))
            timeRow("From", Binding(get: { prefs.quietFrom }, set: { prefs.quietFrom = $0 }))
            timeRow("To", Binding(get: { prefs.quietTo }, set: { prefs.quietTo = $0 }))
            KitFooter(text: "No alert sounds or banners during these hours, except life-threatening warnings like tornado, flash flood, extreme wind and hurricane warnings.")
        }
    }

    private func timeRow(_ title: String, _ minutes: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
        return HStack {
            Text(title)
            Spacer()
            DatePicker(title, selection: date, displayedComponents: .hourAndMinute).labelsHidden()
        }
        .kitRow()
        .disabled(!prefs.quietOn)
        .opacity(prefs.quietOn ? 1 : 0.45)
    }
}

private struct RainLevelPage: View {
    @ObservedObject private var prefs = AlertSettings.shared

    var body: some View {
        KitPage(title: "Rain Alerts") {
            KitFooter(text: "Get a heads-up when rain at or heavier than this level is expected within about 45 minutes.")
            KitSectionHeader(text: "Alert me for")
            ForEach(RainLevel.allCases) { l in
                KitCheckRow(title: l.title, subtitle: l.detail, selected: prefs.rainLevel == l) { prefs.rainLevel = l }
            }
        }
    }
}

// MARK: - Display

private struct AppearancePage: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        KitPage(title: "Appearance") {
            KitSectionHeader(text: "Theme")
            ForEach(Appearance.allCases) { a in
                KitCheckRow(title: a.title, selected: state.appearance == a) { state.appearance = a }
            }
        }
    }
}

private struct UnitsPage: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        KitPage(title: "Units") {
            KitSectionHeader(text: "Units")
            KitCheckRow(title: "°F, mph", subtitle: "US", selected: state.units == .imperial) { state.units = .imperial }
            KitCheckRow(title: "°C, km/h", subtitle: "Metric", selected: state.units == .metric) { state.units = .metric }
        }
    }
}

private struct AdvancedPage: View {
    @AppStorage("mapBorders") private var borders = true
    @AppStorage("mapCounties") private var counties = true

    var body: some View {
        KitPage(title: "Advanced Settings") {
            KitFooter(text: "These settings may change or reset in future updates.")
            KitSectionHeader(text: "Map")
            KitToggleRow(title: "State and US borders", isOn: $borders)
            KitToggleRow(title: "County lines", subtitle: "Shown when zoomed in to about one state", isOn: $counties)
        }
    }
}
