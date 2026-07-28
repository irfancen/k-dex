import Foundation

nonisolated enum Fmt {
    /// kubectl-style compact age: 45s, 12m, 5h, 3d, 2y.
    static func age(_ date: Date?, relativeTo now: Date = Date()) -> String {
        guard let date else { return "–" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 0 { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 365 { return "\(days)d" }
        return "\(days / 365)y"
    }

    /// Parses RFC3339 timestamps as produced by Kubernetes and Helm,
    /// tolerating fractional seconds and timezone offsets.
    static func parseDate(_ raw: String?) -> Date? {
        guard var text = raw, !text.isEmpty else { return nil }
        // Strip fractional seconds ("2024-05-05T10:00:00.123456789Z" → "...:00Z").
        if let dotIndex = text.firstIndex(of: ".") {
            var end = text.index(after: dotIndex)
            while end < text.endIndex, text[end].isNumber {
                end = text.index(after: end)
            }
            let fractionRanToEnd = end == text.endIndex
            text.removeSubrange(dotIndex..<end)
            if fractionRanToEnd, text.last != "Z" {
                text.append("Z")
            }
        }
        return try? Date(text, strategy: .iso8601)
    }

    static func mediumDate(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "5m32s" style duration between two dates (job durations).
    static func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "–" }
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m\(seconds % 60)s" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }
}
