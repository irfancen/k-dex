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
}
