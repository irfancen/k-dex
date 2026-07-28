import Foundation

nonisolated struct HelmRevision: Identifiable, Sendable, Hashable {
    let revision: Int
    let status: String
    let date: Date?

    var id: Int { revision }
}

nonisolated struct HelmRelease: Identifiable, Sendable, Hashable {
    let name: String
    let namespace: String
    let revision: Int
    let status: String
    let chartName: String
    let chartVersion: String
    let appVersion: String
    let updated: Date?
    let notes: String
    let manifest: String
    let values: JSONValue
    let history: [HelmRevision]

    var id: String { "\(namespace)/\(name)" }

    var chart: String {
        if chartName.isEmpty { return "–" }
        return chartVersion.isEmpty ? chartName : "\(chartName)-\(chartVersion)"
    }

    /// Sortable stand-in for the optional `updated` date.
    var updatedTime: TimeInterval { updated?.timeIntervalSince1970 ?? 0 }

    var statusTone: StatusTone {
        switch status {
        case "deployed": return .ok
        case "failed": return .bad
        case "superseded", "uninstalled": return .neutral
        default: return .warn // pending-install, pending-upgrade, uninstalling…
        }
    }

    static func == (lhs: HelmRelease, rhs: HelmRelease) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.status == rhs.status
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(revision)
    }
}
