import Foundation

/// Builds and refreshes the container's copy of the kubeconfig.
///
/// The sequence exists because neither side can do the whole job alone: the
/// app can read the user's files but cannot parse kubeconfig YAML, and the
/// bundled kubectl parses it perfectly but cannot see outside the container.
/// So the bytes are carried in, kubectl is asked what they mean, and the
/// answer is rewritten into something a sandboxed child can actually use.
@MainActor
enum KubeconfigSync {
    /// What one pass needs next. The caller drives the prompts, because
    /// opening a panel from here would bury user interaction inside a
    /// refresh path that also runs unattended.
    enum Outcome: Equatable {
        case synced(
            inlined: Int,
            requirements: [KubeconfigMirror.CredentialRequirement],
            unsupported: [KubeconfigMirror.Unsupported]
        )
        /// No grant yet for the directory holding the kubeconfig itself.
        case needsKubeconfigAccess
        /// The config points at certificates under a directory no grant
        /// reaches — `~/.minikube` being the usual one.
        case needsAccess(to: URL, forPaths: [String])
        case failed(String)
    }

    static var shimPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kdex-auth").path
    }

    /// Reads the user's kubeconfig, rewrites it, and writes the result where
    /// the child kubectl will look for it.
    static func run() async -> Outcome {
        let source = KubeconfigLocation.path

        // Idempotent, and deliberately not balanced by a stop here: access has
        // to outlive this call, because the kubeconfig file watch holds a
        // descriptor open for the whole session.
        SandboxGrants.activate()

        guard let original = FileManager.default.contents(atPath: source) else {
            // Unreadable rather than absent is the common case here: the file
            // exists, the container just cannot see it yet.
            return FileManager.default.fileExists(atPath: source)
                ? .needsKubeconfigAccess
                : .failed("No kubeconfig at \(source).")
        }

        do {
            try FileManager.default.createDirectory(
                at: SandboxPaths.mirrorDirectory, withIntermediateDirectories: true
            )
        } catch {
            return .failed("Could not prepare the container directory: \(error.localizedDescription)")
        }

        // kubectl has to parse this, so it has to be somewhere kubectl can
        // read: a verbatim copy inside the container, deleted as soon as it
        // has been read rather than left as a second copy of the user's
        // credentials.
        let scratch = SandboxPaths.mirrorDirectory.appendingPathComponent("source.yaml")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try original.write(to: scratch, options: .atomic)
        } catch {
            return .failed("Could not stage the kubeconfig: \(error.localizedDescription)")
        }

        let parsed: JSONValue
        do {
            // `--raw` or the values come back as DATA+OMITTED / REDACTED.
            // `--kubeconfig` on argv beats the KUBECONFIG this process sets
            // for its children, which already points at the mirror.
            let result = try await Commands.runner.runChecked(
                "kubectl",
                ["config", "view", "--raw", "-o", "json", "--kubeconfig", scratch.path]
            )
            parsed = try KubeJSON.decode(result.stdout)
        } catch {
            return .failed("kubectl could not read the kubeconfig: \(error.localizedDescription)")
        }

        // Ask for one directory at a time. The alternative — a prompt per
        // missing file — is three panels for a single minikube context.
        let base = (source as NSString).deletingLastPathComponent
        let referenced = KubeconfigMirror.referencedPaths(in: parsed, relativeTo: base)
        let unreachable = referenced.filter { !FileManager.default.isReadableFile(atPath: $0) }
        if !unreachable.isEmpty, let ancestor = SandboxGrants.commonAncestor(of: unreachable) {
            return .needsAccess(to: ancestor, forPaths: unreachable)
        }

        var files: [String: Data] = [:]
        for path in referenced {
            if let data = FileManager.default.contents(atPath: path) { files[path] = data }
        }

        let output = KubeconfigMirror.mirror(
            config: parsed, files: files, shim: shimPath, relativeTo: base
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            // Atomic: a half-written kubeconfig would fail every command with
            // a parse error, and the watch loop can fire mid-write.
            try encoder.encode(output.config).write(to: SandboxPaths.mirroredKubeconfig, options: .atomic)
        } catch {
            return .failed("Could not write the mirrored kubeconfig: \(error.localizedDescription)")
        }

        return .synced(
            inlined: output.inlined.count,
            requirements: output.requirements,
            unsupported: output.unsupported
        )
    }
}
