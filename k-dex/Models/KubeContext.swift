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
/// (relative comparison → neutral color).
nonisolated struct UsageValue: Sendable {
    let fraction: Double
    let bounded: Bool
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
    var now: Date = Date()
}
