import Foundation
import Testing
@testable import K_Dex

// Pins the resource-summing and cell-text helpers behind the usage columns,
// using real JSON fixtures decoded the same way cluster output is.
struct KindHelpersTests {
    private func object(_ json: String) throws -> KubeObject {
        KubeObject(raw: try KubeJSON.decode(Data(json.utf8)))
    }

    private let workload = """
    {
      "metadata": {"name": "web", "namespace": "demo", "uid": "u1"},
      "spec": {
        "template": {
          "spec": {
            "containers": [
              {"name": "app", "resources": {"requests": {"cpu": "50m", "memory": "64Mi"},
                                            "limits": {"cpu": "200m", "memory": "128Mi"}}},
              {"name": "sidecar", "resources": {"requests": {"cpu": "10m"},
                                                "limits": {"memory": "32Mi"}}}
            ]
          }
        }
      }
    }
    """

    @Test func sumsResourcesAcrossContainers() throws {
        let containers = try KubeJSON.decode(Data(workload.utf8))["spec"]["template"]["spec"]["containers"].array
        // Requests: 50m + 10m CPU; 64Mi memory (sidecar declares none).
        #expect(KindHelpers.summedRawResource(containers, section: "requests", resource: "cpu") == 60)
        #expect(KindHelpers.summedRawResource(containers, section: "requests", resource: "memory") == 67_108_864)
        // Limits: 200m CPU (sidecar none); 128Mi + 32Mi memory.
        #expect(KindHelpers.summedRawResource(containers, section: "limits", resource: "cpu") == 200)
        #expect(KindHelpers.summedRawResource(containers, section: "limits", resource: "memory") == 167_772_160)
    }

