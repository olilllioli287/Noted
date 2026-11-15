import AppKit
import Combine
import Quartz
import SwiftUI

// Noted: ShotLine 併進 Noted 後的入口。
// 取代原本的 AppDelegate.swift（整條繩子的視窗、滑下來／收回去、選單列圖示）：
// 監看截圖、收件匣、Markup／剪裁／Quick Look、拖曳這些照舊，
// 「什麼時候顯示」改由 Noted 的瀏海面板決定。

/// 截圖模組的狀態。
public enum ShotLineState: Equatable {
    /// 還沒啟動（設定裡關掉了）
    case off
    /// 獨立版 ShotLine 還在跑，先不接手，免得兩邊搶同一張截圖
    case standby
    case running
}

@MainActor
public final class ShotLineModule: ObservableObject {
    public static let shared = ShotLineModule()

    /// 測試用：設了 `NOTED_SHOT_TEST_DIR` 就只看這個暫存資料夾，
    /// 不讀寫系統截圖設定、不看桌面、不管獨立版有沒有在跑。
    /// 只設了 `NOTED_DATA_DIR`（筆記的測試資料夾）時也算測試，用它底下的 shots/，
    /// 免得測試版只隔離了筆記、卻去搬正式的截圖或改系統截圖設定。
    public nonisolated static let testDirectory: URL? = {
        let env = DevBuild.environment
        if let path = env["NOTED_SHOT_TEST_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        if let data = env["NOTED_DATA_DIR"], !data.isEmpty {
            return URL(fileURLWithPath: data, isDirectory: true).appendingPathComponent("shots", isDirectory: true)
        }
        return nil
    }()

    public static let standaloneBundleID = "local.shotline.ShotLine"

    /// 右欄最多留幾張。再多，最舊的自己退場（檔案不動）。
    public static let columnCapacity = 12

    /// Debug-only entry point used by Noted's bring command.
    public func debugBring(at point: NSPoint) {
        FocusReturn.shared.bringForward(windowAt: point)
    }

    @Published public private(set) var state: ShotLineState = .off
    @Published private(set) var line: Line?

    /// 有新的截圖掛上（或編輯完掛回來）。Noted 用它在瀏海長出提示。
    public var onNewCapture: () -> Void = {}
    /// 截圖被拖進別的 App 了。Noted 用它把面板收起來。
    public var onSent: () -> Void = {}
    /// 瀏海面板展開打字中、或 Noted 自己的視窗開著時回 true，
    /// 這時候不把鍵盤交回上一個 App。
    public var hostBusy: () -> Bool = { false }
    /// 原本「叫出繩子」的快捷鍵（預設 ⌃ ⌥ T）被按了。Noted 用它展開／收起面板。
    public var onTogglePanel: () -> Void = {}
    private var hotKey: HotKey?

    private var watcher: ScreenshotWatcher?
    private var safetyWatcher: ScreenshotWatcher?
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher?
    private var inboxTimer: Timer?
    private var watchedExtraPaths: [String] = []
    private var remountPending = false
    private var observers: [NSObjectProtocol] = []
    private var standbyObserver: NSObjectProtocol?
    private var focusStarted = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: 啟動與結束

