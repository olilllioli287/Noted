import AppKit
import SwiftUI
import Quartz
import ShotLineKit
import FineTuneKit

// 三合一：把音量（FineTuneKit）和截圖（ShotLineKit）接到瀏海面板。
// 設計見 docs/notch-suite-設計.md。

/// 三欄面板自己的偏好（跟筆記的 Prefs 分開，原本的設定鍵都不動）
final class SuitePrefs: ObservableObject {
    static let shared = SuitePrefs()
    private let d = UserDefaults.standard

    /// 三欄面板。關掉就回到原本只有筆記的面板。
    @Published var threeColumns: Bool { didSet { d.set(threeColumns, forKey: "suite.threeColumns") } }
    /// 展開的寬、高佔螢幕的比例
    @Published var widthRatio: Double { didSet { d.set(widthRatio, forKey: "suite.widthRatio") } }
    @Published var heightRatio: Double { didSet { d.set(heightRatio, forKey: "suite.heightRatio") } }
    /// 左欄（音量）、右欄（截圖）佔面板寬度的比例；中間是筆記
    @Published var leftRatio: Double { didSet { d.set(leftRatio, forKey: "suite.leftRatio") } }
    @Published var rightRatio: Double { didSet { d.set(rightRatio, forKey: "suite.rightRatio") } }
    @Published var audioEnabled: Bool { didSet { d.set(audioEnabled, forKey: "suite.audioEnabled") } }
    @Published var shotEnabled: Bool { didSet { d.set(shotEnabled, forKey: "suite.shotEnabled") } }
    /// 截圖一掛上，瀏海長出提示
    @Published var shotPeek: Bool { didSet { d.set(shotPeek, forKey: "suite.shotPeek") } }
    /// 新截圖提示停幾秒才收（游標在上面不算）。第一輪是固定 5 秒。
    @Published var shotPeekSeconds: Double { didSet { d.set(shotPeekSeconds, forKey: "suite.shotPeekSeconds") } }
    static let defaultShotPeekSeconds = 10.0
    static let shotPeekRange = 3.0...60.0

    static let defaultWidthRatio = 0.82, defaultHeightRatio = 0.39
    static let defaultLeftRatio = 0.26, defaultRightRatio = 0.23
    /// 面板比這個窄就不排三欄，改成一次看一欄
    static let minThreeColumnWidth: CGFloat = 820

    private init() {
        d.register(defaults: [
            "suite.threeColumns": true,
            "suite.widthRatio": Self.defaultWidthRatio, "suite.heightRatio": Self.defaultHeightRatio,
            "suite.leftRatio": Self.defaultLeftRatio, "suite.rightRatio": Self.defaultRightRatio,
            "suite.audioEnabled": true, "suite.shotEnabled": true, "suite.shotPeek": true,
            "suite.shotPeekSeconds": Self.defaultShotPeekSeconds,
        ])
        threeColumns = d.bool(forKey: "suite.threeColumns")
        widthRatio = min(max(d.double(forKey: "suite.widthRatio"), 0.4), 0.98)
        heightRatio = min(max(d.double(forKey: "suite.heightRatio"), 0.2), 0.9)
        leftRatio = min(max(d.double(forKey: "suite.leftRatio"), 0.15), 0.4)
        rightRatio = min(max(d.double(forKey: "suite.rightRatio"), 0.15), 0.4)
        audioEnabled = d.bool(forKey: "suite.audioEnabled")
        shotEnabled = d.bool(forKey: "suite.shotEnabled")
        shotPeek = d.bool(forKey: "suite.shotPeek")
        shotPeekSeconds = min(max(d.double(forKey: "suite.shotPeekSeconds"), Self.shotPeekRange.lowerBound), Self.shotPeekRange.upperBound)
    }

    func resetLayout() {
        widthRatio = Self.defaultWidthRatio; heightRatio = Self.defaultHeightRatio
        leftRatio = Self.defaultLeftRatio; rightRatio = Self.defaultRightRatio
    }
}

/// 兩個模組跟瀏海面板之間的接線。
/// Noted 原本的 AppDelegate／NotchController 沒有標 @MainActor（但都只在主執行緒上跑），
/// 兩個模組是 @MainActor，所以這裡每個入口用 assumeIsolated 接過去。
enum SuiteHost {
    private static var env: [String: String] { DevBuild.environment }

