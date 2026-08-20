import Foundation
import Testing
@testable import K_Dex

// Pins the app's own cluster memory, whose whole point is to stop deferring to
// the kubeconfig's current-context. The distinction that matters: a cluster
// never visited ("unset") must fall through to the kubeconfig's default
// namespace, while an explicit All Namespaces choice must override it — both
// are stored as an empty-ish value, so only the API keeps them apart.
struct ClusterStateStoreTests {
    /// One key per test: the suite runs in parallel against the single real
    /// UserDefaults domain, so a shared context name let one test's cleanup
    /// delete another's value mid-assertion.
    private func freshContext(_ name: String) -> String {
        let context = "k-dex-test-\(name)"
        UserDefaults.standard.removeObject(forKey: "cluster-namespace-\(context)")
        return context
    }

    private func cleanUp(_ context: String) {
        UserDefaults.standard.removeObject(forKey: "cluster-namespace-\(context)")
    }

    @Test func neverVisitedContextIsUnset() {
        let context = freshContext("unvisited")
        #expect(ClusterStateStore.namespace(for: context) == .unset)
        #expect(ClusterStateStore.namespace(for: "") == .unset)
    }

    @Test func allNamespacesIsStoredAsAChoiceNotAsAbsence() {
        let context = freshContext("all-namespaces")
        ClusterStateStore.store(namespace: nil, for: context)
        #expect(ClusterStateStore.namespace(for: context) == .all)
        cleanUp(context)
    }

    @Test func namedNamespaceRoundTrips() {
        let context = freshContext("named")
        ClusterStateStore.store(namespace: "kube-system", for: context)
        #expect(ClusterStateStore.namespace(for: context) == .named("kube-system"))
        #expect(ClusterStateStore.namespace(for: context).name == "kube-system")
        // Re-picking All Namespaces replaces it rather than reverting to unset.
        ClusterStateStore.store(namespace: nil, for: context)
        #expect(ClusterStateStore.namespace(for: context) == .all)
        cleanUp(context)
    }

    /// Serialized against the other tests only by using its own key; the
    /// user's real last-context value is restored either way.
    @Test func lastContextRoundTripsAndClears() {
        let original = ClusterStateStore.lastContext
        let context = freshContext("last-used")
        ClusterStateStore.lastContext = context
        #expect(ClusterStateStore.lastContext == context)
        ClusterStateStore.lastContext = nil
        #expect(ClusterStateStore.lastContext == nil)
        ClusterStateStore.lastContext = original
        cleanUp(context)
    }
}
