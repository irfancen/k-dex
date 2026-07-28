import Foundation

/// Shared status/derivation helpers used by column extractors and detail views.
nonisolated enum KindHelpers {
    /// Ready/total counts matching kubectl's printer: native sidecars (init
    /// containers with restartPolicy: Always, k8s 1.29+) count toward READY.
    static func podReadyCounts(_ obj: KubeObject) -> (ready: Int, total: Int) {
        let statuses = obj.raw["status"]["containerStatuses"].array
        var ready = statuses.filter { $0["ready"].bool == true }.count
        var total = max(obj.raw["spec"]["containers"].array.count, statuses.count)

        let sidecarNames = Set(
            obj.raw["spec"]["initContainers"].array
                .filter { $0["restartPolicy"].stringValue == "Always" }
                .map { $0["name"].stringValue }
        )
        if !sidecarNames.isEmpty {
            total += sidecarNames.count
            ready += obj.raw["status"]["initContainerStatuses"].array
                .filter { sidecarNames.contains($0["name"].stringValue) && $0["ready"].bool == true }
                .count
        }
        return (ready, total)
    }

    static func podReady(_ obj: KubeObject) -> String {
        let counts = podReadyCounts(obj)
        return "\(counts.ready)/\(counts.total)"
    }

    /// Most recent container restart time (lastState.terminated.finishedAt).
    static func podLastRestart(_ obj: KubeObject) -> Date? {
        var latest: Date?
        for status in obj.raw["status"]["containerStatuses"].array {
            if let date = Fmt.parseDate(status["lastState"]["terminated"]["finishedAt"].string),
               latest.map({ date > $0 }) ?? true {
                latest = date
            }
        }
        return latest
    }

    static func podReadyTone(_ obj: KubeObject) -> StatusTone {
        let phase = obj.raw["status"]["phase"].stringValue
        if phase == "Succeeded" { return .neutral }
        let counts = podReadyCounts(obj)
        if counts.total == 0 { return .neutral }
        if counts.ready >= counts.total { return .ok }
        return counts.ready == 0 ? .bad : .warn
    }

    private static let badPodReasons: Set<String> = [
        "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName",
        "CreateContainerConfigError", "CreateContainerError", "RunContainerError", "OOMKilled", "Error",
    ]

    static func podStatus(_ obj: KubeObject) -> (String, StatusTone) {
        let status = obj.raw["status"]
        if obj.isTerminating { return ("Terminating", .warn) }
        if let reason = status["reason"].string, !reason.isEmpty {
            return (reason, reason == "Evicted" ? .bad : .warn)
        }
        let badReasons = Self.badPodReasons
        var transientReason: String?
        for cs in status["containerStatuses"].array + status["initContainerStatuses"].array {
            if let reason = cs["state"]["waiting"]["reason"].string {
                if badReasons.contains(reason) { return (reason, .bad) }
                transientReason = reason
            }
            if let reason = cs["state"]["terminated"]["reason"].string, badReasons.contains(reason) {
                return (reason, .bad)
            }
        }
        let phase = status["phase"].stringValue
        switch phase {
        case "Running":
            let statuses = status["containerStatuses"].array
            let allReady = !statuses.isEmpty && statuses.allSatisfy { $0["ready"].bool == true }
            return ("Running", allReady ? .ok : .warn)
        case "Succeeded":
            return ("Completed", .neutral)
        case "Pending":
            return (transientReason ?? "Pending", .warn)
        case "Failed":
            return ("Failed", .bad)
        default:
            return (phase, .neutral)
        }
    }

    static func replicaTone(_ obj: KubeObject, readyKey: String) -> StatusTone {
        let desired = obj.raw["spec"]["replicas"].int ?? 0
        let ready = obj.raw["status"][readyKey].int ?? 0
        if desired == 0 { return .neutral }
        if ready >= desired { return .ok }
        return ready == 0 ? .bad : .warn
    }

    static func jobStatus(_ obj: KubeObject) -> (String, StatusTone) {
        for condition in obj.raw["status"]["conditions"].array where condition["status"].stringValue == "True" {
            switch condition["type"].stringValue {
            case "Complete": return ("Complete", .ok)
            case "Failed": return ("Failed", .bad)
            case "Suspended": return ("Suspended", .neutral)
            default: break
            }
        }
        if (obj.raw["status"]["active"].int ?? 0) > 0 { return ("Running", .neutral) }
        return ("Pending", .warn)
    }

    static func nodeStatus(_ obj: KubeObject) -> (String, StatusTone) {
        var ready = false
        for condition in obj.raw["status"]["conditions"].array where condition["type"].stringValue == "Ready" {
            ready = condition["status"].stringValue == "True"
        }
        let cordoned = obj.raw["spec"]["unschedulable"].bool == true
        var text = ready ? "Ready" : "NotReady"
        if cordoned { text += ",Cordoned" }
        return (text, ready ? (cordoned ? .warn : .ok) : .bad)
    }

    static func nodeRoles(_ obj: KubeObject) -> String {
        let roles = obj.labels.keys
            .filter { $0.hasPrefix("node-role.kubernetes.io/") }
            .map { String($0.dropFirst("node-role.kubernetes.io/".count)) }
            .sorted()
        return roles.isEmpty ? "worker" : roles.joined(separator: ", ")
    }

    static func servicePorts(_ obj: KubeObject) -> String {
        obj.raw["spec"]["ports"].array.map { port in
            var text = "\(port["port"].displayString)/\(port["protocol"].stringValue)"
            if let nodePort = port["nodePort"].int { text = "\(port["port"].displayString):\(nodePort)/\(port["protocol"].stringValue)" }
            return text
        }.joined(separator: ", ")
    }

    static func serviceExternalIP(_ obj: KubeObject) -> String {
        let lb = obj.raw["status"]["loadBalancer"]["ingress"].array
            .map { $0["ip"].string ?? $0["hostname"].stringValue }
            .filter { !$0.isEmpty }
        if !lb.isEmpty { return lb.joined(separator: ", ") }
        let external = obj.raw["spec"]["externalIPs"].array.map(\.displayString)
        if !external.isEmpty { return external.joined(separator: ", ") }
        switch obj.raw["spec"]["type"].stringValue {
        case "ExternalName": return obj.raw["spec"]["externalName"].stringValue
        case "LoadBalancer": return "<pending>"
        default: return ""
        }
    }

    static func pvcTone(_ obj: KubeObject) -> StatusTone {
        if obj.isTerminating { return .warn }
        switch obj.raw["status"]["phase"].stringValue {
        case "Bound": return .ok
        case "Pending": return .warn
        case "Lost": return .bad
        default: return .neutral
        }
    }

    static func pvTone(_ obj: KubeObject) -> StatusTone {
        switch obj.raw["status"]["phase"].stringValue {
        case "Bound": return .ok
        case "Available": return .neutral
        case "Released": return .warn
        case "Failed": return .bad
        default: return .neutral
        }
    }

    /// "app=web,tier=frontend" from a workload's matchLabels, for `kubectl get pods -l`.
    static func podSelectorString(_ obj: KubeObject) -> String? {
        let matchLabels = obj.raw["spec"]["selector"]["matchLabels"].stringDictionary
        guard !matchLabels.isEmpty else { return nil }
        return matchLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    /// Raw sum of one resource (cpu → millicores, memory → bytes) across containers.
    static func summedRawResource(_ containers: [JSONValue], section: String, resource: String) -> Double? {
        var total = 0.0
        var found = false
        for container in containers {
            let raw = container["resources"][section][resource].stringValue
            guard !raw.isEmpty else { continue }
            let value = resource == "cpu" ? Quantity.cpuMillicores(raw) : Quantity.memoryBytes(raw)
            if let value {
                total += value
                found = true
            }
        }
        return found ? total : nil
    }

    /// Sums one resource (cpu/memory) across containers for a requests/limits section.
    static func summedResource(_ containers: [JSONValue], section: String, resource: String) -> String? {
        summedRawResource(containers, section: section, resource: resource).map {
            resource == "cpu" ? Quantity.formatCPU(millicores: $0) : Quantity.formatMemory(bytes: $0)
        }
    }

    /// Usage bar for one pod: vs limit, else vs request, else relative to the
    /// biggest consumer in the list (so every row gets a bar).
    static func podUsage(_ obj: KubeObject, _ ctx: RowContext, resource: String) -> UsageValue? {
        guard let metric = ctx.podMetrics["\(obj.namespace)/\(obj.name)"] else { return nil }
        let usageRaw = resource == "cpu" ? metric.cpu : metric.memory
        guard let usage = resource == "cpu" ? Quantity.cpuMillicores(usageRaw) : Quantity.memoryBytes(usageRaw) else {
            return nil
        }
        let containers = obj.raw["spec"]["containers"].array
        if let limit = summedRawResource(containers, section: "limits", resource: resource), limit > 0 {
            return UsageValue(fraction: usage / limit, bounded: true)
        }
        if let request = summedRawResource(containers, section: "requests", resource: resource), request > 0 {
            return UsageValue(fraction: usage / request, bounded: true)
        }
        let peak = resource == "cpu" ? ctx.maxPodCPUMillis : ctx.maxPodMemoryBytes
        guard peak > 0 else { return nil }
        return UsageValue(fraction: usage / peak, bounded: false)
    }

    /// Usage bar for a workload: summed pod usage vs (per-pod limit × pod count),
    /// falling back to requests, then relative to the biggest workload.
    static func workloadUsageValue(_ obj: KubeObject, _ ctx: RowContext, resource: String) -> UsageValue? {
        guard let usage = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"], usage.hasMetrics else { return nil }
        let value = resource == "cpu" ? usage.cpuMillis : usage.memoryBytes
        let containers = obj.raw["spec"]["template"]["spec"]["containers"].array
        if usage.podCount > 0 {
            if let perPod = summedRawResource(containers, section: "limits", resource: resource), perPod > 0 {
                return UsageValue(fraction: value / (perPod * Double(usage.podCount)), bounded: true)
            }
            if let perPod = summedRawResource(containers, section: "requests", resource: resource), perPod > 0 {
                return UsageValue(fraction: value / (perPod * Double(usage.podCount)), bounded: true)
            }
        }
        let peak = resource == "cpu" ? ctx.maxWorkloadCPUMillis : ctx.maxWorkloadMemoryBytes
        guard peak > 0 else { return nil }
        return UsageValue(fraction: value / peak, bounded: false)
    }

    /// "usage / total-limit" for a workload; falls back to template request/limit
    /// text when live metrics aren't available.
    static func workloadUsageText(_ obj: KubeObject, _ ctx: RowContext, resource: String) -> String {
        guard let usage = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"], usage.hasMetrics else {
            return templateResources(obj, resource: resource)
        }
        let value = resource == "cpu" ? usage.cpuMillis : usage.memoryBytes
        let usageText = resource == "cpu" ? Quantity.formatCPU(millicores: value) : Quantity.formatMemory(bytes: value)
        let containers = obj.raw["spec"]["template"]["spec"]["containers"].array
        var limitText: String?
        if usage.podCount > 0,
           let perPod = summedRawResource(containers, section: "limits", resource: resource) {
            let total = perPod * Double(usage.podCount)
            limitText = resource == "cpu" ? Quantity.formatCPU(millicores: total) : Quantity.formatMemory(bytes: total)
        }
        return usageWithLimit(usage: usageText, limit: limitText)
    }

    /// "45%" → 0.45
    static func percentFraction(_ text: String) -> Double? {
        Double(text.hasSuffix("%") ? String(text.dropLast()) : text).map { $0 / 100 }
    }

    /// "12m / 500m" style cell combining live usage with the spec'd limit.
    static func usageWithLimit(usage: String?, limit: String?) -> String {
        switch (usage, limit) {
        case (nil, nil): return "–"
        case (let usage?, nil): return usage
        case (nil, let limit?): return "– / \(limit)"
        case (let usage?, let limit?): return "\(usage) / \(limit)"
        }
    }

    /// "request / limit" summed over a workload's pod template containers.
    static func templateResources(_ obj: KubeObject, resource: String) -> String {
        let containers = obj.raw["spec"]["template"]["spec"]["containers"].array
        let request = summedResource(containers, section: "requests", resource: resource)
        let limit = summedResource(containers, section: "limits", resource: resource)
        if request == nil && limit == nil { return "–" }
        return "\(request ?? "–") / \(limit ?? "–")"
    }

    /// Approved/Denied/Pending for a CertificateSigningRequest.
    static func csrStatus(_ obj: KubeObject) -> (String, StatusTone) {
        var approved = false
        for condition in obj.raw["status"]["conditions"].array where condition["status"].stringValue != "False" {
            switch condition["type"].stringValue {
            case "Approved": approved = true
            case "Denied": return ("Denied", .bad)
            case "Failed": return ("Failed", .bad)
            default: break
            }
        }
        if approved {
            let issued = !obj.raw["status"]["certificate"].stringValue.isEmpty
            return (issued ? "Approved, Issued" : "Approved", .ok)
        }
        return ("Pending", .warn)
    }

    /// Best-effort status for an arbitrary custom resource: status.phase if
    /// present, else the standard Ready condition. Nil when the CR has neither.
    static func crdStatus(_ obj: KubeObject) -> (String, StatusTone)? {
        let phase = obj.raw["status"]["phase"].stringValue
        if !phase.isEmpty {
            let tone: StatusTone
            switch phase.lowercased() {
            case "running", "active", "ready", "bound", "succeeded", "healthy": tone = .ok
            case "pending", "progressing", "terminating": tone = .warn
            case "failed", "error", "degraded": tone = .bad
            default: tone = .neutral
            }
            return (phase, tone)
        }
        for condition in obj.raw["status"]["conditions"].array where condition["type"].stringValue == "Ready" {
            let ready = condition["status"].stringValue == "True"
            return (ready ? "Ready" : (condition["reason"].string ?? "NotReady"), ready ? .ok : .warn)
        }
        return nil
    }

    static func accessModes(_ value: JSONValue) -> String {
        let abbreviations = [
            "ReadWriteOnce": "RWO",
            "ReadOnlyMany": "ROX",
            "ReadWriteMany": "RWX",
            "ReadWriteOncePod": "RWOP",
        ]
        return value.array.map { abbreviations[$0.stringValue] ?? $0.stringValue }.joined(separator: ",")
    }
}
