import Foundation

/// All interaction with clusters goes through the user's kubectl, so every
/// auth mechanism their kubeconfig supports (EKS/GKE/AKS/OIDC exec plugins,
/// client certs, tokens) works without this app knowing about it.
nonisolated enum Kubectl {
    static var isAvailable: Bool {
        ProcessRunner.resolveExecutable("kubectl") != nil
    }

    // MARK: Contexts & namespaces

    static func contexts() async throws -> (current: String?, contexts: [KubeContext]) {
        let result = try await Commands.runner.runChecked("kubectl", ["config", "view", "-o", "json"])
        let root = try KubeJSON.decode(result.stdout)
        let contexts = root["contexts"].array.map { entry in
            KubeContext(
                name: entry["name"].stringValue,
                cluster: entry["context"]["cluster"].stringValue,
                user: entry["context"]["user"].stringValue,
                defaultNamespace: entry["context"]["namespace"].string
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let current = root["current-context"].string
        return (current?.isEmpty == true ? nil : current, contexts)
    }

    static func namespaces(context: String) async throws -> [String] {
        let objects = try await list(kind: .namespaces, context: context, namespace: nil)
        return objects.map(\.name)
    }

    // MARK: Resource listing

    private static func scopeArguments(kind: ResourceKind, namespace: String?) -> [String] {
        guard kind.isNamespaced else { return [] }
        if let namespace { return ["-n", namespace] }
        return ["--all-namespaces"]
    }

    static func list(kind: ResourceKind, context: String, namespace: String?) async throws -> [KubeObject] {
        var args = ["get", kind.cliName, "-o", "json", "--context", context]
        args += scopeArguments(kind: kind, namespace: namespace)
        let result = try await Commands.runner.runChecked("kubectl", args)
        let data = result.stdout
        return try await Task.detached(priority: .userInitiated) {
            try KubeJSON.objects(fromListData: data)
        }.value
    }

    /// Pods matching a label selector (e.g. a workload's spec.selector.matchLabels)
    /// or a field selector (e.g. spec.nodeName=<node> for pods on a node).
    static func pods(matching selector: String, isFieldSelector: Bool = false, namespace: String?, context: String) async throws -> [KubeObject] {
        var args = ["get", "pods", isFieldSelector ? "--field-selector" : "-l", selector, "-o", "json", "--context", context]
        if let namespace, !namespace.isEmpty { args += ["-n", namespace] } else { args += ["--all-namespaces"] }
        let result = try await Commands.runner.runChecked("kubectl", args)
        let data = result.stdout
        return try await Task.detached(priority: .userInitiated) {
            try KubeJSON.objects(fromListData: data)
        }.value
    }

    // MARK: API discovery

    /// Every resource kind the cluster serves — built-in, aggregated, and
    /// CRD-backed — via the API discovery endpoints. Kinds must support
    /// `list`; subresources are excluded. The curated seed is merged back in
    /// so a partially failed discovery never shrinks the catalog below it.
    static func discoverKinds(context: String) async throws -> [ResourceKind] {
        async let crdFetch = customResourceIDs(context: context)
        let groupsResult = try await Commands.runner.runChecked("kubectl", ["get", "--raw", "/apis", "--context", context])
        let groups = try KubeJSON.decode(groupsResult.stdout)["groups"].array.compactMap { group -> (String, String)? in
            let name = group["name"].stringValue
            let version = group["preferredVersion"]["version"].stringValue
            guard !name.isEmpty, !version.isEmpty else { return nil }
            return (name, version)
        }
        let crds = await crdFetch

        var kinds = (try? await resourceList(group: "", version: "v1", crds: crds, context: context)) ?? []
        // Bounded fan-out: one kubectl per API group, but GUI apps get a soft
        // 256-fd limit and each subprocess costs four descriptors — a big
        // cluster has 40+ groups, so cap what runs at once.
        await withTaskGroup(of: [ResourceKind].self) { taskGroup in
            var pending = groups.makeIterator()
            func addNext() {
                guard let (name, version) = pending.next() else { return }
                taskGroup.addTask {
                    (try? await resourceList(group: name, version: version, crds: crds, context: context)) ?? []
                }
            }
            for _ in 0..<6 { addNext() }
            for await batch in taskGroup {
                kinds += batch
                addNext()
            }
        }

        var byID = Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for builtin in ResourceKind.builtins where byID[builtin.id] == nil {
            byID[builtin.id] = builtin
        }
        // Curated kinds keep their hand-picked order; the rest sort by name.
        let builtinOrder = Dictionary(uniqueKeysWithValues: ResourceKind.builtins.enumerated().map { ($1.id, $0) })
        return byID.values.sorted { lhs, rhs in
            let l = builtinOrder[lhs.id] ?? Int.max
            let r = builtinOrder[rhs.id] ?? Int.max
            if l != r { return l < r }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// One API group-version's listable resource kinds.
    private static func resourceList(group: String, version: String, crds: Set<String>, context: String) async throws -> [ResourceKind] {
        let path = group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)"
        let result = try await Commands.runner.runChecked("kubectl", ["get", "--raw", path, "--context", context])
        let root = try KubeJSON.decode(result.stdout)
        return root["resources"].array.compactMap { resource in
            let plural = resource["name"].stringValue
            let kindName = resource["kind"].stringValue
            guard !plural.isEmpty, !kindName.isEmpty, !plural.contains("/"),
                  resource["verbs"].array.contains(where: { $0.stringValue == "list" }) else { return nil }
            var kind = ResourceKind(
                group: group,
                version: version,
                plural: plural,
                kindName: kindName,
                isNamespaced: resource["namespaced"].bool ?? true
            )
            kind.isCustom = crds.contains(kind.id)
            return kind
        }
    }

    /// ids ("plural.group") of CRD-backed kinds, for catalog marking.
    private static func customResourceIDs(context: String) async -> Set<String> {
        guard let result = try? await Commands.runner.runChecked("kubectl", ["get", "crds", "-o", "name", "--context", context]) else {
            return []
        }
        return Set(result.stdoutString.split(separator: "\n").compactMap { line in
            line.split(separator: "/").last.map(String.init)
        })
    }

    /// Full CRD definition (schema included) for one custom kind, whose id
    /// ("plural.group") is exactly the CRD object's name.
    static func crdDefinition(id: String, context: String) async throws -> JSONValue {
        let result = try await Commands.runner.runChecked("kubectl", ["get", "crd", id, "-o", "json", "--context", context])
        return try KubeJSON.decode(result.stdout)
    }

    static func fetchYAML(kind: ResourceKind, name: String, namespace: String?, context: String) async throws -> String {
        var args = ["get", kind.cliName, name, "-o", "yaml", "--context", context]
        if kind.isNamespaced, let namespace { args += ["-n", namespace] }
        let result = try await Commands.runner.runChecked("kubectl", args)
        return result.stdoutString
    }

    /// Events that reference a specific object, newest first.
    static func events(forName name: String, kindName: String, namespace: String?, context: String) async throws -> [KubeObject] {
        var args = [
            "get", "events",
            "--field-selector", "involvedObject.name=\(name),involvedObject.kind=\(kindName)",
            "-o", "json", "--context", context,
        ]
        if let namespace, !namespace.isEmpty { args += ["-n", namespace] } else { args += ["--all-namespaces"] }
        let result = try await Commands.runner.runChecked("kubectl", args)
        let data = result.stdout
        let objects = try await Task.detached(priority: .userInitiated) {
            try KubeJSON.objects(fromListData: data)
        }.value
        return objects.sorted { (ResourceKind.events.ageDate($0) ?? .distantPast) > (ResourceKind.events.ageDate($1) ?? .distantPast) }
    }

    // MARK: Actions

    /// One kubectl call for any number of same-namespace objects: batch
    /// actions must not fan out one subprocess per object (finding 11's
    /// 256-fd GUI ceiling, ~4 fds per spawn — a 60-row selection would burn
    /// ~240 at once).
    static func delete(kind: ResourceKind, names: [String], namespace: String?, context: String) async throws {
        guard !names.isEmpty else { return }
        var args = ["delete", kind.cliName] + names + ["--context", context]
        if kind.isNamespaced, let namespace { args += ["-n", namespace] }
        try await Commands.runner.runChecked("kubectl", args)
    }

    static func delete(kind: ResourceKind, name: String, namespace: String?, context: String) async throws {
        try await delete(kind: kind, names: [name], namespace: namespace, context: context)
    }

    static func rolloutRestart(kind: ResourceKind, names: [String], namespace: String?, context: String) async throws {
        guard !names.isEmpty else { return }
        var args = ["rollout", "restart"] + names.map { "\(kind.cliName)/\($0)" } + ["--context", context]
        if let namespace { args += ["-n", namespace] }
        try await Commands.runner.runChecked("kubectl", args)
    }

    static func rolloutRestart(kind: ResourceKind, name: String, namespace: String?, context: String) async throws {
        try await rolloutRestart(kind: kind, names: [name], namespace: namespace, context: context)
    }

    static func scale(kind: ResourceKind, name: String, namespace: String?, replicas: Int, context: String) async throws {
        var args = ["scale", "\(kind.cliName)/\(name)", "--replicas", String(replicas), "--context", context]
        if let namespace { args += ["-n", namespace] }
        try await Commands.runner.runChecked("kubectl", args)
    }

    /// Applies an edited manifest; returns kubectl's confirmation output.
    static func apply(yaml: String, context: String) async throws -> String {
        let result = try await Commands.runner.runChecked(
            "kubectl",
            ["apply", "-f", "-", "--context", context],
            stdin: Data(yaml.utf8)
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Metrics (requires metrics-server in the cluster)

    // `kubectl get --raw` hits the metrics API directly, returning real JSON —
    // unlike `kubectl top`, whose human-formatted table would need scraping.

    /// Turns a failed metrics call into the reason the UI should show. The
    /// aggregated API reports its absence, a denial, and an unready backend
    /// with three distinct server errors, and telling them apart is the
    /// difference between "install metrics-server" and "ask for RBAC".
    static func metricsStatus(for error: any Error) -> MetricsStatus {
        guard let processError = error as? ProcessError,
              case .failed(_, _, let stderr) = processError else {
            return .failed(error.localizedDescription)
        }
        let text = stderr.lowercased()
        if text.contains("could not find the requested resource") || text.contains("(notfound)") {
            return .notInstalled
        }
        if text.contains("(serviceunavailable)") || text.contains("currently unable to handle the request") {
            return .unavailable
        }
        if text.contains("(forbidden)") || text.contains("(unauthorized)") || text.contains("cannot list resource") {
            return .forbidden
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "kubectl exited with an error" : trimmed)
    }

    /// Pod metrics plus, on failure, why they're missing. Callers rendering
    /// usage need the reason; a bare `try?` here is what made a missing
    /// metrics-server indistinguishable from an idle cluster.
    static func podMetricsResult(
        context: String,
        namespace: String?
    ) async -> (metrics: [String: PodMetric], status: MetricsStatus) {
        do {
            return (try await podMetrics(context: context, namespace: namespace), .available)
        } catch {
            return ([:], metricsStatus(for: error))
        }
    }

    /// Node usage plus the reason it's missing. See `podMetricsResult`.
    static func nodeMetricsResult(context: String) async -> (usage: [String: RawUsage], status: MetricsStatus) {
        do {
            return (try await nodeMetrics(context: context), .available)
        } catch {
            return ([:], metricsStatus(for: error))
        }
    }

    static func podMetrics(context: String, namespace: String?) async throws -> [String: PodMetric] {
        let path = namespace.map { "/apis/metrics.k8s.io/v1beta1/namespaces/\($0)/pods" }
            ?? "/apis/metrics.k8s.io/v1beta1/pods"
        let result = try await Commands.runner.runChecked("kubectl", ["get", "--raw", path, "--context", context])
        let root = try KubeJSON.decode(result.stdout)
        var metrics: [String: PodMetric] = [:]
        for item in root["items"].array {
            let metadata = item["metadata"]
            var cpu = 0.0
            var memory = 0.0
            for container in item["containers"].array {
                cpu += Quantity.cpuMillicores(container["usage"]["cpu"].stringValue) ?? 0
                memory += Quantity.memoryBytes(container["usage"]["memory"].stringValue) ?? 0
            }
            metrics["\(metadata["namespace"].stringValue)/\(metadata["name"].stringValue)"] = PodMetric(
                cpu: Quantity.formatCPU(millicores: cpu),
                memory: Quantity.formatMemory(bytes: memory)
            )
        }
        return metrics
    }

    /// Node usage; percent-of-allocatable is computed by the caller, which has
    /// the node objects (the metrics API doesn't include capacity).
    static func nodeMetrics(context: String) async throws -> [String: RawUsage] {
        let result = try await Commands.runner.runChecked(
            "kubectl",
            ["get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes", "--context", context]
        )
        let root = try KubeJSON.decode(result.stdout)
        var usage: [String: RawUsage] = [:]
        for item in root["items"].array {
            usage[item["metadata"]["name"].stringValue] = RawUsage(
                cpuMillis: Quantity.cpuMillicores(item["usage"]["cpu"].stringValue) ?? 0,
                memoryBytes: Quantity.memoryBytes(item["usage"]["memory"].stringValue) ?? 0
            )
        }
        return usage
    }
}
