import Foundation
import Testing
@testable import K_Dex

// Pins the timestamp parsing shapes the code review verified by hand (all
// the RFC3339 variants Kubernetes and Helm emit) and the kubectl-style
// age/duration rendering.
struct FormattersTests {
    @Test(arguments: [
        "2024-05-05T10:00:00Z",
        "2024-05-05T10:00:00.123Z",
        "2024-05-05T10:00:00.123456789Z",
        "2024-05-05T12:00:00+02:00",
        "2024-05-05T03:00:00-07:00",
        "2024-05-05T10:00:00.123", // fractional, zoneless → append-Z fallback
    ])
    func parsesKubernetesTimestamps(_ raw: String) throws {
        let date = try #require(Fmt.parseDate(raw))
        // All the arguments above are the same instant, 2024-05-05T10:00:00Z
        // (fractions are deliberately truncated by the parser).
        #expect(date == Fmt.parseDate("2024-05-05T10:00:00Z"))
    }

    @Test func rejectsGarbage() {
        #expect(Fmt.parseDate(nil) == nil)
        #expect(Fmt.parseDate("") == nil)
        #expect(Fmt.parseDate("yesterday") == nil)
    }

    @Test func ageRendersKubectlStyle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            Fmt.age(now.addingTimeInterval(-secondsAgo), relativeTo: now)
        }
        #expect(age(45) == "45s")
        #expect(age(120) == "2m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(3 * 86400) == "3d")
        #expect(age(2 * 365 * 86400) == "2y")
        #expect(Fmt.age(nil) == "–")
        // Clock skew (object "created in the future") clamps to 0s.
        #expect(Fmt.age(now.addingTimeInterval(60), relativeTo: now) == "0s")
    }

    @Test func durationRendersCompactly() {
        let start = Date(timeIntervalSince1970: 0)
        func duration(_ seconds: TimeInterval) -> String {
            Fmt.duration(from: start, to: start.addingTimeInterval(seconds))
        }
        #expect(duration(32) == "32s")
        #expect(duration(332) == "5m32s")
        #expect(duration(3 * 3600 + 5 * 60) == "3h5m")
        #expect(Fmt.duration(from: nil, to: Date()) == "–")
    }
}