    /// App 啟動時呼叫一次
    static func start() {
        MainActor.assumeIsolated {
            let suite = SuitePrefs.shared

            // 音訊資料放在筆記資料夾底下（測試時 NOTED_DATA_DIR 會一起把它帶到暫存資料夾）
            FineTuneStorage.directory = Store.shared.dir.appendingPathComponent("audio", isDirectory: true)
            let audio = FineTuneModule.shared
            if env["NOTED_DATA_DIR"] != nil { audio.importsStandaloneSettings = false }
            // 測試：獨立版 FineTune 開著也啟動，但輸出策略只算不做
            if env["NOTED_AUDIO_DRYRUN"] == "1" { audio.forceDryRun = true }
            audio.onTogglePanel = {
                let app = AppDelegate.shared!
                if let open = app.controllers.first(where: \.isExpanded) { open.collapse() } else { app.openPanelFromMenu(nil) }
            }
            audio.onFullPanelClosed = {
                // 完整面板拿走了鍵盤，關掉後還給展開中的瀏海面板
                if let open = AppDelegate.shared.controllers.first(where: \.isExpanded), open.window.allowKey {
                    open.window.makeKey()
                }
            }
            audio.onOpenSettings = { AppDelegate.shared.openSettings(pane: .audio) }
            if suite.audioEnabled { audio.start() }

            let shot = ShotLineModule.shared
            shot.hostBusy = {
                let app = AppDelegate.shared!
                return app.hasOpenWindows || app.controllers.contains(where: \.isExpanded)
                    || FineTuneModule.shared.isFullPanelVisible
            }
            shot.onTogglePanel = { audio.onTogglePanel() }
            shot.onOpenSettings = { AppDelegate.shared.openSettings(pane: .shots) }
            shot.onNewCapture = {
                guard SuitePrefs.shared.shotPeek else { return }
                let app = AppDelegate.shared!
                // 面板已經展開就不用提示，右欄自己會多一張
                guard !app.controllers.contains(where: \.isExpanded) else { return }
                let target = app.controllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? app.controllers.first
                target?.showShot(count: ShotLineModule.shared.peekCount)
            }
            shot.onSent = {
                // 截圖拖給別的 App 了：面板收起來（原本是繩子收回去），焦點由 ShotLine 的 FocusReturn 交給那個 App
                let app = AppDelegate.shared!
                app.controllers.first(where: \.isExpanded)?.collapse(restoreFocus: false)
                app.controllers.forEach { $0.refreshShot(count: ShotLineModule.shared.peekCount) }
            }
            if suite.shotEnabled { shot.start() }
        }
    }

    /// App 要結束
    static func shutdown() {
        MainActor.assumeIsolated {
            ShotLineModule.shared.shutdown()
            FineTuneModule.shared.shutdown()
        }
    }

    static func setAudioEnabled(_ on: Bool) {
        // 關掉前先問要不要解除被策略靜音的裝置；按「取消」就維持原狀
        if !on, !MainActor.assumeIsolated({ confirmAudioOff() }) { return }
        SuitePrefs.shared.audioEnabled = on
        // 音訊引擎關掉要拆 tap、還原裝置，做成「下次啟動生效」比較安全；打開可以馬上啟動
        if on { MainActor.assumeIsolated { FineTuneModule.shared.start() } }
    }

