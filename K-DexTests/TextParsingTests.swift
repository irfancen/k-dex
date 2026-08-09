import Foundation
import Testing
@testable import K_Dex

// Pins the log-line splitter that feeds the aggregated log view's gutter,
// colors, and timestamp column.
struct LogLineParserTests {
    @Test func parsesTagTimestampAndMessage() {
        let parsed = LogLineParser.parse("[pod/web-7d4b9-abc12/nginx] 2026-07-24T09:12:33.123456789Z GET /healthz 200")
        #expect(parsed.tag == "pod/web-7d4b9-abc12/nginx")
        #expect(parsed.timestamp == "09:12:33")
        #expect(parsed.message == "GET /healthz 200")
    }

    @Test func plainLineIsAllMessage() {
        let parsed = LogLineParser.parse("no tag, no timestamp here")
        #expect(parsed.tag == nil)
        #expect(parsed.timestamp == nil)
        #expect(parsed.message == "no tag, no timestamp here")
    }

    @Test func timestampWithoutTag() {
        let parsed = LogLineParser.parse("2026-07-24T09:12:33Z started")
        #expect(parsed.tag == nil)
        #expect(parsed.timestamp == "09:12:33")
        #expect(parsed.message == "started")
    }

    /// A short leading token that merely looks numeric must not be eaten as
    /// a timestamp.
    @Test func numericWordIsNotATimestamp() {
        let parsed = LogLineParser.parse("404 not found")
        #expect(parsed.timestamp == nil)
        #expect(parsed.message == "404 not found")
    }

    @Test func podNameAndSuffix() {
        #expect(LogLineParser.podName(from: "pod/web-7d4b9-abc12/nginx") == "web-7d4b9-abc12")
        #expect(LogLineParser.podName(from: "weird") == "weird")
        #expect(LogLineParser.shortSuffix("web-7d4b9-abc12") == "abc12")
        #expect(LogLineParser.shortSuffix("nodash") == "nodash")
    }

    /// The hash feeds a modulo palette pick; it must be deterministic and
    /// must not trap on any input (the abs(Int.min) case from finding 6).
    @Test func stableHashIsStable() {
        #expect(LogLineParser.stableHash("web-abc") == LogLineParser.stableHash("web-abc"))
        _ = LogLineParser.stableHash("") // must not trap
    }
}

// Pins the YAML helpers behind the editor: top-level key detection and the
// manifest cleanup that keeps `kubectl apply` from stale-version conflicts.
struct YAMLTextTests {
    @Test func topLevelKeyDetection() {
        #expect(YAMLHighlighter.topLevelKey(of: "metadata:") == "metadata")
        #expect(YAMLHighlighter.topLevelKey(of: "status: {}") == "status")
        #expect(YAMLHighlighter.topLevelKey(of: "  nested:") == nil)
        #expect(YAMLHighlighter.topLevelKey(of: "- item:") == nil)
        #expect(YAMLHighlighter.topLevelKey(of: "# comment:") == nil)
        #expect(YAMLHighlighter.topLevelKey(of: "no colon") == nil)
    }

    @Test func editableStripsStatusAndVolatileMetadata() {
        let yaml = """
        apiVersion: v1
        kind: Pod
        metadata:
          name: web
          uid: abc-123
          resourceVersion: "4242"
          generation: 7
          creationTimestamp: "2026-07-24T09:12:33Z"
          labels:
            app: web
        spec:
          nodeName: minikube
        status:
          phase: Running
        """
        let cleaned = ManifestCleaner.editable(yaml)
        #expect(!cleaned.contains("status:"))
        #expect(!cleaned.contains("phase: Running"))
        #expect(!cleaned.contains("uid:"))
        #expect(!cleaned.contains("resourceVersion:"))
        #expect(!cleaned.contains("generation:"))
        #expect(!cleaned.contains("creationTimestamp:"))
        #expect(cleaned.contains("name: web"))
        #expect(cleaned.contains("app: web"))
        #expect(cleaned.contains("nodeName: minikube"))
    }

    /// Only *top-level* metadata's direct children are stripped: a uid inside
    /// ownerReferences (deeper indentation) must survive.
    @Test func editableKeepsDeepUIDs() {
        let yaml = """
        metadata:
          name: web
          ownerReferences:
          - kind: ReplicaSet
            uid: keep-me
        """
        let cleaned = ManifestCleaner.editable(yaml)
        #expect(cleaned.contains("uid: keep-me"))
    }

    /// `---` resets the top-level key tracker so a second document's fields
    /// aren't treated as still being inside the previous block.
    @Test func documentSeparatorResetsContext() {
        let yaml = """
        status:
          phase: Running
        ---
        kind: ConfigMap
        """
        let cleaned = ManifestCleaner.editable(yaml)
        #expect(!cleaned.contains("phase: Running"))
        #expect(cleaned.contains("kind: ConfigMap"))
    }
}
