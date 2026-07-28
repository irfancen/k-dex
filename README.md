# K-Dex

A clean, minimal Kubernetes UI for macOS, built with SwiftUI.

## Features

- **Cluster browsing** — switch between kubeconfig contexts; filter by namespace.
- **Live updates** — each list is fed by a Kubernetes watch stream, so changes
  appear the moment they happen; polling only reconciles and refreshes metrics.
- **Every resource kind** — 30+ built-in kinds with kind-specific columns and
  status badges; everything else the cluster serves (aggregated APIs, any CRD)
  is discovered at connect time and reachable via the **⌘K palette**. Installed
  CRDs get their own per-API-group sidebar sections; sidebar sections and items
  are reorderable and hideable.
- **Detail inspector** — overview (metadata, containers, conditions, labels,
  secret/configmap data with reveal), live YAML, per-object events, and the
  pods of a workload or node.
- **Pod & workload logs** — streamed with follow, container picker, filtering,
  wrap/timestamps, aggregated multi-pod logs with color-coded prefixes, and
  crash awareness: a banner on crashed containers with one-click access to the
  previous instance's logs.
- **Overview dashboard** — workload status cards, recent warnings, recent
  restarts, pods running near their limits.
- **Actions** — delete, rollout restart, scale — all confirmed, with namespace
  and context named in the dialog.
- **Create & edit YAML** — per-kind creation templates and an in-app editor
  with syntax highlighting, backed by `kubectl apply`.
- **Port forwarding** — pods and services, managed from a toolbar popover.
- **Helm releases** — read directly from release Secrets (no helm CLI needed):
  chart, status, values, manifest, notes, history — values and manifest behind
  an explicit reveal, since they often contain credentials.
- **Metrics** — pod/node CPU & memory usage bars via metrics-server, when
  available.
- **Auto-updates** via Sparkle.

## How it works

The app drives a bundled `kubectl` (or your own — path configurable in
Settings), so every auth mechanism your kubeconfig supports (EKS/GKE/AKS exec
plugins, certs, tokens) works untouched. Responses are parsed as raw JSON into
a dynamic `JSONValue` tree; kind identity is discovered from the cluster's API,
while columns and status logic are curated per kind. Lists stay current through
`kubectl get --watch` streams, with polling demoted to metrics and periodic
reconciliation.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design and
[LIMITATIONS.md](LIMITATIONS.md) for known trade-offs.

Requirements: macOS 26+. kubectl is bundled with the app. App Sandbox is
disabled because the app must read `~/.kube` and spawn kubectl and your auth
plugins.

## Install

Download the notarized DMG from
[Releases](https://github.com/irfancen/k-dex/releases), or build from source:

```sh
xcodebuild -project k-dex.xcodeproj -scheme k-dex -configuration Release build
```

## Roadmap ideas

- Exec shell into containers
- Helm uninstall/rollback
- Multi-cluster simultaneous views
- Mac App Store edition with native cloud auth

## License

MIT — see [LICENSE](LICENSE).
