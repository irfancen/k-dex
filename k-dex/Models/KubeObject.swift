import Foundation

/// A single Kubernetes object of any kind, backed by its raw JSON.
nonisolated struct KubeObject: Identifiable, Sendable, Hashable {
    let raw: JSONValue
    let name: String
    let namespace: String
    let uid: String
    let resourceVersion: String
    let creationDate: Date?

    init(raw: JSONValue) {
        self.raw = raw
        let metadata = raw["metadata"]
        self.name = metadata["name"].stringValue
        self.namespace = metadata["namespace"].stringValue
        self.uid = metadata["uid"].stringValue
        self.resourceVersion = metadata["resourceVersion"].stringValue
        self.creationDate = Fmt.parseDate(metadata["creationTimestamp"].string)
    }

    var id: String { uid.isEmpty ? "\(namespace)/\(name)" : uid }

    var labels: [String: String] { raw["metadata"]["labels"].stringDictionary }
    var annotations: [String: String] { raw["metadata"]["annotations"].stringDictionary }
    var isTerminating: Bool { raw["metadata"]["deletionTimestamp"].string != nil }

    /// The controller that owns this object, e.g. "ReplicaSet/web-7d4b9".
    var controlledBy: String? {
        let owners = raw["metadata"]["ownerReferences"].array
        guard let first = owners.first else { return nil }
        return "\(first["kind"].stringValue)/\(first["name"].stringValue)"
    }

    static func == (lhs: KubeObject, rhs: KubeObject) -> Bool {
        lhs.id == rhs.id && lhs.resourceVersion == rhs.resourceVersion
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(resourceVersion)
    }
}

nonisolated enum KubeJSON {
    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a `kubectl get ... -o json` List into objects.
    static func objects(fromListData data: Data) throws -> [KubeObject] {
        try decode(data)["items"].array.map(KubeObject.init(raw:))
    }
}
