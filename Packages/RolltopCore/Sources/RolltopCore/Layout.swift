import Foundation

/// Where an owner's items live.
public enum Section: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    case shown
    case hidden
    case alwaysHidden = "always-hidden"

    /// Accepts the raw value plus a few spellings (`alwaysHidden`, `always_hidden`).
    public init?(argument: String) {
        switch argument.lowercased() {
        case "shown", "show", "visible": self = .shown
        case "hidden", "hide": self = .hidden
        case "always-hidden", "alwayshidden", "always_hidden": self = .alwaysHidden
        default: return nil
        }
    }

    private var order: Int {
        switch self {
        case .shown: 0
        case .hidden: 1
        case .alwaysHidden: 2
        }
    }

    public static func < (lhs: Section, rhs: Section) -> Bool { lhs.order < rhs.order }
}

/// How much of the bar is currently revealed.
public enum PresentationLevel: String, CaseIterable, Codable, Sendable, Hashable, Comparable {
    /// Only the shown section is visible.
    case collapsed
    /// Shown and hidden sections are visible.
    case hiddenRevealed = "hidden-revealed"
    /// Every section is visible.
    case allRevealed = "all-revealed"

    private var order: Int {
        switch self {
        case .collapsed: 0
        case .hiddenRevealed: 1
        case .allRevealed: 2
        }
    }

    /// Whether items of `section` are revealed at this level (ignoring conceal-shown).
    public func reveals(_ section: Section) -> Bool {
        switch section {
        case .shown: true
        case .hidden: self >= .hiddenRevealed
        case .alwaysHidden: self == .allRevealed
        }
    }

    public static func < (lhs: PresentationLevel, rhs: PresentationLevel) -> Bool { lhs.order < rhs.order }
}

/// Section assignments. Owners without an explicit entry use `defaultSection`.
public struct Layout: Hashable, Sendable {
    public var sections: [OwnerID: Section]
    public var defaultSection: Section

    public init(sections: [OwnerID: Section] = [:], defaultSection: Section = .shown) {
        self.sections = sections
        self.defaultSection = defaultSection
    }

    public static let empty = Layout()

    public func section(for owner: OwnerID) -> Section {
        sections[owner] ?? defaultSection
    }

    public func hasExplicitSection(_ owner: OwnerID) -> Bool {
        sections[owner] != nil
    }

    /// Sets an explicit section, or removes the entry when `section` is nil.
    public mutating func setSection(_ section: Section?, for owner: OwnerID) {
        sections[owner] = section
    }

    /// Owners with an explicit entry in `section`, sorted.
    public func explicitOwners(in section: Section) -> [OwnerID] {
        sections.filter { $0.value == section }.map(\.key).sorted()
    }

    /// Writes the current effective section of every given owner explicitly, so a
    /// later change of `defaultSection` only affects owners seen afterwards.
    public func freezingSections(of owners: some Sequence<OwnerID>) -> Layout {
        var copy = self
        for owner in owners where copy.sections[owner] == nil {
            copy.sections[owner] = defaultSection
        }
        return copy
    }
}

extension Layout: Codable {
    private enum CodingKeys: String, CodingKey {
        case sections
        case defaultSection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: Section].self, forKey: .sections) ?? [:]
        var sections: [OwnerID: Section] = [:]
        for (key, value) in raw {
            // Unknown or malformed keys are dropped instead of failing the whole layout.
            if let owner = OwnerID(stringValue: key) { sections[owner] = value }
        }
        self.sections = sections
        self.defaultSection = try container.decodeIfPresent(Section.self, forKey: .defaultSection) ?? .shown
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: sections.map { ($0.key.stringValue, $0.value) })
        try container.encode(raw, forKey: .sections)
        try container.encode(defaultSection, forKey: .defaultSection)
    }
}
