import Foundation
import Testing
@testable import Rolltop

/// Every string catalog is translated into Simplified Chinese, each translation keeps its
/// source's placeholders and plural categories, and the built app carries every table in
/// `zh-Hans.lproj`. When this fails, add the missing translations to scripts/l10n/tm/ and run
/// `scripts/l10n/l10n.py --build` (see scripts/l10n/glossary.md for the terms).
@Suite struct LocalizationCatalogTests {
    static let source = "en"
    static let target = "zh-Hans"
    /// CLDR plural categories Rolltop's catalogs use: English one/other, Chinese other only.
    static let pluralCategories: [String: Set<String>] = ["en": ["one", "other"], "zh-Hans": ["other"]]

    struct Catalog {
        let table: String
        let path: String
        let strings: [String: [String: Any]]
    }

    /// The repository, from this file's location (RolltopTests/Localization/…).
    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func catalogs() throws -> [Catalog] {
        let rolltop = repository.appendingPathComponent("Rolltop")
        let files = FileManager.default.enumerator(at: rolltop, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "xcstrings" } ?? []
        return try files.map { url in
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
            return Catalog(table: url.deletingPathExtension().lastPathComponent,
                           path: String(url.path.dropFirst(repository.path.count + 1)), strings: strings)
        }.sorted { $0.table < $1.table }
    }

    // MARK: Placeholders

    /// printf specifiers by argument position (`%@`, `%lld`, `%2$@`…) and `${name}` tokens.
    struct Placeholders: Equatable {
        var arguments: [Int: String] = [:]
        var tokens: Set<String> = []
    }

