import Foundation
import Testing
@testable import K_Dex

// Pins the watch-stream framer: brace-depth document splitting, the quote
// handling from code-review finding 2 (braces inside quoted noise must not
// open phantom documents), and the 8 MiB corruption backstop (residual A —
// a bare `{` in unquoted noise is indistinguishable from a document start,
// so recovery is size-bounded by design).
struct JSONStreamFramerTests {
    private func strings(_ documents: [Data]) -> [String] {
        documents.map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func singleDocument() {
        let framer = JSONStreamFramer()
        let docs = framer.append(Data(#"{"a":1}"#.utf8))
        #expect(strings(docs) == [#"{"a":1}"#])
    }

    @Test func documentSplitAcrossChunks() {
        let framer = JSONStreamFramer()
        #expect(framer.append(Data(#"{"a":"#.utf8)).isEmpty)
        #expect(framer.append(Data(#"1,"#.utf8)).isEmpty)
        let docs = framer.append(Data(#""b":{"c":2}}"#.utf8))
        #expect(strings(docs) == [#"{"a":1,"b":{"c":2}}"#])
    }

    @Test func multipleDocumentsInOneChunk() {
        let framer = JSONStreamFramer()
        let docs = framer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        #expect(strings(docs) == [#"{"a":1}"#, #"{"b":2}"#])
    }

    @Test func bracesInsideStringsDoNotNest() {
        let framer = JSONStreamFramer()
        let doc = #"{"msg":"see {here} and }there{"}"#
        #expect(strings(framer.append(Data(doc.utf8))) == [doc])
    }

    @Test func escapedQuotesStayInString() {
        let framer = JSONStreamFramer()
        let doc = #"{"msg":"a \"quoted\" {brace}"}"#
        #expect(strings(framer.append(Data(doc.utf8))) == [doc])
    }

    /// Finding 2: quoted noise *between* documents must not open a phantom
    /// document off the brace inside the quotes.
    @Test func quotedNoiseBetweenDocumentsIsInert() {
        let framer = JSONStreamFramer()
        let noise = "note: \"see {here}\"\n"
        let docs = framer.append(Data((noise + #"{"a":1}"#).utf8))
        #expect(strings(docs) == [#"{"a":1}"#])
    }

    /// Residual A's documented behavior: a bare `{` in unquoted noise opens
    /// a phantom document, and the framer resyncs only via the 8 MiB
    /// backstop — after which real documents parse again.
    @Test func strayBraceRecoversViaBackstop() {
        let framer = JSONStreamFramer()
        // Phantom open: everything after this accumulates.
        #expect(framer.append(Data("warn: shim {\n".utf8)).isEmpty)
        // A legit document is swallowed by the phantom (depth never hits 0).
        #expect(framer.append(Data(#"{"a":1}"#.utf8)).isEmpty)
        // Push the buffer past the backstop, forcing a reset…
        let filler = Data(repeating: UInt8(ascii: "x"), count: 9 * 1024 * 1024)
        _ = framer.append(filler)
        // …after which the stream frames normally again.
        let docs = framer.append(Data(#"{"b":2}"#.utf8))
        #expect(strings(docs) == [#"{"b":2}"#])
    }

    /// The compaction path: a completed document is released from the buffer
    /// and later documents still frame correctly (offsets rebased).
    @Test func compactionPreservesFraming() {
        let framer = JSONStreamFramer()
        _ = framer.append(Data(#"{"a":1}"#.utf8))
        #expect(framer.append(Data("  {\"b\":".utf8)).isEmpty)
        let docs = framer.append(Data("2}".utf8))
        #expect(strings(docs) == [#"{"b":2}"#])
    }
}
