import Foundation

/// Parses and formats Kubernetes resource quantities (CPU cores, memory bytes).
nonisolated enum Quantity {
    /// "100m" → 100, "1" → 1000, "0.5" → 500, "12345678n" → ~12.3 (metrics-server nanocores).
    static func cpuMillicores(_ raw: String) -> Double? {
        guard !raw.isEmpty else { return nil }
        if raw.hasSuffix("n"), let value = Double(raw.dropLast()) { return value / 1_000_000 }
        if raw.hasSuffix("u"), let value = Double(raw.dropLast()) { return value / 1_000 }
        if raw.hasSuffix("m"), let value = Double(raw.dropLast()) { return value }
        if let value = Double(raw) { return value * 1000 }
        return nil
    }

    /// "128Mi", "1Gi", "500M", "1073741824" → bytes.
    static func memoryBytes(_ raw: String) -> Double? {
        guard !raw.isEmpty else { return nil }
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824),
            ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624), ("Ei", 1_152_921_504_606_846_976),
            ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18),
        ]
        for (suffix, multiplier) in suffixes where raw.hasSuffix(suffix) {
            return Double(raw.dropLast(suffix.count)).map { $0 * multiplier }
        }
        return Double(raw)
    }

    static func formatCPU(millicores: Double) -> String {
        if millicores >= 1000 {
            let cores = millicores / 1000
            return cores == cores.rounded() ? String(Int(cores)) : String(format: "%.1f", cores)
        }
        return "\(Int(millicores.rounded()))m"
    }

    static func formatMemory(bytes: Double) -> String {
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