    private var standaloneRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).isEmpty
    }

    public func start() {
        guard state != .running else { return }
        if Self.testDirectory == nil, standaloneRunning {
            state = .standby
            waitForStandaloneToQuit()
            return
        }
        if let o = standbyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            standbyObserver = nil
        }
        migrateFromStandaloneIfNeeded()
        Line.migrateShotKeep10minIfNeeded()

        let line = Line()
        line.maxItems = Self.columnCapacity
        line.visibleCount = Self.columnCapacity
        self.line = line

        Inbox.removeSentLeftovers()
        Line.resumePendingTrash()
        if Inbox.isEnabled { Inbox.apply() }
        if !focusStarted {
            focusStarted = true
            FocusReturn.shared.hostBusy = { [weak self] in self?.hostBusy() ?? false }
            FocusReturn.shared.start()
        }
        startWatcher()
        observeVolumes()
        watchScreenshotSettings()
        let clipboard = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        clipboardWatcher = clipboard
        if ClipboardWatcher.isEnabled { clipboard.start() }

        Markup.shared.onSaved = { [weak line] url in line?.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak line] url in line?.reloadThumbnail(for: url) }
        // 原本這裡有「照片飛進編輯器」的動畫；Noted 沒有整條繩子，直接讓編輯器出現。
        Markup.shared.onShown = { [weak line] url, _ in
            if let item = line?.items.first(where: { $0.url == url && !$0.falling && !$0.away }) { line?.takeAway(item.id) }
            Markup.shared.show()
        }
        Trim.shared.onShown = { [weak line] url, _ in
            if let item = line?.items.first(where: { $0.url == url && !$0.falling && !$0.away }) { line?.takeAway(item.id) }
            Trim.shared.show()
        }
        Markup.shared.onClosing = { [weak line] url, area in line?.editClosing(url, from: area) }
        Markup.shared.onEnded = { [weak line] url, area in line?.editEnded(url, from: area) }
        Trim.shared.onEnded = { [weak line] url, area in line?.editEnded(url, from: area) }

        line.onSent = { [weak self] in self?.onSent() }
        // 編輯完掛回來：沒有飛行動畫，直接落位，並讓瀏海提示一下
        line.onRehung = { [weak self, weak line] id, _ in
            line?.land(id)
            self?.onNewCapture()
        }
        // 原本叫出繩子的快捷鍵改成展開面板。測試時不註冊，免得搶走正式版的快捷鍵。
        if Self.testDirectory == nil, let shortcut = Shortcut.current {
            hotKey = HotKey(shortcut) { [weak self] in self?.onTogglePanel() }
        }

        line.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        state = .running
    }

    private func waitForStandaloneToQuit() {
        guard standbyObserver == nil else { return }
        standbyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == ShotLineModule.standaloneBundleID else { return }
            MainActor.assumeIsolated {
                // 等它把系統截圖設定還原完再接手
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if ShotLineModule.shared.state == .standby { ShotLineModule.shared.start() }
                }
            }
        }
    }

    /// 關掉模組（設定裡關掉時）。系統截圖設定還原、監看停掉。
    public func stop() {
        if let o = standbyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            standbyObserver = nil
        }
        guard state == .running else { state = .off; return }
        shutdown()
        watcher?.stop(); watcher = nil
        safetyWatcher?.stop(); safetyWatcher = nil
        folderWatchers.forEach { $0.stop() }; folderWatchers = []
        clipboardWatcher?.stop(); clipboardWatcher = nil
        inboxTimer?.invalidate(); inboxTimer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        cancellables.removeAll()
        hotKey = nil
        line = nil
        state = .off
    }

    /// App 要結束了：把系統截圖設定還給使用者原本的值。
    public func shutdown() {
        guard state == .running else { return }
        if Inbox.isEnabled { Inbox.restore() }
    }

    /// 第一次接手時，把獨立版 ShotLine 的偏好抄過來（只讀它的，不改它的）。
    private func migrateFromStandaloneIfNeeded() {
        let d = UserDefaults.standard
        guard Self.testDirectory == nil, !d.bool(forKey: "shot.migrated") else { return }
        d.set(true, forKey: "shot.migrated")
        guard let old = UserDefaults.standard.persistentDomain(forName: Self.standaloneBundleID) else { return }
        for key in ["inboxEnabled", "inboxOffered", "inboxSavedSettings", "soundOff", "keepDelay",
                    "extraFolders", "clipboardEnabled", "capturesFollowScreen"] {
            if d.object(forKey: key) == nil, let v = old[key] { d.set(v, forKey: key) }
        }
    }

    // MARK: 給 Noted 問的

    /// 還掛著幾張
    public var liveCount: Int { line?.liveCount ?? 0 }

    /// 正在拖、按住、開著右鍵選單、編輯中：這時候面板不要自己收起來。
    public var isInteracting: Bool {
        GrabView.isDragging || GrabView.isShowingMenu || line?.pressedID != nil || line?.draggingID != nil
    }

    public var isDragging: Bool { GrabView.isDragging }

    /// 新截圖提示要顯示幾張（最新的 1～3 張）
    public var peekCount: Int { min(3, liveCount) }

    /// 新截圖提示那一塊的大小（不含瀏海本身的高度）
    public var peekSize: CGSize {
        let n = max(1, peekCount)
        let scale = ShotLinePeek.scale
        let card = (150 * scale).rounded()
        return CGSize(width: CGFloat(n) * (card + 14) + 26, height: (104 * scale).rounded() + 8 + 14 + 22)
    }

    // MARK: 監看（照搬原本 AppDelegate 的做法）

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        let main = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line?.prune() })
        main.start()
        watcher = main
        // 收件匣模式下再看一眼桌面：有的 macOS 版本會無視截圖位置設定
        if Self.testDirectory == nil, Inbox.isEnabled,
           main.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line?.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        watchedExtraPaths = Self.extraFolders.map { $0.path }
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line?.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ShotLineModule.shared.volumesChanged() }
            })
        }
    }

    private func volumesChanged() {
        guard state == .running, !Self.extraFolderPaths.isEmpty, !remountPending else { return }
        remountPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.remountPending = false
            if self.state == .running, Self.extraFolders.map({ $0.path }) != self.watchedExtraPaths { self.startWatcher() }
        }
    }

    public static let maxExtraFolders = 3

    public static var extraFolderPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraFolders") }
    }

    static var extraFolders: [URL] {
        guard testDirectory == nil else { return [] }
        return extraFolderPaths.compactMap { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// ⌘ ⇧ 5 的選項可以在收件匣模式開著時把截圖位置改走；每秒看一次、拿回來。
    private func watchScreenshotSettings() {
        inboxTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { _ = Inbox.reclaim() }
        }
        RunLoop.main.add(timer, forMode: .common)
        inboxTimer = timer
    }

    private func hangCapture(_ url: URL) {
        guard let line, line.hang(url) != nil else { return }
        onNewCapture()
    }

    // MARK: 設定（Noted 的設定頁與右欄選單用）

    public var inboxEnabled: Bool {
        get { Inbox.isEnabled }
        set {
            guard newValue != Inbox.isEnabled else { return }
            Inbox.isEnabled = newValue
            guard state == .running else { return }
            if newValue { Inbox.apply() } else { Inbox.restore() }
            startWatcher()
            objectWillChange.send()
        }
    }

    public var clipboardEnabled: Bool {
        get { ClipboardWatcher.isEnabled }
        set {
            ClipboardWatcher.isEnabled = newValue
            if newValue { clipboardWatcher?.start() } else { clipboardWatcher?.stop() }
            objectWillChange.send()
        }
    }

    public var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff"); objectWillChange.send() }
    }

    /// 收好（搬到截圖資料夾）之後還留在右欄
    public var staysAfterKeep: Bool {
        get { Line.staysAfterKeep }
        set { Line.staysAfterKeep = newValue; objectWillChange.send() }
    }

    /// 拖出去、對方收下之後不保留：不收進截圖資料夾，10 分鐘後丟垃圾桶
    public var discardsAfterSend: Bool {
        get { Line.discardsAfterSend }
        set { Line.discardsAfterSend = newValue; objectWillChange.send() }
    }

    /// 掛上後幾秒自動收進截圖資料夾；nil＝不自動收
    public var keepDelay: TimeInterval? {
        get { Line.keepDelay }
        set { Line.keepDelay = newValue; line?.restartKeepTimers(); objectWillChange.send() }
    }
    public static let keepDelayChoices: [TimeInterval] = Line.keepDelayChoices

    /// 收好的截圖會放到哪
    public var keepFolder: URL { Inbox.keepFolder }
    /// 現在監看的截圖資料夾
    public var watchedFolder: URL? { watcher?.folder }

    public func clear() { line?.clear() }

    /// 設定頁「截圖設定⋯」的入口（右欄選單用）
    public var onOpenSettings: () -> Void = {}

    /// 設定頁：停止監看某個另外加的資料夾
    public func removeExtraFolder(_ path: String) {
        Self.extraFolderPaths.removeAll { URL(fileURLWithPath: $0).standardizedFileURL == URL(fileURLWithPath: path).standardizedFileURL }
        if state == .running { startWatcher() }
        objectWillChange.send()
    }

    /// 測試模式下不能加（測試只看暫存資料夾）
    public var canAddExtraFolder: Bool { Self.extraFolderPaths.count < Self.maxExtraFolders && Self.testDirectory == nil }

    /// 設定頁：選一個資料夾加進監看
    public func addExtraFolder() {
        chooseExtraFolder()
        objectWillChange.send()
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolderPaths.count < Self.maxExtraFolders,
              !Self.extraFolderPaths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolderPaths.append(url.path)
        if state == .running { startWatcher() }
    }

    /// 右欄「⋯」的選單。項目對應原本 ShotLine 選單列圖示的選單。
    public func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard state == .running else {
            let item = NSMenuItem(title: state == .standby ? "獨立版 ShotLine 還在執行，結束它之後這裡會接手" : "截圖功能已關閉",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in self?.clear() }
        clearItem.isEnabled = liveCount > 0
        menu.addItem(clearItem)
        menu.addItem(.separator())

        // 第二輪：選項都搬到 Noted 的合併設定視窗（截圖頁），這裡只留動作
        menu.addItem(ClosureMenuItem("截圖設定⋯") { [weak self] in self?.onOpenSettings() })
        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.keepFolder)
        })
        return menu
    }

    // MARK: 測試指令（只在 NOTED_SHOT_TEST_DIR 模式有作用）

    /// 模擬滑鼠對最新那張做的事：sent＝拖給 App 成功、discard＝雙擊、keep＝按勾勾
    public func debugAct(_ action: String) {
        guard Self.testDirectory != nil, let line else { return }
        if action == "clear" { line.clear(); return }   // 選單的「全部拿下」
        guard let item = line.items.last(where: { !$0.falling }) else { return }
        switch action {
        case "sent": line.sent(item.id)
        case "discard": line.discard(item.id)
        case "keep": line.keep(item.id)
        default: break
        }
    }

    /// 現在掛著的每一張：檔名、在哪個資料夾、是不是 Noted 收好的
    public var debugItems: [String] {
        (line?.items ?? []).filter { !$0.falling }.map {
            "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.url.lastPathComponent) managed=\($0.managed)"
        }
    }

    // MARK: Quick Look（要經過 App 的 delegate 轉進來）

    public func takePreviewPanel(_ panel: QLPreviewPanel) { QuickLook.shared.take(panel) }

    public func releasePreviewPanel(_ panel: QLPreviewPanel) {
        QuickLook.shared.release(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.line?.trimIfOver() }
    }
}

