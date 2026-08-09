import Foundation

/// Splits `[pod/web-abc/nginx] 2026-07-24T09:12:33.1Z message` into parts.
nonisolated enum LogLineParser {
    struct Parsed {
        var tag: String?
        var timestamp: String?
        var message: String
    }

    static func parse(_ raw: String) -> Parsed {
        var rest = Substring(raw)
        var tag: String?
        if rest.first == "[", let close = rest.firstIndex(of: "]") {
            tag = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            if rest.first == " " { rest = rest.dropFirst() }
        }
        var timestamp: String?
        if let space = rest.firstIndex(of: " ") {
            let candidate = rest[rest.startIndex..<space]
            if candidate.count >= 19, candidate.first?.isNumber == true,
               let tIndex = candidate.firstIndex(of: "T") {
                timestamp = String(candidate[candidate.index(after: tIndex)...].prefix(8))
                rest = rest[rest.index(after: space)...]
            }
        }
        return Parsed(tag: tag, timestamp: timestamp, message: String(rest))
    }

    /// "pod/web-7d4b9-abc12/nginx" → "web-7d4b9-abc12"
    static func podName(from tag: String) -> String {
        let parts = tag.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : tag
    }

    /// "web-7d4b9-abc12" → "abc12" (the replica-unique suffix).
    static func shortSuffix(_ podName: String) -> String {
        if let dash = podName.lastIndex(of: "-"), dash != podName.startIndex {
            let suffix = podName[podName.index(after: dash)...]
            if !suffix.isEmpty { return String(suffix) }
        }
        return String(podName.prefix(6))
    }

    static func stableHash(_ text: String) -> Int {
        var hash = 5381
        for scalar in text.unicodeScalars {
            hash = (hash << 5) &+ hash &+ Int(scalar.value)
        }
        return hash
    }
}
