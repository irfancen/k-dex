import Foundation

/// UserDefaults persistence for sidebar customization: per-kind
/// visibility and per-section expansion/order. Reads happen inside
/// SidebarView.body (see the orderVersion counter there) — writes from
/// anywhere else won't refresh the UI, a known limitation recorded in
/// CODE-REVIEW.md.
nonisolated enum KindVisibilityStore {
    private static let hiddenKey = "sidebar-hidden-kinds"
    private static let shownKey = "sidebar-shown-kinds"

    static func isVisible(_ kind: ResourceKind) -> Bool {
        if kind.visibleByDefault { return !ids(forKey: hiddenKey).contains(kind.id) }
        return ids(forKey: shownKey).contains(kind.id)
    }

    static func toggle(_ kind: ResourceKind) {
        let key = kind.visibleByDefault ? hiddenKey : shownKey
        var set = ids(forKey: key)
        if set.contains(kind.id) { set.remove(kind.id) } else { set.insert(kind.id) }
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: key)
    }

    private static func ids(forKey key: String) -> Set<String> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init))
    }
}

/// Sidebar section collapse state, shared so RootView can toggle it when a
/// category row is clicked (selected). Sections default to expanded except
/// the ones listed in `collapsedByDefault`, whose user-expansion is stored
/// in a separate override key.
nonisolated enum SidebarSectionStore {
    private static let collapsedKey = "sidebar-collapsed"
    private static let expandedKey = "sidebar-expanded"

    /// Sections that start collapsed until the user opens them.
    static func collapsedByDefault(_ id: String) -> Bool {
        id == "other"
    }

    static func toggle(_ id: String) {
        let key = collapsedByDefault(id) ? expandedKey : collapsedKey
        var set = Set(
            (UserDefaults.standard.string(forKey: key) ?? "")
                .split(separator: ",")
                .map(String.init)
        )
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        UserDefaults.standard.set(set.sorted().joined(separator: ","), forKey: key)
    }
}
