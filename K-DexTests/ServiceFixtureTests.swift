import Foundation
import Testing
@testable import K_Dex

/// A CommandRunning that answers from canned fixtures and records every
/// invocation — no kubectl, no cluster. Returning nil from the responder
/// yields a nonzero exit ("no fixture"), which services must tolerate the
/// same way they tolerate a real kubectl failure.
private final class FixtureRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [[String]] = []
    private let respond: @Sendable ([String]) -> ProcessResult?

    init(_ respond: @escaping @Sendable ([String]) -> ProcessResult?) {
        self.respond = respond
    }

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> ProcessResult {
        record([executable] + arguments)
        return respond(arguments)
            ?? ProcessResult(stdout: Data(), stderr: Data("no fixture for \(arguments)".utf8), exitCode: 1)
    }

    /// Synchronous on purpose: Swift 6 forbids NSLock inside async bodies
    /// (a suspension inside the critical section would deadlock); a sync
    /// method can't suspend, which proves the safety instead of assuming it.
    private func record(_ call: [String]) {
        lock.lock()
        invocations.append(call)
        lock.unlock()
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return invocations
    }
}

private func ok(_ stdout: String) -> ProcessResult {
    ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), exitCode: 0)
}

private func fail(_ stderr: String) -> ProcessResult {
    ProcessResult(stdout: Data(), stderr: Data(stderr.utf8), exitCode: 1)
}

/// Swaps the process-wide runner for the duration of `body`. The suite is
/// `.serialized` because `Commands.runner` is one global knob.
@discardableResult
private func withRunner<T>(_ runner: FixtureRunner, _ body: () async throws -> T) async rethrows -> T {
    let previous = Commands.runner
    Commands.runner = runner
    defer { Commands.runner = previous }
    return try await body()
}

// Service-level tests over the Commands.runner seam: real parsing and
// aggregation code, fixture subprocess output.
@Suite(.serialized)
struct ServiceFixtureTests {
    // MARK: Kubectl

    @Test func contextsParseAndSort() async throws {
        let runner = FixtureRunner { args in
            guard args.first == "config" else { return nil }
            return ok("""
            {"current-context": "minikube",
             "contexts": [
               {"name": "prod", "context": {"cluster": "prod-cluster", "user": "admin"}},
               {"name": "minikube", "context": {"cluster": "mk", "user": "mk", "namespace": "default"}}
             ]}
            """)
        }
        let (current, contexts) = try await withRunner(runner) { try await Kubectl.contexts() }
        #expect(current == "minikube")
        #expect(contexts.map(\.name) == ["minikube", "prod"]) // sorted
        #expect(contexts[0].defaultNamespace == "default")
        #expect(contexts[1].cluster == "prod-cluster")
    }

    @Test func listDecodesObjectsAndBuildsArgs() async throws {
        let runner = FixtureRunner { args in
            guard args.first == "get" else { return nil }
            return ok("""
            {"items": [
              {"metadata": {"name": "web", "namespace": "demo", "uid": "u1"}},
              {"metadata": {"name": "db", "namespace": "demo", "uid": "u2"}}
            ]}
            """)
        }
        let objects = try await withRunner(runner) {
            try await Kubectl.list(kind: .pods, context: "test", namespace: "demo")
        }
        #expect(objects.map(\.name) == ["web", "db"])
        #expect(objects[0].uid == "u1")
        #expect(runner.calls == [["kubectl", "get", "pods", "-o", "json", "--context", "test", "-n", "demo"]])
    }

    /// Batch actions: one kubectl call for a whole namespace group, never a
    /// subprocess per object (round 3, B1).
    @Test func batchDeleteIsOneInvocation() async throws {
        let runner = FixtureRunner { _ in ok("") }
        try await withRunner(runner) {
            try await Kubectl.delete(kind: .pods, names: ["a", "b", "c"], namespace: "demo", context: "test")
        }
        #expect(runner.calls == [["kubectl", "delete", "pods", "a", "b", "c", "--context", "test", "-n", "demo"]])
    }

