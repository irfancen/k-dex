import Foundation

nonisolated enum StatusTone: Sendable {
    case ok, warn, bad, neutral
}

/// A table column for a resource kind: title, layout hints, and extractors.
nonisolated struct ColumnSpec: Identifiable, Sendable {
    let title: String
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    /// When present, the cell renders as a colored status badge.
    let tone: (@Sendable (KubeObject, RowContext) -> StatusTone)?
    /// When present, the cell renders a usage bar under the text.
    let fraction: (@Sendable (KubeObject, RowContext) -> UsageValue?)?
    let value: @Sendable (KubeObject, RowContext) -> String

    var id: String { title }

    init(
        _ title: String,
        min: CGFloat? = nil,
        ideal: CGFloat? = nil,
        max: CGFloat? = nil,
        tone: (@Sendable (KubeObject, RowContext) -> StatusTone)? = nil,
        fraction: (@Sendable (KubeObject, RowContext) -> UsageValue?)? = nil,
        value: @escaping @Sendable (KubeObject, RowContext) -> String
    ) {
        self.title = title
        self.minWidth = min
        self.idealWidth = ideal
        self.maxWidth = max
        self.tone = tone
        self.fraction = fraction
        self.value = value
    }
}

nonisolated enum ResourceCategory: String, CaseIterable, Identifiable, Sendable {
    case workloads, network, config, storage, access, cluster, crd, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workloads: return "Workloads"
        case .network: return "Network"
        case .config: return "Config"
        case .storage: return "Storage"
        case .access: return "Access Control"
        case .cluster: return "Cluster"
        case .crd: return "Custom Resources"
        case .other: return "Other"
        }
    }
}

nonisolated enum SidebarItem: Hashable, Sendable {
    case overview
    case resource(ResourceKind)
    case helm
    /// Transient: clicking a category row toggles its expansion, then the
    /// selection is bounced back to the previous item.
    case category(String)
}

/// Curated metadata for a well-known kind: how it's presented and which
/// actions it supports. Identity comes from API discovery; this is the
/// editorial layer discovery can't provide (columns, icons, grouping).
nonisolated struct KindEnrichment: Sendable {
    var displayName: String
    var icon: String
    var category: ResourceCategory
    var visibleByDefault = true
    var supportsLogs = false
    var supportsRestart = false
    var supportsScale = false
    var supportsPortForward = false
    var showsPods = false
    var columns: [ColumnSpec] = []
}

