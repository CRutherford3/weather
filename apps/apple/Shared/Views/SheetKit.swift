import SwiftUI

// Shared look for sheets and settings pages: a centered bold title with round back and close buttons,
// full-width rows with purple switches, green checkmarks, pill tabs, picture cards and big round buttons.
// Used on iPhone, iPad and Mac so every screen feels the same.

enum Kit {
    static let purple = Color(red: 0.54, green: 0.24, blue: 0.86)
    static let green = Color(red: 0.06, green: 0.73, blue: 0.47)
    static let amber = Color(red: 0.97, green: 0.66, blue: 0.13)
    /// Gray for unselected pills, round buttons and secondary buttons.
    static let fill = Color.primary.opacity(0.12)
    static let line = Color.primary.opacity(0.09)
    #if os(macOS)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let row = Color(nsColor: .controlBackgroundColor)
    #else
    static let page = Color(uiColor: .systemGroupedBackground)
    static let row = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

// MARK: - Closing the whole sheet from any page inside it

private struct KitCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Closes the sheet these pages live in. Nil when the pages aren't in a sheet (the Settings tab).
    var kitClose: (() -> Void)? {
        get { self[KitCloseKey.self] }
        set { self[KitCloseKey.self] = newValue }
    }
}

/// Root of a sheet: a navigation stack whose pages can all close the sheet with the X button.
struct KitSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack { content() }
            .environment(\.kitClose, { dismiss() })
            #if os(iOS)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            #else
            .frame(width: 500, height: 700)
            #endif
    }
}

// MARK: - Header and page

struct KitCircleButton: View {
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Kit.fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct KitHeader: View {
    let title: String
    var back: (() -> Void)?
    var close: (() -> Void)?

    var body: some View {
        ZStack {
            Text(title).font(.headline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 60)
            HStack {
                if let back { KitCircleButton(icon: "chevron.left", action: back) }
                Spacer()
                if let close { KitCircleButton(icon: "xmark", action: close) }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

/// A settings-style page: header, then scrolling content.
struct KitPage<Content: View>: View {
    let title: String
    /// First page of a sheet or tab: no back button.
    var root = false
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.kitClose) private var close

    var body: some View {
        VStack(spacing: 0) {
            KitHeader(title: title, back: backAction, close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.bottom, 28)
            }
        }
        .background(Kit.page.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var backAction: (() -> Void)? {
        if root { return nil }
        return { dismiss() }
    }
}

// MARK: - Section text

struct KitSectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

struct KitFooter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

// MARK: - Rows

private struct KitRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(Kit.row)
            .overlay(alignment: .bottom) { Rectangle().fill(Kit.line).frame(height: 0.5) }
            .contentShape(Rectangle())
    }
}

extension View {
    /// Full-width settings row: padding, row color and a hairline under it.
    func kitRow() -> some View { modifier(KitRowStyle()) }
}

struct KitLabel: View {
    let title: String
    var subtitle: String?
    var badge: Plan?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.primary)
                if let badge { TierBadge(plan: badge) }
            }
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
}

struct KitToggleRow: View {
    let title: String
    var subtitle: String?
    var badge: Plan?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { KitLabel(title: title, subtitle: subtitle, badge: badge) }
            .toggleStyle(.switch)
            .tint(Kit.purple)
            .kitRow()
    }
}

/// Opens another page.
struct KitNavRow<Destination: View>: View {
    let title: String
    var value: String?
    var icon: String?
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink { destination() } label: {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).frame(width: 24).foregroundStyle(Kit.purple) }
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
                Chevron()
            }
            .kitRow()
        }
        .buttonStyle(.plain)
    }
}

/// Opens another page, with an on/off switch on the right (alert categories).
struct KitNavToggleRow<Destination: View>: View {
    let title: String
    var value: String?
    var badge: Plan?
    @Binding var isOn: Bool
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink { destination() } label: {
                HStack(spacing: 10) {
                    Text(title).foregroundStyle(.primary)
                    if let badge { TierBadge(plan: badge) }
                    Spacer(minLength: 8)
                    if let value { Text(value).foregroundStyle(.secondary) }
                    Chevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Kit.purple)
        }
        .kitRow()
    }
}

/// A tappable row (open a link, run an action).
struct KitButtonRow: View {
    let title: String
    var value: String?
    var icon: String?
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).frame(width: 24).foregroundStyle(Kit.purple) }
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(.secondary) }
                if chevron { Chevron() }
            }
            .kitRow()
        }
        .buttonStyle(.plain)
    }
}

/// One choice in a list, with a green check on the selected one.
struct KitCheckRow: View {
    let title: String
    var subtitle: String?
    var badge: Plan?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                KitLabel(title: title, subtitle: subtitle, badge: badge)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Kit.green) }
            }
            .kitRow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pills, cards, buttons, banners

/// Big pill tabs: purple when selected, gray otherwise.
struct KitPills<T: Hashable>: View {
    let options: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Button { withAnimation(.snappy) { selection = o.value } } label: {
                    Text(o.title)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(selection == o.value ? Kit.purple : Kit.fill, in: Capsule())
                        .foregroundStyle(selection == o.value ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Picture card: thumbnail, title, description, a green lock when it needs an upgrade,
/// and a purple outline when it's on.
struct KitCard<Thumb: View>: View {
    let title: String
    let subtitle: String
    var selected = false
    var locked = false
    let action: () -> Void
    @ViewBuilder var thumb: () -> Thumb

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                thumb()
                    .frame(width: 108, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Kit.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if locked { Image(systemName: "lock.fill").font(.title3).foregroundStyle(Kit.green) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Kit.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Kit.purple : Kit.line, lineWidth: selected ? 2.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Full-width round button. Primary is green; secondary is gray.
struct KitBigButton: View {
    let title: String
    var subtitle: String?
    var primary = true
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle { Text(subtitle).font(.subheadline) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, subtitle == nil ? 16 : 11)
            .background(primary ? Kit.green : Kit.fill, in: Capsule())
            .foregroundStyle(primary ? Color.black : Color.primary)
            .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Amber tip with an X to hide it.
struct KitTip: View {
    let text: String
    let onClose: () -> Void
    var body: some View {
        HStack {
            Text(text).font(.subheadline).foregroundStyle(.black)
            Spacer(minLength: 8)
            Button(action: onClose) { Image(systemName: "xmark.circle").font(.title3).foregroundStyle(.black) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Kit.amber, in: Capsule())
    }
}

/// Rounded search field.
struct KitSearchField: View {
    let prompt: String
    @Binding var text: String
    var body: some View {
        HStack {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if text.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Kit.row, in: Capsule())
    }
}
