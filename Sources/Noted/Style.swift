import AppKit
import SwiftUI

// 介面風格：原本的 macOS 風格，或「科幻藍 HUD」。
// HUD 的外觀全部用 SwiftUI 的形狀、漸層、陰影自己畫，字體用系統內建的等寬字體，
// 不含任何外部圖片、圖示、字型檔。設計見 docs/notch-suite-設計.md 8.7。

enum UIStyle: String, CaseIterable, Identifiable {
    case mac, hud
    var id: String { rawValue }
    var label: String { self == .mac ? "macOS 原生" : "科幻藍 HUD" }
}

/// 科幻藍的色票與尺寸（FineTuneKit／ShotLineKit 裡用的是同一組數值，兩邊不互相依賴所以各寫一份）
enum HUDLook {
    static let background = NSColor(red: 0.024, green: 0.063, blue: 0.11, alpha: 0.92)
    static let backgroundSolid = NSColor(red: 0.024, green: 0.063, blue: 0.11, alpha: 1)
    static let line = NSColor(red: 0.27, green: 0.78, blue: 1.0, alpha: 1)
    static let text = NSColor(red: 0.80, green: 0.93, blue: 1.0, alpha: 1)
    static let chamfer: CGFloat = 7
    static var lineColor: Color { line.swiftUI }
}

/// 斜切角的矩形（四個角各切掉一小塊，可以指定只切哪幾個角）
struct ChamferRect: InsettableShape {
    var cut: CGFloat = HUDLook.chamfer
    var corners: UIRectCornerSet = .diagonal
    var inset: CGFloat = 0

    struct UIRectCornerSet: OptionSet {
        let rawValue: Int
        static let topLeft = Self(rawValue: 1), topRight = Self(rawValue: 2)
        static let bottomLeft = Self(rawValue: 4), bottomRight = Self(rawValue: 8)
        static let all: Self = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        /// 左上＋右下（指令卡格子常見的切法）
        static let diagonal: Self = [.topLeft, .bottomRight]
        static let bottom: Self = [.bottomLeft, .bottomRight]
    }

    func inset(by amount: CGFloat) -> ChamferRect { var s = self; s.inset += amount; return s }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cut, r.width / 2, r.height / 2)
        func k(_ corner: UIRectCornerSet) -> CGFloat { corners.contains(corner) ? c : 0 }
        var p = Path()
        p.move(to: CGPoint(x: r.minX + k(.topLeft), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k(.topRight), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + k(.topRight)))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k(.bottomRight)))
        p.addLine(to: CGPoint(x: r.maxX - k(.bottomRight), y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + k(.bottomLeft), y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k(.bottomLeft)))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + k(.topLeft)))
        p.closeSubpath()
        return p
    }
}

/// 科幻藍的瀏海形狀：上緣跟 NotchShape 一樣往外翹接上螢幕頂端，下緣兩角改成斜切。
/// open＝不畫上緣（畫外框用，頂端那條貼著螢幕邊不用畫）。
struct HUDNotchShape: Shape {
    var top: CGFloat
    var cut: CGFloat
    var open = false
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, cut) }
        set { top = newValue.first; cut = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = min(top, r.width / 4), c = min(cut, r.height / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.minY + t))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.minX + t + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        if !open { p.closeSubpath() }
        return p
    }
}

/// 很淡的格線底紋
struct HUDGrid: View {
    var step: CGFloat = 26
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = step
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = step
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(path, with: .color(HUDLook.lineColor.opacity(0.045)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// 工具列的小按鈕外框：科幻藍時是斜切角的格子，滑過去變亮；原生風格不加任何東西。
struct HUDCell: ViewModifier {
    let hud: Bool
    var active = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        if hud {
            content
                .background(ChamferRect(cut: 5).fill(HUDLook.lineColor.opacity(active ? 0.28 : (hovering ? 0.2 : 0.07))))
                .overlay(ChamferRect(cut: 5).strokeBorder(HUDLook.lineColor.opacity(hovering || active ? 0.95 : 0.5), lineWidth: 1))
                .shadow(color: HUDLook.lineColor.opacity(hovering || active ? 0.55 : 0), radius: 4)
                .onHover { hovering = $0 }
        } else {
            content
        }
    }
}

extension View {
    func hudCell(_ hud: Bool, active: Bool = false) -> some View { modifier(HUDCell(hud: hud, active: active)) }

    /// 科幻藍時介面文字改用系統等寬字體（只影響沒有指定字體設計的系統字；筆記內文用的是自己的字體，不受影響）
    func hudFont(_ hud: Bool) -> some View { fontDesign(hud ? .monospaced : nil) }
}
