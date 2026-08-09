import Foundation

/// Per-kind YAML starting points for the New-resource sheet.
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
        case .statefulSets:
            return """
            apiVersion: apps/v1
            kind: StatefulSet
            metadata:
              name: my-app
              namespace: \(namespace)
              labels:
                app: my-app
            spec:
              serviceName: my-app # must name a headless Service
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
                      volumeMounts:
                        - name: data
                          mountPath: /data
              volumeClaimTemplates:
                - metadata:
                    name: data
                  spec:
                    accessModes: ["ReadWriteOnce"]
                    resources:
                      requests:
                        storage: 1Gi
            """
        case .daemonSets:
            return """
            apiVersion: apps/v1
            kind: DaemonSet
            metadata:
              name: my-agent
              namespace: \(namespace)
              labels:
                app: my-agent
            spec:
              selector:
                matchLabels:
                  app: my-agent
              template:
                metadata:
                  labels:
                    app: my-agent
                spec:
                  containers:
                    - name: agent
                      image: nginx:1.27
                      resources:
                        requests:
                          cpu: 50m
                          memory: 64Mi
                        limits:
                          cpu: 100m
                          memory: 128Mi
            """
        case .horizontalPodAutoscalers:
            return """
            apiVersion: autoscaling/v2
            kind: HorizontalPodAutoscaler
            metadata:
              name: my-app
              namespace: \(namespace)
            spec:
              scaleTargetRef:
                apiVersion: apps/v1
                kind: Deployment
                name: my-app
              minReplicas: 2
              maxReplicas: 5
              metrics:
                - type: Resource
                  resource:
                    name: cpu
                    target:
                      type: Utilization
                      averageUtilization: 80
            """
        case .podDisruptionBudgets:
            return """
            apiVersion: policy/v1
            kind: PodDisruptionBudget
            metadata:
              name: my-app
              namespace: \(namespace)
            spec:
              minAvailable: 1
              selector:
                matchLabels:
                  app: my-app
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
