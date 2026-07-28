# K-Dex

A clean, minimal Kubernetes UI for macOS, built with SwiftUI.

## Features

- **Cluster browsing** — switch between kubeconfig contexts; filter by namespace.
- **Resources** — Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, Services, Ingresses, EndpointSlices, NetworkPolicies, ConfigMaps, Secrets, HPAs, PVCs, PVs, StorageClasses, RBAC, Nodes, Namespaces, Events — with kind-specific columns and status badges.
- **Detail inspector** — overview (metadata, containers, conditions, labels, secret/configmap data with reveal), live YAML, and per-object events.
- **Pod logs** — streamed with follow, container picker, and filtering.
- **Actions** — delete, rollout restart, scale (with confirmations).
- **Edit & apply YAML** — in-app editor backed by `kubectl apply`.
- **Port forwarding** — pods and services, managed from a toolbar popover.
- **Helm releases** — read directly from release Secrets (no helm CLI needed): chart, status, values, manifest, notes, history.
- **Metrics** — pod/node CPU & memory via metrics-server (`kubectl top`), when available.

## How it works

The app shells out to your local `kubectl` (`Services/ProcessRunner.swift`), so every auth
mechanism your kubeconfig supports (EKS/GKE/AKS exec plugins, certs, tokens) works untouched.
Responses are parsed as raw JSON into a dynamic `JSONValue` tree; per-kind table columns and
status logic live in `Models/ResourceKind.swift`. Data refreshes by polling (configurable
interval) plus manual ⌘R.

Requirements: macOS 26+, `kubectl` installed (path configurable in Settings). App Sandbox is
disabled because the app must read `~/.kube` and spawn `kubectl`.

## Roadmap ideas

- Multi-pod aggregated logs
- Exec shell into containers
- CRD browsing
- Helm uninstall/rollback (via helm CLI)
- Watch-based live updates (`kubectl proxy` + REST)
