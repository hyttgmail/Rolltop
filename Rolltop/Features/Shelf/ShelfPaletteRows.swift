import Foundation

/// Clipboard history rows for the command palette (Search), through the palette's
/// result-provider contract (`PaletteResultProviding`, App/Contracts/FeatureServices.swift).
/// `rows(…)` is the pure-ish part the tests use; the provider adapts it.
struct ShelfPaletteRow {
    /// The clip's stored UUID: opaque, never derived from content (the palette keeps usage
    /// history by row id outside the shelf's store).
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let action: @MainActor () async throws -> Void
    /// ⌘Return: paste when choosing copies, copy when choosing pastes.
    var alternateTitle: String = ""
    var alternate: (@MainActor () async throws -> Void)?
}

enum ShelfPaletteRows {
    static let providerID = "shelf.clipboard"

    /// Nothing while the query is empty (the palette's rule: answer from memory, no I/O).
    static func rows(controller: ShelfController, query: String, limit: Int = 20) -> [ShelfPaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // The app Search was opened over: captured now, while Search is still on screen.
        let target = controller.pasteTargetPID()
        let alternateTitle = controller.config.chooseAction == .paste
            ? String(localized: "Copy", table: "Shelf") : String(localized: "Paste", table: "Shelf")
        return controller.paletteClips(matching: trimmed, limit: limit).map { clip in
            let kind: String = switch clip.kind {
            case .text, .richText: String(localized: "Text", table: "Shelf")
            case .url: String(localized: "Link", table: "Shelf")
            case .files: String(localized: "Files", table: "Shelf")
            case .image: String(localized: "Image", table: "Shelf")
            }
            let id = clip.id
            return ShelfPaletteRow(id: id.uuidString, title: clip.preview,
                                   subtitle: String(localized: "Copied \(ShelfFormat.relative(clip.lastCopied)) · \(kind)", table: "Shelf"),
                                   symbol: clip.kind.symbol, keywords: [String(clip.searchableText.prefix(200))],
                                   action: { [weak controller] in controller?.choose(id, alternate: false, target: .some(target)) },
                                   alternateTitle: alternateTitle,
                                   alternate: { [weak controller] in controller?.choose(id, alternate: true, target: .some(target)) })
        }
    }

    /// Adds the clipboard provider to the palette's registry (from `start()`).
    static func register(controller: ShelfController, context: AppContext) {
        context.services[.paletteResultProviders].register(ShelfClipboardPaletteProvider(controller: controller))
    }
}

/// The palette's "Clipboard" rows: only while clipboard history is on, only for a typed
/// query, answered from memory (no I/O: image clips show their symbol, not a thumbnail).
final class ShelfClipboardPaletteProvider: PaletteResultProviding {
    private weak var controller: ShelfController?

    init(controller: ShelfController) {
        self.controller = controller
    }

    var id: String { ShelfPaletteRows.providerID }
    var title: String { String(localized: "Clipboard", table: "Shelf") }

    func results(for query: String) -> [PaletteProvidedResult] {
        guard let controller else { return [] }
        return ShelfPaletteRows.rows(controller: controller, query: query).map { row in
            PaletteProvidedResult(id: row.id, title: row.title, subtitle: row.subtitle, icon: .symbol(row.symbol),
                                  keywords: row.keywords,
                                  alternateAction: row.alternate.map { PaletteAlternateAction(title: row.alternateTitle, action: $0) },
                                  action: row.action)
        }
    }
}
