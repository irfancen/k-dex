import Foundation

// kdex-auth — the credential helper the sandboxed build substitutes for the
// user's own exec plugin.
//
// A sandboxed kubectl cannot run `aws`, `gcloud` or `kubelogin`: they live
// outside the container and are invisible from inside it. So the kubeconfig
// mirror rewrites every exec entry to point here, and this binary answers
// kubectl's ExecCredential protocol from a cache the app fills.
//
// It deliberately cannot *authenticate*. Signing in is interactive, and a
// credential plugin is spawned once per kubectl invocation — a single `get
// nodes` was measured starting this binary five times in 66ms. If signing in
// happened here, one expired session would open five browser windows. The app
// owns sign-in; this turns what the app already obtained into the credential
// kubectl asked for.
//
// For EKS that means *minting*, not replaying: the cache holds AWS role
// credentials (good for about an hour) and each invocation signs a fresh
// short-lived token from them. Signing is local HMAC — no network, no lock,
// microseconds — which is what makes a five-spawn burst harmless.

// MARK: Protocol types

/// kubectl's contract. Field names are wire format, so they are spelled the
/// way kubectl spells them rather than the way Swift would.
struct ExecCredential: Encodable {
    let apiVersion = "client.authentication.k8s.io/v1"
    let kind = "ExecCredential"
    let status: Status

    struct Status: Encodable {
        let token: String?
        let clientCertificateData: String?
        let clientKeyData: String?
        /// kubectl caches the credential in memory until this moment, which is
        /// what keeps a burst of subprocesses from each redoing this work.
        let expirationTimestamp: String?
    }
}

/// What the app writes, and the only thing this binary reads.
struct CachedCredential: Decodable {
    let token: String?
    let clientCertificateData: String?
    let clientKeyData: String?
    let expiresAt: Date?
    /// Present for EKS: sign with these rather than serving a stored token.
    let aws: AWSRoleCache?

    struct AWSRoleCache: Decodable {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
        let cluster: String
        let region: String
        let expiresAt: Date?
    }
}

// MARK: Arguments

func value(of flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), args.index(after: index) < args.endIndex else { return nil }
    return args[args.index(after: index)]
}

func fail(_ message: String) -> Never {
    // stderr, never stdout: kubectl parses stdout as the credential and would
    // report a JSON decode error instead of the actual problem.
    FileHandle.standardError.write(Data("kdex-auth: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let user = value(of: "--user", in: arguments) else {
    fail("missing --user; this binary is invoked by kubectl through the mirrored kubeconfig, not directly")
}
let provider = value(of: "--provider", in: arguments) ?? "unknown"

// MARK: Cache lookup

// Same container as the app, because `com.apple.security.inherit` puts this
// process inside it — so the path is derived identically rather than passed
// in argv, where it would show up in `ps` for every spawn.
//
// Note this resolves through the account record, not $HOME: Foundation's
// directory lookup ignores the environment, so the container wins here even
// though the app sets HOME for kubectl's benefit. The env override exists
// only so the test harness can point the lookup somewhere writable — it
// widens nothing, since a caller able to set it already controls this
// process's environment.
let support = ProcessInfo.processInfo.environment["KDEX_AUTH_CACHE_DIR"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
let cacheURL = support
    .appendingPathComponent("K-Dex", isDirectory: true)
    .appendingPathComponent("credentials", isDirectory: true)
    .appendingPathComponent("\(user).json")

guard let data = try? Data(contentsOf: cacheURL) else {
    fail("""
    no stored credential for user "\(user)" (\(provider)). Open K-Dex and sign in to this cluster.
    """)
}

// No lock is taken. The app writes this file atomically — temp file, then
// rename — so a reader either sees the whole previous credential or the whole
// new one. A lock would serialize every kubectl spawn behind the app's
// refresh for no gain.
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
guard let cached = try? decoder.decode(CachedCredential.self, from: data) else {
    fail("stored credential for \"\(user)\" is unreadable; sign in again from K-Dex")
}

let formatter = ISO8601DateFormatter()

// MARK: EKS — sign a fresh token from cached role credentials

if let aws = cached.aws {
    if let expiry = aws.expiresAt, expiry <= Date() {
        fail("your AWS session for \"\(user)\" expired at \(expiry); sign in again from K-Dex")
    }
    let credentials = AWSCredentials(
        accessKeyId: aws.accessKeyId,
        secretAccessKey: aws.secretAccessKey,
        sessionToken: aws.sessionToken,
        expiration: aws.expiresAt
    )
    let token = AWSSigV4.eksToken(
        cluster: aws.cluster, region: aws.region, credentials: credentials
    )
    // Expire the credential before the role credentials behind it do, so
    // kubectl asks again while there is still something to sign with.
    let horizon = Date().addingTimeInterval(14 * 60)
    let expiry = min(horizon, aws.expiresAt ?? horizon)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let credential = ExecCredential(status: .init(
        token: token, clientCertificateData: nil, clientKeyData: nil,
        expirationTimestamp: formatter.string(from: expiry)
    ))
    guard let output = try? encoder.encode(credential) else {
        fail("could not encode the credential response")
    }
    FileHandle.standardOutput.write(output)
    exit(0)
}

// MARK: Stored credentials — serve what the app put there

if let expiry = cached.expiresAt, expiry <= Date() {
    // Saying so beats handing kubectl a dead token and letting it surface as
    // a 401 the user has to interpret.
    fail("the stored credential for \"\(user)\" expired at \(expiry); sign in again from K-Dex")
}

guard cached.token != nil || cached.clientCertificateData != nil else {
    fail("the stored credential for \"\(user)\" carries neither a token nor a client certificate")
}

let credential = ExecCredential(status: .init(
    token: cached.token,
    clientCertificateData: cached.clientCertificateData,
    clientKeyData: cached.clientKeyData,
    expirationTimestamp: cached.expiresAt.map { formatter.string(from: $0) }
))

let encoder = JSONEncoder()
// kubectl parses `\/` correctly, but the apiVersion is read by humans in logs
// and bug reports often enough to be worth keeping legible.
encoder.outputFormatting = [.withoutEscapingSlashes]
guard let output = try? encoder.encode(credential) else {
    fail("could not encode the credential response")
}
FileHandle.standardOutput.write(output)
