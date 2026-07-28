import SwiftUI
import AppKit

/// Editable YAML view with live syntax highlighting. Backed by NSTextView;
/// highlighting is applied as attribute-only changes on the text storage,
/// so typing, selection, and undo behave like a normal editor.
struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = Coordinator.font
        textView.typingAttributes = [.foregroundColor: NSColor.labelColor, .font: Coordinator.font]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = isEditable
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)

        // No line wrapping — match the read-only YAML view (horizontal scroll).
        let infinity = CGFloat.greatestFiniteMagnitude
        scrollView.hasHorizontalScroller = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: infinity, height: infinity)
        textView.isHorizontallyResizable = true
        // The default autoresizing mask snaps the frame back to the clip
        // view's width on every layout pass, clamping long lines and killing
        // horizontal scrolling (visible in the expanded sheet, where the text
        // arrives before the first layout).
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: infinity, height: infinity)

        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting()
        context.coordinator.resizeToFitContent()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        // Only push external changes (reload, template swap) — not our own edits.
        if textView.string != text {
            textView.string = text
            context.coordinator.applyHighlighting()
            context.coordinator.resizeToFitContent()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        var parent: YAMLEditor
        weak var textView: NSTextView?

        init(_ parent: YAMLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            applyHighlighting()
        }

        /// Grows the frame to the laid-out content so long lines are
        /// reachable via horizontal scrolling.
        func resizeToFitContent() {
            guard let textView, let container = textView.textContainer else { return }
            textView.layoutManager?.ensureLayout(for: container)
            textView.sizeToFit()
        }

        // Insert two spaces instead of a tab — tabs are invalid YAML indentation.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        func applyHighlighting() {
            guard let textView, let storage = textView.textStorage else { return }
            let nsString = textView.string as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)

            storage.beginEditing()
            storage.setAttributes(
                [.foregroundColor: NSColor.labelColor, .font: Self.font],
                range: fullRange
            )
            if nsString.length < 400_000 {
                var topLevelKey: String?
                nsString.enumerateSubstrings(in: fullRange, options: .byLines) { line, lineRange, _, _ in
                    guard let line else { return }
                    if let key = YAMLHighlighter.topLevelKey(of: line) {
                        topLevelKey = key
                    } else if line.trimmingCharacters(in: .whitespaces) == "---" {
                        topLevelKey = nil
                    }
                    Self.highlightLine(line, at: lineRange.location, in: storage, dimmed: topLevelKey == "status")
                }
            }
            storage.endEditing()
        }

        private static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)

        private static func highlightLine(_ line: String, at lineStart: Int, in storage: NSTextStorage, dimmed: Bool) {
            func paint(_ color: NSColor, location: Int, length: Int) {
                guard length > 0 else { return }
                storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: location, length: length))
            }

            func shade(_ base: NSColor) -> NSColor {
                dimmed ? base.withAlphaComponent(0.55) : base
            }

            if dimmed {
                // Status block: same syntax colors, faded.
                paint(.secondaryLabelColor, location: lineStart, length: line.utf16.count)
            }

            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#") || trimmed == "---" {
                paint(.secondaryLabelColor, location: lineStart, length: line.utf16.count)
                return
            }

            // Skip indentation and "- " list markers (all ASCII → 1 UTF-16 unit each).
            var rest = Substring(line)
            var prefixLength = 0
            while true {
                if rest.first == " " {
                    rest = rest.dropFirst()
                    prefixLength += 1
                } else if rest.hasPrefix("- ") {
                    rest = rest.dropFirst(2)
                    prefixLength += 2
                } else {
                    break
                }
            }

            var valueStart = lineStart + prefixLength
            var value = rest

            // "key:" or "key: value"
            if let colonIndex = rest.firstIndex(of: ":"),
               rest.index(after: colonIndex) == rest.endIndex || rest[rest.index(after: colonIndex)] == " " {
                let key = rest[..<colonIndex]
                if !key.contains("\""), !key.contains("#"), key.count < 80 {
                    let keyLength = key.utf16.count
                    let keyRange = NSRange(location: lineStart + prefixLength, length: keyLength)
                    paint(shade(.systemBlue), location: keyRange.location, length: keyRange.length)
                    if prefixLength == 0 {
                        storage.addAttribute(.font, value: boldFont, range: keyRange)
                    }
                    valueStart += keyLength + 1
                    value = rest[rest.index(after: colonIndex)...]
                } else {
                    return
                }
            }

            let scalar = value.trimmingCharacters(in: .whitespaces)
            guard !scalar.isEmpty else { return }
            let valueLength = value.utf16.count
            if scalar.hasPrefix("#") {
                paint(.secondaryLabelColor, location: valueStart, length: valueLength)
            } else if Double(scalar) != nil {
                paint(shade(.systemPurple), location: valueStart, length: valueLength)
            } else if ["true", "false", "null", "~", "True", "False", "Null", "yes", "no"].contains(scalar) {
                paint(shade(.systemOrange), location: valueStart, length: valueLength)
            } else {
                paint(shade(.systemGreen), location: valueStart, length: valueLength)
            }
        }
    }
}
