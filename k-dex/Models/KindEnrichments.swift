import Foundation

// The curated presentation table: columns, icons, categories, and
// capabilities for the well-known kinds. Discovery provides identity for
// everything the cluster serves; kinds without an entry here get generic
// treatment.
nonisolated extension ResourceKind {
    // MARK: Shared column builders

    /// "ready/desired" replica badge used by Deployments and StatefulSets.
    private static func replicaReadyColumn() -> ColumnSpec {
        ColumnSpec("Ready", ideal: 60, max: 80, style: .badge) { obj, _ in
            let desired = obj.raw["spec"]["replicas"].int ?? 0
            let ready = obj.raw["status"]["readyReplicas"].int ?? 0
            let tone: StatusTone = desired == 0 ? .neutral : (ready >= desired ? .ok : (ready == 0 ? .bad : .warn))
            return Cell(text: "\(ready)/\(desired)", tone: tone)
        }
    }

    /// Live aggregated CPU/Memory bars shared by all pod-owning workloads.
    private static func workloadUsageColumns() -> [ColumnSpec] {
        [
            // Ideal = "888m"/"888Mi" text + gap + the fixed bar rail.
            ColumnSpec("CPU", ideal: 150, max: 190, style: .usage) { obj, ctx in
                KindHelpers.workloadUsageCell(obj, ctx, resource: "cpu")
            },
            ColumnSpec("Memory", ideal: 165, max: 205, style: .usage) { obj, ctx in
                KindHelpers.workloadUsageCell(obj, ctx, resource: "memory")
            },
        ]
    }

    /// Summed restart count + most recent restart, shared by workloads.
    private static func workloadRestartColumns() -> [ColumnSpec] {
        [
            ColumnSpec("Restarts", ideal: 60, max: 80) { obj, ctx in
                ctx.workloadUsage["\(obj.namespace)/\(obj.name)"].map { String($0.restarts) } ?? "–"
            },
            ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                guard let date = ctx.workloadUsage["\(obj.namespace)/\(obj.name)"]?.lastRestart else { return "–" }
                return Fmt.age(date, relativeTo: ctx.now) + " ago"
            },
        ]
    }

    private static func roleColumns() -> [ColumnSpec] {
        [
            ColumnSpec("Rules", ideal: 50, max: 70) { obj, _ in String(obj.raw["rules"].array.count) },
        ]
    }

    private static func bindingColumns() -> [ColumnSpec] {
        [
            ColumnSpec("Role", ideal: 180) { obj, _ in obj.raw["roleRef"]["name"].stringValue },
            ColumnSpec("Subjects", ideal: 200) { obj, _ in
                obj.raw["subjects"].array.map { "\($0["kind"].stringValue)/\($0["name"].stringValue)" }.joined(separator: ", ")
            },
        ]
    }

    private static func webhookColumns() -> [ColumnSpec] {
        [
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
    }

    // MARK: The table

    static let enrichments: [String: KindEnrichment] = {
        var t: [String: KindEnrichment] = [:]

        t[pods.id] = KindEnrichment(
            displayName: "Pods", icon: "cube", category: .workloads,
            supportsLogs: true, supportsPortForward: true,
            columns: [
                ColumnSpec("Ready", ideal: 55, max: 70, style: .badge) { obj, _ in
                    let counts = KindHelpers.podReadyCounts(obj)
                    let tone: StatusTone
                    if obj.raw["status"]["phase"].stringValue == "Succeeded" || counts.total == 0 {
                        tone = .neutral
                    } else if counts.ready >= counts.total {
                        tone = .ok
                    } else {
                        tone = counts.ready == 0 ? .bad : .warn
                    }
                    return Cell(text: "\(counts.ready)/\(counts.total)", tone: tone)
                },
                ColumnSpec("Status", ideal: 130, max: 190, style: .badge) { obj, _ in
                    let (text, tone) = KindHelpers.podStatus(obj)
                    return Cell(text: text, tone: tone)
                },
                ColumnSpec("Restarts", ideal: 70, max: 90) { obj, _ in
                    String(obj.raw["status"]["containerStatuses"].array.reduce(0) { $0 + ($1["restartCount"].int ?? 0) })
                },
                ColumnSpec("Last Restart", ideal: 84, max: 110) { obj, ctx in
                    guard let date = KindHelpers.podLastRestart(obj) else { return "–" }
                    return Fmt.age(date, relativeTo: ctx.now) + " ago"
                },
                ColumnSpec("CPU", ideal: 150, max: 190, style: .usage) { obj, ctx in
                    KindHelpers.podUsageCell(obj, ctx, resource: "cpu")
                },
                ColumnSpec("Memory", ideal: 165, max: 205, style: .usage) { obj, ctx in
                    KindHelpers.podUsageCell(obj, ctx, resource: "memory")
                },
                ColumnSpec("Node", ideal: 140) { obj, _ in obj.raw["spec"]["nodeName"].stringValue },
            ])

        t[deployments.id] = KindEnrichment(
            displayName: "Deployments", icon: "square.stack.3d.up", category: .workloads,
            supportsRestart: true, supportsScale: true, supportsPortForward: true, showsPods: true,
            columns: [
                replicaReadyColumn(),
                ColumnSpec("Up-to-date", ideal: 84, max: 104) { obj, _ in String(obj.raw["status"]["updatedReplicas"].int ?? 0) },
                ColumnSpec("Available", ideal: 76, max: 96) { obj, _ in String(obj.raw["status"]["availableReplicas"].int ?? 0) },
            ] + workloadUsageColumns() + workloadRestartColumns())

        t[statefulSets.id] = KindEnrichment(
            displayName: "Stateful Sets", icon: "list.number", category: .workloads,
            supportsRestart: true, supportsScale: true, supportsPortForward: true, showsPods: true,
            columns: [replicaReadyColumn()] + workloadUsageColumns() + workloadRestartColumns())

        t[daemonSets.id] = KindEnrichment(
            displayName: "Daemon Sets", icon: "circle.hexagongrid", category: .workloads,
            supportsRestart: true, supportsPortForward: true, showsPods: true,
            columns: [
                ColumnSpec("Desired", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["desiredNumberScheduled"].int ?? 0) },
                ColumnSpec("Ready", ideal: 55, max: 75, style: .badge) { obj, _ in
                    let desired = obj.raw["status"]["desiredNumberScheduled"].int ?? 0
                    let ready = obj.raw["status"]["numberReady"].int ?? 0
                    let tone: StatusTone = desired == 0 ? .neutral : (ready >= desired ? .ok : .warn)
                    return Cell(text: String(ready), tone: tone)
                },
                ColumnSpec("Up-to-date", ideal: 84, max: 104) { obj, _ in String(obj.raw["status"]["updatedNumberScheduled"].int ?? 0) },
                ColumnSpec("Available", ideal: 76, max: 96) { obj, _ in String(obj.raw["status"]["numberAvailable"].int ?? 0) },
            ] + workloadUsageColumns() + workloadRestartColumns())

        t[replicaSets.id] = KindEnrichment(
            displayName: "Replica Sets", icon: "square.on.square", category: .workloads,
            supportsScale: true, supportsPortForward: true, showsPods: true,
            columns: [
                ColumnSpec("Desired", ideal: 55, max: 75) { obj, _ in String(obj.raw["spec"]["replicas"].int ?? 0) },
                ColumnSpec("Current", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["replicas"].int ?? 0) },
                ColumnSpec("Ready", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["readyReplicas"].int ?? 0) },
            ] + workloadRestartColumns())

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
                ColumnSpec("Status", ideal: 90, max: 120, style: .badge) { obj, _ in
                    let (text, tone) = KindHelpers.jobStatus(obj)
                    return Cell(text: text, tone: tone)
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
                ColumnSpec("Healthy", ideal: 66, max: 86, style: .badge) { obj, _ in
                    let healthy = obj.raw["status"]["currentHealthy"].int ?? 0
                    let desired = obj.raw["status"]["desiredHealthy"].int ?? 0
                    let tone: StatusTone = desired == 0 ? .neutral : (healthy >= desired ? .ok : .warn)
                    return Cell(text: "\(healthy)/\(desired)", tone: tone)
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

        t[mutatingWebhookConfigurations.id] = KindEnrichment(
            displayName: "Mutating Webhooks", icon: "arrow.triangle.swap", category: .config,
            visibleByDefault: false, columns: webhookColumns())
        t[validatingWebhookConfigurations.id] = KindEnrichment(
            displayName: "Validating Webhooks", icon: "checkmark.shield", category: .config,
            visibleByDefault: false, columns: webhookColumns())

        t[persistentVolumeClaims.id] = KindEnrichment(
            displayName: "Volume Claims", icon: "externaldrive", category: .storage,
            columns: [
                ColumnSpec("Status", ideal: 80, max: 110, style: .badge) { obj, _ in
                    Cell(
                        text: obj.isTerminating ? "Terminating" : obj.raw["status"]["phase"].stringValue,
                        tone: KindHelpers.pvcTone(obj)
                    )
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
                ColumnSpec("Status", ideal: 80, max: 110, style: .badge) { obj, _ in
                    Cell(text: obj.raw["status"]["phase"].stringValue, tone: KindHelpers.pvTone(obj))
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

        t[roles.id] = KindEnrichment(
            displayName: "Roles", icon: "person.text.rectangle", category: .access, columns: roleColumns())
        t[roleBindings.id] = KindEnrichment(
            displayName: "Role Bindings", icon: "link", category: .access, columns: bindingColumns())
        t[clusterRoles.id] = KindEnrichment(
            displayName: "Cluster Roles", icon: "person.2.badge.gearshape", category: .access, columns: roleColumns())
        t[clusterRoleBindings.id] = KindEnrichment(
            displayName: "Cluster Role Bindings", icon: "link.circle", category: .access, columns: bindingColumns())

        t[certificateSigningRequests.id] = KindEnrichment(
            displayName: "CSRs", icon: "signature", category: .access,
            visibleByDefault: false,
            columns: [
                ColumnSpec("Signer", ideal: 220) { obj, _ in obj.raw["spec"]["signerName"].stringValue },
                ColumnSpec("Requestor", ideal: 160) { obj, _ in obj.raw["spec"]["username"].stringValue },
                ColumnSpec("Status", ideal: 110, max: 140, style: .badge) { obj, _ in
                    let (text, tone) = KindHelpers.csrStatus(obj)
                    return Cell(text: text, tone: tone)
                },
            ])

        t[nodes.id] = KindEnrichment(
            displayName: "Nodes", icon: "server.rack", category: .cluster,
            columns: [
                ColumnSpec("Status", ideal: 90, max: 160, style: .badge) { obj, _ in
                    let (text, tone) = KindHelpers.nodeStatus(obj)
                    return Cell(text: text, tone: tone)
                },
                ColumnSpec("Roles", ideal: 110, max: 160) { obj, _ in KindHelpers.nodeRoles(obj) },
                ColumnSpec("Version", ideal: 90, max: 130) { obj, _ in obj.raw["status"]["nodeInfo"]["kubeletVersion"].stringValue },
                // Wider than the workload columns: node text carries a
                // percent suffix ("888m (88%)") beside the same bar rail.
                ColumnSpec("CPU", ideal: 195, max: 235, style: .usage) { obj, ctx in
                    guard let m = ctx.nodeMetrics[obj.name] else {
                        return Cell(text: "–", fallback: ctx.metricsStatus)
                    }
                    return Cell(
                        text: "\(m.cpu) (\(m.cpuPercent))",
                        usage: KindHelpers.percentFraction(m.cpuPercent).map { UsageValue(fraction: $0, bounded: true) },
                        detail: KindHelpers.nodeCapacityDetail(obj, resource: "cpu")
                    )
                },
                ColumnSpec("Memory", ideal: 210, max: 245, style: .usage) { obj, ctx in
                    guard let m = ctx.nodeMetrics[obj.name] else {
                        return Cell(text: "–", fallback: ctx.metricsStatus)
                    }
                    return Cell(
                        text: "\(m.memory) (\(m.memoryPercent))",
                        usage: KindHelpers.percentFraction(m.memoryPercent).map { UsageValue(fraction: $0, bounded: true) },
                        detail: KindHelpers.nodeCapacityDetail(obj, resource: "memory")
                    )
                },
            ])

        t[namespaces.id] = KindEnrichment(
            displayName: "Namespaces", icon: "folder", category: .cluster,
            columns: [
                ColumnSpec("Status", ideal: 80, max: 110, style: .badge) { obj, _ in
                    let phase = obj.raw["status"]["phase"].stringValue
                    return Cell(text: phase, tone: phase == "Active" ? .ok : .warn)
                },
            ])

        t[events.id] = KindEnrichment(
            displayName: "Events", icon: "bell", category: .cluster,
            columns: [
                ColumnSpec("Type", ideal: 70, max: 90, style: .badge) { obj, _ in
                    let type = obj.raw["type"].stringValue
                    return Cell(text: type, tone: type == "Warning" ? .warn : .neutral)
                },
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

        // MARK: Deprecated / legacy core kinds — live in Other, visible by
        // default (they're real cluster objects, just superseded ones). Keyed
        // by discovered id; they are not part of the builtin seed.

        t["endpoints"] = KindEnrichment(
            displayName: "Endpoints", icon: "smallcircle.filled.circle", category: .other,
            columns: [
                ColumnSpec("Endpoints", ideal: 240) { obj, _ in
                    var entries: [String] = []
                    for subset in obj.raw["subsets"].array {
                        let port = subset["ports"].array.first?["port"].displayString
                        for address in subset["addresses"].array {
                            let ip = address["ip"].stringValue
                            entries.append(port.map { "\(ip):\($0)" } ?? ip)
                        }
                    }
                    guard !entries.isEmpty else { return "<none>" }
                    let shown = entries.prefix(3).joined(separator: ", ")
                    return entries.count > 3 ? "\(shown) +\(entries.count - 3) more" : shown
                },
            ])

        t["replicationcontrollers"] = KindEnrichment(
            displayName: "Replication Controllers", icon: "rectangle.on.rectangle", category: .other,
            columns: [
                ColumnSpec("Desired", ideal: 55, max: 75) { obj, _ in String(obj.raw["spec"]["replicas"].int ?? 0) },
                ColumnSpec("Current", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["replicas"].int ?? 0) },
                ColumnSpec("Ready", ideal: 55, max: 75) { obj, _ in String(obj.raw["status"]["readyReplicas"].int ?? 0) },
            ])

        t["podtemplates"] = KindEnrichment(
            displayName: "Pod Templates", icon: "doc.on.doc", category: .other)

        t["componentstatuses"] = KindEnrichment(
            displayName: "Component Statuses", icon: "waveform.path.ecg", category: .other,
            columns: [
                ColumnSpec("Status", ideal: 90, max: 130, style: .badge) { obj, _ in
                    let healthy = obj.raw["conditions"].array.first { $0["type"].stringValue == "Healthy" }
                    let ok = healthy?["status"].stringValue == "True"
                    return Cell(text: ok ? "Healthy" : "Unhealthy", tone: ok ? .ok : .bad)
                },
                ColumnSpec("Message", ideal: 220) { obj, _ in
                    obj.raw["conditions"].array.first { $0["type"].stringValue == "Healthy" }?["message"].stringValue ?? ""
                },
            ])

        // Bake the trailing Age column in once, so `columns` is a plain
        // stored-array lookup at render/sort time.
        for (id, var enrichment) in t {
            enrichment.columns.append(id == events.id ? eventAgeColumn : ageColumn)
            t[id] = enrichment
        }
        return t
    }()
}
