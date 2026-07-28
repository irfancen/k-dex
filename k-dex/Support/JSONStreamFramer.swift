import Foundation

/// Splits a byte stream of concatenated JSON documents — the shape of
/// `kubectl get --watch -o json` output — into complete documents by tracking
/// brace depth outside string literals. Thread-safe; fed from pipe-drain
/// threads.
nonisolated final class JSONStreamFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var scanned = 0
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var docStart: Int?

    /// Appends a chunk and returns any documents it completed.
    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: data)
        var documents: [Data] = []

        while scanned < buffer.count {
            let byte = buffer[scanned]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    if docStart != nil { inString = true }
                case UInt8(ascii: "{"):
                    if docStart == nil { docStart = scanned }
                    depth += 1
                case UInt8(ascii: "}"):
                    if docStart != nil {
                        depth -= 1
                        if depth == 0, let start = docStart {
                            documents.append(Data(buffer[start...scanned]))
                            docStart = nil
                        }
                    }
                default:
                    break // whitespace between documents
                }
            }
            scanned += 1
        }

        // Compact: keep only the current partial document (if any).
        let keep = docStart ?? scanned
        if keep > 0 {
            buffer.removeFirst(keep)
            scanned -= keep
            if docStart != nil { docStart = 0 }
        }
        return documents
    }
}