    /// 回傳 false＝使用者按了「取消」
    @MainActor
    private static func confirmAudioOff() -> Bool {
        if FineTuneModule.shared.state == .standby { return true }
        FineTuneModule.shared.flushSettings()
        let stored = PolicyMuteRelease.readSettings()
        guard PolicyMuteRelease.pendingCount(in: stored) > 0,
              DevBuild.environment["NOTED_AUDIO_DRYRUN"] == nil,
              DevBuild.environment["NOTED_DATA_DIR"] == nil else { return true }
        let alert = NSAlert()
        alert.messageText = "要解除被靜音的輸出裝置嗎？"
        alert.addButton(withTitle: "解除並關閉")
        alert.addButton(withTitle: "保持靜音並關閉")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if FineTuneModule.shared.state == .running { FineTuneModule.shared.disarmOutputPolicy() }
            else { _ = PolicyMuteRelease.releaseStoredMutes() }
            return true
        case .alertThirdButtonReturn:
            return false
        default:
            return true
        }
    }

    static func setShotEnabled(_ on: Bool) {
        SuitePrefs.shared.shotEnabled = on
        MainActor.assumeIsolated { if on { ShotLineModule.shared.start() } else { ShotLineModule.shared.stop() } }
    }

    // MARK: 面板要不要收

    /// 游標在這裡時，面板不要因為「滑鼠移開」或「點了別處」而收起
    static func keepsPanelOpen(at point: NSPoint) -> Bool {
        MainActor.assumeIsolated {
            if ShotLineModule.shared.isInteracting { return true }
            if let frame = FineTuneModule.shared.fullPanelFrame, frame.insetBy(dx: -20, dy: -20).contains(point) { return true }
            return false
        }
    }

    static var shotBusy: Bool { MainActor.assumeIsolated { ShotLineModule.shared.isInteracting } }

    static var shotPeekCount: Int { MainActor.assumeIsolated { ShotLineModule.shared.peekCount } }

    static func panelDidCollapse() {
        MainActor.assumeIsolated { FineTuneModule.shared.closeFullPanel() }
    }

    // MARK: 新截圖提示

    static func peekSize(count: Int) -> CGSize {
        // 跟 ShotLineModule.peekSize 同一個算法，但張數由瀏海控制器決定
        let scale: CGFloat = 0.72
        let card = (150 * scale).rounded()
        return CGSize(width: CGFloat(max(1, count)) * (card + 14) + 26, height: (104 * scale).rounded() + 8 + 14 + 22)
    }

    @MainActor static func peekView() -> some View { ShotLinePeek() }

    // MARK: 測試指令

    static func debugAudioToggle(_ text: String) {
        MainActor.assumeIsolated { FineTuneModule.shared.debugToggleOutput(uidContaining: text) }
    }

    static func debugAudioLog() -> String {
        MainActor.assumeIsolated {
            let m = FineTuneModule.shared
            return "audio=\(m.state) armed=\(m.outputPolicyArmed) shot=\(ShotLineModule.shared.state) hanging=\(ShotLineModule.shared.liveCount)\n"
                + (ShotLineModule.shared.debugItems + ["--"] + m.dryRunLog).joined(separator: "\n")
        }
    }

    static func debugShot(_ action: String) {
        MainActor.assumeIsolated { ShotLineModule.shared.debugAct(action) }
    }
}

// MARK: - 三欄面板

