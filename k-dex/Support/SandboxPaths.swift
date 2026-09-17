import Foundation

/// Home directories, kept apart deliberately.
///
/// Under App Sandbox `NSHomeDirectory()` stops meaning "the user's home" and
/// starts meaning "this app's container" — silently, with no error and no
/// nil. Every path built from it therefore has to declare which of the two it
/// wants, or the unsandboxed build reads `~/.kube/config` while the sandboxed
/// one reads an empty container directory and reports a cluster-less machine.
nonisolated enum SandboxPaths {
    /// True when the process is running inside an App Sandbox container.
    ///
    /// Derived from the container's own marker rather than from a build flag:
    /// a `#if APPSTORE` answer would be a claim about how the binary was
    /// compiled, and this needs to be a fact about how it is running.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// The user's actual home directory, container or not.
    ///
    /// `getpwuid` reads the account record, which the sandbox does not
    /// rewrite. The result is where the kubeconfig and its certificates live —
    /// reading either still needs a grant; knowing the path does not.
    static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let home = String(cString: dir)
            if !home.isEmpty { return home }
        }
        // Outside a container these agree, so this is only ever a fallback
        // for a user record without a home directory.
        return NSHomeDirectory()
    }

    /// The home the *child* processes should see: the container when
    /// sandboxed, the user's home otherwise.
    ///
    /// Worth setting explicitly. launchd hands the app a `HOME` naming the
    /// real home even inside a container, and kubectl — being a Go program —
    /// believes the environment. Left alone it would try to cache discovery
    /// under the real `~/.kube`, which the container forbids, and every call
    /// would fail on a write rather than on the read that actually matters.
    static var childHome: String { NSHomeDirectory() }

    /// The writable root this app owns: its container when sandboxed, its
    /// Application Support directory otherwise.
    static var containerSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("K-Dex", isDirectory: true)
    }

    /// Where the sanitized kubeconfig is written for the child kubectl.
    ///
    /// A directory of its own, not a bare file: kubectl writes a discovery
    /// cache and a lock beside the config it is given, and those belong in the
    /// container next to the mirror rather than scattered through it.
    static var mirrorDirectory: URL {
        containerSupport.appendingPathComponent("kube", isDirectory: true)
    }

    static var mirroredKubeconfig: URL {
        mirrorDirectory.appendingPathComponent("config")
    }
}