// MARK: - 右欄：小曬衣繩牆

/// 右欄的內容：一排兩張、往下排，最新的在最上面。
/// 每一排是一小段繩子，照片用夾子夾在上面，外觀與互動沿用 ShotLine 的 PeggedView。
public struct ShotLineColumn: View {
    @ObservedObject private var module = ShotLineModule.shared
    private let fg: Color
    private let isLight: Bool

    public init(fg: Color, isLight: Bool) {
        self.fg = fg
        self.isLight = isLight
    }

    public var body: some View {
        Group {
            switch module.state {
            case .running:
                if let line = module.line { LineWall(line: line, fg: fg) }
            case .standby:
                notice("獨立版 ShotLine 還在執行", "結束它之後，這一欄會自己接手截圖。")
            case .off:
                notice("截圖功能已關閉", "可以在設定裡打開。")
            }
        }
        .environment(\.colorScheme, isLight ? .light : .dark)
    }

    private func notice(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "tshirt").font(.system(size: 20)).opacity(0.45)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).opacity(0.6).multilineTextAlignment(.center)
        }
        .foregroundStyle(fg)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineWall: View {
    @ObservedObject var line: Line
    let fg: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // 一排兩張：卡片寬度由欄寬決定
            let scale = min(1.1, max(0.55, (width - 30) / 2 / 150))
            let _ = (Layout.columnScale = scale)
            let live = Array(line.items.reversed())
            let rows = stride(from: 0, to: live.count, by: 2).map { Array(live[$0..<min($0 + 2, live.count)]) }
            if live.isEmpty {
                VStack(spacing: 8) {
                    Rope(width: width).frame(height: 24)
                    Text(L("Take a screenshot and it will hang here"))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(fg.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                    Spacer(minLength: 0)
                }
                .frame(width: width, height: geo.size.height)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(rows, id: \.first!.id) { row in
                            RopeRow(items: row, line: line, width: width)
                        }
                    }
                    .padding(.bottom, 18)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: line.items.map(\.id))
                }
                .frame(width: width, height: geo.size.height)
            }
        }
    }
}

