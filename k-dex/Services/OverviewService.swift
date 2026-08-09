import Foundation

nonisolated struct OverviewData: Sendable {
    struct Bucket: Sendable, Identifiable {
        let label: String
        let count: Int
        let tone: StatusTone
        var id: String { label }
    }

    struct KindSummary: Sendable, Identifiable {
        let kind: ResourceKind
        let total: Int
        let buckets: [Bucket]
        var id: String { kind.id }
    }

    struct Warning: Sendable, Identifiable {
        let reason: String
        let count: Int
        let lastSeen: Date?
        let message: String
        var id: String { reason }
    }

    struct Restart: Sendable, Identifiable {
        let namespace: String
        let podName: String
        let container: String
        let reason: String
        let exitCode: Int?
        let restarts: Int
        let lastAt: Date?
        var id: String { "\(namespace)/\(podName)/\(container)" }
    }

    struct HotPod: Sendable, Identifiable {
        let namespace: String
        let podName: String
        let cpuText: String
        let cpuFraction: Double?
        let memoryText: String
        let memoryFraction: Double?
        var id: String { "\(namespace)/\(podName)" }
    }

    let summaries: [KindSummary]
    let warnings: [Warning]
    let restarts: [Restart]
    let hotPods: [HotPod]
    let metricsStatus: MetricsStatus
}

