import Foundation
import RolltopCore

/// A command as the palette sees it: plain data, so expansion is testable.
nonisolated struct PaletteCommandDescriptor: Sendable {
    nonisolated struct Argument: Sendable {
        var name: String
        var isRequired: Bool
        var allowedValues: [String]?
    }

    var id: CommandID
    var arguments: [Argument]
    var isAvailable: Bool
}

/// One runnable command row: a command id plus a value for each required argument.
nonisolated struct PaletteCommandInvocation: Sendable, Hashable {
    var id: CommandID
    var arguments: [String: String]
    /// Arguments in declaration order, for titles ("Set Section for New Items: Hidden").
    var orderedValues: [(name: String, value: String)]

    /// Usage-history key: `command:<id>` or `command:<id>?name=value&…`.
    var key: String {
        guard !orderedValues.isEmpty else { return "command:\(id.rawValue)" }
        return "command:\(id.rawValue)?" + orderedValues.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.arguments == rhs.arguments }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(arguments)
    }
}

/// Which commands become rows and how arguments expand. Pure.
nonisolated enum PaletteCommandExpansion {
    /// Cap per command, so a long `allowedValues` list cannot flood the results.
    static let maxRowsPerCommand = 64

    /// Never listed: Debug commands; the commands that open the palette itself;
    /// `profiles.apply…`, whose rows duplicate the "Apply profile <name>" rows built from
    /// the profiles service.
    static func isExcluded(_ id: CommandID) -> Bool {
        let raw = id.rawValue
        return id.isDebugOnly || raw == "palette.toggle" || raw == "palette.show"
            || raw == "profiles.apply" || raw.hasPrefix("profiles.apply-")
    }

    /// Rows for one command: none when it is unavailable, excluded or needs free text (a
    /// required argument without `allowedValues`); one row when it needs nothing; one row
    /// per combination of allowed values otherwise. Optional arguments are left out.
    static func invocations(for command: PaletteCommandDescriptor) -> [PaletteCommandInvocation] {
        guard command.isAvailable, !isExcluded(command.id) else { return [] }
        let required = command.arguments.filter(\.isRequired)
        var combinations: [[(name: String, value: String)]] = [[]]
        for argument in required {
            guard let values = argument.allowedValues else { return [] }
            var next: [[(name: String, value: String)]] = []
            for combination in combinations {
                for value in values where !value.isEmpty {
                    next.append(combination + [(argument.name, value)])
                    if next.count >= maxRowsPerCommand { break }
                }
                if next.count >= maxRowsPerCommand { break }
            }
            combinations = next
        }
        return combinations.map { values in
            PaletteCommandInvocation(id: command.id,
                                     arguments: Dictionary(values.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
                                     orderedValues: values)
        }
    }

    /// A readable form of a raw argument value without a better name: "always-hidden" →
    /// "Always hidden".
    static func humanize(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return value }
        return first.uppercased() + spaced.dropFirst()
    }
}
