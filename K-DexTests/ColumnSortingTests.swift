import Foundation
import Testing
@testable import K_Dex

// Pins the sort-key extraction, especially residual C from the code review:
// a single non-finite key breaks the comparator's strict weak ordering and
// sorted(by:) silently mis-sorts unrelated rows rather than trapping. Both
// branches that parse arbitrary cell text must reject nan/inf.
struct ColumnSortingTests {
    @Test(arguments: [
        // Ready ratios sort by the ready count.
        ("1/2", "Ready", 1.0),
        ("0/3", "Ready", 0.0),
        ("10/10", "Ready", 10.0),
        // Quantity-aware columns.
        ("155m", "CPU", 155.0),
        ("2m", "CPU Usage", 2.0),
        ("70Mi", "Memory", 73_400_320.0),
        ("70Mi", "Mem", 73_400_320.0),
        // Plain numerics and capacity fallback.
        ("42", "Restarts", 42.0),
        ("1Gi", "Capacity", 1_073_741_824.0),
    ])
    func extractsNumericKeys(_ text: String, _ columnID: String, _ expected: Double) {
        #expect(ColumnSorting.numericValue(text, columnID: columnID) == expected)
    }

    /// Only the first whitespace-separated token is parsed.
    @Test func firstTokenWins() {
        #expect(ColumnSorting.numericValue("155m (2%)", columnID: "CPU") == 155.0)
        #expect(ColumnSorting.numericValue("3 restarts", columnID: "Restarts") == 3.0)
    }

    @Test(arguments: ["–", "", "Pending", "Running"])
    func nonNumericTextYieldsNil(_ text: String) {
        #expect(ColumnSorting.numericValue(text, columnID: "Status") == nil)
    }

    /// Residual C, both branches: the plain-token path (`ccf4bd7`) and the
    /// ready-ratio path (`59a1173`). "nan"/"inf" parse as Double but must
    /// never become sort keys.
    @Test(arguments: [
        ("nan", "Status"), ("inf", "Status"), ("-inf", "Status"),
        ("infinity", "Status"),
        ("nan/1", "Status"), ("inf/3", "Ready"), ("1e400/3", "Ready"),
    ])
    func nonFiniteTokensYieldNil(_ text: String, _ columnID: String) {
        #expect(ColumnSorting.numericValue(text, columnID: columnID) == nil)
    }

    /// The property the comparator actually depends on: whatever comes back
    /// is finite, for any input.
    @Test func neverReturnsNonFinite() {
        let hostile = ["nan", "inf", "-inf", "nan/1", "inf/inf", "1e400",
                       "nanMi", "infm", "0", "3/3", "–", "x"]
        for text in hostile {
            for column in ["CPU", "Memory", "Status", "Ready"] {
                if let value = ColumnSorting.numericValue(text, columnID: column) {
                    #expect(value.isFinite, "\(text) in \(column) produced \(value)")
                }
            }
        }
    }

    // MARK: Comparator ordering laws

    /// A representative key population: dates, numerics, plain text, and the
    /// mixed rows (numeric vs "–") whose ordering finding 13 made total.
    private var keys: [ColumnSorting.SortKey] {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            .init(date: epoch),
            .init(date: epoch.addingTimeInterval(60)),
            .init(date: .distantPast),
            .init(numeric: 0), .init(numeric: 5), .init(numeric: 5),
            .init(numeric: -1), .init(numeric: 1_073_741_824),
            .init(text: "–"), .init(text: "Pending"), .init(text: "Running"),
            .init(text: "web", tieBreak: "demo"), .init(text: "web", tieBreak: "prod"),
            .init(),
        ]
    }

    /// Strict-weak-ordering obligations, pairwise: reflexive sameness and
    /// antisymmetry. sorted(by:) silently mis-sorts when these break (the
    /// residual-C failure mode), so they're pinned directly.
    @Test func compareIsAntisymmetric() {
        for a in keys {
            #expect(ColumnSorting.compare(a, a) == .orderedSame)
            for b in keys {
                let ab = ColumnSorting.compare(a, b)
                let ba = ColumnSorting.compare(b, a)
                switch ab {
                case .orderedSame: #expect(ba == .orderedSame)
                case .orderedAscending: #expect(ba == .orderedDescending)
                case .orderedDescending: #expect(ba == .orderedAscending)
                }
            }
        }
    }

    @Test func comparePrecedence() {
        let older = ColumnSorting.SortKey(date: Date(timeIntervalSince1970: 0))
        let newer = ColumnSorting.SortKey(date: Date(timeIntervalSince1970: 100))
        // Ascending = newest first for dates.
        #expect(ColumnSorting.compare(newer, older) == .orderedAscending)
        // Numeric rows sort ahead of non-numeric ones.
        #expect(ColumnSorting.compare(.init(numeric: 1), .init(text: "–")) == .orderedAscending)
        #expect(ColumnSorting.compare(.init(text: "–"), .init(numeric: 1)) == .orderedDescending)
        // Ties fall back to the tie-break field.
        #expect(ColumnSorting.compare(
            .init(text: "web", tieBreak: "demo"),
            .init(text: "web", tieBreak: "prod")
        ) == .orderedAscending)
    }

    // MARK: Key construction

    @Test func sortKeyRoutesByColumn() throws {
        let object = KubeObject(raw: try KubeJSON.decode(Data("""
        {"metadata": {"name": "web", "namespace": "demo", "uid": "u1",
                      "creationTimestamp": "2024-05-05T10:00:00Z"}}
        """.utf8)))
        let ctx = RowContext()

        let name = ColumnSorting.sortKey(columnID: "name", column: nil, object: object, kind: .pods, ctx: ctx)
        #expect(name.text == "web" && name.tieBreak == "demo")

        let namespace = ColumnSorting.sortKey(columnID: "Namespace", column: nil, object: object, kind: .pods, ctx: ctx)
        #expect(namespace.text == "demo" && namespace.tieBreak == "web")

        let age = ColumnSorting.sortKey(columnID: "Age", column: nil, object: object, kind: .pods, ctx: ctx)
        #expect(age.date == Fmt.parseDate("2024-05-05T10:00:00Z"))

        // A cell-backed column extracts once and parses its own text.
        let cpu = ColumnSpec("CPU", style: .usage) { _, _ in Cell(text: "155m") }
        let key = ColumnSorting.sortKey(columnID: "CPU", column: cpu, object: object, kind: .pods, ctx: ctx)
        #expect(key.numeric == 155.0)
    }
}
