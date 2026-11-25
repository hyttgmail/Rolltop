import AppKit
import SwiftUI

/// The panel's content: a glass sheet hanging from the menu bar, growing downwards.
struct ShelfPanelView: View {
    @Bindable var controller: ShelfController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 26,
                                                      bottomTrailingRadius: 26, topTrailingRadius: 12, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            let revealed = controller.isRevealed
            let height = reduceMotion || revealed ? proxy.size.height : min(proxy.size.height, 44)
            ShelfPanelContent(controller: controller)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .frame(width: proxy.size.width, height: height, alignment: .top)
                .clipShape(Self.shape)
                .glassEffect(.regular, in: Self.shape)
                .opacity(revealed ? 1 : 0)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .onExitCommand { controller.send(.escape) }
        // The panel never becomes the key window of an active app: draw its controls as
        // active anyway, or every button would look disabled.
        .environment(\.controlActiveState, .key)
    }
}

private struct ShelfPanelContent: View {
    @Bindable var controller: ShelfController

    var body: some View {
        let sections = controller.config.enabledSections
        VStack(spacing: 0) {
            ShelfHeader(controller: controller, sections: sections)
            ShelfCardsRow(controller: controller)
            if sections.isEmpty {
                ShelfNothingOn(controller: controller)
            } else {
                switch controller.section {
                case .clipboard: ShelfClipboardSection(controller: controller)
                case .files: ShelfFilesSection(controller: controller)
                case .upNext: ShelfUpNextSection(controller: controller)
                }
            }
        }
    }
}

extension ShelfSection {
    var title: Text {
        switch self {
        case .clipboard: Text("Clipboard", tableName: "Shelf")
        case .files: Text("Files", tableName: "Shelf")
        case .upNext: Text("Up next", tableName: "Shelf")
        }
    }
}

