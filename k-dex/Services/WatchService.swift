import Foundation

/// One long-lived `kubectl get --watch` per visible resource list. Events are
/// framed, decoded off the main thread, and delivered as batched
/// upserts/deletes — so the UI updates the moment the cluster changes and
/// polling is demoted to reconciliation.
@MainActor
final class KubectlWatcher {
    struct Spec: Equatable {
        let kind: ResourceKind
        let context: String
        let namespace: String?
        let filter: AppModel.PodFilter?
    }

    private(set) var spec: Spec?
    private var process: Process?
    /// Monotonic launch token: a superseded watcher's delayed onExit must not
    /// be attributed to its identically-specced replacement (which would
    /// count phantom failures and eventually disable live watch).
    private var runToken = 0

    var isRunning: Bool { process?.isRunning ?? false }

    func start(
        spec: Spec,
        onEvents: @escaping @MainActor ([KubeObject], [String]) -> Void,
        onExit: @escaping @MainActor () -> Void
    ) {
        stop()
        self.spec = spec

        var args = [
            "get", spec.kind.cliName, "-o", "json",
            "--watch", "--output-watch-events=true",
            "--context", spec.context,
        ]
        if spec.kind == .pods, let filter = spec.filter {
            args += [filter.isFieldSelector ? "--field-selector" : "-l", filter.selector]
        }
        if spec.kind.isNamespaced {
            if let namespace = spec.namespace { args += ["-n", namespace] } else { args += ["--all-namespaces"] }
        }

        let framer = JSONStreamFramer()
        let token = runToken
        do {
            process = try ProcessRunner.streamData("kubectl", args, onData: { [weak self] chunk in
                let documents = framer.append(chunk)
                guard !documents.isEmpty else { return }
                var upserts: [KubeObject] = []
                var deletes: [String] = []
                for document in documents {
                    guard let root = try? KubeJSON.decode(document) else { continue }
                    Self.collect(root, upserts: &upserts, deletes: &deletes)
                }
                guard !upserts.isEmpty || !deletes.isEmpty else { return }
                let up = upserts
                let del = deletes
                Task { @MainActor in
                    guard let self, self.runToken == token else { return }
                    onEvents(up, del)
                }
            }, onExit: { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.runToken == token else { return }
                    onExit()
                }
            })
        } catch {
            process = nil
            self.spec = nil
            Task { @MainActor in onExit() }
        }
    }

    func stop() {
        runToken &+= 1
        spec = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    /// Accepts both watch-event envelopes ({"type":…,"object":…}) and bare
    /// object/List documents (kubectl's initial listing), so either output
    /// shape upserts correctly.
    private nonisolated static func collect(
        _ root: JSONValue,
        upserts: inout [KubeObject],
        deletes: inout [String]
    ) {
        if let type = root["type"].string, !root["object"].isNull {
            let object = KubeObject(raw: root["object"])
            guard !object.name.isEmpty else { return }
            if type == "DELETED" {
                deletes.append(object.id)
            } else {
                upserts.append(object)
            }
            return
        }
        if root["kind"].stringValue.hasSuffix("List") {
            upserts.append(contentsOf: root["items"].array.map(KubeObject.init(raw:)))
        } else if !root["metadata"]["name"].stringValue.isEmpty {
            upserts.append(KubeObject(raw: root))
        }
    }
}
