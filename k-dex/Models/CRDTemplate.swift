import Foundation

/// Synthesizes a starting manifest for a CRD-backed kind from the CRD's own
/// OpenAPI v3 structural schema — the closest thing to a template a cluster
/// carries for its custom resources (plain CRDs ship no sample manifests;
/// OLM's alm-examples exist only on OLM-managed clusters).
///
/// Emission rules, tuned for a useful starting point over completeness —
/// operator schemas run to megabytes, and emitting every optional field of a
/// Prometheus CR would produce an unusable wall:
/// - required fields are emitted at any depth;
/// - optional fields only near the surface (depth ≤ 2 below `spec`);
/// - declared defaults win, then the first enum value, then a type
///   placeholder (`""`, `0`, `false`);
/// - `x-kubernetes-preserve-unknown-fields` objects emit `{}`;
/// - arrays emit one example element;
/// - recursion hard-stops at depth 8 (schemas can self-nest);
/// - object keys emit required-first, alphabetical within each group, so the
///   output is deterministic.
nonisolated enum CRDTemplate {
    /// Nil when the CRD carries no usable `spec` schema — callers keep the
    /// generic stub.
    static func generate(fromCRD crd: JSONValue, kind: ResourceKind, namespace: String) -> String? {
        let versions = crd["spec"]["versions"].array
        let version = versions.first { $0["name"].stringValue == kind.version && ($0["served"].bool ?? false) }
            ?? versions.first { $0["served"].bool ?? false }
        guard let version else { return nil }
        let specSchema = version["schema"]["openAPIV3Schema"]["properties"]["spec"]
        guard !specSchema.isNull else { return nil }

        let group = crd["spec"]["group"].stringValue
        let versionName = version["name"].stringValue
        var lines: [String] = []
        lines.append("apiVersion: \(group.isEmpty ? versionName : "\(group)/\(versionName)")")
        lines.append("kind: \(kind.kindName)")
        lines.append("metadata:")
        lines.append("  name: my-\(kind.kindName.lowercased())")
        if kind.isNamespaced {
            lines.append("  namespace: \(namespace)")
        }
        emit(key: "spec", schema: specSchema, indent: "", depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    // MARK: Emission

    private static let maxDepth = 8
    private static let optionalDepthLimit = 2

    /// One rendered schema node: the remainder of its `key…` line, plus
    /// following lines expressed relative to the key's indentation.
    private struct Rendered {
        let suffix: String
        let body: [String]
    }

    private static func emit(key: String, schema: JSONValue, indent: String, depth: Int, into lines: inout [String]) {
        let rendered = render(schema: schema, depth: depth)
        lines.append(indent + key + rendered.suffix)
        lines.append(contentsOf: rendered.body.map { indent + $0 })
    }

    private static func render(schema: JSONValue, depth: Int) -> Rendered {
        switch schema["type"].stringValue {
        case "object":
            let properties = schema["properties"].object
            guard !properties.isEmpty, depth < maxDepth else { return Rendered(suffix: ": {}", body: []) }
            let required = Set(schema["required"].array.map(\.stringValue))
            let children = orderedKeys(properties, required: required).filter { name in
                required.contains(name) || depth < optionalDepthLimit
            }
            guard !children.isEmpty else { return Rendered(suffix: ": {}", body: []) }
            var body: [String] = []
            for name in children {
                emit(key: name, schema: properties[name] ?? .null, indent: "  ", depth: depth + 1, into: &body)
            }
            return Rendered(suffix: ":", body: body)
        case "array":
            guard depth < maxDepth else { return Rendered(suffix: ": []", body: []) }
            let items = schema["items"]
            if items["type"].stringValue == "object", !items["properties"].object.isEmpty {
                let element = render(schema: items, depth: depth + 1)
                if element.suffix == ":", let first = element.body.first {
                    // The element's body lines all carry a uniform two-space
                    // child indent; re-prefix into a single "- " list item.
                    var body = ["  - " + String(first.dropFirst(2))]
                    body += element.body.dropFirst().map { "    " + String($0.dropFirst(2)) }
                    return Rendered(suffix: ":", body: body)
                }
                return Rendered(suffix: ": []", body: [])
            }
            return Rendered(suffix: ":", body: ["  - " + scalarValue(items)])
        default:
            return Rendered(suffix: ": " + scalarValue(schema), body: [])
        }
    }

    /// Required keys first, alphabetical within each group — object order is
    /// lost in decoding, so this keeps the output deterministic.
    private static func orderedKeys(_ properties: [String: JSONValue], required: Set<String>) -> [String] {
        let all = properties.keys.sorted()
        return all.filter { required.contains($0) } + all.filter { !required.contains($0) }
    }

    private static func scalarValue(_ schema: JSONValue) -> String {
        if !schema["default"].isNull { return literal(schema["default"]) }
        if let firstEnum = schema["enum"].array.first { return literal(firstEnum) }
        if schema["x-kubernetes-int-or-string"].bool == true { return "0" }
        switch schema["type"].stringValue {
        case "integer", "number": return "0"
        case "boolean": return "false"
        case "string": return "\"\""
        default: return "{}" // preserve-unknown-fields or untyped
        }
    }

    /// YAML-safe literal for a schema-supplied value: strings quoted so
    /// enum values like "ON"/"yes" can't be misread as booleans.
    private static func literal(_ value: JSONValue) -> String {
        if let text = value.string { return "\"\(text)\"" }
        return value.displayString
    }
}
