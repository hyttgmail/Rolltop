import Foundation

/// A video meeting link found in an event's URL, location or notes.
nonisolated struct ShelfMeetingLink: Sendable, Equatable {
    enum Service: String, Sendable, CaseIterable {
        case zoom
        case meet
        case teams
        case webex
        case faceTime = "facetime"

        var displayName: String {
            switch self {
            case .zoom: "Zoom"
            case .meet: "Google Meet"
            case .teams: "Microsoft Teams"
            case .webex: "Webex"
            case .faceTime: "FaceTime"
            }
        }
    }

    var service: Service
    var url: URL
}

/// Finds the first recognisable meeting link. Pure, testable.
nonisolated enum ShelfMeetingLinks {
    /// Looks through the fields in order (event URL, location, notes) and returns the first
    /// link that belongs to a known meeting service.
    static func detect(in fields: [String?]) -> ShelfMeetingLink? {
        for field in fields {
            guard let field, !field.isEmpty else { continue }
            for candidate in urls(in: field) {
                if let link = classify(candidate) { return link }
            }
        }
        return nil
    }

    /// `https://…` and `zoommtg://…` substrings, trailing punctuation trimmed.
    static func urls(in text: String) -> [String] {
        let pattern = #"(?i)\b(?:https?|zoommtg|msteams)://[^\s<>"'()\[\]{}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?>")) }
        }
    }

    static func classify(_ raw: String) -> ShelfMeetingLink? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "zoommtg" { return ShelfMeetingLink(service: .zoom, url: url) }
        if scheme == "msteams" { return ShelfMeetingLink(service: .teams, url: url) }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if isHost("zoom.us") || isHost("zoom.com") || isHost("zoomgov.com") {
            // Meeting, personal room and webinar links; not the marketing site.
            if path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/") || path.hasPrefix("/s/") || path.hasPrefix("/wc/") {
                return ShelfMeetingLink(service: .zoom, url: url)
            }
            return nil
        }
        if host == "meet.google.com" {
            // Meeting codes look like abc-defg-hij; also /lookup/… links.
            let code = path.dropFirst()
            if code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil || code.hasPrefix("lookup/") {
                return ShelfMeetingLink(service: .meet, url: url)
            }
            return nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.microsoft.us" {
            if path.contains("/meetup-join/") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet") {
                return ShelfMeetingLink(service: .teams, url: url)
            }
            return nil
        }
        if isHost("webex.com") {
            if path.contains("/meet/") || path.contains("j.php") || path.contains("/join/") || path.hasPrefix("/wbxmjs/joinservice") {
                return ShelfMeetingLink(service: .webex, url: url)
            }
            return nil
        }
        if host == "facetime.apple.com", path.hasPrefix("/join") {
            return ShelfMeetingLink(service: .faceTime, url: url)
        }
        return nil
    }
}
