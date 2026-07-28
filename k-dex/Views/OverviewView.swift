import SwiftUI

/// Aptakube-style workload overview: per-kind status cards, recent warnings,
/// recent restarts, and pods running close to their limits.
struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let data = model.overview {
                content(data)
            } else if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.lastError != nil {
                // Banner is in the safeAreaInset; leave the body empty.
                ContentUnavailableView(
                    "Overview Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The cluster could not be reached.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        // Rendered alongside data, not instead of it — a stale dashboard with
        // a visible error beats a confident wrong one.
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.lastError {
                ErrorBanner(message: error) { model.requestRefresh() }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                NamespacePicker()
                PortForwardsButton()
                RefreshControls()
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.selectedNamespace.map { "Namespace: \($0)" } ?? "All namespaces")
    }

    private func content(_ data: OverviewData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(data.summaries) { summary in
                        Button {
                            model.sidebarSelection = .resource(summary.kind)
                        } label: {
                            WorkloadCard(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(alignment: .top, spacing: 24) {
                    warningsSection(data.warnings)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    restartsSection(data.restarts)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                hotPodsSection(data)
            }
            .padding(16)
        }
    }

    // MARK: Sections

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func warningsSection(_ warnings: [OverviewData.Warning]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent Warnings")
            if warnings.isEmpty {
                Text("No warning events. All quiet. 🎉")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(warnings) { warning in
                Button {
                    model.sidebarSelection = .resource(.events)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(warning.reason)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.orange)
                            Text("(\(warning.count)x)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Fmt.age(warning.lastSeen) + " ago")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        if !warning.message.isEmpty {
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func restartsSection(_ restarts: [OverviewData.Restart]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Recent Restarts")
            if restarts.isEmpty {
                Text("No container restarts found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(restarts) { restart in
                Button {
                    model.jumpTo(kind: .pods, namespace: restart.namespace, name: restart.podName)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("\(restart.namespace) / \(restart.podName)")
                                .font(.callout)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            Text(restartDetail(restart))
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text("(\(restart.restarts)x)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Fmt.age(restart.lastAt) + " ago")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func restartDetail(_ restart: OverviewData.Restart) -> String {
        if let exitCode = restart.exitCode {
            return "\(restart.reason) (ExitCode: \(exitCode))"
        }
        return restart.reason
    }

    @ViewBuilder
    private func hotPodsSection(_ data: OverviewData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Abnormal Resource Usage")
            if !data.metricsAvailable {
                Text("Metrics unavailable — install metrics-server to see pods running close to their limits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if data.hotPods.isEmpty {
                Text("No pods above 90% of their CPU or memory limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(data.hotPods) { pod in
                    Button {
                        model.jumpTo(kind: .pods, namespace: pod.namespace, name: pod.podName)
                    } label: {
                        HStack(spacing: 14) {
                            Text("\(pod.namespace) / \(pod.podName)")
                                .font(.callout)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            UsageBar(text: "CPU " + pod.cpuText, usage: pod.cpuFraction.map { UsageValue(fraction: $0, bounded: true) })
                                .frame(width: 150)
                            UsageBar(text: "Mem " + pod.memoryText, usage: pod.memoryFraction.map { UsageValue(fraction: $0, bounded: true) })
                                .frame(width: 150)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Workload card

private struct WorkloadCard: View {
    let summary: OverviewData.KindSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.kind.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(summary.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            segmentedBar

            VStack(alignment: .leading, spacing: 2) {
                if summary.total == 0 {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(summary.buckets.prefix(5)) { bucket in
                    Text("\(bucket.count) \(bucket.label)")
                        .font(.caption)
                        .foregroundStyle(bucket.tone == .neutral ? Color.secondary : bucket.tone.color)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                if summary.total == 0 {
                    Capsule().fill(.quaternary)
                } else {
                    ForEach(summary.buckets) { bucket in
                        Capsule()
                            .fill(bucket.tone == .neutral ? Color.gray.opacity(0.45) : bucket.tone.color)
                            .frame(width: max(3, geo.size.width * CGFloat(bucket.count) / CGFloat(summary.total)))
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}
