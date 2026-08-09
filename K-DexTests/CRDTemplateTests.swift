import Foundation
import Testing
@testable import K_Dex

// Pins the schema-driven CRD template generator: required/optional depth
// rules, defaults, enums, arrays, preserve-unknown blobs, version selection,
// and deterministic ordering.
struct CRDTemplateTests {
    private let widgetKind = ResourceKind(
        group: "example.com", version: "v1", plural: "widgets",
        kindName: "Widget", isNamespaced: true, isCustom: true
    )

    private func crd(_ json: String) throws -> JSONValue {
        try KubeJSON.decode(Data(json.utf8))
    }

    private let widgetCRD = """
    {"metadata": {"name": "widgets.example.com"},
     "spec": {
      "group": "example.com",
      "versions": [
        {"name": "v1alpha1", "served": false,
         "schema": {"openAPIV3Schema": {"properties": {"spec": {"type": "object",
           "properties": {"old": {"type": "string"}}}}}}},
        {"name": "v1", "served": true,
         "schema": {"openAPIV3Schema": {"type": "object", "properties": {
           "spec": {
             "type": "object",
             "required": ["size", "engine", "rules"],
             "properties": {
               "size": {"type": "integer"},
               "engine": {
                 "type": "object",
                 "required": ["mode"],
                 "properties": {
                   "mode": {"type": "string", "enum": ["Auto", "Manual"]},
                   "threads": {"type": "integer", "default": 4}
                 }
               },
               "enabled": {"type": "boolean"},
               "tags": {"type": "array", "items": {"type": "string"}},
               "rules": {"type": "array", "items": {
                 "type": "object",
                 "required": ["port"],
                 "properties": {"port": {"x-kubernetes-int-or-string": true}}
               }},
               "overrides": {"type": "object", "x-kubernetes-preserve-unknown-fields": true},
               "deep": {
                 "type": "object",
                 "properties": {
                   "optionalAtLimit": {"type": "string"},
                   "inner": {
                     "type": "object",
                     "properties": {
                       "optionalPastLimit": {"type": "string"}
                     }
                   }
                 }
               }
             }
           },
           "status": {"type": "object"}
         }}}}
      ]
    }}
    """

    @Test func generatesFromServedVersionSchema() throws {
        let yaml = try #require(CRDTemplate.generate(fromCRD: crd(widgetCRD), kind: widgetKind, namespace: "demo"))
        #expect(yaml == """
        # Generated from the widgets.example.com schema:
        # required fields are filled in; optional sections are collapsed
        # ({} / []) — expand the ones you need.
        apiVersion: example.com/v1
        kind: Widget
        metadata:
          name: my-widget
          namespace: demo
        spec:
          engine:
            mode: "Auto"
            threads: 4
          rules:
            - port: 0
          size: 0
          deep: {}
          enabled: false
          overrides: {}
          tags: []
        """)
    }

    @Test func completeModeExpandsEverything() throws {
        let yaml = try #require(CRDTemplate.generate(
            fromCRD: crd(widgetCRD), kind: widgetKind, namespace: "demo", detail: .complete
        ))
        #expect(yaml == """
        # Generated from the widgets.example.com schema:
        # every field, required and optional — trim what you don't need.
        apiVersion: example.com/v1
        kind: Widget
        metadata:
          name: my-widget
          namespace: demo
        spec:
          engine:
            mode: "Auto"
            threads: 4
          rules:
            - port: 0
          size: 0
          deep:
            inner:
              optionalPastLimit: ""
            optionalAtLimit: ""
          enabled: false
          overrides: {}
          tags:
            - ""
        """)
    }

    /// The unserved v1alpha1 must be skipped even though it comes first.
    @Test func unservedVersionsAreSkipped() throws {
        let yaml = try #require(CRDTemplate.generate(fromCRD: crd(widgetCRD), kind: widgetKind, namespace: "demo"))
        #expect(!yaml.contains("old"))
        #expect(yaml.contains("example.com/v1"))
    }

    @Test func noSpecSchemaMeansNoTemplate() throws {
        let bare = """
        {"spec": {"group": "example.com", "versions": [
          {"name": "v1", "served": true,
           "schema": {"openAPIV3Schema": {"type": "object", "properties": {}}}}
        ]}}
        """
        #expect(CRDTemplate.generate(fromCRD: try crd(bare), kind: widgetKind, namespace: "demo") == nil)
    }

    @Test func clusterScopedKindOmitsNamespace() throws {
        var clusterKind = widgetKind
        clusterKind = ResourceKind(
            group: "example.com", version: "v1", plural: "widgets",
            kindName: "Widget", isNamespaced: false, isCustom: true
        )
        let yaml = try #require(CRDTemplate.generate(fromCRD: crd(widgetCRD), kind: clusterKind, namespace: "demo"))
        #expect(!yaml.contains("namespace:"))
        _ = clusterKind
    }

    /// The generated manifest must survive the app's own YAML→apply path
    /// assumptions: no tabs, consistent two-space indentation.
    @Test func outputUsesTwoSpaceIndentationOnly() throws {
        let yaml = try #require(CRDTemplate.generate(fromCRD: crd(widgetCRD), kind: widgetKind, namespace: "demo"))
        for line in yaml.split(separator: "\n") {
            #expect(!line.contains("\t"))
            let leading = line.prefix { $0 == " " }.count
            #expect(leading % 2 == 0, "odd indent in: \(line)")
        }
    }
}
