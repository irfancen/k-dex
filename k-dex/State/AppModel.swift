import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum BootState: Equatable {
        case loading
        case missingKubectl
        case noContexts
        case failed(String)
        case ready
    }

    // MARK: Cluster / navigation state

    private(set) var bootState: BootState = .loading
    private(set) var contexts: [KubeContext] = []
    private(set) var selectedContext: String = ""
    private(set) var namespaces: [String] = []
    private(set) var selectedNamespace: String?
    /// Every kind the cluster serves, discovered at connect time. Seeded with
    /// the curated built-ins so the sidebar renders before discovery lands.
    private(set) var kindCatalog: [ResourceKind] = ResourceKind.builtins
    var sidebarSelection: SidebarItem? = .overview

    /// Selector filter applied to the Pods list — a label selector (pods of one
    /// deployment) or a field selector (pods on one node).
    struct PodFilter: Equatable {
        let selector: String
        let label: String
        var isFieldSelector = false
    }

    private(set) var podFilter: PodFilter?

    // MARK: Data

    private(set) var objects: [KubeObject] = []
    private(set) var helmReleases: [HelmRelease] = []
    private(set) var overview: OverviewData?
    private(set) var podMetrics: [String: PodMetric] = [:]
    private(set) var nodeMetrics: [String: NodeMetric] = [:]
    private(set) var workloadUsage: [String: WorkloadUsage] = [:]
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var lastRefreshed: Date?
    /// True while a `kubectl get --watch` subprocess is live for the current list.
    private(set) var isWatching = false

    // MARK: UI state

    var searchText = ""
    var selectedObjectID: String?
    /// ⌘K resource palette visibility (in-window overlay).
    var showKindSearch = false
    /// Set when the installed kubectl is older than the app assumes; dismissible.
    var kubectlVersionWarning: String?
    /// False while the app is in the background; auto-refresh pauses and a
    /// catch-up refresh runs on reactivation.
    var isAppActive = true {
        didSet {
            guard isAppActive, !oldValue, bootState == .ready else { return }
            Task { await self.refresh(quiet: true) }
        }
    }
    /// Tab the detail panel should switch to when it next presents ("logs", "yaml").
    var pendingDetailTab: String?
    var selectedHelmID: String?
    var actionError: String?
    var refreshSeconds: Int = 5 { didSet { startAutoRefresh() } }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastNamespaceLoad: Date?
    @ObservationIgnored private var lastCRDLoad: Date?
    @ObservationIgnored private let watcher = KubectlWatcher()
    @ObservationIgnored private var watchStartedAt: Date?
    @ObservationIgnored private var watchFailures = 0
    @ObservationIgnored private var lastListAt: Date = .distantPast
    @ObservationIgnored private var generation = 0
    /// Set when navigating to a kind with the intent of selecting one object once loaded.
    @ObservationIgnored private var pendingSelection: (kind: ResourceKind, namespace: String, name: String)?
    /// Set when a programmatic navigation should keep the pod filter alive through the sidebar change.
    @ObservationIgnored private var keepPodFilterOnSidebarChange = false

    var currentKind: ResourceKind? {
        if case .resource(let kind) = sidebarSelection { return kind }
        return nil
    }

    var selectedObject: KubeObject? {
        guard let selectedObjectID else { return nil }
        return objects.first { $0.id == selectedObjectID }
    }

    var selectedHelmRelease: HelmRelease? {
        guard let selectedHelmID else { return nil }
        return helmReleases.first { $0.id == selectedHelmID }
    }

    var rowContext: RowContext {
        var context = RowContext(
            podMetrics: podMetrics,
            nodeMetrics: nodeMetrics,
            workloadUsage: workloadUsage,
            now: lastRefreshed ?? Date()
        )
        for metric in podMetrics.values {
            context.maxPodCPUMillis = max(context.maxPodCPUMillis, Quantity.cpuMillicores(metric.cpu) ?? 0)
            context.maxPodMemoryBytes = max(context.maxPodMemoryBytes, Quantity.memoryBytes(metric.memory) ?? 0)
        }
        for usage in workloadUsage.values where usage.hasMetrics {
            context.maxWorkloadCPUMillis = max(context.maxWorkloadCPUMillis, usage.cpuMillis)
            context.maxWorkloadMemoryBytes = max(context.maxWorkloadMemoryBytes, usage.memoryBytes)
        }
        return context
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard bootState == .loading else { return }
        guard Kubectl.isAvailable else {
            bootState = .missingKubectl
            return
        }
        do {
            let (current, found) = try await Kubectl.contexts()
            contexts = found
            guard !found.isEmpty else {
                bootState = .noContexts
                return
            }
            selectedContext = current ?? found[0].name
            bootState = .ready
            await loadNamespaces()
            requestRefresh()
            startAutoRefresh()
            Task { await self.loadKindCatalog() }
            Task { await self.checkKubectlVersion() }
        } catch {
            bootState = .failed(error.localizedDescription)
        }
    }

    func retryBootstrap() {
        bootState = .loading
        Task { await self.bootstrap() }
    }

    /// Warns once if kubectl predates flags the app relies on
    /// (--output-watch-events, the metrics API via --raw).
    private func checkKubectlVersion() async {
        guard let result = try? await ProcessRunner.run("kubectl", ["version", "--client", "-o", "json"]),
              let root = try? KubeJSON.decode(result.stdout) else { return }
        let version = root["clientVersion"]["gitVersion"].stringValue
        let parts = version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return }
        if major < 1 || (major == 1 && minor < 24) {
            kubectlVersionWarning = "kubectl \(version) is older than v1.24 — live updates and metrics may not work. Consider upgrading."
        }
    }

    func switchContext(_ name: String) {
        guard name != selectedContext else { return }
        selectedContext = name
        selectedNamespace = nil
        namespaces = []
        kindCatalog = ResourceKind.builtins
        clearData()
        Task {
            await self.loadNamespaces()
            self.requestRefresh()
            await self.loadKindCatalog()
        }
    }

    /// Kinds of one sidebar category, in catalog order.
    func kinds(in category: ResourceCategory) -> [ResourceKind] {
        kindCatalog.filter { $0.category == category }
    }

    func setNamespace(_ namespace: String?) {
        guard namespace != selectedNamespace else { return }
        selectedNamespace = namespace
        clearData()
        requestRefresh()
    }

    /// Navigates to a kind's list and selects one object once it loads.
    func jumpTo(kind: ResourceKind, namespace: String, name: String) {
        pendingSelection = (kind, namespace, name)
        if let current = selectedNamespace, current != namespace {
            selectedNamespace = namespace
        }
        if sidebarSelection == .resource(kind) {
            clearData()
            requestRefresh()
        } else {
            sidebarSelection = .resource(kind) // RootView's onChange clears + refreshes
        }
    }

    /// Navigates to the Pods list filtered to a workload's pods (label selector)
    /// or a node's pods (field selector), optionally selecting one.
    /// A nil namespace forces All Namespaces (node pods span namespaces).
    func jumpToPods(
        selector: String,
        isFieldSelector: Bool = false,
        filterLabel: String,
        namespace: String?,
        selectNamespace: String? = nil,
        selectName: String? = nil
    ) {
        podFilter = PodFilter(selector: selector, label: filterLabel, isFieldSelector: isFieldSelector)
        pendingSelection = selectName.map { (.pods, selectNamespace ?? namespace ?? "", $0) }
        if let namespace {
            if let current = selectedNamespace, current != namespace {
                selectedNamespace = namespace
            }
        } else {
            selectedNamespace = nil
        }
        if sidebarSelection == .resource(.pods) {
            clearData()
            requestRefresh()
        } else {
            keepPodFilterOnSidebarChange = true
            sidebarSelection = .resource(.pods)
        }
    }

    func clearPodFilter() {
        podFilter = nil
        clearData()
        requestRefresh()
    }

    func sidebarSelectionChanged() {
        searchText = ""
        if keepPodFilterOnSidebarChange {
            keepPodFilterOnSidebarChange = false
        } else {
            podFilter = nil
        }
        clearData()
        requestRefresh()
    }

    private func clearData() {
        watcher.stop()
        isWatching = false
        watchFailures = 0
        objects = []
        helmReleases = []
        overview = nil
        workloadUsage = [:]
        selectedObjectID = nil
        selectedHelmID = nil
        lastError = nil
    }

    private func loadNamespaces() async {
        lastNamespaceLoad = Date()
        do {
            namespaces = try await Kubectl.namespaces(context: selectedContext)
        } catch {
            // RBAC may forbid listing namespaces; keep the picker minimal.
            namespaces = selectedNamespace.map { [$0] } ?? []
        }
    }

    private func loadKindCatalog() async {
        lastCRDLoad = Date()
        // Discovery failure (RBAC, flaky network) keeps the current catalog.
        guard let kinds = try? await Kubectl.discoverKinds(context: selectedContext) else { return }
        kindCatalog = kinds
        // Selected kind vanished (context switch, CRD uninstalled) — bail out
        // so the list view isn't stuck fetching a kind the cluster lacks.
        if case .resource(let current) = sidebarSelection, !kinds.contains(current) {
            sidebarSelection = .overview
        }
    }

    /// Keeps the namespace picker and CRD sidebar current so cluster-level
    /// changes show up without a context switch. Runs alongside the main
    /// fetch; throttled during auto-refresh.
    private func reloadNamespacesIfNeeded(force: Bool) {
        let namespacesStale = lastNamespaceLoad.map { Date().timeIntervalSince($0) > 15 } ?? true
        if force || namespacesStale {
            lastNamespaceLoad = Date()
            Task { await self.loadNamespaces() }
        }
        // The kind catalog changes rarely; a slower cadence is enough.
        let catalogStale = lastCRDLoad.map { Date().timeIntervalSince($0) > 60 } ?? true
        if force || catalogStale {
            lastCRDLoad = Date()
            Task { await self.loadKindCatalog() }
        }
    }

    // MARK: Refresh

    func requestRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await self.refresh() }
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        guard refreshSeconds > 0 else { return }
        let seconds = refreshSeconds
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                // Don't burn cluster budget rendering to a backgrounded window;
                // reactivation triggers an immediate catch-up refresh.
                guard self.isAppActive else { continue }
                await self.refresh(quiet: true)
            }
        }
    }

    private func refresh(quiet: Bool = false) async {
        guard bootState == .ready, let selection = sidebarSelection else { return }
        // With a live watch feeding the current list, quiet ticks only need
        // metrics; a full reconciliation re-list still happens once a minute.
        if quiet, case .resource(let kind) = selection,
           watcher.isRunning, watcher.spec?.kind == kind,
           Date().timeIntervalSince(lastListAt) < 60 {
            reloadNamespacesIfNeeded(force: false)
            await refreshMetrics(kind: kind, generationSnapshot: generation)
            return
        }
        generation += 1
        let gen = generation
        if !quiet { isLoading = true }
        reloadNamespacesIfNeeded(force: !quiet)

        do {
            switch selection {
            case .category:
                // Transient sidebar state; nothing to load.
                break
            case .overview:
                let data = try await OverviewService.load(context: selectedContext, namespace: selectedNamespace)
                guard gen == generation else { return }
                overview = data
            case .resource(let kind):
                let namespace = kind.isNamespaced ? selectedNamespace : nil
                let fetched: [KubeObject]
                if kind == .pods, let filter = podFilter {
                    fetched = try await Kubectl.pods(
                        matching: filter.selector,
                        isFieldSelector: filter.isFieldSelector,
                        namespace: namespace,
                        context: selectedContext
                    )
                } else {
                    fetched = try await Kubectl.list(kind: kind, context: selectedContext, namespace: namespace)
                }
                guard gen == generation else { return }
                lastListAt = Date()
                let sorted = Self.sort(fetched, kind: kind)
                // Same uids at the same resourceVersions → skip the assignment
                // so an idle cluster doesn't churn table identity every tick.
                if sorted != objects { objects = sorted }
                resolvePendingSelection(kind: kind)
                startWatchIfNeeded(kind: kind)
                await refreshMetrics(kind: kind, generationSnapshot: gen)
            case .helm:
                let releases = try await HelmService.listReleases(context: selectedContext, namespace: selectedNamespace)
                guard gen == generation else { return }
                helmReleases = releases
            }
            if gen == generation {
                lastError = nil
                lastRefreshed = Date()
            }
        } catch is CancellationError {
            return
        } catch {
            if gen == generation { lastError = error.localizedDescription }
        }
        if gen == generation { isLoading = false }
    }

    // MARK: Live watch

    private func startWatchIfNeeded(kind: ResourceKind) {
        let spec = KubectlWatcher.Spec(
            kind: kind,
            context: selectedContext,
            namespace: kind.isNamespaced ? selectedNamespace : nil,
            filter: kind == .pods ? podFilter : nil
        )
        if watcher.isRunning, watcher.spec == spec { return }
        // Repeated fast exits mean watch isn't viable here (RBAC, old
        // kubectl); polling continues to carry the view on its own.
        guard watchFailures < 3 else { return }
        watchStartedAt = Date()
        watcher.start(spec: spec, onEvents: { [weak self] upserts, deletes in
            self?.applyWatchEvents(spec: spec, upserts: upserts, deletes: deletes)
        }, onExit: { [weak self] in
            self?.watchExited(spec: spec)
        })
        isWatching = watcher.isRunning
    }

    private func applyWatchEvents(spec: KubectlWatcher.Spec, upserts: [KubeObject], deletes: [String]) {
        guard watcher.spec == spec, currentKind == spec.kind else { return }
        var byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for object in upserts { byID[object.id] = object }
        for id in deletes { byID.removeValue(forKey: id) }
        let updated = Self.sort(Array(byID.values), kind: spec.kind)
        if updated != objects {
            objects = updated
            lastRefreshed = Date()
        }
    }

    private func watchExited(spec: KubectlWatcher.Spec) {
        guard watcher.spec == spec else { return } // superseded or stopped deliberately
        isWatching = false
        if let started = watchStartedAt, Date().timeIntervalSince(started) < 10 {
            watchFailures += 1
        } else {
            watchFailures = 0 // it ran fine for a while; a drop is normal
        }
        // Re-list to reconcile anything missed; a successful refresh also
        // restarts the watch (unless it has struck out).
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard self.currentKind == spec.kind else { return }
            await self.refresh(quiet: true)
        }
    }

    private func resolvePendingSelection(kind: ResourceKind) {
        guard let pending = pendingSelection, pending.kind == kind else { return }
        pendingSelection = nil
        if let match = objects.first(where: { $0.name == pending.name && $0.namespace == pending.namespace }) {
            selectedObjectID = match.id
        }
    }

    private func refreshMetrics(kind: ResourceKind, generationSnapshot: Int) async {
        switch kind {
        case .pods:
            let metrics = (try? await Kubectl.podMetrics(context: selectedContext, namespace: selectedNamespace)) ?? [:]
            if generationSnapshot == generation { podMetrics = metrics }
        case .nodes:
            let usage = (try? await Kubectl.nodeMetrics(context: selectedContext)) ?? [:]
            if generationSnapshot == generation {
                nodeMetrics = Self.computeNodeMetrics(nodes: objects, usage: usage)
            }
        case .deployments, .statefulSets, .daemonSets, .replicaSets:
            async let podsFetch = Kubectl.list(kind: .pods, context: selectedContext, namespace: selectedNamespace)
            async let metricsFetch = Kubectl.podMetrics(context: selectedContext, namespace: selectedNamespace)
            let pods = (try? await podsFetch) ?? []
            let metrics = (try? await metricsFetch) ?? [:]
            if generationSnapshot == generation {
                workloadUsage = Self.computeWorkloadUsage(workloads: objects, pods: pods, metrics: metrics)
            }
        default:
            break
        }
    }

    /// Joins raw node usage with each node's allocatable capacity to produce
    /// the "250m (6%)" strings and percent bars the Nodes columns expect.
    private nonisolated static func computeNodeMetrics(
        nodes: [KubeObject],
        usage: [String: RawUsage]
    ) -> [String: NodeMetric] {
        var metrics: [String: NodeMetric] = [:]
        for node in nodes {
            guard let use = usage[node.name] else { continue }
            let allocatable = node.raw["status"]["allocatable"]
            metrics[node.name] = NodeMetric(
                cpu: Quantity.formatCPU(millicores: use.cpuMillis),
                cpuPercent: percentText(use.cpuMillis, of: Quantity.cpuMillicores(allocatable["cpu"].stringValue)),
                memory: Quantity.formatMemory(bytes: use.memoryBytes),
                memoryPercent: percentText(use.memoryBytes, of: Quantity.memoryBytes(allocatable["memory"].stringValue))
            )
        }
        return metrics
    }

    private nonisolated static func percentText(_ value: Double, of capacity: Double?) -> String {
        guard let capacity, capacity > 0 else { return "–" }
        return "\(Int((value / capacity * 100).rounded()))%"
    }

    /// Sums live pod metrics per workload by matching each workload's
    /// matchLabels selector against pod labels.
    private nonisolated static func computeWorkloadUsage(
        workloads: [KubeObject],
        pods: [KubeObject],
        metrics: [String: PodMetric]
    ) -> [String: WorkloadUsage] {
        var result: [String: WorkloadUsage] = [:]
        for workload in workloads {
            let selector = workload.raw["spec"]["selector"]["matchLabels"].stringDictionary
            guard !selector.isEmpty else { continue }
            var cpu = 0.0
            var memory = 0.0
            var count = 0
            var hasMetrics = false
            var restarts = 0
            var lastRestart: Date?
            for pod in pods where pod.namespace == workload.namespace {
                let labels = pod.labels
                guard selector.allSatisfy({ labels[$0.key] == $0.value }) else { continue }
                count += 1
                if let metric = metrics["\(pod.namespace)/\(pod.name)"] {
                    cpu += Quantity.cpuMillicores(metric.cpu) ?? 0
                    memory += Quantity.memoryBytes(metric.memory) ?? 0
                    hasMetrics = true
                }
                restarts += pod.raw["status"]["containerStatuses"].array.reduce(0) { $0 + ($1["restartCount"].int ?? 0) }
                if let restartDate = KindHelpers.podLastRestart(pod),
                   lastRestart.map({ restartDate > $0 }) ?? true {
                    lastRestart = restartDate
                }
            }
            if count > 0 {
                result["\(workload.namespace)/\(workload.name)"] = WorkloadUsage(
                    cpuMillis: cpu,
                    memoryBytes: memory,
                    podCount: count,
                    hasMetrics: hasMetrics,
                    restarts: restarts,
                    lastRestart: lastRestart
                )
            }
        }
        return result
    }

    private nonisolated static func sort(_ objects: [KubeObject], kind: ResourceKind) -> [KubeObject] {
        if kind == .events {
            return objects.sorted { (kind.ageDate($0) ?? .distantPast) > (kind.ageDate($1) ?? .distantPast) }
        }
        return objects.sorted {
            let result = $0.name.localizedCaseInsensitiveCompare($1.name)
            if result != .orderedSame { return result == .orderedAscending }
            return $0.namespace < $1.namespace
        }
    }

    // MARK: Filtering

    var filteredObjects: [KubeObject] {
        guard !searchText.isEmpty else { return objects }
        let query = searchText.lowercased()
        return objects.filter {
            $0.name.lowercased().contains(query) || $0.namespace.lowercased().contains(query)
        }
    }

    var filteredHelmReleases: [HelmRelease] {
        guard !searchText.isEmpty else { return helmReleases }
        let query = searchText.lowercased()
        return helmReleases.filter {
            $0.name.lowercased().contains(query)
                || $0.namespace.lowercased().contains(query)
                || $0.chartName.lowercased().contains(query)
        }
    }

    // MARK: Actions

    /// Opens the detail panel for an object on a specific tab.
    func openDetail(_ object: KubeObject, tab: String) {
        pendingDetailTab = tab
        selectedObjectID = object.id
    }

    func deleteObject(_ object: KubeObject, kind: ResourceKind) {
        Task {
            do {
                try await Kubectl.delete(
                    kind: kind,
                    name: object.name,
                    namespace: object.namespace.isEmpty ? nil : object.namespace,
                    context: self.selectedContext
                )
                self.requestRefresh()
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

    func restartObject(_ object: KubeObject, kind: ResourceKind) {
        Task {
            do {
                try await Kubectl.rolloutRestart(
                    kind: kind,
                    name: object.name,
                    namespace: object.namespace.isEmpty ? nil : object.namespace,
                    context: self.selectedContext
                )
                self.requestRefresh()
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

    func scaleObject(_ object: KubeObject, kind: ResourceKind, replicas: Int) {
        Task {
            do {
                try await Kubectl.scale(
                    kind: kind,
                    name: object.name,
                    namespace: object.namespace.isEmpty ? nil : object.namespace,
                    replicas: replicas,
                    context: self.selectedContext
                )
                self.requestRefresh()
            } catch {
                self.actionError = error.localizedDescription
            }
        }
    }

    /// Applies edited YAML; throws so the editor sheet can surface the error inline.
    func applyYAML(_ yaml: String) async throws -> String {
        let message = try await Kubectl.apply(yaml: yaml, context: selectedContext)
        requestRefresh()
        return message
    }
}
