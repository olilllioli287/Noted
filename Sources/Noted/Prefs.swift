import AppKit
import SwiftUI

// 面板外觀選項
enum Surface: String, CaseIterable, Identifiable {
    case shell, cream, paper
    var id: String { rawValue }
    var label: String {
        switch self { case .shell: "黑色"; case .cream: "奶油"; case .paper: "紙張" }
    }
    var background: NSColor {
        switch self {
        case .shell: NSColor(white: 0.0, alpha: 1)
        case .cream: NSColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1)
        case .paper: NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        }
    }
    var isLight: Bool { self != .shell }
}

enum FontStyle: String, CaseIterable, Identifiable {
    case standard, rounded, serif, mono, pen, book, cilantro
    var id: String { rawValue }
    static func fromStored(_ value: String) -> FontStyle? {
        if value == "niyu" { return .cilantro }
        return FontStyle(rawValue: value)
    }
    var label: String {
        switch self {
        case .standard: "預設"; case .rounded: "圓體"; case .serif: "襯線"
        case .mono: "等寬"; case .pen: "手寫"; case .book: "書本"; case .cilantro: "香菜碼等寬"
        }
    }
    func font(size: CGFloat, bold: Bool = false) -> NSFont {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        func design(_ d: NSFontDescriptor.SystemDesign) -> NSFont {
            NSFont(descriptor: base.fontDescriptor.withDesign(d) ?? base.fontDescriptor, size: size) ?? base
        }
        func named(_ names: [String], cjk: [String]) -> NSFont {
            var f: NSFont = base
            for n in names { if let x = NSFont(name: n, size: size) { f = x; break } }
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            let cascade = cjk.map { NSFontDescriptor(name: $0, size: size) }
            return NSFont(descriptor: f.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? f
        }
        switch self {
        case .standard: return base
        case .rounded: return design(.rounded)
        case .serif: return named(["NewYork-Regular", "Georgia"], cjk: ["STSongti-TC-Regular"])
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .pen: return named(["BradleyHandITCTT-Bold", "Noteworthy-Light"], cjk: ["HanziPenTC-W3", "STKaiti-TC-Regular"])
        case .book: return named(["IowanOldStyle-Roman", "Palatino-Roman"], cjk: ["STSongti-TC-Light"])
        case .cilantro:
            let name = bold ? "CilantroCodeMono-Bold" : "CilantroCodeMono-Regular"
            guard let cilantro = NSFont(name: name, size: size) else { return base }
            let cascade = [NSFontDescriptor(name: "PingFangTC-Regular", size: size), base.fontDescriptor]
            return NSFont(descriptor: cilantro.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? base
        }
    }
}

enum TextTint: String, CaseIterable, Identifiable {
    case white, green
    var id: String { rawValue }
    var label: String { self == .white ? "白色" : "終端機綠" }
    var color: NSColor {
        self == .white ? NSColor(white: 0.95, alpha: 1) : NSColor(red: 0.33, green: 0.95, blue: 0.45, alpha: 1)
    }
}

struct PanelTheme: Identifiable {
    let id: String
    let name: String
    let surface: Surface
    let font: FontStyle
    let tint: TextTint
    let ink: Bool
    static let all: [PanelTheme] = [
        .init(id: "standard", name: "預設", surface: .shell, font: .standard, tint: .white, ink: false),
        .init(id: "paper", name: "紙張", surface: .paper, font: .book, tint: .white, ink: true),
        .init(id: "manuscript", name: "手稿", surface: .cream, font: .pen, tint: .white, ink: true),
        .init(id: "terminal", name: "終端機", surface: .shell, font: .mono, tint: .green, ink: false),
        .init(id: "typewriter", name: "打字機", surface: .cream, font: .mono, tint: .white, ink: true),
    ]
}

let textSizes: [(name: String, size: CGFloat)] = [("最小", 11), ("小", 13), ("中", 15), ("大", 17), ("最大", 20)]

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    /// 介面風格（macOS 原生／科幻藍 HUD）。科幻藍開著時，下面的背景與文字顏色暫時不作用，值不會被改掉。
    @Published var uiStyle: UIStyle { didSet { d.set(uiStyle.rawValue, forKey: "uiStyle") } }
    var isHUD: Bool { uiStyle == .hud }
    @Published var surface: Surface { didSet { d.set(surface.rawValue, forKey: "surface") } }
    @Published var fontStyle: FontStyle { didSet { d.set(fontStyle.rawValue, forKey: "fontStyle") } }
    @Published var tint: TextTint { didSet { d.set(tint.rawValue, forKey: "tint") } }
    @Published var inkInput: Bool { didSet { d.set(inkInput, forKey: "inkInput") } }
    @Published var textSizeIndex: Int { didSet { d.set(textSizeIndex, forKey: "textSizeIndex") } }
    @Published var notchScale: Double { didSet { d.set(notchScale, forKey: "notchScale") } }
    @Published var panelWidth: Double { didSet { d.set(panelWidth, forKey: "panelWidth") } }
    @Published var panelHeight: Double { didSet { d.set(panelHeight, forKey: "panelHeight") } }
    @Published var hoverHaptic: Bool { didSet { d.set(hoverHaptic, forKey: "hoverHaptic") } }
    @Published var textDrop: Bool { didSet { d.set(textDrop, forKey: "textDrop") } }
    @Published var textDropSound: Bool { didSet { d.set(textDropSound, forKey: "textDropSound") } }
    @Published var collapseOnLeave: Bool { didSet { d.set(collapseOnLeave, forKey: "collapseOnLeave") } }
    @Published var reminderEnabled: Bool { didSet { d.set(reminderEnabled, forKey: "reminderEnabled") } }
    @Published var reminderMinutes: Int { didSet { d.set(reminderMinutes, forKey: "reminderMinutes") } }
    @Published var reminderSound: Bool { didSet { d.set(reminderSound, forKey: "reminderSound") } }
    /// 停用瀏海的螢幕（存螢幕 UUID）
    @Published var disabledDisplays: [String] { didSet { d.set(disabledDisplays, forKey: "disabledDisplays") } }

    private init() {
        d.register(defaults: [
            "surface": Surface.shell.rawValue, "fontStyle": FontStyle.standard.rawValue,
            "tint": TextTint.white.rawValue, "inkInput": false, "textSizeIndex": 2,
            "notchScale": 1.0, "panelWidth": 560.0, "panelHeight": 340.0,
            "hoverHaptic": true, "textDrop": true, "textDropSound": true, "collapseOnLeave": true,
            "reminderEnabled": true, "reminderMinutes": 60, "reminderSound": true,
            "disabledDisplays": [String](),
        ])
        uiStyle = UIStyle(rawValue: d.string(forKey: "uiStyle") ?? "") ?? .mac
        surface = Surface(rawValue: d.string(forKey: "surface") ?? "") ?? .shell
        fontStyle = FontStyle.fromStored(d.string(forKey: "fontStyle") ?? "") ?? .standard
        tint = TextTint(rawValue: d.string(forKey: "tint") ?? "") ?? .white
        inkInput = d.bool(forKey: "inkInput")
        textSizeIndex = min(max(d.integer(forKey: "textSizeIndex"), 0), textSizes.count - 1)
        notchScale = d.double(forKey: "notchScale")
        panelWidth = d.double(forKey: "panelWidth")
        panelHeight = d.double(forKey: "panelHeight")
        hoverHaptic = d.bool(forKey: "hoverHaptic")
        textDrop = d.bool(forKey: "textDrop")
        textDropSound = d.bool(forKey: "textDropSound")
        collapseOnLeave = d.bool(forKey: "collapseOnLeave")
        reminderEnabled = d.bool(forKey: "reminderEnabled")
        reminderMinutes = min(max(d.integer(forKey: "reminderMinutes"), 1), 1440)
        reminderSound = d.bool(forKey: "reminderSound")
        disabledDisplays = d.stringArray(forKey: "disabledDisplays") ?? []
    }

    /// 集合面板（Hub）直接改了 defaults 之後呼叫：把設定重讀一次。
    /// 只在值真的不同時才指派，避免多餘的重繪與寫回；回傳 (幾何是否變了, 停用螢幕是否變了)
    @discardableResult
    func reloadFromDefaults() -> (geometry: Bool, displays: Bool) {
        func set<T: Equatable>(_ cur: inout T, _ new: T) -> Bool { if cur != new { cur = new; return true }; return false }
        _ = set(&uiStyle, UIStyle(rawValue: d.string(forKey: "uiStyle") ?? "") ?? .mac)
        _ = set(&surface, Surface(rawValue: d.string(forKey: "surface") ?? "") ?? .shell)
        _ = set(&fontStyle, FontStyle.fromStored(d.string(forKey: "fontStyle") ?? "") ?? .standard)
        _ = set(&tint, TextTint(rawValue: d.string(forKey: "tint") ?? "") ?? .white)
        _ = set(&inkInput, d.bool(forKey: "inkInput"))
        _ = set(&textSizeIndex, min(max(d.integer(forKey: "textSizeIndex"), 0), textSizes.count - 1))
        _ = set(&hoverHaptic, d.bool(forKey: "hoverHaptic"))
        _ = set(&textDrop, d.bool(forKey: "textDrop"))
        _ = set(&textDropSound, d.bool(forKey: "textDropSound"))
        _ = set(&collapseOnLeave, d.bool(forKey: "collapseOnLeave"))
        _ = set(&reminderEnabled, d.bool(forKey: "reminderEnabled"))
        _ = set(&reminderMinutes, min(max(d.integer(forKey: "reminderMinutes"), 1), 1440))
        _ = set(&reminderSound, d.bool(forKey: "reminderSound"))
        var geo = set(&notchScale, d.double(forKey: "notchScale"))
        geo = set(&panelWidth, d.double(forKey: "panelWidth")) || geo
        geo = set(&panelHeight, d.double(forKey: "panelHeight")) || geo
        let disp = set(&disabledDisplays, d.stringArray(forKey: "disabledDisplays") ?? [])
        return (geo, disp)
    }

    var textSize: CGFloat { textSizes[textSizeIndex].size * CGFloat(notchScale) }
    /// 展開面板的底色（科幻藍時是半透明深藍，其餘照「背景」設定）
    var panelBackground: NSColor { isHUD ? HUDLook.background : surface.background }
    /// 面板是不是淺色底（科幻藍一律深色）
    var panelIsLight: Bool { !isHUD && surface.isLight }
    var textColor: NSColor {
        if isHUD { return HUDLook.text }
        return surface.isLight ? NSColor(red: 0.13, green: 0.14, blue: 0.2, alpha: 1) : tint.color
    }
    var secondaryColor: NSColor { textColor.withAlphaComponent(0.5) }
    var accent: NSColor {
        if isHUD { return HUDLook.line }
        if surface.isLight { return NSColor(red: 0.2, green: 0.35, blue: 0.75, alpha: 1) }
        return tint == .green ? tint.color : NSColor(red: 1.0, green: 0.78, blue: 0.3, alpha: 1)
    }

    func apply(_ t: PanelTheme) {
        surface = t.surface; fontStyle = t.font; tint = t.tint; inkInput = t.ink
    }

    // 膠囊位置（每個螢幕各記一個，用比例存，換解析度也不會跑掉）
    func capsulePosition(for key: String) -> CGPoint? {
        guard let a = d.array(forKey: "capsule.\(key)") as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }
    func setCapsulePosition(_ p: CGPoint, for key: String) {
        d.set([Double(p.x), Double(p.y)], forKey: "capsule.\(key)")
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }
}