/// 展開後的內容：左音量、中筆記、右截圖。面板太窄時改成一次看一欄。
struct SuitePanel: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var suite = SuitePrefs.shared
    @ObservedObject var shot = ShotLineModule.shared
    @State private var resizeStart: (mouse: NSPoint, w: Double, h: Double)?

    private var fg: Color { prefs.textColor.swiftUI }
    private var accent: Color { prefs.accent.swiftUI }
    private var barHeight: CGFloat { m.hasNotch ? m.notchSize.height : 32 * prefs.notchScale }

    var body: some View {
        if !suite.threeColumns {
            PanelContent(m: m)
        } else {
            GeometryReader { geo in
                let w = geo.size.width
                Group {
                    if w < SuitePrefs.minThreeColumnWidth { tabbed } else { columns(width: w) }
                }
                .frame(width: w, height: geo.size.height)
            }
            .overlay(alignment: .bottomTrailing) { resizeGrip }
        }
    }

    private func columns(width w: CGFloat) -> some View {
        let left = (w * CGFloat(suite.leftRatio)).rounded()
        let right = (w * CGFloat(suite.rightRatio)).rounded()
        return HStack(spacing: 0) {
            audioColumn.frame(width: left)
            divider
            PanelContent(m: m, inSuite: true).frame(maxWidth: .infinity)
            divider
            shotColumn.frame(width: right)
        }
    }

    private var hud: Bool { prefs.isHUD }

    @ViewBuilder private var divider: some View {
        if hud {
            // 青藍細線，兩端漸淡
            Rectangle().fill(LinearGradient(colors: [.clear, HUDLook.lineColor.opacity(0.7), HUDLook.lineColor.opacity(0.7), .clear],
                                            startPoint: .top, endPoint: .bottom))
                .frame(width: 1).shadow(color: HUDLook.lineColor.opacity(0.6), radius: 3)
                .padding(.top, barHeight + 2).padding(.bottom, 10)
        } else {
            Rectangle().fill(fg.opacity(0.09)).frame(width: 1)
                .padding(.top, barHeight + 2).padding(.bottom, 10)
        }
    }

    /// 欄的小標題：科幻藍時字距拉開
    private func columnTitle(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
            .tracking(hud ? 3 : 0)
            .foregroundStyle(hud ? HUDLook.lineColor : fg)
    }

    // 窄螢幕（例如 iPhone 當副螢幕）：三個分頁，一次一欄
    private var tabbed: some View {
        VStack(spacing: 0) {
            ZStack {
                switch m.suiteTab {
                case 0: audioColumn
                case 2: shotColumn
                default: PanelContent(m: m, inSuite: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 4) {
                tab(0, "音量", "speaker.wave.2")
                tab(1, "筆記", "square.and.pencil")
                tab(2, "截圖", "tshirt")
            }
            .padding(.horizontal, 28).padding(.bottom, 6).padding(.top, 2)
        }
    }

    private func tab(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button { m.suiteTab = index; if index == 1 { m.focusToken += 1 } } label: {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(fg.opacity(hud ? 0 : (m.suiteTab == index ? 0.14 : 0.04)), in: Capsule())
                .hudCell(hud, active: m.suiteTab == index)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(fg)
    }

    // MARK: 左欄：音量

    private var audioColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                columnTitle("音量", "speaker.wave.2")
                Spacer(minLength: 4)
                barButton("slider.horizontal.3", "完整面板：EQ、AutoEQ、各 App 的輸出、輸入裝置") {
                    let p = NSEvent.mouseLocation
                    FineTuneModule.shared.toggleFullPanel(below: NSRect(x: p.x - 12, y: p.y - 10, width: 24, height: 20),
                                                          on: m.controller?.screen)
                }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: barHeight)
            FineTuneColumn(fg: fg, accent: accent, isLight: prefs.panelIsLight, hud: hud)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, 6).padding(.bottom, 6)
        .foregroundStyle(fg)
    }

    // MARK: 右欄：截圖

    private var shotColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                columnTitle("截圖", "tshirt")
                if shot.liveCount > 0 {
                    Text("\(shot.liveCount)").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1).background(fg.opacity(0.1), in: Capsule())
                }
                Spacer(minLength: 4)
                barButton("folder", "打開截圖資料夾") { NSWorkspace.shared.open(ShotLineModule.shared.keepFolder) }
                barButton("ellipsis.circle", "截圖選項") {
                    ShotLineModule.shared.makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            }
            .padding(.leading, 8).padding(.trailing, 14)
            .frame(height: barHeight)
            ShotLineColumn(fg: fg, isLight: prefs.panelIsLight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.trailing, 6).padding(.bottom, 6)
        .foregroundStyle(fg)
    }

    private func barButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hudCell(hud).help(help)
    }

    /// 右下角：拖曳調整整個面板的大小（存成佔螢幕的比例）
    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold)).opacity(0.3).foregroundStyle(fg)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .help("調整大小")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    guard let screen = m.controller?.screen.frame else { return }
                    let p = NSEvent.mouseLocation
                    if resizeStart == nil { resizeStart = (p, suite.widthRatio, suite.heightRatio) }
                    guard let s = resizeStart else { return }
                    // 面板置中，所以寬度變化是游標位移的兩倍
                    suite.widthRatio = min(max(s.w + Double((p.x - s.mouse.x) * 2 / screen.width), 0.4), 0.98)
                    suite.heightRatio = min(max(s.h - Double((p.y - s.mouse.y) / screen.height), 0.2), 0.9)
                    m.controller?.refreshGeometry()
                }
                .onEnded { _ in resizeStart = nil })
            .padding(4)
    }
}

// MARK: - Quick Look
// ShotLine 的 Quick Look 沒有自己的視窗，面板會沿著回應鏈問到 App 的 delegate。

extension AppDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { ShotLineModule.shared.state == .running }
    }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { ShotLineModule.shared.takePreviewPanel(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { ShotLineModule.shared.releasePreviewPanel(panel) }
    }
}