/// Builds the workload overview: per-kind status buckets,
/// recent warning events, recent container restarts, and pods near their limits.
nonisolated enum OverviewService {
    static func load(context: String, namespace: String?) async throws -> OverviewData {
        // The pods fetch propagates failure: with every list wrapped in try?
        // the dashboard would render confident zeros when the cluster is
        // unreachable or credentials expired. Secondary lists stay soft so
        // partial RBAC still yields a dashboard.
        async let podsFetch = Kubectl.list(kind: .pods, context: context, namespace: namespace)
        async let deploymentsFetch = safeList(.deployments, context: context, namespace: namespace)
        async let statefulSetsFetch = safeList(.statefulSets, context: context, namespace: namespace)
        async let daemonSetsFetch = safeList(.daemonSets, context: context, namespace: namespace)
        async let replicaSetsFetch = safeList(.replicaSets, context: context, namespace: namespace)
        async let jobsFetch = safeList(.jobs, context: context, namespace: namespace)
        async let cronJobsFetch = safeList(.cronJobs, context: context, namespace: namespace)
        async let eventsFetch = safeList(.events, context: context, namespace: namespace)
        async let metricsFetch = Kubectl.podMetricsResult(context: context, namespace: namespace)

        let pods = try await podsFetch
        let (metrics, rawMetricsStatus) = await metricsFetch
        // Zero metrics rows for zero pods is not a metrics problem.
        let metricsStatus: MetricsStatus = rawMetricsStatus == .available && metrics.isEmpty && !pods.isEmpty
            ? .empty
            : rawMetricsStatus

        var summaries: [OverviewData.KindSummary] = []
        summaries.append(podSummary(pods))
        summaries.append(replicaSummary(.deployments, await deploymentsFetch, readyKey: "readyReplicas"))
        summaries.append(replicaSummary(.statefulSets, await statefulSetsFetch, readyKey: "readyReplicas"))
        summaries.append(daemonSetSummary(await daemonSetsFetch))
        summaries.append(replicaSummary(.replicaSets, await replicaSetsFetch, readyKey: "readyReplicas"))
        summaries.append(jobSummary(await jobsFetch))
        summaries.append(cronJobSummary(await cronJobsFetch))

        return OverviewData(
            summaries: summaries,
            warnings: warnings(from: await eventsFetch),
            restarts: restarts(from: pods),
            hotPods: hotPods(from: pods, metrics: metrics),
            metricsStatus: metricsStatus
        )
    }

    private static func safeList(_ kind: ResourceKind, context: String, namespace: String?) async -> [KubeObject] {
        (try? await Kubectl.list(kind: kind, context: context, namespace: namespace)) ?? []
    }

    // MARK: Summaries

    private static func buckets(from counts: [String: (count: Int, tone: StatusTone)]) -> [OverviewData.Bucket] {
        counts
            .map { OverviewData.Bucket(label: $0.key, count: $0.value.count, tone: $0.value.tone) }
            .sorted { lhs, rhs in
                if lhs.tone.sortRank != rhs.tone.sortRank { return lhs.tone.sortRank < rhs.tone.sortRank }
                return lhs.count > rhs.count
            }
    }

    private static func podSummary(_ pods: [KubeObject]) -> OverviewData.KindSummary {
        var counts: [String: (count: Int, tone: StatusTone)] = [:]
        for pod in pods {
            let (label, tone) = KindHelpers.podStatus(pod)
            counts[label, default: (0, tone)].count += 1
        }
        return OverviewData.KindSummary(kind: .pods, total: pods.count, buckets: buckets(from: counts))
    }

    private static func replicaSummary(_ kind: ResourceKind, _ objects: [KubeObject], readyKey: String) -> OverviewData.KindSummary {
        var counts: [String: (count: Int, tone: StatusTone)] = [:]
        for object in objects {
            let desired = object.raw["spec"]["replicas"].int ?? 0
            let ready = object.raw["status"][readyKey].int ?? 0
            if desired == 0 {
                counts["Idle", default: (0, .neutral)].count += 1
            } else if ready >= desired {
                counts["Running", default: (0, .ok)].count += 1
            } else {
                counts["Unavailable", default: (0, .bad)].count += 1
            }
        }
        return OverviewData.KindSummary(kind: kind, total: objects.count, buckets: buckets(from: counts))
    }

    private static func daemonSetSummary(_ objects: [KubeObject]) -> OverviewData.KindSummary {
        var counts: [String: (count: Int, tone: StatusTone)] = [:]
        for object in objects {
            let desired = object.raw["status"]["desiredNumberScheduled"].int ?? 0
            let ready = object.raw["status"]["numberReady"].int ?? 0
            if desired == 0 {
                counts["Idle", default: (0, .neutral)].count += 1
            } else if ready >= desired {
                counts["Running", default: (0, .ok)].count += 1
            } else {
                counts["Unavailable", default: (0, .bad)].count += 1
            }
        }
        return OverviewData.KindSummary(kind: .daemonSets, total: objects.count, buckets: buckets(from: counts))
    }

    private static func jobSummary(_ objects: [KubeObject]) -> OverviewData.KindSummary {
        var counts: [String: (count: Int, tone: StatusTone)] = [:]
        for object in objects {
            let (label, tone) = KindHelpers.jobStatus(object)
            counts[label, default: (0, tone)].count += 1
        }
        return OverviewData.KindSummary(kind: .jobs, total: objects.count, buckets: buckets(from: counts))
    }

    private static func cronJobSummary(_ objects: [KubeObject]) -> OverviewData.KindSummary {
        var counts: [String: (count: Int, tone: StatusTone)] = [:]
        for object in objects {
            if object.raw["spec"]["suspend"].bool == true {
                counts["Suspended", default: (0, .neutral)].count += 1
            } else {
                counts["Scheduled", default: (0, .ok)].count += 1
            }
        }
        return OverviewData.KindSummary(kind: .cronJobs, total: objects.count, buckets: buckets(from: counts))
    }

    // MARK: Warnings, restarts, hot pods

    private static func warnings(from events: [KubeObject]) -> [OverviewData.Warning] {
        var grouped: [String: (count: Int, lastSeen: Date?, message: String)] = [:]
        for event in events where event.raw["type"].stringValue == "Warning" {
            let reason = event.raw["reason"].stringValue
            guard !reason.isEmpty else { continue }
            let occurrences = max(event.raw["count"].int ?? 1, 1)
            let seen = ResourceKind.events.ageDate(event)
            var entry = grouped[reason] ?? (0, nil, "")
            entry.count += occurrences
            if let seen, entry.lastSeen.map({ seen > $0 }) ?? true {
                entry.lastSeen = seen
                entry.message = event.raw["message"].stringValue
            }
            grouped[reason] = entry
        }
        return grouped
            .map { OverviewData.Warning(reason: $0.key, count: $0.value.count, lastSeen: $0.value.lastSeen, message: $0.value.message) }
            .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            .prefix(6)
            .map { $0 }
    }

    private static func restarts(from pods: [KubeObject]) -> [OverviewData.Restart] {
        var restarts: [OverviewData.Restart] = []
        for pod in pods {
            for status in pod.raw["status"]["containerStatuses"].array {
                let count = status["restartCount"].int ?? 0
                guard count > 0 else { continue }
                let terminated = status["lastState"]["terminated"]
                restarts.append(OverviewData.Restart(
                    namespace: pod.namespace,
                    podName: pod.name,
                    container: status["name"].stringValue,
                    reason: terminated["reason"].string ?? "Restarted",
                    exitCode: terminated["exitCode"].int,
                    restarts: count,
                    lastAt: Fmt.parseDate(terminated["finishedAt"].string)
                ))
            }
        }
        return restarts
            .sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }
            .prefix(6)
            .map { $0 }
    }

    private static func hotPods(from pods: [KubeObject], metrics: [String: PodMetric]) -> [OverviewData.HotPod] {
        var hot: [OverviewData.HotPod] = []
        for pod in pods {
            let key = "\(pod.namespace)/\(pod.name)"
            guard let metric = metrics[key] else { continue }
            let containers = pod.raw["spec"]["containers"].array
            let cpuLimit = KindHelpers.summedRawResource(containers, section: "limits", resource: "cpu")
            let memLimit = KindHelpers.summedRawResource(containers, section: "limits", resource: "memory")
            let cpuUsage = Quantity.cpuMillicores(metric.cpu)
            let memUsage = Quantity.memoryBytes(metric.memory)
            let cpuFraction = fraction(cpuUsage, cpuLimit)
            let memFraction = fraction(memUsage, memLimit)
            let worst = max(cpuFraction ?? 0, memFraction ?? 0)
            guard worst >= 0.9 else { continue }
            hot.append(OverviewData.HotPod(
                namespace: pod.namespace,
                podName: pod.name,
                cpuText: KindHelpers.usageWithLimit(
                    usage: metric.cpu,
                    limit: cpuLimit.map { Quantity.formatCPU(millicores: $0) }
                ),
                cpuFraction: cpuFraction,
                memoryText: KindHelpers.usageWithLimit(
                    usage: metric.memory,
                    limit: memLimit.map { Quantity.formatMemory(bytes: $0) }
                ),
                memoryFraction: memFraction
            ))
        }
        return hot
            .sorted { max($0.cpuFraction ?? 0, $0.memoryFraction ?? 0) > max($1.cpuFraction ?? 0, $1.memoryFraction ?? 0) }
            .prefix(8)
            .map { $0 }
    }

    private static func fraction(_ usage: Double?, _ limit: Double?) -> Double? {
        guard let usage, let limit, limit > 0 else { return nil }
        return usage / limit
    }
}

nonisolated extension StatusTone {
    /// Ordering for overview legends: healthy first, then problems, then neutral.
    var sortRank: Int {
        switch self {
        case .ok: return 0
        case .warn: return 1
        case .bad: return 2
        case .neutral: return 3
        }
    }
}
