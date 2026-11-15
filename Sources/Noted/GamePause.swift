import AppKit
import Combine

// 玩遊戲時暫停：前景是遊戲（或使用者手動暫停）時，瀏海不展開、不冒提示。
// 只擋「從頂端長出東西」這件事；截圖的檔案流程與音量的輸出策略完全不經過這裡，照常運作。
// 設計見 docs/notch-suite-設計.md 8.2。

/// 判斷用的前景 App 資料（做成純資料，比對函式才能單獨測）
struct FrontAppInfo: Equatable {
    var bundleID: String?
    var name: String?
    var executablePath: String?
    var arguments: [String] = []
    /// Info.plist 的 LSApplicationCategoryType
    var category: String?
    /// 有視窗剛好蓋滿某個螢幕
    var coversScreen = false
}

struct GamePauseRules: Equatable {
    var keywords: [String]
    var useCategory: Bool
    var useFullscreen: Bool

    static let defaultKeywords = [
        "wine", "StarCraft", "SC2", "GenshinImpact", "YuanShen", "StarRail", "ZenlessZoneZero",
        "League of Legends", "LeagueofLegends", "steamapps",
    ]

    /// 回傳暫停的原因（給設定畫面顯示）；nil＝不是遊戲
    func match(_ app: FrontAppInfo) -> String? {
        let fields = [app.bundleID, app.name, app.executablePath].compactMap { $0 } + app.arguments
        for raw in keywords {
            let key = raw.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if fields.contains(where: { $0.localizedCaseInsensitiveContains(key) }) {
                return "\(app.name ?? "前景 App")（符合「\(key)」）"
            }
        }
        if useCategory, let c = app.category?.lowercased(),
           c == "public.app-category.games" || c.hasSuffix("-games") {
            return "\(app.name ?? "前景 App")（標示為遊戲）"
        }
        if useFullscreen, app.coversScreen {
            return "\(app.name ?? "前景 App")（全螢幕）"
        }
        return nil
    }
}

final class GamePause: ObservableObject {
    static let shared = GamePause()

    enum Reason: Equatable {
        /// 手動暫停；until 是 nil 表示直到使用者恢復
        case manual(until: Date?)
        case game(String)
    }

    @Published private(set) var reason: Reason?
    var isPaused: Bool { reason != nil }

    private let d = UserDefaults.standard
    @Published var detectGames: Bool { didSet { d.set(detectGames, forKey: "pause.detectGames"); evaluate() } }
    @Published var keywords: [String] { didSet { d.set(keywords, forKey: "pause.keywords"); evaluate() } }
    @Published var useCategory: Bool { didSet { d.set(useCategory, forKey: "pause.useCategory"); evaluate() } }
    @Published var useFullscreen: Bool { didSet { d.set(useFullscreen, forKey: "pause.useFullscreen"); evaluate() } }

    private var manual: Reason?
    private var manualTimer: Timer?
    private var started = false
    /// 暫停狀態變了（AppDelegate 用它叫各個瀏海控制器收起提示、換選單列圖示）
    var onChange: () -> Void = {}

    private init() {
        d.register(defaults: [
            "pause.detectGames": true, "pause.keywords": GamePauseRules.defaultKeywords,
            "pause.useCategory": true, "pause.useFullscreen": false,
        ])
        detectGames = d.bool(forKey: "pause.detectGames")
        keywords = d.stringArray(forKey: "pause.keywords") ?? GamePauseRules.defaultKeywords
        useCategory = d.bool(forKey: "pause.useCategory")
        useFullscreen = d.bool(forKey: "pause.useFullscreen")
    }

    var rules: GamePauseRules { GamePauseRules(keywords: keywords, useCategory: useCategory, useFullscreen: useFullscreen) }

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.evaluate() }
        }
        evaluate()
    }

    // MARK: 手動

    /// minutes 是 nil＝直到恢復
    func pauseManually(minutes: Int?) {
        manualTimer?.invalidate(); manualTimer = nil
        if let minutes {
            let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
            manual = .manual(until: until)
            let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in self?.resumeManual() }
            RunLoop.main.add(t, forMode: .common)
            manualTimer = t
        } else {
            manual = .manual(until: nil)
        }
        evaluate()
    }

    func resumeManual() {
        manualTimer?.invalidate(); manualTimer = nil
        manual = nil
        evaluate()
    }

    var isManuallyPaused: Bool { manual != nil }

    func toggleManual() { if isManuallyPaused { resumeManual() } else { pauseManually(minutes: nil) } }

    // MARK: 判斷

    func evaluate() {
        var new: Reason? = manual
        if new == nil, detectGames, let app = Self.frontApp(needFullscreen: useFullscreen), let why = rules.match(app) {
            new = .game(why)
        }
        guard new != reason else { return }
        reason = new
        onChange()
    }

    /// 給設定畫面與選單看的一行說明
    var statusText: String {
        switch reason {
        case nil: return "沒有暫停。"
        case .manual(let until?):
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "手動暫停中，\(f.string(from: until)) 恢復。"
        case .manual(nil): return "手動暫停中，直到你按恢復。"
        case .game(let why): return "暫停中：\(why)。切到別的 App 就恢復。"
        }
    }

    /// 現在的前景 App（Noted 自己不算）
    static func frontApp(needFullscreen: Bool) -> FrontAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var info = FrontAppInfo(bundleID: app.bundleIdentifier, name: app.localizedName, executablePath: app.executableURL?.path)
        info.arguments = processArguments(app.processIdentifier)
        if let url = app.bundleURL, let bundle = Bundle(url: url) {
            info.category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        }
        if needFullscreen { info.coversScreen = coversAScreen(pid: app.processIdentifier) }
        return info
    }

    /// 程序的啟動參數（Wine 的遊戲程序名字都叫 wine，要看參數才知道跑的是哪個 .exe）
    static func processArguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parseProcArgs(Array(buffer[0..<size]))
    }

    /// KERN_PROCARGS2 的格式：argc（Int32）、執行檔路徑、補零、接著 argc 個以零結尾的字串（之後是環境變數，不讀）
    static func parseProcArgs(_ bytes: [UInt8]) -> [String] {
        guard bytes.count > MemoryLayout<Int32>.size else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }
        var i = MemoryLayout<Int32>.size
        while i < bytes.count, bytes[i] != 0 { i += 1 }   // 執行檔路徑
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // 補零
        var args: [String] = []
        while i < bytes.count, args.count < Int(argc) {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func coversAScreen(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if screens.contains(where: { abs($0.minX - rect.minX) < 1 && abs($0.minY - rect.minY) < 1
                && abs($0.width - rect.width) < 1 && abs($0.height - rect.height) < 1 }) { return true }
        }
        return false
    }
}