/// 一小段繩子，上面夾一或兩張。
private struct RopeRow: View {
    let items: [Pegged]
    @ObservedObject var line: Line
    let width: CGFloat

    static var height: CGFloat { Layout.photoMaxHeight + Frame.inset * 2 + PeggedView.cardOffsetBelowTop + 20 }

    var body: some View {
        let h = Self.height
        ZStack(alignment: .topLeading) {
            Rope(width: width)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let x = width * (index == 0 ? 0.27 : 0.73)
                let ropeY = Layout.ropeY(x: x, width: width)
                PeggedView(item: item, line: line)
                    .frame(width: Layout.cardWidth, height: h - ropeY, alignment: .top)
                    .position(x: x, y: ropeY - Layout.pinAbove + (h - ropeY) / 2)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
    }
}

// MARK: - 瀏海的新截圖提示

/// 收起時，截圖一掛上就從瀏海長出來的那一小塊：掛著最新的 1～3 張，可以直接拖走。
public struct ShotLinePeek: View {
    static let scale: CGFloat = 0.72

    @ObservedObject private var module = ShotLineModule.shared

    public init() {}

    public var body: some View {
        if let line = module.line {
            PeekRow(line: line).environment(\.colorScheme, .dark)
        }
    }
}

private struct PeekRow: View {
    @ObservedObject var line: Line

    var body: some View {
        let _ = (Layout.columnScale = ShotLinePeek.scale)
        let newest = Array(line.items.filter { !$0.falling }.suffix(3).reversed())
        let h = RopeRow.height
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                ForEach(Array(newest.enumerated()), id: \.element.id) { index, item in
                    let step = Layout.cardWidth + 14
                    let x = width / 2 + (CGFloat(index) - CGFloat(newest.count - 1) / 2) * step
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: h - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (h - ropeY) / 2)
                }
            }
        }
        .frame(height: h)
    }
}
