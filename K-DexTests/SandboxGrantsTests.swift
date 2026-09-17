import Foundation
import Testing
@testable import K_Dex

// The grant arithmetic, which decides how many panels a user answers before
// their cluster works. Bookmarks themselves need a real user grant to create,
// so what is pinned here is the pure part: which single directory covers a
// set of files.
struct SandboxGrantsTests {
    @Test func minikubesTwoDirectoriesCollapseIntoOnePrompt() {
        // The case that motivates asking for an ancestor at all: a CA beside
        // the profile directory holding the client pair.
        let ancestor = SandboxGrants.commonAncestor(of: [
            "/Users/someone/.minikube/ca.crt",
            "/Users/someone/.minikube/profiles/minikube/client.crt",
            "/Users/someone/.minikube/profiles/minikube/client.key",
        ])
        #expect(ancestor?.path == "/Users/someone/.minikube")
    }

    @Test func filesInOneDirectoryAskForThatDirectory() {
        let ancestor = SandboxGrants.commonAncestor(of: [
            "/Users/someone/.kube/ca.crt",
            "/Users/someone/.kube/client.crt",
        ])
        #expect(ancestor?.path == "/Users/someone/.kube")
    }

    @Test func aSingleFileAsksForItsOwnDirectory() {
        #expect(SandboxGrants.commonAncestor(of: ["/Users/someone/.minikube/ca.crt"])?.path
            == "/Users/someone/.minikube")
    }

    @Test func nothingToCoverIsNoPrompt() {
        #expect(SandboxGrants.commonAncestor(of: []) == nil)
    }

    @Test func unrelatedTreesDoNotResolveToTheWholeDisk() {
        // Two certificates with nothing in common would otherwise produce a
        // prompt for "/", which macOS refuses and which no user should be
        // asked for regardless.
        #expect(SandboxGrants.commonAncestor(of: ["/etc/ssl/ca.crt", "/opt/certs/client.crt"]) == nil)
    }

    @Test func homeLevelSiblingsStillCollapseToHome() {
        let ancestor = SandboxGrants.commonAncestor(of: [
            "/Users/someone/.kube/ca.crt",
            "/Users/someone/.minikube/client.crt",
        ])
        #expect(ancestor?.path == "/Users/someone")
    }
}
