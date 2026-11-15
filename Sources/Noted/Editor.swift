import AppKit
import SwiftUI
import Combine

/// 筆記編輯器：純文字＋每行開頭的格式記號，畫面上再套樣式。
final class NoteTextView: NSTextView, NSTextStorageDelegate {
    static weak var active: NoteTextView?

    var taskID: UUID?
    var onEscape: (() -> Void)?
    private var inks: [(range: NSRange, start: CFTimeInterval)] = []
    private var inkTimer: Timer?
    private var prefsSub: AnyCancellable?

    func setup() {
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        textContainerInset = NSSize(width: 10, height: 6)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textStorage?.delegate = self
        prefsSub = Prefs.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.restyle() }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { NoteTextView.active = self }
        return ok
    }

    // MARK: 樣式

    func restyle() {
        guard let ts = textStorage, !hasMarkedText() else { return }
        let p = Prefs.shared
        let size = p.textSize
        let font = p.fontStyle.font(size: size)
        let headFont = p.fontStyle.font(size: (size * 1.3).rounded(), bold: true)
        let boxFont = NSFont.systemFont(ofSize: size * 1.1)
        let color = p.textColor, dim = p.secondaryColor, accent = p.accent
        let para = NSMutableParagraphStyle()
        para.lineSpacing = size * 0.22
        para.paragraphSpacing = size * 0.15

        let s = ts.string as NSString
        let full = NSRange(location: 0, length: s.length)
        ts.beginEditing()
        ts.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: full)
        s.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = s.substring(with: lineRange)
            let (fmt, n) = LineFormat.detect(line)
            guard fmt != .body else { return }
            let pre = NSRange(location: lineRange.location, length: n)
            var indentFont = font
            switch fmt {
            case .heading:
                ts.addAttribute(.font, value: headFont, range: lineRange)
                ts.addAttribute(.foregroundColor, value: dim.withAlphaComponent(0.3), range: pre)
                indentFont = headFont
            case .checklist:
                ts.addAttribute(.font, value: boxFont, range: NSRange(location: pre.location, length: 1))
                ts.addAttribute(.foregroundColor, value: accent, range: pre)
                if line.hasPrefix(LineFormat.checked) {
                    let rest = NSRange(location: lineRange.location + n, length: lineRange.length - n)
                    ts.addAttribute(.foregroundColor, value: dim, range: rest)
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
                    ts.addAttribute(.foregroundColor, value: dim, range: pre)
                }
                indentFont = boxFont
            default:
                ts.addAttribute(.foregroundColor, value: accent, range: pre)
            }
            // 換行時對齊文字，不對齊符號
            let w = (s.substring(with: pre) as NSString).size(withAttributes: [.font: indentFont]).width
            let ps = para.mutableCopy() as! NSMutableParagraphStyle
            ps.headIndent = w
            ts.addAttribute(.paragraphStyle, value: ps, range: lineRange)
        }
        ts.endEditing()
        typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        insertionPointColor = accent
        selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let p = Prefs.shared
            ("開始輸入，或用上方 Aa 選格式" as NSString).draw(
                at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                withAttributes: [.font: p.fontStyle.font(size: p.textSize), .foregroundColor: p.secondaryColor.withAlphaComponent(0.35)])
        }
    }

    // MARK: 檢查表勾選

    override func mouseDown(with e: NSEvent) {
        if let i = checkboxIndex(at: convert(e.locationInWindow, from: nil)) { toggleCheckbox(at: i); return }
        super.mouseDown(with: e)
    }

    private func checkboxIndex(at pt: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        let p = NSPoint(x: pt.x - textContainerOrigin.x, y: pt.y - textContainerOrigin.y)
        let gi = lm.glyphIndex(for: p, in: tc)
        let ci = lm.characterIndexForGlyph(at: gi)
        let s = string as NSString
        guard ci < s.length else { return nil }
        let ch = s.substring(with: NSRange(location: ci, length: 1))
        guard ch == "☐" || ch == "☑", ci == 0 || s.character(at: ci - 1) == 10 else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc).insetBy(dx: -4, dy: -3)
        return rect.contains(p) ? ci : nil
    }

    private func toggleCheckbox(at ci: Int) {
        let r = NSRange(location: ci, length: 1)
        let new = (string as NSString).substring(with: r) == "☐" ? "☑" : "☐"
        replace(r, with: new)
    }

    private func replace(_ r: NSRange, with s: String, select: NSRange? = nil) {
        guard shouldChangeText(in: r, replacementString: s) else { return }
        textStorage?.replaceCharacters(in: r, with: s)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// 把游標所在那一行（或選取範圍）切換成某種格式
    func applyFormat(_ f: LineFormat) {
        let s = string as NSString
        let block = s.lineRange(for: selectedRange())
        var text = s.substring(with: block)
        let trailingNL = text.hasSuffix("\n")
        if trailingNL { text.removeLast() }
        let lines = text.components(separatedBy: "\n")
        let allSame = lines.allSatisfy { LineFormat.detect($0).0 == f }
        let target: LineFormat = allSame ? .body : f
        var n = 0
        let out = lines.map { line -> String in
            n += 1
            return target.prefix(number: n) + LineFormat.strip(line)
        }.joined(separator: "\n") + (trailingNL ? "\n" : "")
        let caretEnd = block.location + (out as NSString).length - (trailingNL ? 1 : 0)
        replace(block, with: out, select: NSRange(location: caretEnd, length: 0))
        restyle()
    }

    // MARK: 按鍵

    override func doCommand(by sel: Selector) {
        if sel == #selector(insertNewline(_:)), !hasMarkedText(), handleReturn() { return }
        if sel == #selector(deleteBackward(_:)), handleBackspace() { return }
        if sel == #selector(cancelOperation(_:)) { onEscape?(); return }
        super.doCommand(by: sel)
    }

    private func handleReturn() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            insertText("\n", replacementRange: sel); return true
        }
        let s = string as NSString
        let lr = s.lineRange(for: NSRange(location: sel.location, length: 0))
        var line = s.substring(with: lr)
        if line.hasSuffix("\n") { line.removeLast() }
        let (fmt, n) = LineFormat.detect(line)
        guard fmt != .body, fmt != .heading, sel.location - lr.location >= n else { return false }
        if line.dropFirst(n).trimmingCharacters(in: .whitespaces).isEmpty {
            // 空的列表項目按 Return：結束列表
            replace(NSRange(location: lr.location, length: n), with: "", select: NSRange(location: lr.location, length: 0))
            restyle()
            return true
        }
        let num = Int(line.prefix(while: { $0.isNumber })) ?? 0
        insertText("\n" + fmt.prefix(number: num + 1), replacementRange: sel)
        return true
    }

    private func handleBackspace() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return false }
        let s = string as NSString
        let lr = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let (fmt, n) = LineFormat.detect(s.substring(with: lr))
        guard fmt != .body, sel.location == lr.location + n else { return false }
        replace(NSRange(location: lr.location, length: n), with: "", select: NSRange(location: lr.location, length: 0))
        restyle()
        return true
    }

    // MARK: 墨水輸入（新打的字慢慢浮現，只改畫面不改內容）

    override func insertText(_ s: Any, replacementRange: NSRange) {
        super.insertText(s, replacementRange: replacementRange)
        guard Prefs.shared.inkInput, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let len = ((s as? NSAttributedString)?.string ?? (s as? String) ?? "").utf16.count
        let end = selectedRange().location
        guard len > 0, end >= len else { return }
        inks.append((NSRange(location: end - len, length: len), CACurrentMediaTime()))
        if inkTimer == nil {
            inkTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.stepInk()
            }
        }
        stepInk()
    }

    private func stepInk() {
        guard let lm = layoutManager else { return }
        let now = CACurrentMediaTime(), length = (string as NSString).length
        let color = Prefs.shared.textColor
        inks = inks.filter { ink in
            guard NSMaxRange(ink.range) <= length else { return false }
            let t = min(1, (now - ink.start) / 0.75)
            if t >= 1 {
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: ink.range)
                return false
            }
            let a = 0.12 + 0.88 * (1 - pow(1 - t, 3))
            lm.addTemporaryAttribute(.foregroundColor, value: color.withAlphaComponent(a), forCharacterRange: ink.range)
            return true
        }
        if inks.isEmpty { inkTimer?.invalidate(); inkTimer = nil }
    }

    func textStorage(_ ts: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range edited: NSRange, changeInLength delta: Int) {
        guard mask.contains(.editedCharacters), !inks.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        inks = inks.compactMap { ink in
            if ink.range.location >= oldEnd { return (NSRange(location: ink.range.location + delta, length: ink.range.length), ink.start) }
            if NSMaxRange(ink.range) <= edited.location { return ink }
            return nil
        }
    }
}