    @Test func batchRestartIsOneInvocation() async throws {
        let runner = FixtureRunner { _ in ok("") }
        try await withRunner(runner) {
            try await Kubectl.rolloutRestart(kind: .deployments, names: ["x", "y"], namespace: "demo", context: "test")
        }
        #expect(runner.calls == [[
            "kubectl", "rollout", "restart",
            "deployments.apps/x", "deployments.apps/y",
            "--context", "test", "-n", "demo",
        ]])
    }

    @Test func emptyBatchSpawnsNothing() async throws {
        let runner = FixtureRunner { _ in ok("") }
        try await withRunner(runner) {
            try await Kubectl.delete(kind: .pods, names: [], namespace: "demo", context: "test")
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func scaleBuildsTheExpectedInvocation() async throws {
        let runner = FixtureRunner { _ in ok("") }
        try await withRunner(runner) {
            try await Kubectl.scale(kind: .deployments, name: "web", namespace: "demo", replicas: 3, context: "test")
        }
        #expect(runner.calls == [[
            "kubectl", "scale", "deployments.apps/web",
            "--replicas", "3", "--context", "test", "-n", "demo",
        ]])
    }

    // MARK: Metrics classification (the MetricsStatus pipeline end to end)

    @Test func podMetricsParseAndFormat() async throws {
        let runner = FixtureRunner { args in
            guard args.contains("--raw") else { return nil }
            return ok("""
            {"items": [{
              "metadata": {"name": "web", "namespace": "demo"},
              "containers": [
                {"usage": {"cpu": "2013912n", "memory": "71680Ki"}},
                {"usage": {"cpu": "1000000n", "memory": "1024Ki"}}
              ]
            }]}
            """)
        }
        let (metrics, status) = await withRunner(runner) {
            await Kubectl.podMetricsResult(context: "test", namespace: nil)
        }
        #expect(status == .available)
        let metric = try #require(metrics["demo/web"])
        #expect(metric.cpu == "3m")     // 2.01m + 1m, summed then formatted
        #expect(metric.memory == "71Mi") // 70Mi + 1Mi
    }

    @Test func missingMetricsAPIClassifiesAsNotInstalled() async throws {
        let runner = FixtureRunner { _ in
            fail("Error from server (NotFound): the server could not find the requested resource")
        }
        let (metrics, status) = await withRunner(runner) {
            await Kubectl.podMetricsResult(context: "test", namespace: nil)
        }
        #expect(metrics.isEmpty)
        #expect(status == .notInstalled)
    }

    @Test func forbiddenMetricsClassifiesAsForbidden() async throws {
        let runner = FixtureRunner { _ in
            fail(#"Error from server (Forbidden): pods.metrics.k8s.io is forbidden: User "x" cannot list resource "pods" in API group "metrics.k8s.io""#)
        }
        let (_, status) = await withRunner(runner) {
            await Kubectl.podMetricsResult(context: "test", namespace: nil)
        }
        #expect(status == .forbidden)
    }

    @Test func unknownFailureCarriesTheRawStderr() async throws {
        let runner = FixtureRunner { _ in fail("dial tcp: connection refused") }
        let (_, status) = await withRunner(runner) {
            await Kubectl.podMetricsResult(context: "test", namespace: nil)
        }
        #expect(status == .failed("dial tcp: connection refused"))
    }

    // MARK: OverviewService aggregation

    @Test func overviewAggregatesPodsAndReportsMetricsReason() async throws {
        let runner = FixtureRunner { args in
            if args.contains("--raw") {
                return fail("Error from server (NotFound): the server could not find the requested resource")
            }
            if args.count > 1, args[1] == "pods" {
                return ok("""
                {"items": [
                  {"metadata": {"name": "a", "namespace": "demo", "uid": "a"},
                   "status": {"phase": "Running",
                              "containerStatuses": [{"ready": true, "restartCount": 0, "state": {"running": {}}}]},
                   "spec": {"containers": [{"name": "c"}]}},
                  {"metadata": {"name": "b", "namespace": "demo", "uid": "b"},
                   "status": {"phase": "Pending"},
                   "spec": {"containers": [{"name": "c"}]}}
                ]}
                """)
            }
            return nil // every other list degrades softly, like partial RBAC
        }
        let data = try await withRunner(runner) {
            try await OverviewService.load(context: "test", namespace: nil)
        }
        #expect(data.metricsStatus == .notInstalled)
        #expect(data.hotPods.isEmpty)
        let podSummary = try #require(data.summaries.first { $0.kind == .pods })
        #expect(podSummary.total == 2)
        #expect(podSummary.buckets.reduce(0) { $0 + $1.count } == 2)
    }

    /// The finding-5 property: an unreachable cluster must throw, not render
    /// a confident all-zeros dashboard.
    @Test func overviewPropagatesPodListFailure() async throws {
        let runner = FixtureRunner { _ in fail("Unable to connect to the server: dial tcp: lookup nope") }
        await withRunner(runner) {
            await #expect(throws: ProcessError.self) {
                _ = try await OverviewService.load(context: "test", namespace: nil)
            }
        }
    }

    // MARK: runChecked semantics

    @Test func runCheckedFiltersWarningsButKeepsRealErrors() async throws {
        let runner = FixtureRunner { _ in
            fail("Warning: v1 ComponentStatus is deprecated\nerror: the real problem")
        }
        await withRunner(runner) {
            do {
                _ = try await Commands.runner.runChecked("kubectl", ["get", "x"])
                Issue.record("expected a throw")
            } catch let ProcessError.failed(_, _, stderr) {
                #expect(stderr == "error: the real problem")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test func runCheckedKeepsAllWarningStderrWhenNothingElseExplains() async throws {
        let runner = FixtureRunner { _ in fail("Warning: only warnings here") }
        await withRunner(runner) {
            do {
                _ = try await Commands.runner.runChecked("kubectl", ["get", "x"])
                Issue.record("expected a throw")
            } catch let ProcessError.failed(_, _, stderr) {
                #expect(stderr == "Warning: only warnings here")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }
}
