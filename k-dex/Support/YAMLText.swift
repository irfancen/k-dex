import Foundation

nonisolated enum YAMLHighlighter {
    /// The key name when a line declares a zero-indentation mapping key.
    static func topLevelKey(of line: String) -> String? {
        guard let first = line.first, first != " ", first != "-", first != "#" else { return nil }
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex])
        guard !key.isEmpty, !key.contains("\""), !key.contains("#") else { return nil }
        return key
    }

}

nonisolated enum ManifestCleaner {
    /// Prepares fetched YAML for editing: strips the server-managed `status:`
    /// block and volatile metadata (resourceVersion, uid, generation,
    /// creationTimestamp) so `kubectl apply` doesn't hit stale-version
    /// conflicts or complain about server-populated fields.
    static func editable(_ yaml: String) -> String {
        var kept: [Substring] = []
        var topLevelKey: String?
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let key = YAMLHighlighter.topLevelKey(of: text) {
                topLevelKey = key
            } else if text.trimmingCharacters(in: .whitespaces) == "---" {
                topLevelKey = nil
            }
            if topLevelKey == "status" { continue }
            if topLevelKey == "metadata", text.hasPrefix("  "), !text.hasPrefix("   ") {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("resourceVersion:")
                    || trimmed.hasPrefix("uid:")
                    || trimmed.hasPrefix("generation:")
                    || trimmed.hasPrefix("creationTimestamp:") {
                    continue
                }
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}
