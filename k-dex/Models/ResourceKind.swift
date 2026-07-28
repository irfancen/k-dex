import Foundation

/// Any resource kind the app can browse. Identity (group/version/plural/kind,
/// scope) is discovered from the cluster at connect time — `builtins` is only
/// the seed shown before discovery lands and the fallback if it fails.
/// Presentation comes from the `enrichments` table (KindEnrichments.swift);
/// kinds without an entry get generic treatment (name/status/age columns,
/// hidden by default).
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

    /// Stored lookup — the enrichment arrays already end with the Age column,
    /// so this allocates nothing per access (sorting touches it per render).
    var columns: [ColumnSpec] { enrichment?.columns ?? Self.genericColumns }

    static let ageColumn = ColumnSpec("Age", ideal: 50, max: 70) { obj, ctx in
        Fmt.age(obj.creationDate, relativeTo: ctx.now)
    }

    static let eventAgeColumn = ColumnSpec("Age", ideal: 50, max: 70) { obj, ctx in
        Fmt.age(ResourceKind.events.ageDate(obj), relativeTo: ctx.now)
    }

    /// Columns for kinds with no curated schema knowledge: a best-effort
    /// status from phase / standard conditions.
    static let genericColumns: [ColumnSpec] = [
        ColumnSpec("Status", ideal: 90, max: 140, style: .badge) { obj, _ in
            let status = KindHelpers.crdStatus(obj)
            return Cell(text: status?.0 ?? "", tone: status?.1 ?? .neutral)
        },
        ageColumn,
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
}
