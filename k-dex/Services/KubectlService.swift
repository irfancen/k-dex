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
        let result = try await ProcessRunner.runChecked("kubectl", ["config", "view", "-o", "json"])
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
        let result = try await ProcessRunner.runChecked("kubectl", args)
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
        let result = try await ProcessRunner.runChecked("kubectl", args)
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
        let groupsResult = try await ProcessRunner.runChecked("kubectl", ["get", "--raw", "/apis", "--context", context])
        let groups = try KubeJSON.decode(groupsResult.stdout)["groups"].array.compactMap { group -> (String, String)? in
            let name = group["name"].stringValue
            let version = group["preferredVersion"]["version"].stringValue
            guard !name.isEmpty, !version.isEmpty else { return nil }
            return (name, version)
        }
        let crds = await crdFetch

        var kinds = (try? await resourceList(group: "", version: "v1", crds: crds, context: context)) ?? []
        await withTaskGroup(of: [ResourceKind].self) { taskGroup in
            for (name, version) in groups {
                taskGroup.addTask {
                    (try? await resourceList(group: name, version: version, crds: crds, context: context)) ?? []
                }
            }
            for await batch in taskGroup { kinds += batch }
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
        let result = try await ProcessRunner.runChecked("kubectl", ["get", "--raw", path, "--context", context])
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
        guard let result = try? await ProcessRunner.runChecked("kubectl", ["get", "crds", "-o", "name", "--context", context]) else {
            return []
        }
        return Set(result.stdoutString.split(separator: "\n").compactMap { line in
            line.split(separator: "/").last.map(String.init)
        })
    }

    static func fetchYAML(kind: ResourceKind, name: String, namespace: String?, context: String) async throws -> String {
        var args = ["get", kind.cliName, name, "-o", "yaml", "--context", context]
        if kind.isNamespaced, let namespace { args += ["-n", namespace] }
        let result = try await ProcessRunner.runChecked("kubectl", args)
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
        let result = try await ProcessRunner.runChecked("kubectl", args)
        let data = result.stdout
        let objects = try await Task.detached(priority: .userInitiated) {
            try KubeJSON.objects(fromListData: data)
        }.value
        return objects.sorted { (ResourceKind.events.ageDate($0) ?? .distantPast) > (ResourceKind.events.ageDate($1) ?? .distantPast) }
    }

    // MARK: Actions

    static func delete(kind: ResourceKind, name: String, namespace: String?, context: String) async throws {
        var args = ["delete", kind.cliName, name, "--context", context]
        if kind.isNamespaced, let namespace { args += ["-n", namespace] }
        try await ProcessRunner.runChecked("kubectl", args)
    }

    static func rolloutRestart(kind: ResourceKind, name: String, namespace: String?, context: String) async throws {
        var args = ["rollout", "restart", "\(kind.cliName)/\(name)", "--context", context]
        if let namespace { args += ["-n", namespace] }
        try await ProcessRunner.runChecked("kubectl", args)
    }

    static func scale(kind: ResourceKind, name: String, namespace: String?, replicas: Int, context: String) async throws {
        var args = ["scale", "\(kind.cliName)/\(name)", "--replicas", String(replicas), "--context", context]
        if let namespace { args += ["-n", namespace] }
        try await ProcessRunner.runChecked("kubectl", args)
    }

    /// Applies an edited manifest; returns kubectl's confirmation output.
    static func apply(yaml: String, context: String) async throws -> String {
        let result = try await ProcessRunner.runChecked(
            "kubectl",
            ["apply", "-f", "-", "--context", context],
            stdin: Data(yaml.utf8)
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Metrics (requires metrics-server in the cluster)

    // `kubectl get --raw` hits the metrics API directly, returning real JSON —
    // unlike `kubectl top`, whose human-formatted table would need scraping.

    static func podMetrics(context: String, namespace: String?) async throws -> [String: PodMetric] {
        let path = namespace.map { "/apis/metrics.k8s.io/v1beta1/namespaces/\($0)/pods" }
            ?? "/apis/metrics.k8s.io/v1beta1/pods"
        let result = try await ProcessRunner.runChecked("kubectl", ["get", "--raw", path, "--context", context])
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
        let result = try await ProcessRunner.runChecked(
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
