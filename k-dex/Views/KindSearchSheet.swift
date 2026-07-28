import SwiftUI

/// ⌘K command palette: type-ahead search over every resource kind — built-ins
/// and cluster CRDs, hidden ones included — jumping straight to its list.
/// Rendered as an in-window overlay so clicking anywhere outside closes it.
struct KindSearchOverlay: View {
    @Environment(AppModel.self) private var model

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var matches: [ResourceKind] {
        let all = model.kindCatalog
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(q)
                || $0.kindName.lowercased().contains(q)
                || $0.cliName.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop; clicking it dismisses the palette.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            palette
        }
        .onExitCommand { close() }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Go to resource…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = matches.first { open(first) }
                    }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            // Fixed height so the centered card doesn't bounce while typing.
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 440)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { kind in
                            KindRow(kind: kind) { open(kind) }
                        }
                    }
                    .padding(10)
                }
                .frame(height: 440)
            }
        }
        .frame(width: 660)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .onAppear { searchFocused = true }
    }

    private func open(_ kind: ResourceKind) {
        model.sidebarSelection = .resource(kind)
        close()
    }

    private func close() {
        model.showKindSearch = false
    }
}

private struct KindRow: View {
    let kind: ResourceKind
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: kind.icon)
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text(kind.displayName)
                    .font(.system(size: 14))
                if kind.isCustom {
                    Text("CRD")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(kind.cliName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                hovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
