// Noted: FineTune 併進 Noted 後的入口，取代上游的 FineTuneApp.swift。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
import AppKit
import Combine
import SwiftUI
import UserNotifications
import os

/// 音訊資料放哪。要在 FineTuneModule.start() 之前設好。
public enum FineTuneStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _directory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("瀏海筆記/audio", isDirectory: true)

    public static var directory: URL {
        get { lock.lock(); defer { lock.unlock() }; return _directory }
        set { lock.lock(); _directory = newValue; lock.unlock() }
    }
}

public enum FineTuneState: Equatable, Sendable {
    /// 還沒啟動（設定裡關掉了）
    case off
    /// 獨立版 FineTune 還在跑：兩邊同時 tap 同一個 App 會把聲音播兩次，所以先不接手
    case standby
    case running
}

private final class PanelToggleBridge: MenuBarPopupControlling {
    var action: () -> Void = {}
    func toggle() { action() }
}

/// 完整面板的視窗。MenuBarPopupView 用類別名稱認它（原本認的是 FluidMenuBarExtra 的視窗）。
final class FineTunePopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class FineTuneModule: ObservableObject {
    public static let shared = FineTuneModule()
    public static let standaloneBundleID = "com.finetuneapp.FineTune"

    @Published public private(set) var state: FineTuneState = .off

    /// 「切換 FineTune 面板」的全域快捷鍵被按了。Noted 用它展開／收起瀏海面板。
    public var onTogglePanel: () -> Void = {}

    /// 第一次啟動時，把獨立版 FineTune 的設定複製一份過來當起點（原檔不動）。測試時關掉。
    public var importsStandaloneSettings = true
    /// 測試用：獨立版在跑也照樣啟動，但輸出策略只算不做（不動任何裝置），也不要求錄音權限。
    public var forceDryRun = false

    private(set) var engine: AudioEngine?
    private var settings: SettingsManager?
    private var accessibility: AccessibilityPermissionService?
    private var mediaKeyStatus: MediaKeyStatus?
    private var popupVisibility: PopupVisibilityService?
    private var hud: HUDWindowController?
    private var mediaKeyMonitor: MediaKeyMonitor?
    private var feedbackPlayer: VolumeFeedbackPlayer?
    private var shortcutsRegistry: ShortcutsRegistry?
    private var resolver: TargetAppResolver?
    private let toggleBridge = PanelToggleBridge()
    private let updateManager = UpdateManager()

    private var popupPanel: FineTunePopupPanel?
    private var standbyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.local.noted", category: "FineTuneModule")

    private init() {}

