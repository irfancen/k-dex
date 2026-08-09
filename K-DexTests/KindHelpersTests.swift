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
}
