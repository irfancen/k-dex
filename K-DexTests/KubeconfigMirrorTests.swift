import Foundation
import Testing
@testable import K_Dex

// Pins the rewrite that makes a sandboxed build possible at all. Every rule
// here exists because the mirrored config is the only one the child kubectl
// can read: anything left pointing outside the container fails at connect
// time, and anything inlined wrongly fails at TLS handshake — both far from
// this code. The fixtures mirror the shapes a real kubeconfig actually holds
// (minikube's file certs, an already-inlined pair, an EKS exec plugin).
struct KubeconfigMirrorTests {
    private let shim = "/Applications/K-Dex.app/Contents/Helpers/kdex-auth"
    private let base = "/Users/someone/.kube"

    private func config(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: Path discovery

    @Test func referencedPathsSpanEveryDirectoryTheConfigNames() {
        // minikube's CA and its client pair live in different directories, and
        // neither is the one holding the kubeconfig — the case that makes a
        // single grant on ~/.kube insufficient.
        let value = config("""
        {"clusters": [{"name": "minikube", "cluster": {
            "server": "https://127.0.0.1:64536",
            "certificate-authority": "/Users/someone/.minikube/ca.crt"}}],
         "users": [{"name": "minikube", "user": {
            "client-certificate": "/Users/someone/.minikube/profiles/minikube/client.crt",
            "client-key": "/Users/someone/.minikube/profiles/minikube/client.key"}}]}
        """)
        let paths = KubeconfigMirror.referencedPaths(in: value, relativeTo: base)
        #expect(paths == [
            "/Users/someone/.minikube/ca.crt",
            "/Users/someone/.minikube/profiles/minikube/client.crt",
            "/Users/someone/.minikube/profiles/minikube/client.key",
        ])
    }

    @Test func alreadyInlinedCredentialsReferenceNoFiles() {
        let value = config("""
        {"clusters": [{"name": "c", "cluster": {"certificate-authority-data": "Y2E="}}],
         "users": [{"name": "u", "user": {
            "client-certificate-data": "Y3J0", "client-key-data": "a2V5"}}]}
        """)
        #expect(KubeconfigMirror.referencedPaths(in: value, relativeTo: base).isEmpty)
    }

    @Test func aSharedCertificateIsAskedForOnce() {
        let value = config("""
        {"clusters": [
            {"name": "a", "cluster": {"certificate-authority": "/certs/ca.crt"}},
            {"name": "b", "cluster": {"certificate-authority": "/certs/ca.crt"}}]}
        """)
        #expect(KubeconfigMirror.referencedPaths(in: value, relativeTo: base) == ["/certs/ca.crt"])
    }

    @Test func relativePathsResolveAgainstTheKubeconfigsOwnDirectory() {
        let value = config("""
        {"clusters": [{"name": "c", "cluster": {"certificate-authority": "certs/ca.crt"}}]}
        """)
        #expect(KubeconfigMirror.referencedPaths(in: value, relativeTo: base) == ["/Users/someone/.kube/certs/ca.crt"])
    }

    // MARK: Inlining

    @Test func certificateFilesBecomeBase64DataAndThePathIsDropped() {
        let value = config("""
        {"clusters": [{"name": "minikube", "cluster": {
            "server": "https://127.0.0.1:64536",
            "certificate-authority": "/certs/ca.crt"}}],
         "users": [{"name": "minikube", "user": {
            "client-certificate": "/certs/client.crt",
            "client-key": "/certs/client.key"}}]}
        """)
        let out = KubeconfigMirror.mirror(
            config: value,
            files: [
                "/certs/ca.crt": Data("ca-pem".utf8),
                "/certs/client.crt": Data("crt-pem".utf8),
                "/certs/client.key": Data("key-pem".utf8),
            ],
            shim: shim, relativeTo: base
        )

        let cluster = out.config["clusters"][0]["cluster"]
        #expect(cluster["certificate-authority-data"].string == Data("ca-pem".utf8).base64EncodedString())
        #expect(cluster["certificate-authority"].isNull)
        // The server URL is the one thing the mirror must never touch.
        #expect(cluster["server"].string == "https://127.0.0.1:64536")

        let user = out.config["users"][0]["user"]
        #expect(user["client-certificate-data"].string == Data("crt-pem".utf8).base64EncodedString())
        #expect(user["client-key-data"].string == Data("key-pem".utf8).base64EncodedString())
        #expect(user["client-certificate"].isNull)
        #expect(user["client-key"].isNull)
        #expect(out.missing.isEmpty)
        #expect(out.inlined.count == 3)
    }

    @Test func anUnreadableCertificateIsReportedWithoutSinkingTheOtherContexts() {
        let value = config("""
        {"clusters": [
            {"name": "good", "cluster": {"certificate-authority": "/certs/ca.crt"}},
            {"name": "revoked", "cluster": {"certificate-authority": "/gone/ca.crt"}}]}
        """)
        let out = KubeconfigMirror.mirror(
            config: value, files: ["/certs/ca.crt": Data("ca".utf8)],
            shim: shim, relativeTo: base
        )
        #expect(out.missing == ["/gone/ca.crt"])
        #expect(out.config["clusters"][0]["cluster"]["certificate-authority-data"].string != nil)
        // The path is dropped even when unreadable: left in place, kubectl
        // would report a path the container can never open.
        #expect(out.config["clusters"][1]["cluster"]["certificate-authority"].isNull)
        #expect(out.config["clusters"][1]["cluster"]["certificate-authority-data"].isNull)
    }

    @Test func tokenFileIsInlinedVerbatimAndStrippedOfItsTrailingNewline() {
        let value = config("""
        {"users": [{"name": "sa", "user": {"tokenFile": "/var/run/secrets/token"}}]}
        """)
        let out = KubeconfigMirror.mirror(
            config: value, files: ["/var/run/secrets/token": Data("ey.JHV.abc\n".utf8)],
            shim: shim, relativeTo: base
        )
        let user = out.config["users"][0]["user"]
        #expect(user["token"].string == "ey.JHV.abc")
        #expect(user["tokenFile"].isNull)
    }

    @Test func inlinedDataWinsOverAFileReferenceBeside() {
        // kubectl prefers the inlined value; the mirror must agree, or the two
        // would disagree about which credential is in play.
        let value = config("""
        {"clusters": [{"name": "c", "cluster": {
            "certificate-authority": "/certs/ca.crt",
            "certificate-authority-data": "aW5saW5l"}}]}
        """)
        let out = KubeconfigMirror.mirror(
            config: value, files: ["/certs/ca.crt": Data("file".utf8)],
            shim: shim, relativeTo: base
        )
        #expect(out.config["clusters"][0]["cluster"]["certificate-authority-data"].string == "aW5saW5l")
        #expect(out.inlined.isEmpty)
    }

    // MARK: Credential plugins

    @Test func anExecPluginIsRewrittenToTheBundledShim() {
        let value = config("""
        {"users": [{"name": "eks-admin", "user": {"exec": {
            "apiVersion": "client.authentication.k8s.io/v1beta1",
            "command": "aws",
            "args": ["eks", "get-token", "--cluster-name", "prod"],
            "env": [{"name": "AWS_PROFILE", "value": "default"}]}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)
        let exec = out.config["users"][0]["user"]["exec"]

        #expect(exec["command"].string == shim)
        #expect(exec["apiVersion"].string == "client.authentication.k8s.io/v1")
        #expect(exec["args"].array.map(\.stringValue) == ["--user", "eks-admin", "--provider", "eks"])
        // The user's env carried AWS_PROFILE and similar; none of it means
        // anything to the shim, and dropping it keeps it out of the container.
        #expect(exec["env"].isNull)
        // A sandboxed helper has no terminal, so kubectl must never try to
        // drive it interactively.
        #expect(exec["interactiveMode"].string == "Never")
        #expect(out.unsupported.isEmpty)
    }

    @Test func aLegacyAuthProviderBecomesAnExecEntryToo() {
        let value = config("""
        {"users": [{"name": "gke-user", "user": {"auth-provider": {"name": "gcp"}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)
        let user = out.config["users"][0]["user"]
        #expect(user["auth-provider"].isNull)
        #expect(user["exec"]["args"].array.map(\.stringValue) == ["--user", "gke-user", "--provider", "gke"])
    }

    @Test func anUnrecognizedPluginIsReportedRatherThanGuessedAt() {
        // Teleport, Vault helpers and corporate SSO wrappers land here. A
        // wrong guess would send the shim at the wrong cloud, so the mirror
        // says so instead and the UI can point at the direct download.
        let value = config("""
        {"users": [{"name": "teleport", "user": {"exec": {"command": "tsh"}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)
        #expect(out.unsupported.count == 1)
        #expect(out.unsupported.first?.user == "teleport")
        #expect(out.unsupported.first?.mechanism == "exec: tsh")
        #expect(out.config["users"][0]["user"]["exec"]["args"].array.map(\.stringValue).contains("unknown"))
    }

    @Test func aPluginNamedByAbsolutePathIsStillRecognized() {
        let value = config("""
        {"users": [{"name": "eks", "user": {"exec": {"command": "/opt/homebrew/bin/aws"}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)
        #expect(out.unsupported.isEmpty)
        #expect(out.config["users"][0]["user"]["exec"]["args"].array.map(\.stringValue).contains("eks"))
    }

    @Test func passwordAuthAndBareUsersAreLeftAlone() {
        let value = config("""
        {"users": [
            {"name": "basic", "user": {"username": "admin", "password": "hunter2"}},
            {"name": "bare", "user": {}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)
        #expect(out.config["users"][0]["user"]["username"].string == "admin")
        #expect(out.config["users"][0]["user"]["exec"].isNull)
        #expect(out.unsupported.isEmpty)
    }

    // MARK: Structure preservation

    @Test func contextsAndClusterTuningSurviveVerbatim() {
        // tls-server-name and proxy-url change how the connection is made;
        // losing either turns a working cluster into a handshake failure.
        let value = config("""
        {"apiVersion": "v1", "kind": "Config", "current-context": "kthw",
         "preferences": {"colors": true},
         "clusters": [{"name": "kthw", "cluster": {
            "server": "https://10.0.0.1:6443",
            "tls-server-name": "kubernetes.default",
            "proxy-url": "socks5://localhost:1080",
            "insecure-skip-tls-verify": true,
            "extensions": [{"name": "minikube.k8s.io"}]}}],
         "contexts": [{"name": "kthw", "context": {
            "cluster": "kthw", "user": "admin", "namespace": "kube-system"}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: shim, relativeTo: base)

        let cluster = out.config["clusters"][0]["cluster"]
        #expect(cluster["tls-server-name"].string == "kubernetes.default")
        #expect(cluster["proxy-url"].string == "socks5://localhost:1080")
        #expect(cluster["insecure-skip-tls-verify"].bool == true)
        #expect(cluster["extensions"].array.count == 1)

        let context = out.config["contexts"][0]["context"]
        #expect(context["namespace"].string == "kube-system")
        #expect(out.config["current-context"].string == "kthw")
        #expect(out.config["preferences"]["colors"].bool == true)
    }

    @Test func anEmptyConfigStillCarriesTheKeysThatMakeItParseable() {
        let out = KubeconfigMirror.mirror(config: config("{}"), files: [:], shim: shim, relativeTo: base)
        #expect(out.config["apiVersion"].string == "v1")
        #expect(out.config["kind"].string == "Config")
    }

    @Test func theMirrorIsSerializableAsJSONWhichIsValidYAML() {
        // The mirror is written as JSON — kubectl's loader is a YAML parser
        // and JSON is a YAML subset, which spares the app a YAML writer.
        let value = config("""
        {"clusters": [{"name": "c", "cluster": {"certificate-authority": "/certs/ca.crt"}}]}
        """)
        let out = KubeconfigMirror.mirror(
            config: value, files: ["/certs/ca.crt": Data("ca".utf8)],
            shim: shim, relativeTo: base
        )
        let encoded = try! JSONEncoder().encode(out.config)
        let round = try! JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(round["clusters"][0]["cluster"]["certificate-authority-data"].string == "Y2E=")
    }
}
