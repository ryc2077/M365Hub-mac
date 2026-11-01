// Native math rendering for macOS via SwiftMath (a Swift port of
// iosMath, added as a Swift Package dependency). KaTeX itself is
// JavaScript and cannot run natively, but SwiftMath typesets the same
// LaTeX with the same TeX rules, so formulas look the way they did
// in the web console. A formula that SwiftMath rejects (label.error)
// falls back to raw LaTeX text, so content is never lost.

import SwiftUI
import SwiftMath

enum MathRender {
    private static var cache: [String: NSImage] = [:]

    /// Renders one formula to an image, or nil when it cannot be rendered.
    /// Results are cached: MessageRow bodies re-evaluate on every keystroke.
    static func image(latex: String, fontSize: CGFloat, display: Bool) -> NSImage? {
        let key = latex + "|" + String(describing: fontSize) + "|" + (display ? "d" : "t")
        if let hit = cache[key] { return hit }
        let label = MTMathUILabel()
        label.latex = latex
        label.labelMode = display ? .display : .text
        label.fontSize = fontSize
        label.textColor = MTColor(Color.primary)
        // sizeToFit() is UIKit-only; on macOS the label is an NSView and
        // SwiftMath gives it sizeThatFits/fittingSize instead (same math).
        label.frame.size = label.sizeThatFits(.zero)
        let size = label.frame.size
        guard size.width > 0, size.height > 0, label.error == nil else { return nil }
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        cache[key] = img
        return img
    }
}

enum MathSeg {
    case text(String)
    case inline(String)
    case display(String)
    case code(String)
}

/// Splits message content the way the web console did: fenced
/// ```latex blocks are display math, other fenced blocks are literal
/// code, \[...\] and $$...$$ are display math, \(...\) and guarded
/// $...$ are inline math (so "$20" stays text).
enum MathSegments {
    static func parse(_ content: String) -> [MathSeg] {
        let pattern = "```([A-Za-z0-9_-]*)\\n([\\s\\S]*?)```"
            + "|\\\\\\[([\\s\\S]*?)\\\\\\]"
            + "|\\$\\$([\\s\\S]*?)\\$\\$"
            + "|\\\\\\(([\\s\\S]*?)\\\\\\)"
            + "|\\$([^$\\n]{1,500})\\$"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return [.text(content)]
        }
        var out: [MathSeg] = []
        var cursor = content.startIndex
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            let range = Range(m.range, in: content)!
            if range.lowerBound > cursor {
                out.append(.text(String(content[cursor..<range.lowerBound])))
            }
            if m.range(at: 1).location != NSNotFound {
                let lang = ns.substring(with: m.range(at: 1)).lowercased()
                let inner = ns.substring(with: m.range(at: 2))
                if lang == "latex" || lang == "math" || lang == "tex" {
                    out.append(.display(inner.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    out.append(.code(inner))
                }
            } else if m.range(at: 3).location != NSNotFound {
                out.append(.display(ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if m.range(at: 4).location != NSNotFound {
                out.append(.display(ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if m.range(at: 5).location != NSNotFound {
                out.append(.inline(ns.substring(with: m.range(at: 5)).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if m.range(at: 6).location != NSNotFound {
                let inner = ns.substring(with: m.range(at: 6))
                if inner.contains("\\") || inner.contains("^") || inner.contains("_") || inner.contains("{") {
                    out.append(.inline(inner.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    out.append(.text(ns.substring(with: m.range)))
                }
            }
            cursor = range.upperBound
        }
        if cursor < content.endIndex {
            out.append(.text(String(content[cursor...])))
        }
        return out
    }
}
