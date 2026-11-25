import AppKit
import SwiftUI

/// Settings › Menu Bar Appearance.
struct AppearanceSettingsView: View {
    let controller: AppearanceController
    let store: AppearanceStore

    /// "all" or a display key.
    @State private var scopeKey = "all"
    @State private var systemSettings = MenuBarSystemSettings.read()
    @State private var previewAppearance: BarAppearance = MenuBarAppearanceProbe.reading(for: NSScreen.main).appearance
    /// "all" or "<display key>\n<Space id>".
    @State private var desktopKey = "all"
    /// nil: Spaces cannot be read.
    @State private var spaceLists: [ManagedDisplaySpaces]? = ManagedSpaces.read()

    private static let menuBarSettingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 })) {
                    Text("Style the menu bar", tableName: "Appearance")
                    Text("Draws behind the menu bar; titles, icons and clicks are not affected.", tableName: "Appearance")
                }
                limitations
                AppearancePreviewStrip(style: styleBinding.wrappedValue, appearance: previewAppearance,
                                       showsNotch: selectedDisplayHasNotch)
                Picker(selection: $previewAppearance) {
                    Text("Light menu bar", tableName: "Appearance").tag(BarAppearance.light)
                    Text("Dark menu bar", tableName: "Appearance").tag(BarAppearance.dark)
                } label: {
                    Text("Preview", tableName: "Appearance")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("macOS picks dark or light menu bar text from your wallpaper. Colors set to “Light and dark” follow that choice.", tableName: "Appearance")
            }

            Section {
                LabeledContent {
                    Menu {
                        ForEach(AppearancePresets.all) { preset in
                            Button(String(localized: preset.name)) {
                                try? store.applyPreset(id: preset.id, to: scope)
                            }
                        }
                    } label: {
                        Text("Choose…", tableName: "Appearance")
                    }
                    .fixedSize()
                } label: {
                    Text("Start from a preset", tableName: "Appearance")
                }
            }

            displaysSection
            cornersSection

            Section {
                Picker(selection: styleBinding.kind) {
                    ForEach(StyleKind.allCases, id: \.self) { kind in
                        Text(Self.title(kind)).tag(kind)
                    }
                } label: {
                    Text("Style", tableName: "Appearance")
                }
                kindOptions
            }

            if styleBinding.wrappedValue.kind != .system {
                shapeSection
                borderSection
            }
        }
        .formStyle(.grouped)
        .task {
            // The background and auto-hide settings are changed in System Settings: re-read while visible.
            while !Task.isCancelled {
                let current = MenuBarSystemSettings.read()
                if current != systemSettings { systemSettings = current }
                let spaces = ManagedSpaces.read()
                if spaces != spaceLists { spaceLists = spaces }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Scope

    private var displays: [DisplayIdentity] { NSScreen.screens.compactMap(\.rolltopDisplayIdentity) }

    /// The display being edited. Per-display styles can be on when the pane opens (an
    /// earlier session, a profile, a command): then the first connected display is edited.
    private var effectiveScopeKey: String {
        guard store.perDisplay else { return "all" }
        if scopeKey != "all",
           displays.contains(where: { $0.key == scopeKey }) || store.configuration.displayStyles[scopeKey] != nil {
            return scopeKey
        }
        return displays.first?.key ?? "all"
    }

    /// The display (or every display) being edited, or one of its desktops.
    private var scope: AppearanceScope {
        guard let desktop = selectedDesktop else { return displayScope }
        return .space(display: desktop.display, spaceID: desktop.spaceID,
                      fallback: store.perDisplay ? .display : .allDisplays)
    }

    private var displayScope: AppearanceScope {
        let key = effectiveScopeKey
        guard key != "all" else { return .allDisplays }
        if let display = displays.first(where: { $0.key == key }) { return .display(display) }
        if let entry = store.configuration.displayStyles[key] {
            return .display(DisplayIdentity(key: key, name: entry.name, displayID: 0))
        }
        return .allDisplays
    }

    private var styleBinding: Binding<AppearanceStyle> {
        Binding(get: { store.style(for: scope) }, set: { store.setStyle($0, for: scope) })
    }

    private var selectedDisplayHasNotch: Bool {
        let screen: NSScreen?
        if case .display(let display) = scope {
            screen = NSScreen.screens.first { $0.rolltopDisplayID == display.displayID }
        } else {
            screen = NSScreen.main
        }
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }

    @ViewBuilder private var displaysSection: some View {
        Section {
            Picker(selection: Binding(get: { store.perDisplay }, set: { newValue in
                store.perDisplay = newValue
                if newValue, scopeKey == "all" { scopeKey = displays.first?.key ?? "all" }
                if !newValue { scopeKey = "all" }
            })) {
                Text("Same on every display", tableName: "Appearance").tag(false)
                Text("Different on each display", tableName: "Appearance").tag(true)
            } label: {
                Text("Displays", tableName: "Appearance")
            }
            if store.perDisplay {
                Picker(selection: Binding(get: { effectiveScopeKey }, set: { scopeKey = $0 })) {
                    ForEach(displays) { display in
                        Text(verbatim: display.name).tag(display.key)
                    }
                    ForEach(disconnectedDisplays, id: \.key) { entry in
                        Text("\(entry.name) (not connected)", tableName: "Appearance").tag(entry.key)
                    }
                } label: {
                    Text("Editing", tableName: "Appearance")
                }
            }
            desktopsSection
        }
    }

    // MARK: Desktops

    private struct DesktopRow: Identifiable {
        var display: DisplayIdentity
        var spaceID: String
        var number: Int
        var isCurrent: Bool
        var id: String { "\(display.key)\n\(spaceID)" }
    }

    /// Desktops of the display being edited (every display when styles are shared).
    private var desktopRows: [DesktopRow] {
        guard let spaceLists else { return [] }
        let shown: [DisplayIdentity]
        if case .display(let display) = displayScope {
            shown = displays.filter { $0.key == display.key }
        } else {
            shown = displays
        }
        return shown.flatMap { display -> [DesktopRow] in
            guard let list = ManagedSpaces.spaces(forDisplay: display.key, in: spaceLists) else { return [] }
            return list.desktops.enumerated().map { index, space in
                DesktopRow(display: display, spaceID: space.id, number: index + 1, isCurrent: space.id == list.currentID)
            }
        }
    }

    private var selectedDesktop: (display: DisplayIdentity, spaceID: String)? {
        guard desktopKey != "all", let row = desktopRows.first(where: { $0.id == desktopKey }) else { return nil }
        return (row.display, row.spaceID)
    }

    @ViewBuilder private var desktopsSection: some View {
        if spaceLists == nil {
            LimitationNote(Text("Desktops can’t be read on this Mac, so styles apply to whole displays.", tableName: "Appearance"))
        } else {
            let rows = desktopRows
            let showsDisplayNames = Set(rows.map(\.display.key)).count > 1
            Picker(selection: Binding(get: { selectedDesktop == nil ? "all" : desktopKey }, set: { desktopKey = $0 })) {
                Text("All desktops", tableName: "Appearance").tag("all")
                ForEach(rows) { row in
                    Text(desktopTitle(row, showsDisplayName: showsDisplayNames)).tag(row.id)
                }
            } label: {
                Text("Desktop", tableName: "Appearance")
                Text("A desktop without its own style uses the display’s style.", tableName: "Appearance")
            }
            if let desktop = selectedDesktop, store.hasOwnStyle(displayKey: desktop.display.key, spaceID: desktop.spaceID) {
                Button {
                    store.removeSpaceStyle(displayKey: desktop.display.key, spaceID: desktop.spaceID)
                } label: {
                    Text("Remove this desktop’s style", tableName: "Appearance")
                }
            }
        }
    }

    private func desktopTitle(_ row: DesktopRow, showsDisplayName: Bool) -> String {
        var title = row.isCurrent
            ? String(localized: "Desktop \(row.number) (current)", table: "Appearance")
            : String(localized: "Desktop \(row.number)", table: "Appearance")
        if showsDisplayName { title = "\(row.display.name) – \(title)" }
        return title
    }

    // MARK: Corners

    @ViewBuilder private var cornersSection: some View {
        let corners = Binding(get: { store.corners }, set: { store.corners = $0 })
        Section {
            Toggle(isOn: corners.screenCorners) {
                Text("Round the screen corners", tableName: "Appearance")
                Text("Black rounded corners at the top of the screen, over the ends of the menu bar.", tableName: "Appearance")
            }
            Toggle(isOn: corners.belowMenuBar) {
                Text("Round the corners below the menu bar", tableName: "Appearance")
                Text("Black rounded corners at the top of the desktop, so the menu bar looks separate. Not drawn in full-screen apps.", tableName: "Appearance")
            }
            if corners.wrappedValue.drawsAny {
                LabeledContent {
                    Slider(value: corners.radius, in: AppearanceCorners.radiusRange, step: 1) { EmptyView() }
                        .frame(maxWidth: 220)
                    Text(verbatim: "\(Int(corners.wrappedValue.radius)) pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                } label: {
                    Text("Corner radius", tableName: "Appearance")
                }
            }
        } header: {
            Text("Screen corners", tableName: "Appearance")
        } footer: {
            Text("On every display, also when the menu bar is not styled.", tableName: "Appearance")
        }
    }

    private var disconnectedDisplays: [(key: String, name: String)] {
        let connected = Set(displays.map(\.key))
        return store.configuration.displayStyles
            .filter { !connected.contains($0.key) }
            .map { (key: $0.key, name: $0.value.name) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Limitations

    @ViewBuilder private var limitations: some View {
        if systemSettings.showsBackground {
            LimitationRow(symbol: "exclamationmark.triangle",
                          text: Text("“Show menu bar background” is on, so macOS draws its own background and these styles stay hidden. Turn it off in System Settings › Menu Bar.", tableName: "Appearance"),
                          action: Text("Open Menu Bar Settings", tableName: "Appearance")) {
                NSWorkspace.shared.open(Self.menuBarSettingsURL)
            }
        }
        if systemSettings.hidesAutomatically {
            LimitationRow(symbol: "exclamationmark.triangle",
                          text: Text("The menu bar hides automatically, so styling is paused. Choose “Never” for “Automatically hide and show the menu bar” in System Settings › Menu Bar to use it.", tableName: "Appearance"),
                          action: Text("Open Menu Bar Settings", tableName: "Appearance")) {
                NSWorkspace.shared.open(Self.menuBarSettingsURL)
            }
        }
        if systemSettings.reducesTransparency {
            LimitationRow(symbol: "info.circle",
                          text: Text("Reduce Transparency is on: materials and glass look solid.", tableName: "Appearance"),
                          action: nil, perform: nil)
        }
    }

    // MARK: Kind options

    @ViewBuilder private var kindOptions: some View {
        let style = styleBinding
        switch style.wrappedValue.kind {
        case .system:
            Text("The menu bar looks as macOS draws it. Nothing runs.", tableName: "Appearance")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .tint:
            AdaptiveColorEditor(title: Text("Color", tableName: "Appearance"), color: style.tint)
            PercentSlider(title: Text("Opacity", tableName: "Appearance"), value: style.tintOpacity)
        case .gradient:
            AdaptiveColorEditor(title: Text("Start color", tableName: "Appearance"), color: style.gradientStart)
            AdaptiveColorEditor(title: Text("End color", tableName: "Appearance"), color: style.gradientEnd)
            LabeledContent {
                Slider(value: style.gradientAngle, in: 0...360, step: 15) { EmptyView() }
                    .frame(maxWidth: 220)
                Text(verbatim: "\(Int(style.wrappedValue.gradientAngle))°")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            } label: {
                Text("Angle", tableName: "Appearance")
            }
            PercentSlider(title: Text("Opacity", tableName: "Appearance"), value: style.gradientOpacity)
        case .material:
            Picker(selection: style.material) {
                ForEach(MaterialThickness.allCases, id: \.self) { thickness in
                    Text(Self.title(thickness)).tag(thickness)
                }
            } label: {
                Text("Thickness", tableName: "Appearance")
            }
        case .glass:
            Picker(selection: style.glass) {
                Text("Regular", tableName: "Appearance").tag(GlassVariant.regular)
                Text("Clear", tableName: "Appearance").tag(GlassVariant.clear)
            } label: {
                Text("Glass", tableName: "Appearance")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: style.glassIsTinted) {
                Text("Tint the glass", tableName: "Appearance")
            }
            if style.wrappedValue.glassIsTinted {
                AdaptiveColorEditor(title: Text("Tint", tableName: "Appearance"), color: style.tint)
            }
        case .outline:
            Text("Only the border is drawn. Set its color and width below.", tableName: "Appearance")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var shapeSection: some View {
        let style = styleBinding
        Section {
            Picker(selection: style.shape) {
                Text("Full width", tableName: "Appearance").tag(BarShape.fullWidth)
                Text("Rounded bar", tableName: "Appearance").tag(BarShape.inset)
                Text("Two pills", tableName: "Appearance").tag(BarShape.split)
            } label: {
                Text("Shape", tableName: "Appearance")
            }
            if style.wrappedValue.shape == .split {
                Text("One pill around the app menus, one around the status items. Needs Device Control and Data Access to follow the menus.", tableName: "Appearance")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                Slider(value: style.cornerRadius, in: 0...16, step: 1) { EmptyView() }
                    .frame(maxWidth: 220)
                Text(verbatim: "\(Int(style.wrappedValue.cornerRadius)) pt")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            } label: {
                Text("Corner radius", tableName: "Appearance")
            }
            if style.wrappedValue.shape != .split {
                Toggle(isOn: style.splitAroundNotch) {
                    Text("Split around the camera housing", tableName: "Appearance")
                    Text("On displays with a notch, draws the bar in two parts beside it.", tableName: "Appearance")
                }
            }
        } header: {
            Text("Shape", tableName: "Appearance")
        }
    }

    @ViewBuilder private var borderSection: some View {
        let style = styleBinding
        Section {
            if style.wrappedValue.kind != .outline {
                Toggle(isOn: style.border.isEnabled) {
                    Text("Border", tableName: "Appearance")
                }
            }
            if style.wrappedValue.effectiveBorder.isEnabled {
                AdaptiveColorEditor(title: Text("Border color", tableName: "Appearance"), color: style.border.color)
                LabeledContent {
                    Slider(value: style.border.width, in: 0.5...4, step: 0.5) { EmptyView() }
                        .frame(maxWidth: 220)
                    Text(verbatim: String(format: "%.1f pt", style.wrappedValue.border.width))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                } label: {
                    Text("Border width", tableName: "Appearance")
                }
            }
            Toggle(isOn: style.shadow.isEnabled) {
                Text("Shadow", tableName: "Appearance")
            }
            if style.wrappedValue.shadow.isEnabled {
                PercentSlider(title: Text("Shadow strength", tableName: "Appearance"), value: style.shadow.strength)
            }
        } header: {
            Text("Border and shadow", tableName: "Appearance")
        }
    }

    // MARK: Titles

    static func title(_ kind: StyleKind) -> String {
        switch kind {
        case .system: String(localized: "System", table: "Appearance")
        case .tint: String(localized: "Tint", table: "Appearance")
        case .gradient: String(localized: "Gradient", table: "Appearance")
        case .material: String(localized: "Material", table: "Appearance")
        case .glass: String(localized: "Glass", table: "Appearance")
        case .outline: String(localized: "Outline", table: "Appearance")
        }
    }

    static func title(_ thickness: MaterialThickness) -> String {
        switch thickness {
        case .ultraThin: String(localized: "Ultra thin", table: "Appearance")
        case .thin: String(localized: "Thin", table: "Appearance")
        case .regular: String(localized: "Regular", table: "Appearance")
        case .thick: String(localized: "Thick", table: "Appearance")
        case .ultraThick: String(localized: "Ultra thick", table: "Appearance")
        }
    }
}

// MARK: - Rows

private struct LimitationRow: View {
    let symbol: String
    let text: Text
    let action: Text?
    let perform: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            text
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action, let perform {
                Button(action: perform) { action }
            }
        }
    }
}

private struct PercentSlider: View {
    let title: Text
    @Binding var value: Double

    var body: some View {
        LabeledContent {
            Slider(value: $value, in: 0...1) { EmptyView() }
                .frame(maxWidth: 220)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        } label: {
            title
        }
    }
}

/// Edits an `AdaptiveColor`: match system, one colour, or one per bar appearance.
struct AdaptiveColorEditor: View {
    let title: Text
    @Binding var color: AdaptiveColor

    var body: some View {
        Picker(selection: $color.mode) {
            Text("Match system", tableName: "Appearance").tag(AdaptiveColor.Mode.matchSystem)
            Text("One color", tableName: "Appearance").tag(AdaptiveColor.Mode.single)
            Text("Light and dark", tableName: "Appearance").tag(AdaptiveColor.Mode.lightAndDark)
        } label: {
            title
        }
        switch color.mode {
        case .matchSystem:
            EmptyView()
        case .single:
            ColorPicker(selection: rgbaBinding(\.light), supportsOpacity: true) {
                Text("Color", tableName: "Appearance")
            }
        case .lightAndDark:
            ColorPicker(selection: rgbaBinding(\.light), supportsOpacity: true) {
                Text("On a light menu bar", tableName: "Appearance")
            }
            ColorPicker(selection: rgbaBinding(\.dark), supportsOpacity: true) {
                Text("On a dark menu bar", tableName: "Appearance")
            }
        }
    }

    private func rgbaBinding(_ keyPath: WritableKeyPath<AdaptiveColor, RGBA>) -> Binding<Color> {
        Binding {
            let rgba = color[keyPath: keyPath]
            return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
        } set: { newValue in
            guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            color[keyPath: keyPath] = RGBA(Double(srgb.redComponent), Double(srgb.greenComponent),
                                           Double(srgb.blueComponent), Double(srgb.alphaComponent))
        }
    }
}

// MARK: - Preview strip

/// A small mock menu bar with the chosen style, drawn by the same segment views as the
/// overlay. Content is drawn above the style, as on the real bar.
struct AppearancePreviewStrip: View {
    let style: AppearanceStyle
    let appearance: BarAppearance
    let showsNotch: Bool

    private let barHeight: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let notch: ClosedRange<CGFloat>? = showsNotch ? (width * 0.44)...(width * 0.56) : nil
            let menusWidth = min(max(width * 0.36, 170), showsNotch ? width * 0.42 : width * 0.5)
            let statusMinX = width * (showsNotch ? 0.62 : 0.6)
            let input = BarLayoutInput(barSize: CGSize(width: width, height: barHeight), notch: notch,
                                       appMenusMaxX: menusWidth, statusItemsMinX: statusMinX,
                                       shape: style.shape, splitAroundNotch: style.splitAroundNotch,
                                       cornerRadius: style.cornerRadius)
            let segments = style.drawsOverlay ? AppearanceBarGeometry.segments(input) : []
            ZStack(alignment: .topLeading) {
                wallpaper
                ForEach(segments) { segment in
                    BarSegmentView(segment: segment, style: style, appearance: appearance)
                        .frame(width: segment.frame.width, height: segment.frame.height)
                        .position(x: segment.frame.midX, y: segment.frame.midY)
                }
                .environment(\.colorScheme, appearance == .dark ? .dark : .light)
                if let notch {
                    UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(bottomLeading: 6, bottomTrailing: 6))
                        .fill(Color.black)
                        .frame(width: notch.upperBound - notch.lowerBound, height: barHeight)
                        .offset(x: notch.lowerBound)
                }
                mockMenus
                    .frame(width: menusWidth, height: barHeight, alignment: .leading)
                mockStatusItems
                    .frame(width: width - statusMinX, height: barHeight, alignment: .trailing)
                    .offset(x: statusMinX)
            }
            .foregroundStyle(appearance == .dark ? Color.white : Color.black.opacity(0.85))
            .animation(.smooth(duration: 0.2), value: segments)
        }
        .frame(height: barHeight + 14)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the menu bar style", tableName: "Appearance"))
    }

    private var wallpaper: some View {
        LinearGradient(colors: appearance == .dark
                       ? [Color(red: 0.24, green: 0.22, blue: 0.34), Color(red: 0.16, green: 0.26, blue: 0.42)]
                       : [Color(red: 0.93, green: 0.86, blue: 0.82), Color(red: 0.80, green: 0.87, blue: 0.95)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private var mockMenus: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.logo")
            Text("Finder", tableName: "Appearance", comment: "Menu bar preview: the Finder’s app menu").fontWeight(.semibold)
            Text("File", tableName: "Appearance", comment: "Menu bar preview: the File menu")
            Text("Edit", tableName: "Appearance", comment: "Menu bar preview: the Edit menu")
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.leading, 12)
    }

    /// Monday 9:41 in the user's format ("Mon 9:41 AM", "周一 上午9:41").
    private static let previewClock: String = {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 41)) ?? Date()
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }()

    private var mockStatusItems: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Image(systemName: "switch.2")
            Text(Self.previewClock)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.trailing, 12)
    }
}