/// Any resource kind the app can browse. Identity (group/version/plural/kind,
/// scope) is discovered from the cluster at connect time — `builtins` is only
/// the seed shown before discovery lands and the fallback if it fails.
/// Presentation comes from the `enrichments` table; kinds without an entry
/// get generic treatment (name/status/age columns, hidden by default).
nonisolated struct ResourceKind: Identifiable, Hashable, Sendable {
    let group: String        // "" for the core API
    let version: String      // preferred/storage version, e.g. "v1"
    let plural: String       // "deployments"
    let kindName: String     // "Deployment"
    let isNamespaced: Bool
    /// Backed by a CustomResourceDefinition (marked during discovery).
    var isCustom = false

    /// Fully qualified resource name for kubectl — also the stable identity
    /// used for selection, persistence, and enrichment lookup.
    var id: String { group.isEmpty ? plural : "\(plural).\(group)" }
    var cliName: String { id }

    /// apiVersion used when creating a new resource of this kind.
    var defaultAPIVersion: String { group.isEmpty ? version : "\(group)/\(version)" }

    // Identity-only equality: a version bump or CRD flagging must not change
    // selection, view identity, or watcher specs.
    static func == (lhs: ResourceKind, rhs: ResourceKind) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: Presentation (enrichment-driven)

    private var enrichment: KindEnrichment? { Self.enrichments[id] }

    var displayName: String { enrichment?.displayName ?? kindName }
    var icon: String { enrichment?.icon ?? "puzzlepiece.extension" }
    var category: ResourceCategory { enrichment?.category ?? (isCustom ? .crd : .other) }
    /// Hidden kinds stay reachable via ⌘K and the Visible Items menus.
    var visibleByDefault: Bool { enrichment?.visibleByDefault ?? isCustom }

    var supportsLogs: Bool { enrichment?.supportsLogs ?? false }
    var supportsRestart: Bool { enrichment?.supportsRestart ?? false }
    var supportsScale: Bool { enrichment?.supportsScale ?? false }
    var supportsPortForward: Bool { enrichment?.supportsPortForward ?? false }
    var showsPods: Bool { enrichment?.showsPods ?? false }
    var supportsDelete: Bool { self != .events && self != .nodes }

    /// The timestamp used for the Age column (events use their last occurrence).
    func ageDate(_ object: KubeObject) -> Date? {
        if self == .events {
            let raw = object.raw
            return Fmt.parseDate(raw["lastTimestamp"].string)
                ?? Fmt.parseDate(raw["eventTime"].string)
                ?? object.creationDate
        }
        return object.creationDate
    }

    var columns: [ColumnSpec] {
        var cols = enrichment?.columns ?? Self.genericColumns
        cols.append(ColumnSpec("Age", ideal: 50, max: 70) { [self] obj, ctx in
            Fmt.age(ageDate(obj), relativeTo: ctx.now)
        })
        return cols
    }

    /// Columns for kinds with no curated schema knowledge: a best-effort
    /// status from phase / standard conditions.
    private static let genericColumns: [ColumnSpec] = [
        ColumnSpec("Status", ideal: 90, max: 140, tone: { obj, _ in KindHelpers.crdStatus(obj)?.1 ?? .neutral }) { obj, _ in
            KindHelpers.crdStatus(obj)?.0 ?? ""
        },
    ]

    // MARK: Well-known kinds (seed catalog + static identities)

    static let pods = ResourceKind(group: "", version: "v1", plural: "pods", kindName: "Pod", isNamespaced: true)
    static let deployments = ResourceKind(group: "apps", version: "v1", plural: "deployments", kindName: "Deployment", isNamespaced: true)
    static let statefulSets = ResourceKind(group: "apps", version: "v1", plural: "statefulsets", kindName: "StatefulSet", isNamespaced: true)
    static let daemonSets = ResourceKind(group: "apps", version: "v1", plural: "daemonsets", kindName: "DaemonSet", isNamespaced: true)
    static let replicaSets = ResourceKind(group: "apps", version: "v1", plural: "replicasets", kindName: "ReplicaSet", isNamespaced: true)
    static let controllerRevisions = ResourceKind(group: "apps", version: "v1", plural: "controllerrevisions", kindName: "ControllerRevision", isNamespaced: true)
    static let jobs = ResourceKind(group: "batch", version: "v1", plural: "jobs", kindName: "Job", isNamespaced: true)
    static let cronJobs = ResourceKind(group: "batch", version: "v1", plural: "cronjobs", kindName: "CronJob", isNamespaced: true)
    static let services = ResourceKind(group: "", version: "v1", plural: "services", kindName: "Service", isNamespaced: true)
    static let ingresses = ResourceKind(group: "networking.k8s.io", version: "v1", plural: "ingresses", kindName: "Ingress", isNamespaced: true)
    static let ingressClasses = ResourceKind(group: "networking.k8s.io", version: "v1", plural: "ingressclasses", kindName: "IngressClass", isNamespaced: false)
    static let endpointSlices = ResourceKind(group: "discovery.k8s.io", version: "v1", plural: "endpointslices", kindName: "EndpointSlice", isNamespaced: true)
    static let networkPolicies = ResourceKind(group: "networking.k8s.io", version: "v1", plural: "networkpolicies", kindName: "NetworkPolicy", isNamespaced: true)
    static let configMaps = ResourceKind(group: "", version: "v1", plural: "configmaps", kindName: "ConfigMap", isNamespaced: true)
    static let secrets = ResourceKind(group: "", version: "v1", plural: "secrets", kindName: "Secret", isNamespaced: true)
    static let horizontalPodAutoscalers = ResourceKind(group: "autoscaling", version: "v2", plural: "horizontalpodautoscalers", kindName: "HorizontalPodAutoscaler", isNamespaced: true)
    static let podDisruptionBudgets = ResourceKind(group: "policy", version: "v1", plural: "poddisruptionbudgets", kindName: "PodDisruptionBudget", isNamespaced: true)
    static let resourceQuotas = ResourceKind(group: "", version: "v1", plural: "resourcequotas", kindName: "ResourceQuota", isNamespaced: true)
    static let limitRanges = ResourceKind(group: "", version: "v1", plural: "limitranges", kindName: "LimitRange", isNamespaced: true)
    static let priorityClasses = ResourceKind(group: "scheduling.k8s.io", version: "v1", plural: "priorityclasses", kindName: "PriorityClass", isNamespaced: false)
    static let mutatingWebhookConfigurations = ResourceKind(group: "admissionregistration.k8s.io", version: "v1", plural: "mutatingwebhookconfigurations", kindName: "MutatingWebhookConfiguration", isNamespaced: false)
    static let validatingWebhookConfigurations = ResourceKind(group: "admissionregistration.k8s.io", version: "v1", plural: "validatingwebhookconfigurations", kindName: "ValidatingWebhookConfiguration", isNamespaced: false)
    static let persistentVolumeClaims = ResourceKind(group: "", version: "v1", plural: "persistentvolumeclaims", kindName: "PersistentVolumeClaim", isNamespaced: true)
    static let persistentVolumes = ResourceKind(group: "", version: "v1", plural: "persistentvolumes", kindName: "PersistentVolume", isNamespaced: false)
    static let storageClasses = ResourceKind(group: "storage.k8s.io", version: "v1", plural: "storageclasses", kindName: "StorageClass", isNamespaced: false)
    static let serviceAccounts = ResourceKind(group: "", version: "v1", plural: "serviceaccounts", kindName: "ServiceAccount", isNamespaced: true)
    static let roles = ResourceKind(group: "rbac.authorization.k8s.io", version: "v1", plural: "roles", kindName: "Role", isNamespaced: true)
    static let roleBindings = ResourceKind(group: "rbac.authorization.k8s.io", version: "v1", plural: "rolebindings", kindName: "RoleBinding", isNamespaced: true)
    static let clusterRoles = ResourceKind(group: "rbac.authorization.k8s.io", version: "v1", plural: "clusterroles", kindName: "ClusterRole", isNamespaced: false)
    static let clusterRoleBindings = ResourceKind(group: "rbac.authorization.k8s.io", version: "v1", plural: "clusterrolebindings", kindName: "ClusterRoleBinding", isNamespaced: false)
    static let certificateSigningRequests = ResourceKind(group: "certificates.k8s.io", version: "v1", plural: "certificatesigningrequests", kindName: "CertificateSigningRequest", isNamespaced: false)
    static let nodes = ResourceKind(group: "", version: "v1", plural: "nodes", kindName: "Node", isNamespaced: false)
    static let namespaces = ResourceKind(group: "", version: "v1", plural: "namespaces", kindName: "Namespace", isNamespaced: false)
    static let events = ResourceKind(group: "", version: "v1", plural: "events", kindName: "Event", isNamespaced: true)
    static let customResourceDefinitions = ResourceKind(group: "apiextensions.k8s.io", version: "v1", plural: "customresourcedefinitions", kindName: "CustomResourceDefinition", isNamespaced: false)
    static let leases = ResourceKind(group: "coordination.k8s.io", version: "v1", plural: "leases", kindName: "Lease", isNamespaced: true)
    static let runtimeClasses = ResourceKind(group: "node.k8s.io", version: "v1", plural: "runtimeclasses", kindName: "RuntimeClass", isNamespaced: false)

    /// Seed catalog: shown at boot and kept as fallback when discovery fails.
    /// Order here is the default sidebar order within each category.
    static let builtins: [ResourceKind] = [
        .pods, .deployments, .statefulSets, .daemonSets, .replicaSets, .jobs, .cronJobs, .controllerRevisions,
        .services, .ingresses, .ingressClasses, .endpointSlices, .networkPolicies,
        .configMaps, .secrets, .horizontalPodAutoscalers, .podDisruptionBudgets,
        .resourceQuotas, .limitRanges, .priorityClasses,
        .mutatingWebhookConfigurations, .validatingWebhookConfigurations,
        .persistentVolumeClaims, .persistentVolumes, .storageClasses,
        .serviceAccounts, .roles, .roleBindings, .clusterRoles, .clusterRoleBindings,
        .certificateSigningRequests,
        .nodes, .namespaces, .events, .customResourceDefinitions, .leases, .runtimeClasses,
    ]

    // MARK: Enrichment table

    static let enrichments: [String: KindEnrichment] = {
        var t: [String: KindEnrichment] = [:]

        t[pods.id] = KindEnrichment(
            displayName: "Pods", icon: "cube", category: .workloads,
            supportsLogs: true, supportsPortForward: true,
            columns: [
                ColumnSpec("Ready", ideal: 55, max: 70, tone: { obj, _ in KindHelpers.podReadyTone(obj) }) { obj, _ in
                    KindHelpers.podReady(obj)
                },
                ColumnSpec("Status", ideal: 130, max: 190, tone: { obj, _ in KindHelpers.podStatus(obj).1 }) { obj, _ in
                    KindHelpers.podStatus(obj).0
                },
                ColumnSpec("Restarts", ideal: 70, max: 90) { obj, _ in
                    String(obj.raw["status"]["containerStatuses"].array.reduce(0) { $0 + ($1["restartCount"].int ?? 0) })
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = KindHelpers.podLastRestart(obj) else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
                ColumnSpec("CPU", ideal: 108, max: 150, fraction: { obj, ctx in
                    KindHelpers.podUsage(obj, ctx, resource: "cpu")
                }) { obj, ctx in
                    KindHelpers.usageWithLimit(
                        usage: ctx.podMetrics["\(obj.namespace)/\(obj.name)"]?.cpu,
                        limit: KindHelpers.summedResource(obj.raw["spec"]["containers"].array, section: "limits", resource: "cpu")
                    )
                },
                ColumnSpec("Memory", ideal: 116, max: 160, fraction: { obj, ctx in
                    KindHelpers.podUsage(obj, ctx, resource: "memory")
                }) { obj, ctx in
                    KindHelpers.usageWithLimit(
                        usage: ctx.podMetrics["\(obj.namespace)/\(obj.name)"]?.memory,
                        limit: KindHelpers.summedResource(obj.raw["spec"]["containers"].array, section: "limits", resource: "memory")
                    )
                },
                ColumnSpec("Node", ideal: 140) { obj, _ in obj.raw["spec"]["nodeName"].stringValue },
            ])

        t[deployments.id] = KindEnrichment(
            displayName: "Deployments", icon: "square.stack.3d.up", category: .workloads,
            supportsRestart: true, supportsScale: true, showsPods: true,
            columns: [
                ColumnSpec("Ready", ideal: 60, max: 80, tone: { obj, _ in KindHelpers.replicaTone(obj, readyKey: "readyReplicas") }) { obj, _ in
                    "\(obj.raw["status"]["readyReplicas"].int ?? 0)/\(obj.raw["spec"]["replicas"].int ?? 0)"
                },
                ColumnSpec("Up-to-date", ideal: 84, max: 104) { obj, _ in String(obj.raw["status"]["updatedReplicas"].int ?? 0) },
                ColumnSpec("Available", ideal: 76, max: 96) { obj, _ in String(obj.raw["status"]["availableReplicas"].int ?? 0) },
                ColumnSpec("CPU", ideal: 108, max: 150, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "cpu")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "cpu") },
                ColumnSpec("Memory", ideal: 116, max: 160, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "memory")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "memory") },
                ColumnSpec("Restarts", ideal: 60, max: 80) { obj, ctx in
                    ctx.workloadUsage["\(obj.namespace)/\(obj.name)"].map { String($0.restarts) } ?? "–"
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"]?.lastRestart else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
            ])

        t[statefulSets.id] = KindEnrichment(
            displayName: "Stateful Sets", icon: "list.number", category: .workloads,
            supportsRestart: true, supportsScale: true, showsPods: true,
            columns: [
                ColumnSpec("Ready", ideal: 60, max: 80, tone: { obj, _ in KindHelpers.replicaTone(obj, readyKey: "readyReplicas") }) { obj, _ in
                    "\(obj.raw["status"]["readyReplicas"].int ?? 0)/\(obj.raw["spec"]["replicas"].int ?? 0)"
                },
                ColumnSpec("CPU", ideal: 108, max: 150, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "cpu")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "cpu") },
                ColumnSpec("Memory", ideal: 116, max: 160, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "memory")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "memory") },
                ColumnSpec("Restarts", ideal: 60, max: 80) { obj, ctx in
                    ctx.workloadUsage["\(obj.namespace)/\(obj.name)"].map { String($0.restarts) } ?? "–"
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"]?.lastRestart else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
            ])

        t[daemonSets.id] = KindEnrichment(
            displayName: "Daemon Sets", icon: "circle.hexagongrid", category: .workloads,
            supportsRestart: true, showsPods: true,
            columns: [
                ColumnSpec("Desired", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["desiredNumberScheduled"].int ?? 0) },
                ColumnSpec("Ready", ideal: 55, max: 75, tone: { obj, _ in
                    let desired = obj.raw["status"]["desiredNumberScheduled"].int ?? 0
                    let ready = obj.raw["status"]["numberReady"].int ?? 0
                    if desired == 0 { return .neutral }
                    return ready >= desired ? .ok : .warn
                }) { obj, _ in String(obj.raw["status"]["numberReady"].int ?? 0) },
                ColumnSpec("Up-to-date", ideal: 84, max: 104) { obj, _ in String(obj.raw["status"]["updatedNumberScheduled"].int ?? 0) },
                ColumnSpec("Available", ideal: 76, max: 96) { obj, _ in String(obj.raw["status"]["numberAvailable"].int ?? 0) },
                ColumnSpec("CPU", ideal: 108, max: 150, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "cpu")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "cpu") },
                ColumnSpec("Memory", ideal: 116, max: 160, fraction: { obj, ctx in
                    KindHelpers.workloadUsageValue(obj, ctx, resource: "memory")
                }) { obj, ctx in KindHelpers.workloadUsageText(obj, ctx, resource: "memory") },
                ColumnSpec("Restarts", ideal: 60, max: 80) { obj, ctx in
                    ctx.workloadUsage["\(obj.namespace)/\(obj.name)"].map { String($0.restarts) } ?? "–"
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"]?.lastRestart else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
            ])

        t[replicaSets.id] = KindEnrichment(
            displayName: "Replica Sets", icon: "square.on.square", category: .workloads,
            supportsScale: true, showsPods: true,
            columns: [
                ColumnSpec("Desired", ideal: 55, max: 75) { obj, _ in String(obj.raw["spec"]["replicas"].int ?? 0) },
                ColumnSpec("Current", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["replicas"].int ?? 0) },
                ColumnSpec("Ready", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["readyReplicas"].int ?? 0) },
                ColumnSpec("Restarts", ideal: 60, max: 80) { obj, ctx in
                    ctx.workloadUsage["\(obj.namespace)/\(obj.name)"].map { String($0.restarts) } ?? "–"
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"]?.lastRestart else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
            ])

        t[jobs.id] = KindEnrichment(
            displayName: "Jobs", icon: "checkmark.circle", category: .workloads,
            showsPods: true,
            columns: [
                ColumnSpec("Completions", ideal: 94, max: 114) { obj, _ in
                    // Work-queue jobs leave completions unset; parallelism is
                    // the meaningful denominator there.
                    let desired = obj.raw["spec"]["completions"].int
                        ?? obj.raw["spec"]["parallelism"].int ?? 1
                    return "\(obj.raw["status"]["succeeded"].int ?? 0)/\(desired)"
                },
                ColumnSpec("Status", ideal: 90, max: 120, tone: { obj, _ in KindHelpers.jobStatus(obj).1 }) { obj, _ in
                    KindHelpers.jobStatus(obj).0
                },
                ColumnSpec("Duration", ideal: 70, max: 90) { obj, ctx in
                    Fmt.duration(
                        from: Fmt.parseDate(obj.raw["status"]["startTime"].string),
                        to: Fmt.parseDate(obj.raw["status"]["completionTime"].string) ?? ctx.now
                    )
                },
            ])

        t[cronJobs.id] = KindEnrichment(
            displayName: "Cron Jobs", icon: "calendar.badge.clock", category: .workloads,
            columns: [
                ColumnSpec("Schedule", ideal: 100, max: 140) { obj, _ in obj.raw["spec"]["schedule"].stringValue },
                ColumnSpec("Suspend", ideal: 60, max: 80) { obj, _ in (obj.raw["spec"]["suspend"].bool ?? false) ? "true" : "false" },
                ColumnSpec("Active", ideal: 50, max: 70) { obj, _ in String(obj.raw["status"]["active"].array.count) },
                ColumnSpec("Last Run", ideal: 70, max: 90) { obj, ctx in
                    Fmt.age(Fmt.parseDate(obj.raw["status"]["lastScheduleTime"].string), relativeTo: ctx.now)
                },
            ])

        t[controllerRevisions.id] = KindEnrichment(
            displayName: "Controller Revisions", icon: "clock.arrow.circlepath", category: .workloads,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Controller", ideal: 200) { obj, _ in obj.controlledBy ?? "" },
                ColumnSpec("Revision", ideal: 62, max: 82) { obj, _ in obj.raw["revision"].displayString },
            ])

        t[services.id] = KindEnrichment(
            displayName: "Services", icon: "network", category: .network,
            supportsPortForward: true,
            columns: [
                ColumnSpec("Type", ideal: 100, max: 130) { obj, _ in obj.raw["spec"]["type"].stringValue },
                ColumnSpec("Cluster IP", ideal: 110, max: 150) { obj, _ in obj.raw["spec"]["clusterIP"].stringValue },
                ColumnSpec("External IP", ideal: 110, max: 170) { obj, _ in KindHelpers.serviceExternalIP(obj) },
                ColumnSpec("Ports", ideal: 140) { obj, _ in KindHelpers.servicePorts(obj) },
            ])

        t[ingresses.id] = KindEnrichment(
            displayName: "Ingresses", icon: "arrow.triangle.branch", category: .network,
            columns: [
                ColumnSpec("Class", ideal: 90, max: 130) { obj, _ in obj.raw["spec"]["ingressClassName"].stringValue },
                ColumnSpec("Hosts", ideal: 180) { obj, _ in
                    let hosts = obj.raw["spec"]["rules"].array.map { $0["host"].stringValue.isEmpty ? "*" : $0["host"].stringValue }
                    return hosts.joined(separator: ", ")
                },
                ColumnSpec("Address", ideal: 140) { obj, _ in
                    obj.raw["status"]["loadBalancer"]["ingress"].array
                        .map { $0["ip"].string ?? $0["hostname"].stringValue }
                        .joined(separator: ", ")
                },
            ])

        t[ingressClasses.id] = KindEnrichment(
            displayName: "Ingress Classes", icon: "signpost.right", category: .network,
            columns: [
                ColumnSpec("Controller", ideal: 220) { obj, _ in obj.raw["spec"]["controller"].stringValue },
                ColumnSpec("Default", ideal: 55, max: 75) { obj, _ in
                    obj.annotations["ingressclass.kubernetes.io/is-default-class"] == "true" ? "✓" : ""
                },
            ])

        t[endpointSlices.id] = KindEnrichment(
            displayName: "Endpoint Slices", icon: "point.3.connected.trianglepath.dotted", category: .network,
            columns: [
                ColumnSpec("Address Type", ideal: 98, max: 122) { obj, _ in obj.raw["addressType"].stringValue },
                ColumnSpec("Endpoints", ideal: 70, max: 90) { obj, _ in String(obj.raw["endpoints"].array.count) },
                ColumnSpec("Ports", ideal: 120) { obj, _ in
                    obj.raw["ports"].array.map { "\($0["port"].displayString)/\($0["protocol"].stringValue)" }.joined(separator: ", ")
                },
            ])

        t[networkPolicies.id] = KindEnrichment(
            displayName: "Network Policies", icon: "lock.shield", category: .network,
            columns: [
                ColumnSpec("Pod Selector", ideal: 200) { obj, _ in
                    let selector = obj.raw["spec"]["podSelector"]["matchLabels"].stringDictionary
                    if selector.isEmpty { return "(all pods)" }
                    return selector.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                },
            ])

        t[configMaps.id] = KindEnrichment(
            displayName: "Config Maps", icon: "doc.text", category: .config,
            columns: [
                ColumnSpec("Keys", ideal: 50, max: 70) { obj, _ in String(obj.raw["data"].object.count + obj.raw["binaryData"].object.count) },
            ])

        t[secrets.id] = KindEnrichment(
            displayName: "Secrets", icon: "key", category: .config,
            columns: [
                ColumnSpec("Type", ideal: 200) { obj, _ in obj.raw["type"].stringValue },
                ColumnSpec("Keys", ideal: 50, max: 70) { obj, _ in String(obj.raw["data"].object.count) },
            ])

        t[horizontalPodAutoscalers.id] = KindEnrichment(
            displayName: "HPAs", icon: "arrow.up.arrow.down", category: .config,
            columns: [
                ColumnSpec("Reference", ideal: 180) { obj, _ in
                    let ref = obj.raw["spec"]["scaleTargetRef"]
                    return "\(ref["kind"].stringValue)/\(ref["name"].stringValue)"
                },
                ColumnSpec("Min", ideal: 45, max: 60) { obj, _ in obj.raw["spec"]["minReplicas"].displayString },
                ColumnSpec("Max", ideal: 45, max: 60) { obj, _ in obj.raw["spec"]["maxReplicas"].displayString },
                ColumnSpec("Replicas", ideal: 70, max: 90) { obj, _ in obj.raw["status"]["currentReplicas"].displayString },
            ])

        t[podDisruptionBudgets.id] = KindEnrichment(
            displayName: "Disruption Budgets", icon: "shield.lefthalf.filled", category: .config,
            columns: [
                ColumnSpec("Min Available", ideal: 94, max: 116) { obj, _ in
                    let value = obj.raw["spec"]["minAvailable"]
                    return value.isNull ? "N/A" : value.displayString
                },
                ColumnSpec("Max Unavailable", ideal: 110, max: 130) { obj, _ in
                    let value = obj.raw["spec"]["maxUnavailable"]
                    return value.isNull ? "N/A" : value.displayString
                },
                ColumnSpec("Allowed Disruptions", ideal: 124, max: 144) { obj, _ in
                    obj.raw["status"]["disruptionsAllowed"].displayString
                },
                ColumnSpec("Healthy", ideal: 66, max: 86, tone: { obj, _ in
                    let healthy = obj.raw["status"]["currentHealthy"].int ?? 0
                    let desired = obj.raw["status"]["desiredHealthy"].int ?? 0
                    if desired == 0 { return .neutral }
                    return healthy >= desired ? .ok : .warn
                }) { obj, _ in
                    "\(obj.raw["status"]["currentHealthy"].int ?? 0)/\(obj.raw["status"]["desiredHealthy"].int ?? 0)"
                },
            ])

        t[resourceQuotas.id] = KindEnrichment(
            displayName: "Resource Quotas", icon: "gauge", category: .config,
            columns: [
                ColumnSpec("Usage", min: 200, ideal: 400) { obj, _ in
                    let hard = obj.raw["status"]["hard"].object
                    let used = obj.raw["status"]["used"].object
                    return hard.keys.sorted().map { key in
                        "\(key): \(used[key]?.displayString ?? "0")/\(hard[key]?.displayString ?? "")"
                    }.joined(separator: ", ")
                },
            ])

        t[limitRanges.id] = KindEnrichment(
            displayName: "Limit Ranges", icon: "ruler", category: .config,
            columns: [
                ColumnSpec("Limits", ideal: 50, max: 70) { obj, _ in
                    String(obj.raw["spec"]["limits"].array.count)
                },
                ColumnSpec("Types", ideal: 160) { obj, _ in
                    obj.raw["spec"]["limits"].array.map { $0["type"].stringValue }.joined(separator: ", ")
                },
            ])

        t[priorityClasses.id] = KindEnrichment(
            displayName: "Priority Classes", icon: "flag", category: .config,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Value", ideal: 100, max: 130) { obj, _ in obj.raw["value"].displayString },
                ColumnSpec("Global Default", ideal: 96, max: 116) { obj, _ in
                    (obj.raw["globalDefault"].bool ?? false) ? "true" : "false"
                },
                ColumnSpec("Preemption", ideal: 150, max: 190) { obj, _ in
                    obj.raw["preemptionPolicy"].stringValue
                },
            ])

        let webhookColumns: [ColumnSpec] = [
            ColumnSpec("Webhooks", ideal: 66, max: 86) { obj, _ in
                String(obj.raw["webhooks"].array.count)
            },
            ColumnSpec("Endpoints", ideal: 260) { obj, _ in
                obj.raw["webhooks"].array.map { hook in
                    let service = hook["clientConfig"]["service"]
                    if !service.isNull {
                        return "\(service["namespace"].stringValue)/\(service["name"].stringValue)"
                    }
                    return hook["clientConfig"]["url"].stringValue
                }.joined(separator: ", ")
            },
        ]
        t[mutatingWebhookConfigurations.id] = KindEnrichment(
            displayName: "Mutating Webhooks", icon: "arrow.triangle.swap", category: .config,
            visibleByDefault: false, columns: webhookColumns)
        t[validatingWebhookConfigurations.id] = KindEnrichment(
            displayName: "Validating Webhooks", icon: "checkmark.shield", category: .config,
            visibleByDefault: false, columns: webhookColumns)

        t[persistentVolumeClaims.id] = KindEnrichment(
            displayName: "Volume Claims", icon: "externaldrive", category: .storage,
            columns: [
                ColumnSpec("Status", ideal: 80, max: 110, tone: { obj, _ in KindHelpers.pvcTone(obj) }) { obj, _ in
                    obj.isTerminating ? "Terminating" : obj.raw["status"]["phase"].stringValue
                },
                ColumnSpec("Volume", ideal: 160) { obj, _ in obj.raw["spec"]["volumeName"].stringValue },
                ColumnSpec("Capacity", ideal: 70, max: 90) { obj, _ in obj.raw["status"]["capacity"]["storage"].stringValue },
                ColumnSpec("Access", ideal: 70, max: 100) { obj, _ in KindHelpers.accessModes(obj.raw["spec"]["accessModes"]) },
                ColumnSpec("Class", ideal: 100, max: 140) { obj, _ in obj.raw["spec"]["storageClassName"].stringValue },
            ])

        t[persistentVolumes.id] = KindEnrichment(
            displayName: "Volumes", icon: "internaldrive", category: .storage,
            columns: [
                ColumnSpec("Capacity", ideal: 70, max: 90) { obj, _ in obj.raw["spec"]["capacity"]["storage"].stringValue },
                ColumnSpec("Access", ideal: 70, max: 100) { obj, _ in KindHelpers.accessModes(obj.raw["spec"]["accessModes"]) },
                ColumnSpec("Reclaim", ideal: 70, max: 90) { obj, _ in obj.raw["spec"]["persistentVolumeReclaimPolicy"].stringValue },
                ColumnSpec("Status", ideal: 80, max: 110, tone: { obj, _ in KindHelpers.pvTone(obj) }) { obj, _ in
                    obj.raw["status"]["phase"].stringValue
                },
                ColumnSpec("Claim", ideal: 160) { obj, _ in
                    let claim = obj.raw["spec"]["claimRef"]
                    if claim.isNull { return "" }
                    return "\(claim["namespace"].stringValue)/\(claim["name"].stringValue)"
                },
            ])

        t[storageClasses.id] = KindEnrichment(
            displayName: "Storage Classes", icon: "archivebox", category: .storage,
            columns: [
                ColumnSpec("Provisioner", ideal: 200) { obj, _ in obj.raw["provisioner"].stringValue },
                ColumnSpec("Reclaim", ideal: 70, max: 90) { obj, _ in obj.raw["reclaimPolicy"].stringValue },
                ColumnSpec("Binding", ideal: 130, max: 160) { obj, _ in obj.raw["volumeBindingMode"].stringValue },
                ColumnSpec("Default", ideal: 55, max: 75) { obj, _ in
                    obj.annotations["storageclass.kubernetes.io/is-default-class"] == "true" ? "✓" : ""
                },
            ])

        t[serviceAccounts.id] = KindEnrichment(
            displayName: "Service Accounts", icon: "person.badge.key", category: .access)

        let roleColumns: [ColumnSpec] = [
            ColumnSpec("Rules", ideal: 50, max: 70) { obj, _ in String(obj.raw["rules"].array.count) },
        ]
        let bindingColumns: [ColumnSpec] = [
            ColumnSpec("Role", ideal: 180) { obj, _ in obj.raw["roleRef"]["name"].stringValue },
            ColumnSpec("Subjects", ideal: 200) { obj, _ in
                obj.raw["subjects"].array.map { "\($0["kind"].stringValue)/\($0["name"].stringValue)" }.joined(separator: ", ")
            },
        ]
        t[roles.id] = KindEnrichment(
            displayName: "Roles", icon: "person.text.rectangle", category: .access, columns: roleColumns)
        t[roleBindings.id] = KindEnrichment(
            displayName: "Role Bindings", icon: "link", category: .access, columns: bindingColumns)
        t[clusterRoles.id] = KindEnrichment(
            displayName: "Cluster Roles", icon: "person.2.badge.gearshape", category: .access, columns: roleColumns)
        t[clusterRoleBindings.id] = KindEnrichment(
            displayName: "Cluster Role Bindings", icon: "link.circle", category: .access, columns: bindingColumns)

        t[certificateSigningRequests.id] = KindEnrichment(
            displayName: "CSRs", icon: "signature", category: .access,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Signer", ideal: 220) { obj, _ in obj.raw["spec"]["signerName"].stringValue },
                ColumnSpec("Requestor", ideal: 160) { obj, _ in obj.raw["spec"]["username"].stringValue },
                ColumnSpec("Status", ideal: 110, max: 140, tone: { obj, _ in KindHelpers.csrStatus(obj).1 }) { obj, _ in
                    KindHelpers.csrStatus(obj).0
                },
            ])

        t[nodes.id] = KindEnrichment(
            displayName: "Nodes", icon: "server.rack", category: .cluster,
            columns: [
                ColumnSpec("Status", ideal: 90, max: 160, tone: { obj, _ in KindHelpers.nodeStatus(obj).1 }) { obj, _ in
                    KindHelpers.nodeStatus(obj).0
                },
                ColumnSpec("Roles", ideal: 110, max: 160) { obj, _ in KindHelpers.nodeRoles(obj) },
                ColumnSpec("Version", ideal: 90, max: 130) { obj, _ in obj.raw["status"]["nodeInfo"]["kubeletVersion"].stringValue },
                ColumnSpec("CPU", ideal: 100, max: 130, fraction: { obj, ctx in
                    ctx.nodeMetrics[obj.name]
                        .flatMap { KindHelpers.percentFraction($0.cpuPercent) }
                        .map { UsageValue(fraction: $0, bounded: true) }
                }) { obj, ctx in
                    guard let m = ctx.nodeMetrics[obj.name] else { return "–" }
                    return "\(m.cpu) (\(m.cpuPercent))"
                },
                ColumnSpec("Memory", ideal: 116, max: 150, fraction: { obj, ctx in
                    ctx.nodeMetrics[obj.name]
                        .flatMap { KindHelpers.percentFraction($0.memoryPercent) }
                        .map { UsageValue(fraction: $0, bounded: true) }
                }) { obj, ctx in
                    guard let m = ctx.nodeMetrics[obj.name] else { return "–" }
                    return "\(m.memory) (\(m.memoryPercent))"
                },
            ])

        t[namespaces.id] = KindEnrichment(
            displayName: "Namespaces", icon: "folder", category: .cluster,
            columns: [
                ColumnSpec("Status", ideal: 80, max: 110, tone: { obj, _ in
                    obj.raw["status"]["phase"].stringValue == "Active" ? .ok : .warn
                }) { obj, _ in obj.raw["status"]["phase"].stringValue },
            ])

        t[events.id] = KindEnrichment(
            displayName: "Events", icon: "bell", category: .cluster,
            columns: [
                ColumnSpec("Type", ideal: 70, max: 90, tone: { obj, _ in
                    obj.raw["type"].stringValue == "Warning" ? .warn : .neutral
                }) { obj, _ in obj.raw["type"].stringValue },
                ColumnSpec("Reason", ideal: 120, max: 170) { obj, _ in obj.raw["reason"].stringValue },
                ColumnSpec("Object", ideal: 170) { obj, _ in
                    let involved = obj.raw["involvedObject"]
                    return "\(involved["kind"].stringValue)/\(involved["name"].stringValue)"
                },
                ColumnSpec("Message", min: 200, ideal: 380) { obj, _ in obj.raw["message"].stringValue },
                ColumnSpec("Count", ideal: 50, max: 70) { obj, _ in obj.raw["count"].displayString },
            ])

        t[customResourceDefinitions.id] = KindEnrichment(
            displayName: "CRDs", icon: "puzzlepiece", category: .cluster,
            columns: [
                ColumnSpec("Group", ideal: 190) { obj, _ in obj.raw["spec"]["group"].stringValue },
                ColumnSpec("Kind", ideal: 140) { obj, _ in obj.raw["spec"]["names"]["kind"].stringValue },
                ColumnSpec("Scope", ideal: 86, max: 106) { obj, _ in obj.raw["spec"]["scope"].stringValue },
                ColumnSpec("Version", ideal: 64, max: 84) { obj, _ in
                    obj.raw["spec"]["versions"].array.first { $0["storage"].bool == true }?["name"].string ?? ""
                },
            ])

        t[leases.id] = KindEnrichment(
            displayName: "Leases", icon: "clock.badge.checkmark", category: .cluster,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Holder", ideal: 240) { obj, _ in obj.raw["spec"]["holderIdentity"].stringValue },
                ColumnSpec("Renewed", ideal: 80, max: 104) { obj, ctx in
                    guard let date = Fmt.parseDate(obj.raw["spec"]["renewTime"].string) else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
            ])

        t[runtimeClasses.id] = KindEnrichment(
            displayName: "Runtime Classes", icon: "cpu", category: .cluster,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Handler", ideal: 140) { obj, _ in obj.raw["handler"].stringValue },
            ])

        return t
    }()
}

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

    static func podStatus(_ obj: KubeObject) -> (String, StatusTone) {
        let status = obj.raw["status"]
        if obj.isTerminating { return ("Terminating", .warn) }
        if let reason = status["reason"].string, !reason.isEmpty {
            return (reason, reason == "Evicted" ? .bad : .warn)
        }
        let badReasons: Set<String> = [
            "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName",
            "CreateContainerConfigError", "CreateContainerError", "RunContainerError", "OOMKilled", "Error",
        ]
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
