import Foundation

/// Rewrites a kubeconfig into the sanitized copy the sandboxed build hands to
/// its bundled kubectl.
///
/// The sandboxed app can read the user's kubeconfig (one-time grant, held as a
/// security-scoped bookmark) but the *child* kubectl cannot: the file, and
/// every certificate it points at, live outside the container. So the app
/// mirrors the config inward — certificates inlined as `*-data`, token files
/// inlined as `token`, and exec plugins rewritten to the bundled `kdex-auth`
/// shim, which is the only executable a sandboxed child can reach.
///
/// Both entry points are pure: `referencedPaths` says which files the caller
/// must read, `mirror` takes their bytes back. No file system, no container,
/// no panel — which is what makes every rule below testable against fixtures.
/// The user's own kubeconfig is never written to.
nonisolated enum KubeconfigMirror {
    /// A credential the mirror could rewrite but the shim cannot yet serve.
    /// Surfaced so the UI can name the cluster and point at the direct
    /// download, rather than letting kubectl fail with a confusing exec error.
    struct Unsupported: Sendable, Equatable {
        let user: String
        let mechanism: String
        let reason: String
    }

    struct Output: Sendable, Equatable {
        /// The sanitized config, ready to serialize into the container.
        let config: JSONValue
        /// Paths whose contents were inlined.
        let inlined: [String]
        /// Paths the config referenced that the caller could not supply —
        /// a revoked grant, or a cert deleted since the last sync.
        let missing: [String]
        let unsupported: [Unsupported]
    }

    // MARK: Referenced files

    /// Cluster keys naming a file, and the key its contents belong in.
    ///
    /// Ordered pairs rather than a dictionary: this order becomes the order of
    /// the grant prompts the user answers, and a dictionary's iteration order
    /// varies per launch.
    private static let clusterFileKeys = [("certificate-authority", "certificate-authority-data")]

    /// User keys naming a file. `tokenFile` is deliberately absent here: its
    /// contents are a bearer token, not base64-wrapped PEM, so it takes a
    /// different inlining path below.
    private static let userFileKeys = [
        ("client-certificate", "client-certificate-data"),
        ("client-key", "client-key-data"),
    ]

    /// Every file the config points at, resolved to absolute paths.
    ///
    /// The caller needs this before it can ask for grants, and the answer is
    /// rarely one directory: minikube keeps its CA in `~/.minikube` and its
    /// client pair under `~/.minikube/profiles/<profile>/`, neither of which a
    /// grant on `~/.kube` covers.
    static func referencedPaths(in config: JSONValue, relativeTo baseDirectory: String) -> [String] {
        var paths: [String] = []

        for entry in config["clusters"].array {
            let cluster = entry["cluster"]
            for (fileKey, dataKey) in clusterFileKeys {
                // An already-inlined value wins; the file reference beside it
                // is what kubectl would ignore, so the mirror ignores it too.
                guard cluster[dataKey].string == nil, let path = cluster[fileKey].string, !path.isEmpty else { continue }
                paths.append(resolve(path, relativeTo: baseDirectory))
            }
        }

        for entry in config["users"].array {
            let user = entry["user"]
            for (fileKey, dataKey) in userFileKeys {
                guard user[dataKey].string == nil, let path = user[fileKey].string, !path.isEmpty else { continue }
                paths.append(resolve(path, relativeTo: baseDirectory))
            }
            if user["token"].string == nil, let path = user["tokenFile"].string, !path.isEmpty {
                paths.append(resolve(path, relativeTo: baseDirectory))
            }
        }

        // Stable order, no duplicates: two contexts commonly share one CA, and
        // the caller turns this into one grant prompt per directory.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// kubectl resolves a relative path against the directory of the
    /// kubeconfig that declared it, not the working directory.
    static func resolve(_ path: String, relativeTo baseDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        return (baseDirectory as NSString).appendingPathComponent(expanded)
    }

    // MARK: Mirroring

    /// Builds the sanitized config.
    ///
    /// - Parameters:
    ///   - files: contents for the paths `referencedPaths` returned, keyed by
    ///     the same resolved path. A missing entry is reported, not fatal —
    ///     one unreadable cluster must not sink the other contexts.
    ///   - shim: absolute container path of the bundled `kdex-auth` binary.
    static func mirror(
        config: JSONValue,
        files: [String: Data],
        shim: String,
        relativeTo baseDirectory: String
    ) -> Output {
        var inlined: [String] = []
        var missing: [String] = []
        var unsupported: [Unsupported] = []

        var root = config.object
        // `kind`/`apiVersion` are what make this parseable as a Config at all,
        // and kubectl omits neither — but a hand-written file might.
        root["apiVersion"] = .string(config["apiVersion"].string ?? "v1")
        root["kind"] = .string(config["kind"].string ?? "Config")

        root["clusters"] = .array(config["clusters"].array.map { entry in
            var wrapper = entry.object
            var cluster = entry["cluster"].object
            for (fileKey, dataKey) in clusterFileKeys {
                inlineBase64(
                    into: &cluster, fileKey: fileKey, dataKey: dataKey,
                    files: files, baseDirectory: baseDirectory,
                    inlined: &inlined, missing: &missing
                )
            }
            wrapper["cluster"] = .object(cluster)
            return .object(wrapper)
        })

        root["users"] = .array(config["users"].array.map { entry in
            var wrapper = entry.object
            var user = entry["user"].object
            let name = entry["name"].stringValue

            for (fileKey, dataKey) in userFileKeys {
                inlineBase64(
                    into: &user, fileKey: fileKey, dataKey: dataKey,
                    files: files, baseDirectory: baseDirectory,
                    inlined: &inlined, missing: &missing
                )
            }
            inlineToken(
                into: &user, files: files, baseDirectory: baseDirectory,
                inlined: &inlined, missing: &missing
            )
            rewriteCredentialPlugin(
                into: &user, name: name, shim: shim, unsupported: &unsupported
            )

            wrapper["user"] = .object(user)
            return .object(wrapper)
        })

        return Output(
            config: .object(root),
            inlined: inlined,
            missing: missing,
            unsupported: unsupported
        )
    }

    // MARK: Rules

    /// PEM file → base64 `*-data`. The file reference is dropped either way:
    /// left in place it would point outside the container, where kubectl's
    /// error names a path the user can see but the app cannot read.
    private static func inlineBase64(
        into node: inout [String: JSONValue],
        fileKey: String,
        dataKey: String,
        files: [String: Data],
        baseDirectory: String,
        inlined: inout [String],
        missing: inout [String]
    ) {
        guard let path = node[fileKey]?.string, !path.isEmpty else { return }
        node[fileKey] = nil
        guard node[dataKey]?.string == nil else { return }

        let resolved = resolve(path, relativeTo: baseDirectory)
        guard let data = files[resolved] else {
            missing.append(resolved)
            return
        }
        node[dataKey] = .string(data.base64EncodedString())
        inlined.append(resolved)
    }

    /// `tokenFile` → `token`. Not base64: the file holds the bearer token
    /// verbatim, and service-account files end with a newline that would
    /// otherwise travel into the Authorization header.
    private static func inlineToken(
        into user: inout [String: JSONValue],
        files: [String: Data],
        baseDirectory: String,
        inlined: inout [String],
        missing: inout [String]
    ) {
        guard let path = user["tokenFile"]?.string, !path.isEmpty else { return }
        user["tokenFile"] = nil
        guard user["token"]?.string == nil else { return }

        let resolved = resolve(path, relativeTo: baseDirectory)
        guard let data = files[resolved] else {
            missing.append(resolved)
            return
        }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        user["token"] = .string(token)
        inlined.append(resolved)
    }

    /// Provider inferred from the binary the kubeconfig names. The mapping is
    /// deliberately narrow: a wrong guess would send the shim to the wrong
    /// cloud, so anything unrecognized is reported rather than assumed.
    private static func provider(forCommand command: String) -> String? {
        switch (command as NSString).lastPathComponent {
        case "aws", "aws-iam-authenticator": return "eks"
        case "gke-gcloud-auth-plugin", "gcloud": return "gke"
        case "kubelogin", "azure-kubelogin": return "aks"
        case "oc": return "openshift"
        default: return nil
        }
    }

    /// Legacy `auth-provider` names map to the same native providers.
    private static func provider(forAuthProvider name: String) -> String? {
        switch name {
        case "gcp": return "gke"
        case "azure": return "aks"
        case "oidc": return "oidc"
        default: return nil
        }
    }

    /// `exec` / `auth-provider` → the bundled shim.
    ///
    /// The user's own plugin is unreachable from inside the container by
    /// design, so the entry is rewritten rather than removed: kubectl keeps
    /// driving its own ExecCredential protocol, and `kdex-auth` answers.
    private static func rewriteCredentialPlugin(
        into user: inout [String: JSONValue],
        name: String,
        shim: String,
        unsupported: inout [Unsupported]
    ) {
        var mechanism: String?
        var resolvedProvider: String?

        if let exec = user["exec"], !exec.isNull {
            let command = exec["command"].stringValue
            mechanism = "exec: \(command)"
            resolvedProvider = provider(forCommand: command)
        } else if let legacy = user["auth-provider"], !legacy.isNull {
            let providerName = legacy["name"].stringValue
            mechanism = "auth-provider: \(providerName)"
            resolvedProvider = provider(forAuthProvider: providerName)
        }

        guard let mechanism else { return }

        user["auth-provider"] = nil
        user["exec"] = .object([
            // v1 is the current protocol; pinning it means the shim answers
            // one shape rather than every historical one.
            "apiVersion": .string("client.authentication.k8s.io/v1"),
            "command": .string(shim),
            "args": .array([
                .string("--user"), .string(name),
                .string("--provider"), .string(resolvedProvider ?? "unknown"),
            ]),
            // A sandboxed helper has no terminal to prompt on, and kubectl
            // refuses to run an interactive plugin without one. Sign-in is the
            // app's job; the shim only ever reports what the cache holds.
            "interactiveMode": .string("Never"),
            // The shim authenticates per user, not per cluster, and cluster
            // info would put the server URL on its stdin for no benefit.
            "provideClusterInfo": .bool(false),
        ])

        if resolvedProvider == nil {
            unsupported.append(Unsupported(
                user: name,
                mechanism: mechanism,
                reason: "This credential plugin has no built-in equivalent, so the sandboxed build can't sign in with it. Use the direct download, which runs your own plugin."
            ))
        }
    }
}
