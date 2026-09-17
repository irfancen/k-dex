import Foundation
import Testing
@testable import K_Dex

// The contract between the app and a binary that shares no code with it. Both
// sides derive the same path and the same JSON shape independently, so a drift
// here does not fail loudly — it reports "not signed in" forever.
struct CredentialCacheTests {
    @Test func anARNUserNameBecomesOneFileNotANestedPath() {
        // The slash in `cluster/name` would otherwise create a directory level
        // nobody creates, and every lookup would miss.
        let name = CredentialCache.fileName(
            for: "arn:aws:eks:ap-southeast-3:134604498185:cluster/lucky7-planpal")
        #expect(!name.contains("/"))
        #expect(name == "arn:aws:eks:ap-southeast-3:134604498185:cluster_lucky7-planpal.json")
    }

    @Test func ordinaryNamesAreLeftRecognizable() {
        #expect(CredentialCache.fileName(for: "minikube") == "minikube.json")
    }

    /// Encodes exactly as written, then decodes with the settings the shim
    /// uses — ISO-8601 dates, which is where a mismatch would hide.
    @Test func anAWSEntryRoundTripsThroughTheShimsDecoder() throws {
        let expiry = Date(timeIntervalSince1970: 1_789_689_600)
        let entry = CredentialCache.Entry(aws: .init(
            accessKeyId: "ASIA", secretAccessKey: "secret", sessionToken: "tok",
            cluster: "lucky7-planpal", region: "ap-southeast-3", expiresAt: expiry
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        // The shim's decoder, spelled out rather than shared.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CredentialCache.Entry.self, from: data)

        #expect(decoded.aws?.accessKeyId == "ASIA")
        #expect(decoded.aws?.sessionToken == "tok")
        #expect(decoded.aws?.cluster == "lucky7-planpal")
        #expect(decoded.aws?.expiresAt == expiry)
        // The JSON must name the keys the shim reads.
        let text = String(decoding: data, as: UTF8.self)
        for key in ["aws", "accessKeyId", "secretAccessKey", "sessionToken", "cluster", "region", "expiresAt"] {
            #expect(text.contains("\"\(key)\""), "missing \(key)")
        }
    }

    @Test func aCredentialAboutToExpireCountsAsNeedingSignIn() {
        // Signing in costs a browser round trip; finding out mid-refresh is
        // worse than being asked a minute early.
        let soon = CredentialCache.Entry(aws: .init(
            accessKeyId: "A", secretAccessKey: "S", sessionToken: nil,
            cluster: "c", region: "r", expiresAt: Date().addingTimeInterval(30)
        ))
        let later = CredentialCache.Entry(aws: .init(
            accessKeyId: "A", secretAccessKey: "S", sessionToken: nil,
            cluster: "c", region: "r", expiresAt: Date().addingTimeInterval(3600)
        ))
        #expect(expiring(soon, within: 120))
        #expect(!expiring(later, within: 120))
    }

    /// Mirrors `needsSignIn`'s rule without touching the real container.
    private func expiring(_ entry: CredentialCache.Entry, within margin: TimeInterval) -> Bool {
        guard let expiry = entry.aws?.expiresAt ?? entry.expiresAt else { return false }
        return expiry.timeIntervalSinceNow < margin
    }
}

// The EKS parameters are written down in exactly one place — the exec entry the
// rewrite is about to discard — so recovering them is not optional.
struct EKSTargetTests {
    @Test func theARNCarriesRegionAccountAndCluster() {
        let target = KubeconfigMirror.parseEKSARN(
            "arn:aws:eks:ap-southeast-3:134604498185:cluster/lucky7-planpal-rafly-new-cluster")
        #expect(target?.cluster == "lucky7-planpal-rafly-new-cluster")
        #expect(target?.region == "ap-southeast-3")
        #expect(target?.accountID == "134604498185")
    }

    @Test func nonARNNamesAreNotMisread() {
        #expect(KubeconfigMirror.parseEKSARN("minikube") == nil)
        #expect(KubeconfigMirror.parseEKSARN("arn:aws:iam::123:user/bob") == nil)
        #expect(KubeconfigMirror.parseEKSARN("arn:aws:eks:region:acct:nodegroup/x") == nil)
    }

    private func config(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func execArgsSupplyTheClusterWhenTheNameIsNotAnARN() {
        let value = config("""
        {"users": [{"name": "eks-admin", "user": {"exec": {"command": "aws",
          "args": ["--region","eu-west-1","eks","get-token","--cluster-name","prod"]}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: "/s", relativeTo: "/")
        #expect(out.requirements.count == 1)
        #expect(out.requirements.first?.eks == KubeconfigMirror.EKSTarget(
            cluster: "prod", region: "eu-west-1", accountID: nil))
    }

    @Test func theARNFillsInWhatTheArgsOmit() {
        // aws writes the ARN as the user name and the bare name in the args;
        // only the ARN carries the account id, and only it can say which AWS
        // account to ask for role credentials.
        let value = config("""
        {"users": [{"name": "arn:aws:eks:ap-southeast-3:134604498185:cluster/lucky7",
          "user": {"exec": {"command": "aws",
          "args": ["eks","get-token","--cluster-name","lucky7"]}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: "/s", relativeTo: "/")
        #expect(out.requirements.first?.eks == KubeconfigMirror.EKSTarget(
            cluster: "lucky7", region: "ap-southeast-3", accountID: "134604498185"))
    }

    @Test func awsIamAuthenticatorsShorthandIsUnderstoodToo() {
        let value = config("""
        {"users": [{"name": "arn:aws:eks:us-east-2:999:cluster/legacy",
          "user": {"exec": {"command": "aws-iam-authenticator",
          "args": ["token","-i","legacy"]}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: "/s", relativeTo: "/")
        #expect(out.requirements.first?.eks?.cluster == "legacy")
        #expect(out.requirements.first?.eks?.region == "us-east-2")
    }

    @Test func anUnrecognizedPluginStillReportsARequirementWithoutAnEKSTarget() {
        let value = config("""
        {"users": [{"name": "teleport", "user": {"exec": {"command": "tsh"}}}]}
        """)
        let out = KubeconfigMirror.mirror(config: value, files: [:], shim: "/s", relativeTo: "/")
        #expect(out.requirements.first?.provider == "unknown")
        #expect(out.requirements.first?.eks == nil)
    }

    @Test func certificateUsersNeedNothingFromTheApp() {
        let value = config("""
        {"users": [{"name": "minikube", "user": {"client-certificate-data": "Y3J0"}}]}
        """)
        #expect(KubeconfigMirror.mirror(config: value, files: [:], shim: "/s", relativeTo: "/")
            .requirements.isEmpty)
    }
}
