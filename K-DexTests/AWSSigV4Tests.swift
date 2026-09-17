import Foundation
import Testing
@testable import K_Dex

// SigV4 fails closed and silently: a signature that is wrong by one byte comes
// back as a generic mismatch naming nothing useful, and the only symptom in
// K-Dex would be "EKS doesn't work". So the derivation is pinned against AWS's
// own published vector, and the request shape against the properties EKS
// actually checks.
struct AWSSigV4Tests {
    /// AWS's documented signing-key example (Signature Version 4 test suite).
    /// If this drifts, nothing else in the file is trustworthy.
    @Test func signingKeyMatchesAWSPublishedVector() {
        let key = AWSSigV4.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            date: "20150830",
            region: "us-east-1",
            service: "iam"
        )
        let hex = key.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")
    }

    @Test func emptyPayloadHashIsTheKnownSHA256OfNothing() {
        #expect(AWSSigV4.sha256Hex(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func encodingIsRFC3986NotTheFoundationDefault() {
        // Session tokens routinely contain / + = and a stray unescaped byte
        // changes the signature.
        #expect(AWSSigV4.encode("a/b+c=d") == "a%2Fb%2Bc%3Dd")
        #expect(AWSSigV4.encode("safe-_.~") == "safe-_.~")
        // Foundation's .urlQueryAllowed would leave these alone; we must not.
        #expect(AWSSigV4.encode(":,?") == "%3A%2C%3F")
    }

    private let credentials = AWSCredentials(
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil,
        expiration: nil
    )

    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2015; components.month = 8; components.day = 30
        components.hour = 12; components.minute = 36; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    @Test func presignedURLCarriesEverythingEKSChecks() {
        let url = AWSSigV4.presignedSTSURL(
            cluster: "prod", region: "ap-southeast-3",
            credentials: credentials, now: fixedDate
        )
        #expect(url.hasPrefix("https://sts.ap-southeast-3.amazonaws.com/?"))
        #expect(url.contains("Action=GetCallerIdentity"))
        #expect(url.contains("X-Amz-Date=20150830T123600Z"))
        // The cluster name is a *signed header*, not a query parameter — that
        // binding is what stops a token for one cluster working on another.
        #expect(url.contains("X-Amz-SignedHeaders=host%3Bx-k8s-aws-id"))
        #expect(url.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20150830%2Fap-southeast-3%2Fsts%2Faws4_request"))
        #expect(url.contains("X-Amz-Signature="))
    }

    @Test func signingIsDeterministicAndClusterBound() {
        let a = AWSSigV4.presignedSTSURL(cluster: "prod", region: "us-east-1",
                                         credentials: credentials, now: fixedDate)
        let b = AWSSigV4.presignedSTSURL(cluster: "prod", region: "us-east-1",
                                         credentials: credentials, now: fixedDate)
        let other = AWSSigV4.presignedSTSURL(cluster: "staging", region: "us-east-1",
                                             credentials: credentials, now: fixedDate)
        #expect(a == b)
        #expect(a != other)
    }

    @Test func sessionTokensRideAlongEncoded() {
        let assumed = AWSCredentials(
            accessKeyId: "ASIA", secretAccessKey: "secret",
            sessionToken: "tok/en+with=specials", expiration: nil
        )
        let url = AWSSigV4.presignedSTSURL(cluster: "prod", region: "us-east-1",
                                           credentials: assumed, now: fixedDate)
        #expect(url.contains("X-Amz-Security-Token=tok%2Fen%2Bwith%3Dspecials"))
    }

    @Test func tokenIsUnpaddedBase64URLBehindTheVersionPrefix() {
        let token = AWSSigV4.eksToken(cluster: "prod", region: "us-east-1",
                                      credentials: credentials, now: fixedDate)
        #expect(token.hasPrefix("k8s-aws-v1."))
        let payload = String(token.dropFirst("k8s-aws-v1.".count))
        // EKS rejects padding, and base64url uses - and _ rather than + and /.
        #expect(!payload.contains("="))
        #expect(!payload.contains("+"))
        #expect(!payload.contains("/"))

        // And it must decode back to the URL we signed.
        var padded = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let decoded = String(decoding: Data(base64Encoded: padded)!, as: UTF8.self)
        #expect(decoded.hasPrefix("https://sts.us-east-1.amazonaws.com/?"))
    }
}
