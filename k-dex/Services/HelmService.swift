import Compression
import Foundation

/// Reads Helm releases straight from the cluster: Helm 3 stores each revision
/// as a Secret (type helm.sh/release.v1) whose payload is base64 → gzip → JSON.
/// This means the helm CLI does not need to be installed.
nonisolated enum HelmService {
    static func listReleases(context: String, namespace: String?) async throws -> [HelmRelease] {
        var args = [
            "get", "secrets",
            "-l", "owner=helm",
            "--field-selector", "type=helm.sh/release.v1",
            "-o", "json", "--context", context,
        ]
        if let namespace { args += ["-n", namespace] } else { args += ["--all-namespaces"] }
        let result = try await ProcessRunner.runChecked("kubectl", args)
        let data = result.stdout
        let secrets = try await Task.detached(priority: .userInitiated) {
            try KubeJSON.decode(data)["items"].array
        }.value

        // Group revisions per release, keyed by namespace/name.
        var grouped: [String: [JSONValue]] = [:]
        for secret in secrets {
            let labels = secret["metadata"]["labels"]
            let key = "\(secret["metadata"]["namespace"].stringValue)/\(labels["name"].stringValue)"
            grouped[key, default: []].append(secret)
        }

        var releases: [HelmRelease] = []
        for revisions in grouped.values {
            let sorted = revisions.sorted {
                ($0["metadata"]["labels"]["version"].int ?? 0) < ($1["metadata"]["labels"]["version"].int ?? 0)
            }
            guard let latest = sorted.last else { continue }
            let history = sorted.suffix(20).reversed().map { secret in
                HelmRevision(
                    revision: secret["metadata"]["labels"]["version"].int ?? 0,
                    status: secret["metadata"]["labels"]["status"].stringValue,
                    date: Fmt.parseDate(secret["metadata"]["creationTimestamp"].string)
                )
            }
            if let release = try? await decodeRelease(secret: latest, history: Array(history)) {
                releases.append(release)
            }
        }
        return releases.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private static func decodeRelease(secret: JSONValue, history: [HelmRevision]) async throws -> HelmRelease? {
        let labels = secret["metadata"]["labels"]
        let name = labels["name"].stringValue
        let namespace = secret["metadata"]["namespace"].stringValue
        let revision = labels["version"].int ?? 0
        let status = labels["status"].stringValue
        let fallbackDate = Fmt.parseDate(secret["metadata"]["creationTimestamp"].string)

        var payload = JSONValue.null
        if let encoded = secret["data"]["release"].string,
           let outer = Data(base64Encoded: encoded),
           let inner = Data(base64Encoded: outer) {
            let json: Data?
            if inner.count > 2, inner[inner.startIndex] == 0x1f, inner[inner.startIndex + 1] == 0x8b {
                json = try? gunzip(inner)
            } else {
                json = inner
            }
            if let json, let decoded = try? KubeJSON.decode(json) {
                payload = decoded
            }
        }

        let chartMeta = payload["chart"]["metadata"]
        return HelmRelease(
            name: name.isEmpty ? payload["name"].stringValue : name,
            namespace: namespace,
            revision: revision,
            status: status.isEmpty ? payload["info"]["status"].stringValue : status,
            chartName: chartMeta["name"].stringValue,
            chartVersion: chartMeta["version"].stringValue,
            appVersion: chartMeta["appVersion"].stringValue,
            updated: Fmt.parseDate(payload["info"]["last_deployed"].string) ?? fallbackDate,
            notes: payload["info"]["notes"].stringValue,
            manifest: payload["manifest"].stringValue,
            values: payload["config"],
            history: history
        )
    }

    private struct GzipError: Error {}

    /// In-process gzip decode via the Compression framework — no subprocess
    /// per release, and output is bounded (the payload is cluster-writable,
    /// so an unbounded inflate would be a decompression-bomb vector).
    private static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw GzipError() }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard index + 2 <= bytes.count else { throw GzipError() }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        if flags & 0x08 != 0 { // FNAME
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 } // FHCRC
        guard index < bytes.count - 8 else { throw GzipError() }

        // Trailer's ISIZE gives the exact inflated size (mod 2^32).
        let count = bytes.count
        let inflatedSize = Int(bytes[count - 4]) | Int(bytes[count - 3]) << 8
            | Int(bytes[count - 2]) << 16 | Int(bytes[count - 1]) << 24
        guard inflatedSize > 0, inflatedSize <= 64 * 1024 * 1024 else { throw GzipError() }

        let deflated = [UInt8](bytes[index..<(count - 8)])
        var inflated = [UInt8](repeating: 0, count: inflatedSize)
        let written = deflated.withUnsafeBufferPointer { source in
            inflated.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(
                    destination.baseAddress!, destination.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == inflatedSize else { throw GzipError() }
        return Data(inflated)
    }
}
