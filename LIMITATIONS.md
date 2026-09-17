# Known Limitations

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). After the mitigation pass
that added the live-watch overlay, metrics-API queries, change detection,
background pausing, and the kubectl version check, these are the limitations
that remain — and why each one is deliberately not being fixed right now.

| Limitation | Nature | Revisit when |
| --- | --- | --- |
| No Mac App Store build yet | Built, not released | Packaging and review are done |
| One cluster at a time | Deferred refactor | Multi-cluster is actually wanted |
| Overview & Helm still poll | Deliberate trade-off | Dashboards feel stale in practice |
| Metrics lag by 15–60 s | Upstream (metrics-server) | A richer telemetry source is added |
| Watch events carry managedFields | Upstream (kubectl) | Large clusters make events heavy |
| Everything runs through kubectl | Philosophy, not a bug | Never — it *is* the architecture |

## No Mac App Store build yet (the released build keeps App Sandbox off)

**What ships today:** the notarized direct download, unsandboxed, which is
what lets any kubeconfig work — including auth plugins K-Dex has never heard
of. That is a feature of this build, not an accident, and it is not going
away.

**What used to be written here** was that the store was closed off
structurally, because a sandboxed app cannot execute the user's own kubectl or
auth plugins and the only way out was an in-process Kubernetes client. The
first half is true; the conclusion was wrong. A sandboxed build does not need
to reach outside its container — it needs to bring the work inside. kubectl is
bundled and inherit-signed, the kubeconfig is mirrored into the container with
certificates inlined, and a bundled shim answers kubectl's own ExecCredential
protocol with credentials the app obtained natively. `ARCHITECTURE.md` §9
describes the mechanism.

**Where it actually stands:** the mechanism is built and has been exercised
against real clusters — certificate-based (minikube) and EKS via AWS IAM
Identity Center, with no AWS CLI installed. It is **not released**: it is not
yet part of the Xcode project as a build configuration, nothing is submitted,
and no App Review has happened. Treat it as proven, not shipped.

**What stays impossible in a sandboxed build,** permanently and by design:

- **Credential plugins with no built-in equivalent** — corporate SSO wrappers,
  Teleport `tsh`, Vault helpers, cloud CLIs not natively implemented. The app
  names these clusters and points at the direct download rather than failing
  obscurely.
- **Wrapping other CLIs as features** — Helm write operations would mean
  reimplementing Helm. Browsing releases stays, since that is native secret
  decoding.
- **Terminal-identical behaviour** — the app signs in separately from your
  shell, so sessions and error text differ.
- **Silent file access** — one grant per directory the kubeconfig references,
  which for minikube means `~/.minikube` as well as `~/.kube`.

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

## Everything runs through kubectl

Not a bug to fix — it's the load-bearing decision. The binary *is* the auth
layer, the TLS stack, and the compatibility guarantee; replacing it means the
embedded-client approach and its auth burden (see the pros/cons section of
the architecture doc). Shipped builds bundle kubectl inside the app, so users
don't need it installed; the sharp edges are mitigated rather than removed:
a Settings override for using your own binary, PATH resolution for GUI apps
when falling back, and a version check at boot that warns before an old
kubectl breaks watch or metrics quietly.