/// 在 SwiftUI 裡放 NoteTextView
struct NoteEditor: NSViewRepresentable {
    let taskID: UUID
    var onEscape: () -> Void = {}
    var focusToken = 0

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastToken = -1
        var lastFontStyle: FontStyle?
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NoteTextView, let id = tv.taskID else { return }
            Store.shared.updateBody(id, tv.string)
            tv.restyle()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        let tv = NoteTextView(usingTextLayoutManager: false)
        tv.setup()
        tv.delegate = context.coordinator
        tv.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NoteTextView else { return }
        tv.onEscape = onEscape
        let body = Store.shared.task(taskID)?.body ?? ""
        if context.coordinator.lastFontStyle != Prefs.shared.fontStyle {
            context.coordinator.lastFontStyle = Prefs.shared.fontStyle
            tv.restyle()
        }
        if tv.taskID != taskID {
            tv.taskID = taskID
            tv.string = body
            tv.undoManager?.removeAllActions()
            tv.restyle()
            tv.setSelectedRange(NSRange(location: (body as NSString).length, length: 0))
        } else if tv.string != body, !tv.hasMarkedText() {
            let sel = tv.selectedRange()
            tv.string = body
            tv.undoManager?.removeAllActions()
            tv.restyle()
            tv.setSelectedRange(NSRange(location: min(sel.location, (body as NSString).length), length: 0))
        }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }
}
