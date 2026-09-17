import CryptoKit
import Foundation

/// Temporary AWS credentials, however they were obtained.
nonisolated struct AWSCredentials: Sendable, Equatable {
    let accessKeyId: String
    let secretAccessKey: String
    /// Present for anything assumed — SSO roles always have one.
    let sessionToken: String?
    let expiration: Date?
}

/// Signature Version 4, only as far as EKS needs it.
///
/// This is not a general AWS client: it presigns exactly one request, a GET of
/// STS `GetCallerIdentity`, because that presigned URL *is* an EKS bearer
/// token. Implementing it here is what lets the sandboxed build authenticate
/// without the `aws` CLI, which it cannot execute.
nonisolated enum AWSSigV4 {
    private static let algorithm = "AWS4-HMAC-SHA256"
    private static let service = "sts"
    /// SHA256 of the empty string — a presigned GET carries no body, and the
    /// canonical request still has to name the hash of the one it doesn't have.
    private static let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: Primitives

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        ))
    }

    /// The four-step derivation: key → date → region → service → request.
    /// Split out because it is the part with published test vectors, so it can
    /// be pinned independently of the request being signed.
    static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let initial = Data("AWS4\(secret)".utf8)
        let dateKey = hmac(initial, date)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, service)
        return hmac(serviceKey, "aws4_request")
    }

    /// Percent-encoding per RFC 3986, which is stricter than
    /// `addingPercentEncoding` defaults — a single unescaped `/` or `:` in the
    /// session token changes the signature and the request is rejected with a
    /// mismatch that names nothing useful.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: Presigning

    /// The presigned STS URL that EKS accepts as a bearer token.
    ///
    /// - Parameters:
    ///   - cluster: the EKS cluster *name*, which travels as the signed
    ///     `x-k8s-aws-id` header. Signing it is what stops a token minted for
    ///     one cluster being replayed against another.
    ///   - expiresIn: seconds. Kept short; kubectl re-invokes the plugin when
    ///     the credential expires, so a long-lived URL buys nothing.
    static func presignedSTSURL(
        cluster: String,
        region: String,
        credentials: AWSCredentials,
        now: Date = Date(),
        expiresIn: Int = 60
    ) -> String {
        let host = "sts.\(region).amazonaws.com"

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let amzDate = stamp.string(from: now)
        let dateOnly = String(amzDate.prefix(8))

        let scope = "\(dateOnly)/\(region)/\(service)/aws4_request"

        // Sorted by key, because the canonical form is defined that way and
        // the signature depends on the exact byte order.
        var query: [(String, String)] = [
            ("Action", "GetCallerIdentity"),
            ("Version", "2011-06-15"),
            ("X-Amz-Algorithm", algorithm),
            ("X-Amz-Credential", "\(credentials.accessKeyId)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expiresIn)),
            ("X-Amz-SignedHeaders", "host;x-k8s-aws-id"),
        ]
        if let token = credentials.sessionToken {
            query.append(("X-Amz-Security-Token", token))
        }
        let canonicalQuery = query
            .map { (encode($0.0), encode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            "GET",
            "/",
            canonicalQuery,
            "host:\(host)\nx-k8s-aws-id:\(cluster)\n",
            "host;x-k8s-aws-id",
            emptyPayloadHash,
        ].joined(separator: "\n")

        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let key = signingKey(
            secret: credentials.secretAccessKey,
            date: dateOnly, region: region, service: service
        )
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()

        return "https://\(host)/?\(canonicalQuery)&X-Amz-Signature=\(signature)"
    }

    /// The bearer token kubectl hands to EKS: the presigned URL, base64url
    /// encoded, unpadded, behind a version prefix. EKS rejects padding.
    static func eksToken(
        cluster: String,
        region: String,
        credentials: AWSCredentials,
        now: Date = Date(),
        expiresIn: Int = 60
    ) -> String {
        let url = presignedSTSURL(
            cluster: cluster, region: region,
            credentials: credentials, now: now, expiresIn: expiresIn
        )
        let encoded = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "k8s-aws-v1.\(encoded)"
    }
}