    private var standaloneRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneBundleID).isEmpty
    }

    // MARK: 啟動與結束

    public func start() {
        guard state != .running else { return }
        if !forceDryRun, standaloneRunning {
            state = .standby
            waitForStandaloneToQuit()
            return
        }
        if let o = standbyObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            standbyObserver = nil
        }
        importStandaloneSettingsIfNeeded()

        // 以下照上游 FineTuneApp.init 的順序
        CrashGuard.install()
        if !forceDryRun { OrphanedTapCleanup.destroyOrphanedDevices() }

        let settings = SettingsManager(directory: FineTuneStorage.directory)
        let profileManager = AutoEQProfileManager()
        let permission = AudioRecordingPermission()
        // 測試（只算不做）時不自動啟動全部監看：藍牙監看會跳權限視窗、process 監看會掛 tap。
        // 只開裝置清單與裝置音量這兩個唯讀的，夠畫面和輸出策略用。
        let engine = AudioEngine(permission: permission, settingsManager: settings, autoEQProfileManager: profileManager,
                                 startMonitorsAutomatically: !forceDryRun)
        engine.outputPolicy.dryRun = forceDryRun
        if forceDryRun {
            engine.deviceMonitor.start()
            engine.deviceVolumeMonitor.start()
            engine.registerNewDevicesInPriority()
            engine.outputPolicy.start()
        }
        self.engine = engine
        self.settings = settings

        let accessibilityService = AccessibilityPermissionService()
        let statusService = MediaKeyStatus()
        let popupService = PopupVisibilityService()
        let hud = HUDWindowController(settingsManager: settings, mediaKeyStatus: statusService, popupVisibility: popupService)
        let feedbackPlayer = VolumeFeedbackPlayer()

        hud.volumeWriter = { [weak engine] sliderFraction in
            guard let engine else { return }
            let volumeMonitor = engine.deviceVolumeMonitor
            // Noted: HUD 的滑桿跟音量鍵一樣，調所有勾選的裝置
            for deviceID in engine.outputPolicy.targetDeviceIDs where deviceID.isValid {
                let tier = volumeMonitor.outputVolumeBackend(for: deviceID)
                let currentMute = volumeMonitor.muteStates[deviceID] ?? false
                let willBeSilent = sliderFraction <= 0.001
                if currentMute && !willBeSilent {
                    volumeMonitor.setMute(for: deviceID, to: false)
                } else if !currentMute && willBeSilent {
                    volumeMonitor.setMute(for: deviceID, to: true)
                }
                let gain = VolumeMapping.systemGain(forSliderFraction: sliderFraction, tier: tier)
                volumeMonitor.setVolume(for: deviceID, to: gain)
                feedbackPlayer.requestFeedback(gain: VolumeFeedback.gain(tier: tier, sliderFraction: sliderFraction))
            }
        }

        let monitor = MediaKeyMonitor(
            decoder: IOKitMediaKeyDecoder(),
            audioEngine: engine,
            settingsManager: settings,
            accessibility: accessibilityService,
            hudController: hud,
            popupVisibility: popupService,
            mediaKeyStatus: statusService
        )
        monitor.feedbackPlayer = feedbackPlayer
        self.accessibility = accessibilityService
        self.mediaKeyStatus = statusService
        self.popupVisibility = popupService
        self.hud = hud
        self.mediaKeyMonitor = monitor
        self.feedbackPlayer = feedbackPlayer

        if !forceDryRun {
            accessibilityService.onTrustChanged = { [weak monitor] _ in monitor?.reconcile() }
            accessibilityService.start()
            monitor.reconcile()
        }

        toggleBridge.action = { [weak self] in self?.onTogglePanel() }
        let resolver = TargetAppResolver(ownBundleID: Bundle.main.bundleIdentifier ?? "com.local.noted")
        resolver.start()
        let registry = ShortcutsRegistry(
            settings: settings,
            popupController: toggleBridge,
            resolver: resolver,
            audioEngine: engine,
            hud: hud
        )
        self.resolver = resolver
        self.shortcutsRegistry = registry
        if !forceDryRun {
            // 上游等選單列圖示建好才註冊快捷鍵；這裡沒有那個圖示，下一輪主迴圈就註冊
            DispatchQueue.main.async { registry.start() }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }

        state = .running
    }

    private func waitForStandaloneToQuit() {
        guard standbyObserver == nil else { return }
        standbyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == FineTuneModule.standaloneBundleID else { return }
            MainActor.assumeIsolated {
                // 等它把自己的 tap 和 aggregate 收乾淨
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if FineTuneModule.shared.state == .standby { FineTuneModule.shared.start() }
                }
            }
        }
    }

    private func importStandaloneSettingsIfNeeded() {
        guard importsStandaloneSettings, !forceDryRun else { return }
        let fm = FileManager.default
        let target = FineTuneStorage.directory
        let marker = target.appendingPathComponent("settings.json")
        guard !fm.fileExists(atPath: marker.path) else { return }
        let source = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FineTune")
        guard fm.fileExists(atPath: source.appendingPathComponent("settings.json").path) else { return }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["settings.json", "autoeq-catalog.json", "AutoEQ"] {
                let from = source.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) {
                    try fm.copyItem(at: from, to: target.appendingPathComponent(name))
                }
            }
            logger.info("Imported standalone FineTune settings")
        } catch {
            logger.error("Could not import FineTune settings: \(error.localizedDescription)")
        }
    }

    /// App 要結束：還原被策略靜音的裝置、收掉音量鍵攔截、存設定。
    public func shutdown() {
        guard state == .running else { return }
        mediaKeyMonitor?.stop()
        accessibility?.stop()
        hud?.shutdown()
        engine?.shutdown()
        settings?.flushSync()
    }

    // MARK: 權限

    /// 還沒有「螢幕與系統錄音」權限：不能 tap，所以沒有每 App 音量控制。
    public var needsCapturePermission: Bool {
        guard let engine else { return false }
        return engine.permission.status != .authorized
    }

    public func requestCapturePermission() {
        engine?.permission.request()
    }

    // MARK: 完整面板（上游原本的選單列彈出面板）

    public var isFullPanelVisible: Bool { popupPanel?.isVisible == true }

    /// 在 `anchor`（螢幕座標，通常是左欄那顆按鈕）下方開上游原本的完整面板：EQ、AutoEQ、每 App 路由、輸入裝置都在這裡。
    public func toggleFullPanel(below anchor: NSRect, on screen: NSScreen?) {
        if isFullPanelVisible { closeFullPanel(); return }
        // 測試（只算不做）時不開：完整面板的滑桿會直接寫到真的裝置
        guard !forceDryRun else { return }
        // 上一個面板如果不是經 closeFullPanel 消失的，先把它和觀察者收乾淨
        if popupPanel != nil { closeFullPanel() }
        guard let engine, let accessibility, let mediaKeyStatus, let popupVisibility, let hud, let mediaKeyMonitor,
              let volumeMonitor = engine.deviceVolumeMonitor as? DeviceVolumeMonitor else { return }
        let view = MenuBarPopupView(
            audioEngine: engine,
            deviceVolumeMonitor: volumeMonitor,
            updateManager: updateManager,
            permission: engine.permission,
            accessibility: accessibility,
            mediaKeyStatus: mediaKeyStatus,
            popupVisibility: popupVisibility,
            hudController: hud,
            mediaKeyMonitor: mediaKeyMonitor
        )
        let host = NSHostingController(rootView: view)
        let panel = FineTunePopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = host
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.masksToBounds = true
        let size = host.view.fittingSize
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = max(origin.y, bounds.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        popupPanel = panel
        panel.makeKeyAndOrderFront(nil)

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // 面板裡的選單、彈出視窗會讓它暫時不是 key；有子視窗時不關
                let module = FineTuneModule.shared
                guard let panel = module.popupPanel else { return }
                if panel.childWindows?.isEmpty == false || panel.attachedSheet != nil { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard let panel = module.popupPanel, !panel.isKeyWindow,
                          panel.childWindows?.isEmpty != false, panel.attachedSheet == nil else { return }
                    module.closeFullPanel()
                }
            }
        }
    }

    /// 完整面板關掉了。Noted 用它把鍵盤還給瀏海面板。
    public var onFullPanelClosed: () -> Void = {}

    public func closeFullPanel() {
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let panel = popupPanel else { return }
        panel.orderOut(nil)
        panel.contentViewController = nil
        popupPanel = nil
        popupVisibility?.isVisible = false
        objectWillChange.send()
        onFullPanelClosed()
    }

    /// 完整面板（含它的子視窗）目前佔的範圍。Noted 判斷「游標離開面板就收起」時要把它算進去。
    public var fullPanelFrame: NSRect? {
        guard let panel = popupPanel, panel.isVisible else { return nil }
        return (panel.childWindows ?? []).reduce(panel.frame) { $0.union($1.frame) }
    }

    // MARK: 設定（上游原本的 Settings scene）
    // 第二輪起沒有自己的設定視窗：上游的設定頁內容（FineTuneSettingsPane）放進 Noted 的合併設定視窗。

    /// 完整面板裡的齒輪被按了。Noted 用它打開合併設定視窗的音量頁。
    public var onOpenSettings: () -> Void = {}

    public func openSettingsWindow() { onOpenSettings() }

    /// 上游設定頁需要的那一串物件；模組沒在跑時是 nil
    struct SettingsContext {
        let settings: SettingsManager
        let engine: AudioEngine
        let volumeMonitor: DeviceVolumeMonitor
        let accessibility: AccessibilityPermissionService
        let mediaKeyStatus: MediaKeyStatus
        let mediaKeyMonitor: MediaKeyMonitor
        let shortcutsRegistry: ShortcutsRegistry
    }

    var settingsContext: SettingsContext? {
        guard state == .running, let engine, let settings, let accessibility, let mediaKeyStatus, let mediaKeyMonitor, let shortcutsRegistry,
              let volumeMonitor = engine.deviceVolumeMonitor as? DeviceVolumeMonitor else { return nil }
        return SettingsContext(settings: settings, engine: engine, volumeMonitor: volumeMonitor, accessibility: accessibility,
                               mediaKeyStatus: mediaKeyStatus, mediaKeyMonitor: mediaKeyMonitor, shortcutsRegistry: shortcutsRegistry)
    }

    // MARK: 輸出策略（給 Noted 的設定頁與測試用）

    /// 輸出複選有沒有開始接管
    public var outputPolicyArmed: Bool { engine?.outputPolicy.isArmed ?? false }

    /// 測試（只算不做）中：左欄的滑桿與按鈕不接滑鼠，免得寫到真的裝置
    public var isDryRun: Bool { forceDryRun }

    /// 停止接管，回到原本 FineTune 的行為（點哪個哪個是預設輸出）
    public func disarmOutputPolicy() {
        engine?.outputPolicy.disarm()
        objectWillChange.send()
    }

    public func flushSettings() {
        settings?.flushSync()
    }

    // MARK: 同時輸出時的延遲對齊（設定頁用）

    /// 設定頁的一列：一個正在同時輸出的裝置
    public struct AlignmentRow: Identifiable, Sendable {
        public let id: String
        public let name: String
        /// 系統回報的輸出延遲（毫秒）；讀不到是 nil
        public let reportedMs: Double?
        /// 手動微調（毫秒）
        public let trimMs: Double
        /// 實際加在這個裝置上的延遲（毫秒）
        public let delayMs: Double
    }

    public static let alignmentTrimRange = OutputAlignmentState.trimRange

    public var alignmentEnabled: Bool {
        get { engine?.outputAlignment.enabled ?? true }
        set {
            guard let engine else { return }
            var s = engine.outputAlignment
            s.enabled = newValue
            engine.setOutputAlignment(s)
            objectWillChange.send()
        }
    }

    /// 現在同時輸出的裝置（不到兩個就是空的）
    public var alignmentRows: [AlignmentRow] {
        guard let engine, let uids = engine.outputPolicy.targets, uids.count > 1 else { return [] }
        let state = engine.outputAlignment
        let devices = uids.compactMap { engine.deviceMonitor.device(for: $0) }
        let reported = devices.map { OutputAlignment.reportedLatencyMs(of: $0.id) }
        let delays = OutputAlignment.delaysMs(latenciesMs: reported.map { $0 ?? 0 }, trimsMs: devices.map { state.trimMs[$0.uid] ?? 0 })
        return devices.enumerated().map { i, d in
            AlignmentRow(id: d.uid, name: d.name, reportedMs: reported[i], trimMs: state.trimMs[d.uid] ?? 0, delayMs: delays[i])
        }
    }

    public func setAlignmentTrim(uid: String, ms: Double) {
        guard let engine else { return }
        var s = engine.outputAlignment
        let v = min(max(ms, Self.alignmentTrimRange.lowerBound), Self.alignmentTrimRange.upperBound)
        if v == 0 { s.trimMs[uid] = nil } else { s.trimMs[uid] = v }
        engine.setOutputAlignment(s)
        objectWillChange.send()
    }

    /// 測試用：只算不做時累積的動作紀錄
    public var dryRunLog: [String] { engine?.outputPolicy.dryRunLog ?? [] }

    /// 測試用：直接切換某個裝置的勾選（forceDryRun 時不會真的動裝置）
    public func debugToggleOutput(uidContaining text: String) {
        guard let engine, let device = engine.outputPolicy.orderedDevices.first(where: {
            $0.uid.localizedCaseInsensitiveContains(text) || $0.name.localizedCaseInsensitiveContains(text)
        }) else { return }
        engine.outputPolicy.toggle(device.uid)
    }
}
