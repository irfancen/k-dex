import Foundation

/// The directories the user has let this app read, held as security-scoped
/// bookmarks so the permission survives relaunch.
///
/// Grants are taken on **directories, not files**. A kubeconfig names
/// certificates that rotate — minikube rewrites its client pair on every
/// `minikube start` — and a file grant would go stale the moment one is
/// replaced, leaving the user to re-pick a file they already chose. A
/// directory grant covers whatever the config points at next.
nonisolated enum SandboxGrants {
    private static let key = "sandbox-grants"

    /// Resolving a bookmark yields a URL that only works between
    /// `startAccessingSecurityScopedResource` and its stop. Callers take the
    /// whole set for the length of one mirror pass rather than per file.
    struct Access {
        let urls: [URL]

        func stop() {
            for url in urls { url.stopAccessingSecurityScopedResource() }
        }
    }

    // MARK: Storage

    static func record(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var all = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        // Re-granting the same directory replaces rather than appends, or the
        // list grows every time the user answers a prompt twice.
        all.removeAll { existing in resolve(existing)?.path == url.path }
        all.append(data)
        UserDefaults.standard.set(all, forKey: key)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        // A stale bookmark still resolves; it just needs rewriting, which
        // requires access we may not hold yet. Report it and let the next
        // successful pass refresh it rather than dropping the grant here.
        return url
    }

    /// Every granted directory, dropping bookmarks that no longer resolve
    /// (the directory was deleted, or the grant was revoked in System
    /// Settings).
    static func grantedDirectories() -> [URL] {
        (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).compactMap(resolve)
    }

    // MARK: Coverage

    /// Whether some grant already reaches this path, so the user is not asked
    /// again for a directory they have already opened up.
    static func covers(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return grantedDirectories().contains { granted in
            let components = granted.standardizedFileURL.pathComponents
            guard components.count <= target.count else { return false }
            return Array(target.prefix(components.count)) == components
        }
    }

    /// The directory to ask for, given files that no grant reaches yet: their
    /// deepest common ancestor.
    ///
    /// minikube is the case that motivates this — `~/.minikube/ca.crt` and
    /// `~/.minikube/profiles/<name>/client.crt` would otherwise be two
    /// prompts, and asking for `~/.minikube` once covers both, plus whatever
    /// the next profile adds.
    static func commonAncestor(of paths: [String]) -> URL? {
        guard let first = paths.first else { return nil }
        var shared = URL(fileURLWithPath: first).standardizedFileURL
            .deletingLastPathComponent().pathComponents

        for path in paths.dropFirst() {
            let components = URL(fileURLWithPath: path).standardizedFileURL
                .deletingLastPathComponent().pathComponents
            var index = 0
            while index < shared.count, index < components.count, shared[index] == components[index] {
                index += 1
            }
            shared = Array(shared.prefix(index))
        }

        // "/" alone is not a useful thing to ask the user to grant, and macOS
        // would refuse it anyway.
        guard shared.count > 1 else { return nil }
        return URL(fileURLWithPath: "/" + shared.dropFirst().joined(separator: "/"))
    }

    // MARK: Access

    /// Grants currently open, keyed by path so `activate` is idempotent.
    @MainActor private static var active: [String: URL] = [:]

    /// Opens every grant and **keeps** it open.
    ///
    /// Scoping access to a single operation was wrong: a resolved
    /// security-scoped URL only works between start and stop, and the
    /// kubeconfig file watch holds a descriptor across the whole session. With
    /// per-pass access the watch's `open(…, O_EVTONLY)` failed outside that
    /// window and retried forever, so a kubeconfig rewritten by
    /// `minikube start` was never noticed.
    ///
    /// Idempotent, so it can be called again after each new grant is recorded.
    @MainActor
    static func activate() {
        for url in grantedDirectories() where active[url.path] == nil {
            if url.startAccessingSecurityScopedResource() {
                active[url.path] = url
            }
        }
    }

    /// Balances `activate`. Process exit would release these anyway; this
    /// exists so a revoked grant can be dropped without relaunching.
    @MainActor
    static func deactivate() {
        for url in active.values { url.stopAccessingSecurityScopedResource() }
        active.removeAll()
    }
}
