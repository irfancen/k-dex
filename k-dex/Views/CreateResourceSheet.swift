import SwiftUI

/// "New <Kind>" sheet: a template manifest the user edits and applies.
struct CreateResourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: ResourceKind

    @State private var yaml: String
    @State private var applying = false
    @State private var errorMessage: String?

    init(kind: ResourceKind, namespace: String?) {
        self.kind = kind
        _yaml = State(initialValue: ResourceTemplates.template(for: kind, namespace: namespace ?? "default"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New \(kind.kindName)")
                    .font(.headline)
                Spacer()
                Text("Created with kubectl apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            YAMLEditor(text: $yaml)
                .frame(minWidth: 640, minHeight: 440)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            HStack {
                if applying {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying || yaml.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func create() {
        applying = true
        errorMessage = nil
        Task {
            do {
                _ = try await model.applyYAML(yaml)
                applying = false
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                applying = false
            }
        }
    }
}

nonisolated enum ResourceTemplates {
    static func template(for kind: ResourceKind, namespace: String) -> String {
        switch kind {
        case .deployments:
            return """
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: my-app
              namespace: \(namespace)
              labels:
                app: my-app
            spec:
              replicas: 2
              selector:
                matchLabels:
                  app: my-app
              template:
                metadata:
                  labels:
                    app: my-app
                spec:
                  containers:
                    - name: app
                      image: nginx:1.27
                      ports:
                        - containerPort: 80
                      resources:
                        requests:
                          cpu: 100m
                          memory: 128Mi
                        limits:
                          cpu: 250m
                          memory: 256Mi
            """
        case .services:
            return """
            apiVersion: v1
            kind: Service
            metadata:
              name: my-service
              namespace: \(namespace)
            spec:
              type: ClusterIP
              selector:
                app: my-app
              ports:
                - port: 80
                  targetPort: 80
                  protocol: TCP
            """
        case .configMaps:
            return """
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: my-config
              namespace: \(namespace)
            data:
              KEY: value
            """
        case .secrets:
            return """
            apiVersion: v1
            kind: Secret
            metadata:
              name: my-secret
              namespace: \(namespace)
            type: Opaque
            stringData:
              KEY: value
            """
        case .namespaces:
            return """
            apiVersion: v1
            kind: Namespace
            metadata:
              name: my-namespace
            """
        case .persistentVolumeClaims:
            return """
            apiVersion: v1
            kind: PersistentVolumeClaim
            metadata:
              name: my-claim
              namespace: \(namespace)
            spec:
              accessModes:
                - ReadWriteOnce
              resources:
                requests:
                  storage: 1Gi
            """
        case .cronJobs:
            return """
            apiVersion: batch/v1
            kind: CronJob
            metadata:
              name: my-cronjob
              namespace: \(namespace)
            spec:
              schedule: "*/5 * * * *"
              jobTemplate:
                spec:
                  template:
                    spec:
                      restartPolicy: OnFailure
                      containers:
                        - name: job
                          image: busybox:1.36
                          command: ["sh", "-c", "date; echo hello"]
            """
        case .jobs:
            return """
            apiVersion: batch/v1
            kind: Job
            metadata:
              name: my-job
              namespace: \(namespace)
            spec:
              template:
                spec:
                  restartPolicy: Never
                  containers:
                    - name: job
                      image: busybox:1.36
                      command: ["sh", "-c", "echo hello"]
              backoffLimit: 3
            """
        case .ingresses:
            return """
            apiVersion: networking.k8s.io/v1
            kind: Ingress
            metadata:
              name: my-ingress
              namespace: \(namespace)
            spec:
              rules:
                - host: example.local
                  http:
                    paths:
                      - path: /
                        pathType: Prefix
                        backend:
                          service:
                            name: my-service
                            port:
                              number: 80
            """
        default:
            let namespaceLine = kind.isNamespaced ? "\n  namespace: \(namespace)" : ""
            return """
            apiVersion: \(kind.defaultAPIVersion)
            kind: \(kind.kindName)
            metadata:
              name: my-\(kind.kindName.lowercased())\(namespaceLine)
            """
        }
    }
}
