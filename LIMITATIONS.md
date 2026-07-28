# Known Limitations

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). After the mitigation pass
that added the live-watch overlay, metrics-API queries, change detection,
background pausing, and the kubectl version check, these are the limitations
that remain — and why each one is deliberately not being fixed right now.

| Limitation | Nature | Revisit when |
| --- | --- | --- |
| No Mac App Store distribution | Structural | A native auth layer is worth funding |
| One cluster at a time | Deferred refactor | Multi-cluster is actually wanted |
| Overview & Helm still poll | Deliberate trade-off | Dashboards feel stale in practice |
| Metrics lag by 15–60 s | Upstream (metrics-server) | A richer telemetry source is added |
| Watch events carry managedFields | Upstream (kubectl) | Large clusters make events heavy |
| kubectl must be installed | Philosophy, not a bug | Never — it *is* the architecture |

## No Mac App Store distribution (App Sandbox stays off)

**Why it can't be fixed now:** the sandbox forbids exactly what the
architecture requires. K-Dex must execute arbitrary user-installed binaries —
kubectl itself, plus whatever auth plugin the kubeconfig names
(`aws`, `gke-gcloud-auth-plugin`, `kubelogin`, …) — and those plugins in turn
read `~/.kube`, write their own token caches, and open network connections.
Sandboxed apps may only spawn helpers they ship and sign; there is no
entitlement for "run whatever the user has in `/opt/homebrew/bin`".

**What fixing it would take:** an in-process Kubernetes client with its own
implementations of exec-plugin auth, OIDC refresh, and client certificates —
abandoning the "kubectl owns auth" foundation. That's the embedded-library
approach whose costs are laid out in the architecture doc, made worse by
Swift having no mature client library.

**Interim answer:** notarized direct distribution with the hardened runtime,
which is how comparable tools (including Aptakube and Lens) ship on macOS.

## One cluster at a time

**Why it isn't fixed now:** this stopped being a transport problem when the
watch overlay landed — a second cluster would cost one idle subprocess, not
N× polling churn. What remains is a state-model refactor: `AppModel` holds a
single `selectedContext`, one `objects` array, one selection, one namespace
catalog, and per-kind column state; port forwards and CRD catalogs are
likewise singular. True multi-cluster means one model instance per context,
a merge layer for combined views, per-row cluster affinity for every action
(delete/scale/logs must target the right cluster), and UI to express all of
it. That's a medium project, not a minimal change — and it isn't blocking
anything today, since context switching is instant.

**What fixing it would take:** `AppModel` → per-context instances behind a
coordinator, cluster tags on rows, and a design pass on merged vs. tabbed
presentation.

## Overview and Helm still poll

**Why it isn't fixed now:** the watch overlay covers the *visible resource
list* — one kind, one subprocess. The Overview dashboard aggregates eight
kinds at once; keeping it live would mean eight concurrent watch subprocesses
for a screen that's typically glanced at, not stared at. Helm releases are
even less suited: each change means re-decoding a double-base64+gzip secret
payload, and releases change on the timescale of deploys, not seconds.
Polling those views on the existing cadence is the right cost/benefit.

**What fixing it would take:** either multiplexed watches through a real API
client, or accepting an 8-subprocess dashboard. Neither is justified by how
these views are used.

## Metrics lag behind by 15–60 seconds

**Why it can't be fixed:** metrics-server scrapes kubelets on its own
interval (15 s by default, often longer) and serves the last scrape. Polling
the metrics API faster returns the same numbers; there is no watch endpoint
for metrics. This bound applies to every Kubernetes client, including
Aptakube and `kubectl top` itself.

**What fixing it would take:** a different telemetry source entirely
(Prometheus, VictoriaMetrics) — a feature project far beyond the app's
current scope.

## Watch events carry managedFields

**Why it can't be fixed now:** kubectl strips the server-side-apply
bookkeeping (`metadata.managedFields`) from one-shot `get -o json` output,
but not from `--watch --output-watch-events` envelopes — verified against
kubectl v1.36, where `--show-managed-fields=false` has no effect on the
watch path. Each event therefore parses 2–3× more JSON than it needs. The
cost is per-event and transient (the fields are parsed, then never read), so
it's accepted.

**What fixing it would take:** an upstream kubectl fix, or stripping the keys
client-side before decoding — extra code for an overhead that hasn't shown up
in profiling. Revisit if high-churn clusters make event processing visible.

## kubectl must be installed

Not a bug to fix — it's the load-bearing decision. The binary *is* the auth
layer, the TLS stack, and the compatibility guarantee; removing the
dependency means the embedded-client approach and its auth burden (see the
pros/cons section of the architecture doc). The app mitigates the sharp
edges instead: PATH resolution for GUI apps, a configurable binary path in
Settings, and a version check at boot that warns before old kubectl breaks
watch or metrics quietly.
