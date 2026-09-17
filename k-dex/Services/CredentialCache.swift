import Foundation

/// The handoff between the app, which can sign in, and `kdex-auth`, which
/// cannot.
///
/// One file per kubeconfig user, named after it, inside the container both
/// processes resolve identically. For EKS the file holds AWS *role
/// credentials* rather than a finished token: the shim signs a fresh token per
/// invocation, so an hour-long session survives on one sign-in and a burst of
/// kubectl spawns costs nothing but local HMAC.
nonisolated enum CredentialCache {
    /// What the shim decodes. Kept in step with `CachedCredential` in
    /// `kdex-auth/main.swift` by hand — the two targets share no code, so this
    /// pair of shapes is the contract between them.
    struct Entry: Codable, Equatable {
        var token: String?
        var clientCertificateData: String?
        var clientKeyData: String?
        var expiresAt: Date?
        var aws: AWSRole?

        struct AWSRole: Codable, Equatable {
            let accessKeyId: String
            let secretAccessKey: String
            let sessionToken: String?
            let cluster: String
            let region: String
            let expiresAt: Date?
        }
    }

    static var directory: URL {
        SandboxPaths.containerSupport.appendingPathComponent("credentials", isDirectory: true)
    }

    /// A kubeconfig user name can be an ARN, full of slashes and colons —
    /// `arn:aws:eks:…:cluster/name` — so it cannot be a file name as-is. The
    /// shim performs the identical substitution; changing it here alone would
    /// silently stop every lookup resolving.
    static func fileName(for user: String) -> String {
        user.replacingOccurrences(of: "/", with: "_") + ".json"
    }

    static func url(for user: String) -> URL {
        directory.appendingPathComponent(fileName(for: user))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Writes atomically, which decision 8 depends on: the shim takes no lock,
    /// so it must be impossible to read a half-written credential.
    static func store(_ entry: Entry, for user: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let data = try encoder.encode(entry)
        try data.write(to: url(for: user), options: [.atomic, .completeFileProtection])
    }

    static func load(for user: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: user)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: data)
    }

    /// Whether a sign-in is still needed, so the UI can offer it before
    /// kubectl fails rather than after.
    ///
    /// A credential about to expire counts as absent: signing in takes a
    /// browser round trip, and discovering that mid-refresh is worse than
    /// being asked a minute early.
    static func needsSignIn(for user: String, margin: TimeInterval = 120) -> Bool {
        guard let entry = load(for: user) else { return true }
        let expiry = entry.aws?.expiresAt ?? entry.expiresAt
        guard let expiry else { return false }
        return expiry.timeIntervalSinceNow < margin
    }

    static func forget(user: String) {
        try? FileManager.default.removeItem(at: url(for: user))
    }
}
