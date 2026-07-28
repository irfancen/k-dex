import Foundation

/// Parses and formats Kubernetes resource quantities (CPU cores, memory bytes).
nonisolated enum Quantity {
    /// "100m" → 100, "1" → 1000, "0.5" → 500, "12345678n" → ~12.3 (metrics-server nanocores).
    static func cpuMillicores(_ raw: String) -> Double? {
        guard !raw.isEmpty else { return nil }
        let value: Double?
        if raw.hasSuffix("n") { value = Double(raw.dropLast()).map { $0 / 1_000_000 } }
        else if raw.hasSuffix("u") { value = Double(raw.dropLast()).map { $0 / 1_000 } }
        else if raw.hasSuffix("m") { value = Double(raw.dropLast()) }
        else if raw.hasSuffix("k") { value = Double(raw.dropLast()).map { $0 * 1_000_000 } }
        else if raw.hasSuffix("M") { value = Double(raw.dropLast()).map { $0 * 1_000_000_000 } }
        else if raw.hasSuffix("G") { value = Double(raw.dropLast()).map { $0 * 1_000_000_000_000 } }
        else { value = Double(raw).map { $0 * 1000 } }
        // Double("inf")/Double("nan") parse; formatting them would trap Int().
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// "128Mi", "1Gi", "500M", "1073741824" → bytes.
    static func memoryBytes(_ raw: String) -> Double? {
        guard !raw.isEmpty else { return nil }
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824),
            ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624), ("Ei", 1_152_921_504_606_846_976),
            ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18),
            ("m", 1e-3), // millibytes: absurd but legal, emitted by some controllers
        ]
        var value = Double(raw)
        for (suffix, multiplier) in suffixes where raw.hasSuffix(suffix) {
            value = Double(raw.dropLast(suffix.count)).map { $0 * multiplier }
            break
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func formatCPU(millicores: Double) -> String {
        guard millicores.isFinite else { return "–" }
        if millicores >= 1000 {
            let cores = millicores / 1000
            return cores == cores.rounded() ? String(Int(cores)) : String(format: "%.1f", cores)
        }
        return "\(Int(millicores.rounded()))m"
    }

    static func formatMemory(bytes: Double) -> String {
        guard bytes.isFinite else { return "–" }
        let ki = 1024.0, mi = 1_048_576.0, gi = 1_073_741_824.0
        if bytes >= gi {
            let value = bytes / gi
            return value == value.rounded() ? "\(Int(value))Gi" : String(format: "%.1fGi", value)
        }
        if bytes >= mi { return "\(Int((bytes / mi).rounded()))Mi" }
        if bytes >= ki { return "\(Int((bytes / ki).rounded()))Ki" }
        return "\(Int(bytes))B"
    }
}
