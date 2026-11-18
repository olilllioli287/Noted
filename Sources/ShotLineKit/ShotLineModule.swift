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

    /// 測試版可以用 NOTED_FAKE_STANDALONE_ID 換成一個假的「舊版」bundle id，在暫存環境重現待命接手；正式版忽略。
    private static let fakeStandaloneID: String? = DevBuild.environment["NOTED_FAKE_STANDALONE_ID"].flatMap { $0.isEmpty ? nil : $0 }
    public static let standaloneBundleID = fakeStandaloneID ?? "local.shotline.ShotLine"

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
    /// 掛著的張數變少了（按叉叉、右鍵丟棄／收下、打勾、雙擊、自動收走、裁掉…任何途徑）。
    /// Noted 用它把提示上已經沒有的截圖收掉或重排。
    public var onCountDecreased: () -> Void = {}
    /// 瀏海面板展開打字中、或 Noted 自己的視窗開著時回 true，
    /// 這時候不把鍵盤交回上一個 App。
    public var hostBusy: () -> Bool = { false }
    /// 宿主放掉自己面板握著的鍵盤（拖放給別的 App 時用）
    public var releaseHostKeyboard: () -> Void = {}
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
    /// 待命時每 2 秒看一次舊版還在不在。NSWorkspace 的結束通知不會送出背景型（LSUIElement，選單列）App 的結束，
    /// 舊版 ShotLine 就是這種 App，只靠通知會永遠等不到。
    private var standbyTimer: Timer?
    private var focusStarted = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: 啟動與結束

    private var standaloneRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).isEmpty
    }

    public func start() {
        guard state != .running else { return }
        if Self.testDirectory == nil || Self.fakeStandaloneID != nil, standaloneRunning {
            state = .standby
            waitForStandaloneToQuit()
            return
        }
        cancelStandbyWait()
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
            FocusReturn.shared.releaseHostKeyboard = { [weak self] in self?.releaseHostKeyboard() }
            FocusReturn.shared.start()
        }
        startWatcher()
        recoverInboxOrphans()
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

        line.$items
            .map { $0.filter { !$0.falling }.count }
            .removeDuplicates()
            .scan((0, 0)) { ($0.1, $1) }
            .filter { $0.1 < $0.0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onCountDecreased() }
            .store(in: &cancellables)

        state = .running
    }

    private func cancelStandbyWait() {
        if let o = standbyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            standbyObserver = nil
        }
        standbyTimer?.invalidate()
        standbyTimer = nil
    }

    private func waitForStandaloneToQuit() {
        if standbyTimer == nil {
            standbyTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.state == .standby else { self.cancelStandbyWait(); return }
                    guard !self.standaloneRunning else { return }
                    // 等它把系統截圖設定還原完再接手
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if ShotLineModule.shared.state == .standby { ShotLineModule.shared.start() }
                    }
                }
            }
        }
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
        cancelStandbyWait()
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

    /// 上次不正常結束（當掉、被強制結束、斷電）時，系統截圖位置還指著收件匣，那段時間拍的截圖
    /// 會留在裡面沒人管；監看器的第一次列表又把啟動前就在的檔案都當舊的。
    /// 啟動時把收件匣裡的圖都掛上（hang 本身會略過已掛著、掛過、正等丟垃圾桶的）。
    private func recoverInboxOrphans() {
        // 收件匣模式沒開時，系統截圖位置沒指到這裡，裡面的東西不是這個功能該管的
        guard Inbox.isEnabled, let line else { return }
        let media: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "mov", "mp4"]
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: Inbox.folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { media.contains($0.pathExtension.lowercased()) && !Line.isPendingTrash($0) }
        // 建立時間每個檔案只讀一次（排序比較器裡重讀會是 N log N 次檔案系統呼叫）
        let dated = urls.map { u in (u, (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast) }
        let sorted = dated.sorted { $0.1 < $1.1 }.map(\.0)
        // 最新的掛到上限為止；更舊的掛不下，直接收進截圖資料夾（不在主執行緒解一堆縮圖）
        let limit = Self.columnCapacity
        for url in sorted.dropLast(limit) { line.shelveOrphan(url) }
        for url in sorted.suffix(limit) {
            // 掛不上（縮圖解不出來、殘缺的錄影）也不能留在隱藏的收件匣，改收進截圖資料夾
            if line.hang(url, quietly: true) == nil { line.shelveOrphan(url) }
        }
    }

    private func hangCapture(_ url: URL) {
        guard let line else { return }
        Self.mark("detect")
        // 檔案一出現就在拍攝位置給回饋（彈一下），不等卡片掛好、也不等新截圖提示長出來；
        // 有拍攝位置、主程式願意（flightContext 回傳不是 nil）、同時飛的少於 2 張才這樣，其餘直接掉進去。
        // 卡片在起飛前先藏著（flying），所以每個 id 一定要有人讓它現身（landCapture）。
        var flight: CaptureFlight?
        var from: CGRect?
        if pendingFlights.count < 2, let r = captureRect(of: url), let c = flightContext?(r) {
            from = r
            let f = CaptureFlight.begin(from: r, on: c.screen, level: Self.flightLevel, dark: c.dark)
            flight = f
            decodeFlightImage(url, for: f, from: r, screen: c.screen)
        }
        guard let id = line.hang(url, flying: flight != nil) else {
            flight?.cancel()   // 掛不上（重複、縮圖解不出來）：彈起的畫面淡掉就好
            return
        }
        onNewCapture()
        guard let flight, let from else { return }
        pendingFlights.insert(id)
        let tilt = line.items.first(where: { $0.id == id })?.tilt ?? 0
        flight.attach(tag: id, tilt: CGFloat(tilt), target: { [weak self] in self?.flightTarget(id: id, from: from) },
                      completion: { [weak self] in
            if DevBuild.isDev { Self.debugAllTo.append("\(id.uuidString.prefix(4)) \(Self.debugLastTo.integral)") }
            self?.landCapture(id)
        })
        // 保險：不管飛行出什麼事，卡片最晚 3 秒後一定現身
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.landCapture(id) }
    }

    /// 在背景把截圖解成飛行用的大小（整張螢幕的 PNG 解碼要幾十毫秒，不能卡住「立刻回饋」）；解好前飛行先用白底。
    private func decodeFlightImage(_ url: URL, for flight: CaptureFlight, from: CGRect, screen: NSScreen) {
        let pixels = min(1500, max(400, Int(max(from.width, from.height) * screen.backingScaleFactor)))
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            DispatchQueue.main.async { flight.setImage(image) }
        }
    }

    /// 卡片現在應該落在哪（螢幕座標）。每一幀問一次；新截圖提示還沒長出來、位置還沒回報、
    /// 面板暫時看不到這張時回傳 nil，飛行就沿用上一次的落點。
    private func flightTarget(id: UUID, from: CGRect) -> CGRect? {
        guard let line, let c = flightContext?(from),
              line.items.contains(where: { $0.id == id && !$0.falling && !$0.away }),
              let g = (c.expanded ? line.columnRects : line.peekRects)[id],
              g.width > 4, g.height > 4, c.windowFrame.width > 0,
              g.minX >= -1, g.minY >= -1, g.maxX <= c.windowFrame.width + 1, g.maxY <= c.windowFrame.height + 1 else { return nil }
        let to = CGRect(x: c.windowFrame.minX + g.minX, y: c.windowFrame.maxY - g.maxY, width: g.width, height: g.height)
        guard c.visible.insetBy(dx: -2, dy: -2).contains(to) else { return nil }
        if DevBuild.isDev { Self.debugLastTo = to }
        return to
    }

    /// 飛行結束（或不飛了）：真的卡片現身。可以重複呼叫。
    public func landCapture(_ id: UUID) {
        Self.mark("land")
        pendingFlights.remove(id)
        line?.land(id)
    }

    /// 現在的面板狀態（由主程式回報；飛行每一幀都會重問，因為面板會長出來、收起、展開）。
    public struct FlightContext {
        /// 瀏海視窗在螢幕上的位置（卡片位置是相對這個視窗回報的）
        public var windowFrame: CGRect
        /// 面板現在可見的範圍（螢幕座標）；落點不在裡面（例如右欄捲走了）就不飛
        public var visible: CGRect
        /// 面板是展開的（看右欄的位置），否則看新截圖提示的位置
        public var expanded: Bool
        /// 面板是暗色的（卡片玻璃也是暗的）
        public var dark: Bool
        public var screen: NSScreen
        public init(windowFrame: CGRect, visible: CGRect, expanded: Bool, dark: Bool, screen: NSScreen) {
            self.windowFrame = windowFrame; self.visible = visible; self.expanded = expanded; self.dark = dark; self.screen = screen
        }
    }

    /// 測試版的除錯指令用：存下飛行中的畫面、回報殘留的飛行視窗數
    public static func debugFlightAuto(_ prefix: String) { CaptureFlight.debugAutoSnapshotPrefix = prefix }
    public static func debugFlightSnapshot(_ path: String) -> Bool { CaptureFlight.debugSnapshot(to: path) }
    private static var debugLastTo: CGRect = .zero
    private static var debugAllTo: [String] = []
    /// 測試用（只有測試版會記）：每個事件的牆上時間（秒），給量「從檔案出現到卡片落地」用
    private static var debugTimeline: [String] = []
    static func mark(_ event: String) {
        guard DevBuild.isDev else { return }
        debugTimeline.append("\(event)=\(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
    /// 測試用：每張起飛時量到的落點，以及現在新截圖提示與右欄各卡片實際的位置（視窗座標）
    public static func debugFlightDetail() -> String {
        let line = shared.line
        let peek = (line?.peekRects ?? [:]).map { "\($0.key.uuidString.prefix(4)) \($0.value.integral)" }.sorted()
        let column = (line?.columnRects ?? [:]).map { "\($0.key.uuidString.prefix(4)) \($0.value.integral)" }.sorted()
        return "timeline=\(debugTimeline.joined(separator: " "))\nflights(螢幕座標)=\(debugAllTo)\npeek(視窗座標)=\(peek)\ncolumn(視窗座標)=\(column)"
    }
    public static var debugFlightState: String { "to=\(debugLastTo) flying=\(CaptureFlight.debugFlying) visibleWindows=\(CaptureFlight.debugVisibleWindows) hiddenCards=\(shared.line?.items.filter(\.flying).count ?? -1) cards=\(shared.line?.items.count ?? -1)" }

    /// 飛行視窗要蓋在瀏海視窗（選單列 + 3）上面，不然落地時會被面板擋住。
    private static let flightLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)

    /// 正在等著飛、或正在飛的截圖（最多 2 張，其餘直接掉進去）
    private var pendingFlights = Set<UUID>()
    /// Noted：新截圖出現時問主程式「現在要不要飛、面板在哪」。回傳 nil（遊戲暫停、提示關閉、拍攝位置不在提示出現的螢幕）就不飛，卡片直接現身。
    /// 飛行進行中每一幀也會再問一次，回報最新的面板位置。
    public var flightContext: ((_ from: CGRect) -> FlightContext?)?

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

    /// 使用者有沒有自選收好的位置（只要選過就算，就算資料夾後來不見了）
    public var hasCustomKeepFolder: Bool { Inbox.customKeepPath != nil }
    /// 自選的資料夾現在不能用（不見了或不能寫）時的路徑；設定頁用來顯示一行小字
    public var unusableCustomKeepPath: String? { Inbox.unusableCustomKeepPath }

    /// 設定頁：選收好的截圖要放的資料夾（可新增資料夾）。選到不能用的就擋下並提示，不改設定。
    public func chooseKeepFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.message = "收好的截圖會放到這個資料夾。已經收好的舊截圖不會搬過去。"
        if let start = Inbox.customKeepFolder { panel.directoryURL = start }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !Inbox.setCustomKeepFolder(url) {
            let alert = NSAlert()
            alert.messageText = "不能用這個資料夾"
            alert.informativeText = "它不存在、沒有寫入權限，或是 Noted 自己暫存截圖用的資料夾。請選別的資料夾。"
            alert.runModal()
        }
        objectWillChange.send()
    }

    /// 設定頁：恢復預設（macOS 原本的截圖位置，沒有就桌面）
    public func resetKeepFolder() {
        Inbox.resetCustomKeepFolder()
        objectWillChange.send()
    }

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
        .onPreferenceChange(HitRectsKey.self) { rects in line.columnRects = rects }
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
        .onPreferenceChange(HitRectsKey.self) { rects in line.peekRects = rects }
    }
}