    static func placeholders(in text: String) -> Placeholders {
        var result = Placeholders()
        let specifier = /%(?:(\d+)\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
        var next = 1
        for match in text.matches(of: specifier) {
            let conversion = String(match.output.3)
            if conversion == "%" { continue }
            let index: Int
            if let position = match.output.1, let value = Int(position) {
                index = value
            } else {
                index = next
                next += 1
            }
            let length = match.output.2.map(String.init) ?? ""
            var kind = ["i": "d", "D": "d", "U": "u", "O": "o", "F": "f", "S": "@", "s": "@", "C": "c"][conversion] ?? conversion
            kind = (length == "q" ? "ll" : length) + kind
            if kind == "ld" { kind = "lld" }
            result.arguments[index] = kind
        }
        for match in text.matches(of: /\$\{([A-Za-z_]\w*)\}/) {
            result.tokens.insert(String(match.output.1))
        }
        return result
    }

    // MARK: Reading an entry

    static func unit(_ localization: [String: Any]?) -> (state: String, value: String)? {
        guard let unit = localization?["stringUnit"] as? [String: Any], let value = unit["value"] as? String else { return nil }
        return (unit["state"] as? String ?? "", value)
    }

    static func plural(_ localization: [String: Any]?) -> [String: [String: Any]]? {
        (localization?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
    }

    static func stringSet(_ localization: [String: Any]?) -> (state: String, values: [String])? {
        guard let set = localization?["stringSet"] as? [String: Any], let values = set["values"] as? [String] else { return nil }
        return (set["state"] as? String ?? "", values)
    }

    /// Problems with one catalog entry, as readable lines.
    static func problems(table: String, key: String, entry: [String: Any]) -> [String] {
        if entry["shouldTranslate"] as? Bool == false { return [] }
        let name = "[\(table)] \"\(key)\""
        let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
        let english = localizations[source]
        guard let chinese = localizations[target] else { return ["\(name): no \(target) translation"] }

        if let set = stringSet(english) ?? stringSet(chinese) {
            guard let translated = stringSet(chinese), translated.state == "translated", !translated.values.isEmpty else {
                return ["\(name): \(target) phrases missing or not translated"]
            }
            let tokens = placeholders(in: set.values.first ?? key).tokens
            return translated.values.filter { placeholders(in: $0).tokens != tokens }
                .map { "\(name): phrase “\($0)” must contain \(tokens.sorted().map { "${\($0)}" })" }
        }

        var found: [String] = []
        let sourcePlural = plural(english)
        let reference: String
        if let sourcePlural {
            if Set(sourcePlural.keys) != pluralCategories[source] {
                found.append("\(name): \(source) plural categories \(sourcePlural.keys.sorted())")
            }
            reference = unit(sourcePlural["other"])?.value ?? key
            for (category, variant) in sourcePlural {
                let text = unit(variant)?.value ?? ""
                let expected = placeholders(in: reference)
                let actual = placeholders(in: text)
                // The "one" form may name the count in words instead of using it.
                let fits = category == "one"
                    ? actual.arguments.allSatisfy { expected.arguments[$0.key] == $0.value } && actual.tokens.isSubset(of: expected.tokens)
                    : actual == expected
                if !fits { found.append("\(name): \(source) \(category) “\(text)” has other placeholders") }
            }
        } else {
            reference = unit(english)?.value ?? key
        }

        let translations: [(String, (state: String, value: String)?)]
        if let targetPlural = plural(chinese) {
            if sourcePlural == nil { found.append("\(name): \(target) varies by plural but the source does not") }
            if Set(targetPlural.keys) != pluralCategories[target] {
                found.append("\(name): \(target) plural categories \(targetPlural.keys.sorted()), expected \(pluralCategories[target]!.sorted())")
            }
            translations = targetPlural.map { ($0.key, unit($0.value)) }
        } else {
            if sourcePlural != nil { found.append("\(name): the source varies by plural but \(target) does not") }
            translations = [("", unit(chinese))]
        }
        for (category, translation) in translations {
            guard let translation, translation.state == "translated", !translation.value.isEmpty else {
                found.append("\(name): \(target) \(category) not translated")
                continue
            }
            if placeholders(in: translation.value) != placeholders(in: reference) {
                found.append("\(name): \(target) “\(translation.value)” has placeholders that differ from “\(reference)”")
            }
        }
        return found
    }

    // MARK: Tests

    @Test func catalogsAreFound() throws {
        let tables = try Self.catalogs().map(\.table)
        #expect(tables.count >= 10, "string catalogs not found under \(Self.repository.path)/Rolltop")
        #expect(tables.contains("InfoPlist") && tables.contains("AppShortcuts") && tables.contains("Localizable"))
    }

    @Test func everyEntryIsTranslatedWithTheSamePlaceholdersAndPluralCategories() throws {
        var problems: [String] = []
        for catalog in try Self.catalogs() {
            if catalog.strings.isEmpty { problems.append("[\(catalog.table)] \(catalog.path) is empty") }
            for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
                problems += Self.problems(table: catalog.table, key: key, entry: entry)
            }
        }
        #expect(problems.isEmpty, "\(problems.count) problems:\n\(problems.joined(separator: "\n"))")
    }

    @Test func theCheckCatchesMistakes() {
        let translated: [String: Any] = ["stringUnit": ["state": "translated", "value": "%@ 等 %lld 项"]]
        #expect(Self.problems(table: "T", key: "%@ and %lld more", entry: ["localizations": ["zh-Hans": translated]]).isEmpty)
        #expect(!Self.problems(table: "T", key: "%@ and %lld more",
                               entry: ["localizations": ["zh-Hans": ["stringUnit": ["state": "translated", "value": "%@ 等"]]]]).isEmpty)
        #expect(!Self.problems(table: "T", key: "Apply ${profile}",
                               entry: ["localizations": ["zh-Hans": ["stringUnit": ["state": "translated", "value": "应用预设"]]]]).isEmpty)
        #expect(!Self.problems(table: "T", key: "Hidden", entry: [:]).isEmpty)
        let english: [String: Any] = ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "%lld item"]],
            "other": ["stringUnit": ["state": "translated", "value": "%lld items"]]]]]
        let chinese: [String: Any] = ["variations": ["plural": ["other": ["stringUnit": ["state": "translated", "value": "%lld 项"]]]]]
        #expect(Self.problems(table: "T", key: "%lld items", entry: ["localizations": ["en": english, "zh-Hans": chinese]]).isEmpty)
        let wrongCategories: [String: Any] = ["variations": ["plural": [
            "one": ["stringUnit": ["state": "translated", "value": "%lld 项"]],
            "other": ["stringUnit": ["state": "translated", "value": "%lld 项"]]]]]
        #expect(!Self.problems(table: "T", key: "%lld items", entry: ["localizations": ["en": english, "zh-Hans": wrongCategories]]).isEmpty)
        #expect(Self.placeholders(in: "%1$@ 失败：%2$@") == Self.placeholders(in: "%@ failed: %@"))
        #expect(Self.placeholders(in: "%lld%%") != Self.placeholders(in: "%@%%"))
    }

    @Test func theAppCarriesEveryTableInBothLanguages() throws {
        let bundle = Bundle.main
        #expect(bundle.localizations.contains(Self.target), "the app has no \(Self.target).lproj")
        #expect(bundle.localizations.contains(Self.source), "the app has no \(Self.source).lproj: \(bundle.localizations)")
        var missing: [String] = []
        for catalog in try Self.catalogs() where !catalog.strings.isEmpty {
            let strings = bundle.url(forResource: catalog.table, withExtension: "strings", subdirectory: nil, localization: Self.target)
            let plurals = bundle.url(forResource: catalog.table, withExtension: "stringsdict", subdirectory: nil, localization: Self.target)
            if strings == nil && plurals == nil { missing.append(catalog.table) }
        }
        #expect(missing.isEmpty, "\(Self.target).lproj lacks: \(missing.joined(separator: ", "))")
    }

    @Test func theBuiltTranslationsMatchTheCatalogs() throws {
        let lproj = try #require(Bundle.main.path(forResource: Self.target, ofType: "lproj"))
        let chinese = try #require(Bundle(path: lproj))
        var wrong: [String] = []
        for catalog in try Self.catalogs() where catalog.table != "AppShortcuts" {
            for (key, entry) in catalog.strings {
                guard let localizations = entry["localizations"] as? [String: [String: Any]],
                      let expected = Self.unit(localizations[Self.target])?.value else { continue }
                let actual = chinese.localizedString(forKey: key, value: "\u{1}", table: catalog.table)
                if actual != expected { wrong.append("[\(catalog.table)] \"\(key)\" → \"\(actual)\"") }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) built strings differ from the catalogs (rebuild?):\n\(wrong.prefix(20).joined(separator: "\n"))")
    }

    /// The scheme runs tests in English (project.yml); only meaningful when the host does.
    @Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en"))
    func englishPluralsUseTheirSingularForm() {
        #expect(String(localized: "\(1) items", table: "LayoutEditor") == "1 item")
        #expect(String(localized: "\(3) items", table: "LayoutEditor") == "3 items")
    }
}
