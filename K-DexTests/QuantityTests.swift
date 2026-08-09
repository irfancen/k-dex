import Testing
@testable import K_Dex

// Pins the quantity parsers and formatters, including the non-finite guards
// from code-review finding 6 — Double("nan")/Double("inf") parse in Swift,
// and an unguarded Int() conversion of either traps.
struct QuantityTests {
    @Test(arguments: [
        ("100m", 100.0),
        ("1", 1000.0),
        ("0.5", 500.0),
        ("1500m", 1500.0),
        ("12000000n", 12.0),
        ("2500u", 2.5),
        ("1k", 1_000_000.0),
        ("2M", 2_000_000_000.0),
        ("1G", 1_000_000_000_000.0),
    ])
    func cpuParses(_ raw: String, _ millicores: Double) {
        #expect(Quantity.cpuMillicores(raw) == millicores)
    }

    @Test(arguments: ["", "nan", "inf", "-inf", "nanm", "infm", "banana"])
    func cpuRejects(_ raw: String) {
        #expect(Quantity.cpuMillicores(raw) == nil)
    }

    @Test(arguments: [
        ("128Mi", 134_217_728.0),
        ("1Gi", 1_073_741_824.0),
        ("1Ki", 1024.0),
        ("1Ti", 1_099_511_627_776.0),
        ("500M", 500_000_000.0),
        ("1k", 1000.0),
        ("1073741824", 1_073_741_824.0),
        ("500m", 0.5), // millibytes: absurd but legal
    ])
    func memoryParses(_ raw: String, _ bytes: Double) {
        #expect(Quantity.memoryBytes(raw) == bytes)
    }

    @Test(arguments: ["", "nan", "inf", "nanMi", "infGi"])
    func memoryRejects(_ raw: String) {
        #expect(Quantity.memoryBytes(raw) == nil)
    }

    @Test func cpuFormats() {
        #expect(Quantity.formatCPU(millicores: 100) == "100m")
        #expect(Quantity.formatCPU(millicores: 999) == "999m")
        #expect(Quantity.formatCPU(millicores: 1000) == "1")
        #expect(Quantity.formatCPU(millicores: 1500) == "1.5")
        #expect(Quantity.formatCPU(millicores: 8000) == "8")
        #expect(Quantity.formatCPU(millicores: 0.4) == "0m")
    }

    @Test func memoryFormats() {
        #expect(Quantity.formatMemory(bytes: 512) == "512B")
        #expect(Quantity.formatMemory(bytes: 2048) == "2Ki")
        #expect(Quantity.formatMemory(bytes: 134_217_728) == "128Mi")
        #expect(Quantity.formatMemory(bytes: 1_073_741_824) == "1Gi")
        #expect(Quantity.formatMemory(bytes: 1_610_612_736) == "1.5Gi")
    }

    /// Finding 6's exact trap: formatting a non-finite value must degrade to
    /// a placeholder, never reach a trapping Int() conversion.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func formattersDegradeOnNonFinite(_ value: Double) {
        #expect(Quantity.formatCPU(millicores: value) == "–")
        #expect(Quantity.formatMemory(bytes: value) == "–")
    }
}