    @Test func summedResourceIsNilWhenNothingDeclared() throws {
        let containers = try KubeJSON.decode(Data(#"{"spec":{"containers":[{"name":"a"}]}}"#.utf8))["spec"]["containers"].array
        #expect(KindHelpers.summedRawResource(containers, section: "requests", resource: "cpu") == nil)
    }

    @Test func templateResourcesRendersRequestSlashLimit() throws {
        let obj = try object(workload)
        #expect(KindHelpers.templateResources(obj, resource: "cpu") == "60m / 200m")
        #expect(KindHelpers.templateResources(obj, resource: "memory") == "64Mi / 160Mi")
    }

    @Test func templateResourcesDashesWhenUnspecified() throws {
        let obj = try object(#"{"metadata":{"name":"x"},"spec":{"template":{"spec":{"containers":[{"name":"a"}]}}}}"#)
        #expect(KindHelpers.templateResources(obj, resource: "cpu") == "–")
    }

    @Test func usageWithLimitCoversAllCombinations() {
        #expect(KindHelpers.usageWithLimit(usage: nil, limit: nil) == "–")
        #expect(KindHelpers.usageWithLimit(usage: "5m", limit: nil) == "5m")
        #expect(KindHelpers.usageWithLimit(usage: nil, limit: "100m") == "– / 100m")
        #expect(KindHelpers.usageWithLimit(usage: "5m", limit: "100m") == "5m / 100m")
    }

    @Test func percentFractionParses() {
        #expect(KindHelpers.percentFraction("45%") == 0.45)
        #expect(KindHelpers.percentFraction("100%") == 1.0)
        #expect(KindHelpers.percentFraction("2") == 0.02)
        #expect(KindHelpers.percentFraction("n/a") == nil)
    }

    @Test func nodeCapacityDetailFormatsAllocatableAndCapacity() throws {
        let node = try object("""
        {
          "metadata": {"name": "node-1"},
          "status": {
            "allocatable": {"cpu": "7910m", "memory": "15Gi"},
            "capacity": {"cpu": "8", "memory": "16Gi"}
          }
        }
        """)
        #expect(KindHelpers.nodeCapacityDetail(node, resource: "cpu") == "Allocatable 7.9 · Capacity 8")
        #expect(KindHelpers.nodeCapacityDetail(node, resource: "memory") == "Allocatable 15Gi · Capacity 16Gi")
    }

    @Test func nodeCapacityDetailNilWithoutStatus() throws {
        let node = try object(#"{"metadata":{"name":"node-1"}}"#)
        #expect(KindHelpers.nodeCapacityDetail(node, resource: "cpu") == nil)
    }

    /// The `.text(…)` column factory: strings verbatim, numbers via
    /// displayString, missing paths as empty text.
    @Test func textColumnFactoryWalksJSONPaths() throws {
        let obj = try object(#"{"metadata":{"name":"x"},"spec":{"type":"ClusterIP","replicas":3}}"#)
        let ctx = RowContext()
        #expect(ColumnSpec.text("Type", "spec", "type").cell(obj, ctx).text == "ClusterIP")
        #expect(ColumnSpec.text("Replicas", "spec", "replicas").cell(obj, ctx).text == "3")
        #expect(ColumnSpec.text("Missing", "spec", "nope").cell(obj, ctx).text == "")
    }
}

// Pins the denominator behind usage bars whose row declares neither a request
// nor a limit: a fixed one vCPU / one Gi per pod. The old rule barred them
// against the busiest row's live usage, which on an idle list made a 1m pod
// fill a quarter of the rail while a spec'd pod at 3% of its request showed a
// dot — two different meanings in one column.
struct AssumedLimitTests {
    private func object(_ json: String) throws -> KubeObject {
        KubeObject(raw: try KubeJSON.decode(Data(json.utf8)))
    }

    private func pod(_ name: String, requests: String? = nil, limits: String? = nil) throws -> KubeObject {
        var resources: [String] = []
        if let requests { resources.append("\"requests\": \(requests)") }
        if let limits { resources.append("\"limits\": \(limits)") }
        return try object("""
        {
          "metadata": {"name": "\(name)", "namespace": "demo", "uid": "\(name)"},
          "spec": {"containers": [{"name": "app", "resources": {\(resources.joined(separator: ", "))}}]},
          "status": {"phase": "Running"}
        }
        """)
    }

    private func context(cpu: String, memory: String, pod name: String = "unspecd") -> RowContext {
        var ctx = RowContext()
        ctx.podMetrics = ["demo/\(name)": PodMetric(cpu: cpu, memory: memory)]
        return ctx
    }

    @Test func unspecdPodBarsAgainstOneVCPU() throws {
        let cell = KindHelpers.podUsageCell(
            try pod("unspecd"), context(cpu: "250m", memory: "512Mi"), resource: "cpu"
        )
        #expect(cell.usage?.fraction == 0.25)
        // Neutral, not threshold-colored: nothing promised this ceiling.
        #expect(cell.usage?.bounded == false)
        #expect(cell.detail?.hasPrefix("25% of 1 vCPU · Request not set · Limit not set") == true)
    }

    @Test func unspecdPodBarsAgainstOneGi() throws {
        let cell = KindHelpers.podUsageCell(
            try pod("unspecd"), context(cpu: "250m", memory: "512Mi"), resource: "memory"
        )
        #expect(cell.usage?.fraction == 0.5)
        #expect(cell.detail?.hasPrefix("50% of 1Gi") == true)
    }

    /// A tiny reading on an idle cluster must read as tiny — the regression
    /// that started this: 1m of usage filling a quarter of the rail.
    @Test func idleUsageStaysNearEmpty() throws {
        let cell = KindHelpers.podUsageCell(
            try pod("idle"), context(cpu: "1m", memory: "4Mi", pod: "idle"), resource: "cpu"
        )
        #expect(cell.usage?.fraction == 0.001)
        #expect(cell.detail?.hasPrefix("0% of 1 vCPU") == true)
    }

    @Test func declaredRequestStillWinsOverTheAssumption() throws {
        let cell = KindHelpers.podUsageCell(
            try pod("requested", requests: "{\"cpu\": \"100m\"}"),
            context(cpu: "50m", memory: "10Mi", pod: "requested"),
            resource: "cpu"
        )
        #expect(cell.usage?.fraction == 0.5)
        #expect(cell.usage?.bounded == true)
        #expect(cell.detail == "Request 100m · Limit not set")
    }

    @Test func workloadAssumesOneVCPUPerPod() throws {
        let deployment = try object("""
        {
          "metadata": {"name": "web", "namespace": "demo", "uid": "u1"},
          "spec": {"selector": {"matchLabels": {"app": "web"}}, "template": {"spec": {"containers": [{"name": "app"}]}}}
        }
        """)
        var ctx = RowContext()
        ctx.workloadUsage = ["demo/web": WorkloadUsage(
            cpuMillis: 600, memoryBytes: 0, podCount: 3, hasMetrics: true, restarts: 0, lastRestart: nil
        )]
        let cell = KindHelpers.workloadUsageCell(deployment, ctx, resource: "cpu")
        // 600m summed over 3 pods, against 1 vCPU each.
        #expect(cell.usage?.fraction == 0.2)
        #expect(cell.detail?.hasPrefix("20% of 1 vCPU per pod") == true)
    }
}
