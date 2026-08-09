import Foundation

nonisolated struct KubeContext: Identifiable, Sendable, Hashable {
    let name: String
    let cluster: String
    let user: String
    let defaultNamespace: String?

    var id: String { name }
}

nonisolated struct PodMetric: Sendable {
    let cpu: String
    let memory: String
}

nonisolated struct NodeMetric: Sendable {
    let cpu: String
    let cpuPercent: String
    let memory: String
    let memoryPercent: String
}

/// Raw usage from the metrics API, before percent-of-allocatable is computed.
nonisolated struct RawUsage: Sendable {
    let cpuMillis: Double
    let memoryBytes: Double
}

/// Summed live usage of the pods belonging to one workload.
nonisolated struct WorkloadUsage: Sendable {
    let cpuMillis: Double
    let memoryBytes: Double
    let podCount: Int
    let hasMetrics: Bool
    let restarts: Int
    let lastRestart: Date?
}

/// A usage-bar value: how full the bar is and whether the denominator was a
/// real bound (limit/request → threshold colors) or just the column max
/// (relative comparison → neutral color). `marker`, when present, is the
/// spec'd request as a fraction of the same denominator — a tick on the bar
/// showing where usage crosses from within-request into burst headroom.
nonisolated struct UsageValue: Sendable {
    let fraction: Double
    let bounded: Bool
    var marker: Double? = nil
}

/// Why the metrics API produced no usage. Every one of these looks identical
/// to "an idle cluster" at the call site, so the reason is classified from
/// kubectl's stderr and carried into the UI instead of being swallowed:
/// installing metrics-server, granting `metrics.k8s.io`, and fixing a
/// metrics-server that can't reach the kubelets are three different jobs.
nonisolated enum MetricsStatus: Sendable, Equatable {
    /// Not fetched yet for the current selection.
    case unknown
    case available
    /// No `metrics.k8s.io` aggregated API — metrics-server isn't installed.
    /// The default on EKS and most self-hosted clusters.
    case notInstalled
    /// The aggregated API is registered but not serving.
    case unavailable
    /// The current credentials may not read `metrics.k8s.io`.
    case forbidden
    /// The API answered with zero rows for objects that do exist — usually
    /// metrics-server unable to scrape kubelets, or a cold start.
    case empty
    case failed(String)

    var hasData: Bool { self == .available }

    /// The cause and its fix, in one sentence, phrased for reuse in both the
    /// list banner and a cell tooltip. Nil when usage is fine, or not known
    /// yet — navigating shouldn't flash a warning before the first fetch lands.
    var reason: String? {
        switch self {
        case .unknown, .available:
            return nil
        case .notInstalled:
            return "This cluster has no metrics API — install metrics-server to see CPU and memory consumption."
        case .unavailable:
            return "The metrics API is registered but not serving — check that the metrics-server pods are ready."
        case .forbidden:
            return "Your credentials can't read metrics.k8s.io."
        case .empty:
            return "metrics-server returned nothing for these objects — it often can't reach the kubelets, which needs --kubelet-insecure-tls on self-hosted clusters."
        case .failed(let message):
            return "The metrics API call failed — \(message)"
        }
    }

    /// Banner sentence for a list whose usage columns can't be filled.
    var listHint: String? { reason.map { "No live usage. \($0)" } }

    /// Tooltip for one cell standing in for usage it couldn't get. Deliberately
    /// says nothing about *what* is shown instead — that differs by kind
    /// (workloads substitute requests/limits, Nodes just show "–").
    var cellDetail: String {
        switch self {
        case .available:
            return "No live usage reported for this object yet — metrics-server scrapes on an interval, so newly created pods take a few seconds to appear."
        case .unknown:
            return "Live usage hasn't loaded yet."
        default:
            return "Not live usage. " + (reason ?? "")
        }
    }
}

/// Extra per-row data available to table column extractors (metrics, current time).
nonisolated struct RowContext: Sendable {
    var podMetrics: [String: PodMetric] = [:]
    var nodeMetrics: [String: NodeMetric] = [:]
    var workloadUsage: [String: WorkloadUsage] = [:]
    var maxPodCPUMillis: Double = 0
    var maxPodMemoryBytes: Double = 0
    var maxWorkloadCPUMillis: Double = 0
    var maxWorkloadMemoryBytes: Double = 0
    /// Lets a usage cell explain, in place, why it is showing spec'd
    /// requests instead of consumption.
    var metricsStatus: MetricsStatus = .unknown
    var now: Date = Date()
}
