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

    /// A "document" larger than this is stream corruption (e.g. a stray `{`
    /// from a kubectl wrapper script opened a phantom document that will
    /// never close). Reset and resync rather than accumulating forever.
    private static let maxBufferBytes = 8 * 1024 * 1024

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
                    // Quotes toggle string state even between documents, so
                    // braces inside noise like `note: "see {here}"` don't
                    // open phantom documents.
                    inString = true
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

        // Corruption backstop: drop the runaway buffer and resync at the
        // next document boundary.
        if buffer.count > Self.maxBufferBytes {
            buffer.removeAll(keepingCapacity: false)
            scanned = 0
            depth = 0
            inString = false
            escaped = false
            docStart = nil
        }
        return documents
    }
}