private struct ShelfHeader: View {
    @Bindable var controller: ShelfController
    let sections: [ShelfSection]
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if sections.count > 1 {
                Picker(selection: Binding(get: { controller.section }, set: { controller.select($0); controller.send(.interacted) })) {
                    ForEach(sections, id: \.self) { section in section.title.tag(section) }
                } label: {
                    Text("Section", tableName: "Shelf")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if let only = sections.first {
                only.title.font(.headline)
            } else {
                Text("Shelf", tableName: "Shelf").font(.headline)
            }
            Spacer(minLength: 4)
            if controller.section == .clipboard, sections.contains(.clipboard) {
                TextField(text: $controller.searchText, prompt: Text("Search", tableName: "Shelf")) {
                    Text("Search clipboard history", tableName: "Shelf")
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 170)
                .focused($searchFocused)
                .onChange(of: searchFocused) { _, focused in if focused { controller.send(.interacted) } }
                .onKeyPress(.downArrow) { controller.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { controller.moveSelection(-1); return .handled }
                .onSubmit { controller.copySelectionOrFirst() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [controller] frame in
                    controller.searchFieldFrame = frame
                }
            }
            Button {
                controller.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(Text("Shelf Settings", tableName: "Shelf"))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Shelf Settings", tableName: "Shelf"))
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct ShelfNothingOn: View {
    let controller: ShelfController

    var body: some View {
        ShelfEmptyState(symbol: "tray", title: Text("Nothing on the shelf yet", tableName: "Shelf"),
                        detail: Text("Turn on clipboard history, the file shelf or Up next in Settings. Each is off until you choose it.", tableName: "Shelf")) {
            Button {
                controller.openSettings()
            } label: {
                Text("Shelf Settings…", tableName: "Shelf")
            }
            .buttonStyle(.glass)
        }
    }
}

private struct ShelfEmptyState<Accessory: View>: View {
    let symbol: String
    let title: Text
    let detail: Text
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            title.font(.headline)
            detail
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            accessory().padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Clipboard

private struct ShelfClipboardSection: View {
    @Bindable var controller: ShelfController

    var body: some View {
        let clips = controller.visibleClips
        VStack(spacing: 0) {
            if controller.history.clips.isEmpty {
                ShelfEmptyState(symbol: "doc.on.clipboard", title: Text("Nothing copied yet", tableName: "Shelf"),
                                detail: Text("Text, links, files and images you copy appear here. Choosing one copies it again; paste it with ⌘V.", tableName: "Shelf")) {
                    EmptyView()
                }
            } else if clips.isEmpty {
                ShelfEmptyState(symbol: "magnifyingglass", title: Text("No matches", tableName: "Shelf"),
                                detail: Text("Nothing in the history contains these words.", tableName: "Shelf")) { EmptyView() }
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(clips) { clip in
                                ShelfClipRow(controller: controller, clip: clip, isSelected: controller.selectedClipID == clip.id)
                                    .id(clip.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                    }
                    .onChange(of: controller.selectedClipID) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
            ShelfClipboardFooter(controller: controller)
        }
    }
}

private struct ShelfClipRow: View {
    let controller: ShelfController
    let clip: ShelfClip
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            // Option-click does the other thing (paste when choosing copies, and back).
            controller.choose(clip.id, alternate: NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 10) {
                leading
                    .frame(width: 26, height: 26)
                Text(verbatim: clip.preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if clip.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Pinned", tableName: "Shelf"))
                }
                if let icon = ShelfAppIcons.icon(for: clip.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
                Text(verbatim: ShelfFormat.relative(clip.lastCopied))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isHovered || isSelected ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [controller, id = clip.id] frame in
            controller.debugRowFrames[id] = frame
        }
        #endif
        .help(Text(verbatim: String(clip.searchableText.prefix(400))))
        .contextMenu {
            Button { controller.copy(clip.id) } label: { Text("Copy", tableName: "Shelf") }
            Button { controller.setPinned(clip.id, !clip.isPinned) } label: {
                clip.isPinned ? Text("Unpin", tableName: "Shelf") : Text("Pin", tableName: "Shelf")
            }
            Divider()
            Button(role: .destructive) { controller.delete(clip.id) } label: { Text("Delete", tableName: "Shelf") }
        }
    }

    @ViewBuilder private var leading: some View {
        if clip.kind == .image, let image = controller.thumbnail(for: clip) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: clip.kind.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

private struct ShelfClipboardFooter: View {
    let controller: ShelfController

    var body: some View {
        HStack(spacing: 8) {
            if let until = controller.pausedUntil {
                Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))", tableName: "Shelf")
                    .foregroundStyle(.secondary)
                Button { controller.resume() } label: { Text("Resume", tableName: "Shelf") }
                    .buttonStyle(.glass)
            } else {
                Text("\(controller.history.clips.count) clips, kept on this Mac", tableName: "Shelf")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if controller.pausedUntil == nil {
                    ForEach(ShelfSettings.pauseChoices, id: \.self) { minutes in
                        Button { controller.pause(minutes: minutes) } label: { ShelfFormat.pauseTitle(minutes) }
                    }
                    Divider()
                }
                Button(role: .destructive) { controller.clearHistory() } label: { Text("Clear History", tableName: "Shelf") }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel(Text("More", tableName: "Shelf"))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

// MARK: - Files

private struct ShelfFilesSection: View {
    let controller: ShelfController

    var body: some View {
        let items = controller.files.items
        VStack(spacing: 0) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(controller.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: controller.isDropTargeted ? 2 : 1.2, dash: [6, 5]))
                    .overlay {
                        ShelfEmptyState(symbol: "tray.and.arrow.down", title: Text("Drop files here", tableName: "Shelf"),
                                        detail: Text("The shelf keeps a reference, not a copy. Drag them out again wherever you need them.", tableName: "Shelf")) {
                            EmptyView()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 100), spacing: 6)], spacing: 6) {
                        ForEach(items) { item in
                            ShelfFileTile(item: item, isMissing: controller.filePresence[item.id] == .missing, controller: controller)
                                .frame(width: 88, height: 92)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .overlay {
                    if controller.isDropTargeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(.horizontal, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
            HStack {
                ShelfFormat.lifetimeCaption(controller.config.fileLifetime)
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button { controller.clearFiles() } label: { Text("Clear Shelf", tableName: "Shelf") }
                        .buttonStyle(.glass)
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Up next

private struct ShelfUpNextSection: View {
    let controller: ShelfController

    var body: some View {
        switch controller.calendarAccess {
        case .granted:
            if controller.upNext.isEmpty {
                ShelfEmptyState(symbol: "calendar", title: Text("Nothing else today or tomorrow", tableName: "Shelf"),
                                detail: Text("Events from your calendars appear here.", tableName: "Shelf")) { EmptyView() }
            } else {
                ScrollView { ShelfUpNextList(controller: controller, upNext: controller.upNext) }
            }
        case .notDetermined:
            ShelfEmptyState(symbol: "calendar.badge.exclamationmark", title: Text("Up next needs your calendars", tableName: "Shelf"),
                            detail: Text("Rolltop reads today’s and tomorrow’s events when the shelf opens and stores none of them.", tableName: "Shelf")) {
                Button { controller.requestCalendarAccess() } label: { Text("Allow Calendar Access…", tableName: "Shelf") }
                    .buttonStyle(.glassProminent)
            }
        case .denied, .restricted, .writeOnly:
            ShelfEmptyState(symbol: "calendar.badge.exclamationmark", title: Text("Calendar access is off", tableName: "Shelf"),
                            detail: Text("Allow Rolltop to read your calendars in System Settings › Privacy & Security › Calendars.", tableName: "Shelf")) {
                Button { controller.requestCalendarAccess() } label: { Text("Open Privacy Settings", tableName: "Shelf") }
                    .buttonStyle(.glass)
            }
        }
    }
}

private struct ShelfUpNextList: View {
    let controller: ShelfController
    let upNext: ShelfUpNext

    var body: some View {
        let calendar = Calendar.current
        let today = upNext.timed.filter { calendar.isDateInToday($0.start) || $0.start < Date() }
        let tomorrow = upNext.timed.filter { !(calendar.isDateInToday($0.start) || $0.start < Date()) }
        VStack(alignment: .leading, spacing: 4) {
            if !upNext.allDayToday.isEmpty || !today.isEmpty {
                ShelfDayHeader(title: Text("Today", tableName: "Shelf"), allDay: upNext.allDayToday)
                ForEach(today) { event in ShelfEventRow(controller: controller, event: event) }
            }
            if !upNext.allDayTomorrow.isEmpty || !tomorrow.isEmpty {
                ShelfDayHeader(title: Text("Tomorrow", tableName: "Shelf"), allDay: upNext.allDayTomorrow)
                    .padding(.top, 6)
                ForEach(tomorrow) { event in ShelfEventRow(controller: controller, event: event) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private struct ShelfDayHeader: View {
    let title: Text
    let allDay: [ShelfEvent]

    var body: some View {
        HStack(spacing: 6) {
            title.font(.subheadline.weight(.semibold))
            if !allDay.isEmpty {
                Text(verbatim: "·").foregroundStyle(.secondary)
                Text("All day: \(allDay.map(\.title).formatted(.list(type: .and)))", tableName: "Shelf")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ShelfEventRow: View {
    let controller: ShelfController
    let event: ShelfEvent

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(ShelfFormat.color(event.color))
                .frame(width: 4, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: event.title).lineLimit(1)
                Text(verbatim: ShelfFormat.timeRange(event) + (event.calendarTitle.isEmpty ? "" : " · " + event.calendarTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if let link = event.meetingLink {
                Button { controller.join(link) } label: { Text("Join", tableName: "Shelf") }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(Text("Join on \(link.service.displayName)", tableName: "Shelf"))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Formatting

enum ShelfFormat {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "now", table: "Shelf") }
        return date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    static func timeRange(_ event: ShelfEvent) -> String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    static func color(_ rgb: [Double]?) -> Color {
        guard let rgb, rgb.count == 3 else { return .accentColor }
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    static func pauseTitle(_ minutes: Int) -> Text {
        minutes < 60 ? Text("Pause for \(minutes) Minutes", tableName: "Shelf")
            : Text("Pause for \(minutes / 60) Hours", tableName: "Shelf")
    }

    static func lifetimeCaption(_ lifetime: TimeInterval?) -> Text {
        guard let lifetime else { return Text("Files stay until you remove them", tableName: "Shelf") }
        let hours = Int((lifetime / 3600).rounded())
        if hours >= 1 { return Text("Files leave the shelf after \(hours) hours", tableName: "Shelf") }
        return Text("Files leave the shelf after \(Int(lifetime)) seconds", tableName: "Shelf")
    }
}

/// Source app icons, cached by bundle id.
enum ShelfAppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        icon.size = CGSize(width: 16, height: 16)
        cache[bundleID] = icon
        return icon
    }
}
