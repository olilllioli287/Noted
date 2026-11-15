import AppKit
import SwiftUI
import Combine
import KeyboardShortcuts
import ShotLineKit

extension KeyboardShortcuts.Name {
    /// 切換「暫停 Noted」（預設不設，設定裡自己錄）
    static let notedTogglePause = Self("notedTogglePause")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate!
    var controllers: [NotchController] = []
    private var statusItem: NSStatusItem!
    var settingsWindow: AppWindow?
    var taskWindow: AppWindow?
    private var rebuildWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var pauseItems: [NSMenuItem] = []

    var hasOpenWindows: Bool { [settingsWindow, taskWindow].contains { $0?.isVisible == true } }
    private var expanded: NotchController? { controllers.first(where: \.isExpanded) }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Noted")
        let m = NSMenu()
        m.addItem(withTitle: "打開筆記", action: #selector(openPanelFromMenu(_:)), keyEquivalent: "")
        m.addItem(withTitle: "任務⋯", action: #selector(openTaskWindow(_:)), keyEquivalent: "0")
        m.addItem(withTitle: "設定⋯", action: #selector(openSettings(_:)), keyEquivalent: ",")
        m.addItem(.separator())
        // 暫停：玩遊戲時游標甩到頂端不要有反應。標題與顯示與否在 menuNeedsUpdate 更新
        let pauseStatus = m.addItem(withTitle: "", action: nil, keyEquivalent: "")
        pauseStatus.isEnabled = false
        let pause30 = m.addItem(withTitle: "暫停 30 分鐘", action: #selector(pauseFor30(_:)), keyEquivalent: "")
        let pauseHold = m.addItem(withTitle: "暫停到我恢復", action: #selector(pauseUntilResume(_:)), keyEquivalent: "")
        let resume = m.addItem(withTitle: "恢復", action: #selector(resumeFromPause(_:)), keyEquivalent: "")
        pauseItems = [pauseStatus, pause30, pauseHold, resume]
        m.delegate = self
        m.addItem(.separator())
        m.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
        #if !NOTED_PUBLIC
        // 集合面板可以藏這個圖示、叫出選單（私人版專用，公開版不含）
        HubLink.install(statusItem: { [weak self] in self?.statusItem }, reload: { [weak self] in
            // 面板改了 defaults：先同步系統設定服務，再重讀、套用（照設定視窗改設定時做的事）
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            let changed = Prefs.shared.reloadFromDefaults()
            if changed.displays { self?.rebuildControllers() }
            else if changed.geometry { self?.controllers.forEach { $0.refreshGeometry() } }
        })
        #endif

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRebuild()
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in NotchController.menuTracking = true }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotchController.menuTracking = false }
        }
        let env = DevBuild.environment
        // 測試用：視窗搬到畫面外、不自動收回，配合 debug 的 snap 截圖
        if env["NOTED_TEST_OFFSCREEN"] == "1" { NotchController.debugOffscreen = true; NotchController.debugHold = true }
        rebuildControllers()
        if env["NOTED_TEST_OFFSCREEN"] != "1" { controllers.forEach { $0.launchTease() } }
        // 音量與截圖兩個模組
        SuiteHost.start()
        // 玩遊戲時暫停（只擋瀏海的展開與提示；上面兩個模組照常跑）
        GamePause.shared.onChange = { [weak self] in self?.pauseChanged() }
        GamePause.shared.start()
        KeyboardShortcuts.onKeyUp(for: .notedTogglePause) { GamePause.shared.toggleManual() }
        pauseChanged()
        installTerminationSignals()
        // 測試用：`debug.sh <指令> [螢幕序號]`，不必動滑鼠就能切狀態。
        // 通知名稱跟著 bundle id，測試版（com.local.noted.suite-dev）不會動到正式版。
        // 只在測試版（bundle id 以 .suite-dev 結尾）掛上；正式版與別人自建的版本沒有這條通道。
        if DevBuild.isDev {
        let debugName = (Bundle.main.bundleIdentifier ?? "com.local.noted") + ".debug"
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(debugName), object: nil, queue: .main) { [weak self] n in
            guard let self, let parts = (n.object as? String)?.split(separator: " ").map(String.init), let cmd = parts.first else { return }
            let c = parts.count > 1 ? self.controllers[safe: Int(parts[1]) ?? 0] : self.controllers.first
            switch cmd {
            case "bring":   // bring <x> <y>
                if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                    ShotLineModule.shared.debugBring(at: NSPoint(x: x, y: y))
                }
            case "expand": c?.expand(activate: false)
            case "collapse": c?.collapse()
            case "hover": c?.hoverBegan()
            case "list": c?.expand(activate: false); c?.model.showList = true
            case "capsule":   // capsule <x 比例> <y 比例> <螢幕序號>
                if parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
                    let t = parts.count > 3 ? self.controllers[safe: Int(parts[3]) ?? 0] : self.controllers.first
                    if let t { Prefs.shared.setCapsulePosition(CGPoint(x: x, y: y), for: t.screenKey); t.refreshGeometry() }
                }
            #if !NOTED_PUBLIC
            case "import":
                let msg: String
                do { let items = try GlideNoteImporter.run(); msg = "找到 \(items.count)，匯入 \(Store.shared.importTasks(items))" }
                catch { msg = "失敗：\(error.localizedDescription)" }
                try? msg.write(toFile: NSTemporaryDirectory() + "noted-import.txt", atomically: true, encoding: .utf8)
            #endif
            case "hold": NotchController.debugHold = parts.count > 1 && parts[1] == "on"
            case "pin": c?.model.pinned = true
            case "reminder": ReminderController.shared.fire(demo: true)
            case "drop": _ = c?.dropEntered(); _ = c?.performDrop("測試拖放文字 " + Date().description)
            case "shot": c?.showShot(count: max(1, SuiteHost.shotPeekCount))
            case "tab": if parts.count > 1, let t = Int(parts[1]) { (parts.count > 2 ? self.controllers[safe: Int(parts[2]) ?? 0] : self.controllers.first)?.model.suiteTab = t }
            case "snap":   // snap <輸出檔.png> [螢幕序號]：把瀏海視窗畫成圖，不用螢幕錄影權限
                if parts.count > 1 {
                    let t = parts.count > 2 ? self.controllers[safe: Int(parts[2]) ?? 0] : self.controllers.first
                    if let view = t?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                    }
                }
            case "shot-act": if parts.count > 1 { SuiteHost.debugShot(parts[1]) }   // sent｜discard｜keep，只在截圖測試模式有作用
            case "theme": if parts.count > 1, let t = PanelTheme.all.first(where: { $0.id == parts[1] }) { Prefs.shared.apply(t) }
            case "ratio": if parts.count > 2, let w = Double(parts[1]), let h = Double(parts[2]) { SuitePrefs.shared.widthRatio = w; SuitePrefs.shared.heightRatio = h; self.controllers.forEach { $0.refreshGeometry() } }
            case "audio-toggle":   // audio-toggle <裝置名稱或 UID 的一部分>（NOTED_AUDIO_DRYRUN=1 時只算不做）
                if parts.count > 1 { SuiteHost.debugAudioToggle(parts.dropFirst().joined(separator: " ")) }
            case "audio-log":
                if parts.count > 1 {
                    try? SuiteHost.debugAudioLog().write(toFile: parts[1], atomically: true, encoding: .utf8)
                }
            case "style": if parts.count > 1, let s = UIStyle(rawValue: parts[1]) { Prefs.shared.uiStyle = s }   // style mac｜hud
            case "settings-snap":   // settings-snap <輸出檔> <頁> [子頁序號]：把設定視窗畫在畫面外的視窗再存成圖，不出現在螢幕上、不搶焦點
                if parts.count > 2, let pane = SettingsPane(rawValue: parts[2]) {
                    SettingsSnapshot.take(to: parts[1], pane: pane, sub: parts.count > 3 ? (Int(parts[3]) ?? 0) : 0)
                }
            case "pause":   // pause on｜off｜30：手動暫停（測遊戲暫停用）
                if parts.count > 1 {
                    switch parts[1] {
                    case "on": GamePause.shared.pauseManually(minutes: nil)
                    case "off": GamePause.shared.resumeManual()
                    default: if let n = Int(parts[1]) { GamePause.shared.pauseManually(minutes: n) }
                    }
                }
            case "pause-dump":   // pause-dump <輸出檔>：現在的前景 App 被判斷成什麼
                if parts.count > 1 {
                    let g = GamePause.shared
                    let app = GamePause.frontApp(needFullscreen: true)
                    let text = "paused=\(g.isPaused) status=\(g.statusText)\nfront=\(String(describing: app))\nmatch=\(app.flatMap { g.rules.match($0) } ?? "nil")\n"
                        + self.controllers.map { "ignoresMouse=\($0.window.ignoresMouseEvents) state=\($0.model.state)" }.joined(separator: "\n")
                    try? text.write(toFile: parts[1], atomically: true, encoding: .utf8)
                }
            case "dump":
                let info = self.controllers.map { "\($0.screen.localizedName) notch=\($0.model.hasNotch) shape=\($0.model.shapeRect) win=\($0.window.frame) state=\($0.model.state)" }
                try? info.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "noted-dump.txt", atomically: true, encoding: .utf8)
            default: break
            }
        }
        }
        ReminderController.shared.start()
        if let err = Store.shared.loadError {
            let a = NSAlert(); a.messageText = "筆記檔讀取失敗"; a.informativeText = err; a.runModal()
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        Store.shared.saveNow()
        // 系統截圖位置還給使用者、被取消勾選而靜音的裝置還原、音訊設定存檔
        SuiteHost.shutdown()
    }

    /// 被 kill（例如 build.sh 的 pkill、登出）時也走一般的結束流程，
    /// 不然系統截圖位置會停在沒人看的資料夾、裝置停在靜音。
    private func installTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    // 選單列圖示被集合面板藏起來時，在 Finder 再打開一次就彈出選單
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if !NOTED_PUBLIC
        HubLink.reopen()
        #endif
        return false
    }

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rebuildControllers() }
        rebuildWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func rebuildControllers() {
        controllers.forEach { $0.teardown() }
        let off = Set(Prefs.shared.disabledDisplays)
        controllers = NSScreen.screens.filter { !off.contains(NotchController.key(for: $0)) }.map { NotchController(screen: $0) }
    }

    // MARK: 暫停

    private func pauseChanged() {
        controllers.forEach { $0.pauseChanged() }
        let paused = GamePause.shared.isPaused
        statusItem?.button?.image = NSImage(systemSymbolName: paused ? "pause.circle" : "square.and.pencil",
                                            accessibilityDescription: paused ? "Noted（暫停中）" : "Noted")
    }
    @objc func pauseFor30(_ s: Any?) { GamePause.shared.pauseManually(minutes: 30) }
    @objc func pauseUntilResume(_ s: Any?) { GamePause.shared.pauseManually(minutes: nil) }
    @objc func resumeFromPause(_ s: Any?) { GamePause.shared.resumeManual() }

    // MARK: 選單列

    private func buildMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title); items.forEach(m.addItem); it.submenu = m; main.addItem(it)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.tag = tag; return i
        }
        sub("Noted", [
            item("設定⋯", #selector(openSettings(_:)), ","),
            item("任務視窗", #selector(openTaskWindow(_:)), "0"),
            .separator(),
            item("結束", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("編輯", [
            item("還原", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪下", #selector(NSText.cut(_:)), "x"),
            item("拷貝", #selector(NSText.copy(_:)), "c"),
            item("貼上", #selector(NSText.paste(_:)), "v"),
            item("全選", #selector(NSText.selectAll(_:)), "a"),
        ])
        let fmtKeys: [(LineFormat, String)] = [(.heading, "h"), (.checklist, "l"), (.bullet, "8"), (.numbered, "7"), (.dash, "-"), (.body, "0")]
        sub("格式", fmtKeys.enumerated().map { i, fk in item(fk.0.label, #selector(formatLine(_:)), fk.1, [.command, .shift], tag: i) })
        sub("任務", [
            item("新增任務", #selector(newTask(_:)), "n"),
            item("刪除任務", #selector(deleteTask(_:)), "\u{8}"),
            item("任務列表", #selector(toggleList(_:)), "l"),
            item("釘選瀏海", #selector(togglePin(_:)), "p"),
            .separator(),
        ] + (1...9).map { item("任務 \($0)", #selector(selectTask(_:)), "\($0)", tag: $0) })
        sub("顯示方式", [
            item("放大文字", #selector(bigger(_:)), "="),
            item("縮小文字", #selector(smaller(_:)), "-"),
        ])
        sub("視窗", [item("關閉", #selector(closeWindow(_:)), "w")])
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(formatLine(_:)): return NoteTextView.active?.window?.isKeyWindow == true
        case #selector(toggleList(_:)), #selector(togglePin(_:)), #selector(selectTask(_:)): return expanded != nil
        default: return true
        }
    }

    // MARK: 動作

    private var controllerUnderMouse: NotchController? {
        controllers.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? controllers.first
    }

    @objc func openPanelFromMenu(_ s: Any?) {
        let c = ((s as? NSMenuItem)?.representedObject as? NotchController) ?? controllerUnderMouse
        // 從狀態列選單打開時，等選單收起再展開
        DispatchQueue.main.async { c?.expand() }
    }
    @objc func newTaskFromMenu(_ s: Any?) {
        let c = ((s as? NSMenuItem)?.representedObject as? NotchController) ?? controllerUnderMouse
        Store.shared.newTask()
        DispatchQueue.main.async { c?.expand() }
    }
    @objc func resetCapsuleFromMenu(_ s: Any?) {
        ((s as? NSMenuItem)?.representedObject as? NotchController)?.resetCapsule()
    }

    @objc func openSettings(_ s: Any?) { openSettings(pane: nil) }

    /// 打開合併的設定視窗；pane 有給就切到那一頁
    func openSettings(pane: SettingsPane?) {
        expanded?.collapse(restoreFocus: false)
        if let pane { SettingsNav.shared.pane = pane }
        if settingsWindow == nil {
            settingsWindow = makeWindow("Noted 設定", size: UnifiedSettingsView.defaultSize, resizable: true, view: UnifiedSettingsView())
            settingsWindow?.setFrameAutosaveName("SettingsWindow")
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openTaskWindow(_ s: Any?) {
        expanded?.collapse(restoreFocus: false)
        if taskWindow == nil {
            taskWindow = makeWindow("任務", size: NSSize(width: 900, height: 560), resizable: true, view: TaskWindowView())
            taskWindow?.setFrameAutosaveName("TaskWindow")
        }
        NSApp.activate(ignoringOtherApps: true)
        taskWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func formatLine(_ s: NSMenuItem) {
        let order: [LineFormat] = [.heading, .checklist, .bullet, .numbered, .dash, .body]
        NoteTextView.active?.applyFormat(order[s.tag])
    }
    @objc func newTask(_ s: Any?) {
        if let c = expanded {
            Store.shared.newTask(folder: c.model.showList ? c.model.effectiveFolder : nil)
            c.model.showList = false; c.model.focusToken += 1
        } else {
            Store.shared.newTask()
            if taskWindow?.isKeyWindow != true { controllerUnderMouse?.expand() }
        }
    }
    @objc func deleteTask(_ s: Any?) {
        // 編輯器裡的 ⌘⌫ 是「刪到行首」，不搶
        if let tv = NoteTextView.active, tv.window?.isKeyWindow == true, tv.window?.firstResponder === tv {
            tv.deleteToBeginningOfLine(nil); return
        }
        if let c = expanded { c.askDelete() }
        else if taskWindow?.isKeyWindow == true, let id = Store.shared.currentTaskID { Store.shared.delete(id) }
    }
    @objc func toggleList(_ s: Any?) {
        guard let c = expanded else { return }
        withAnimation(.easeOut(duration: 0.15)) { c.model.showList.toggle(); c.model.showDeleted = false }
        if !c.model.showList { c.model.focusToken += 1 }
    }
    @objc func togglePin(_ s: Any?) { expanded?.togglePin(); expanded.map { $0.flashHUD($0.model.pinned ? "已釘選" : "已取消釘選") } }
    @objc func selectTask(_ s: NSMenuItem) { expanded?.selectTask(number: s.tag) }
    @objc func bigger(_ s: Any?) { changeSize(1) }
    @objc func smaller(_ s: Any?) { changeSize(-1) }
    private func changeSize(_ d: Int) {
        let p = Prefs.shared
        p.textSizeIndex = min(max(p.textSizeIndex + d, 0), textSizes.count - 1)
        expanded?.flashHUD("文字大小 · \(textSizes[p.textSizeIndex].name)")
    }
    @objc func closeWindow(_ s: Any?) {
        if let c = expanded { c.collapse() } else { NSApp.keyWindow?.performClose(nil) }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 選單列選單打開前：照現在的暫停狀態更新那幾項
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard pauseItems.count == 4 else { return }
        let g = GamePause.shared
        pauseItems[0].title = g.statusText
        pauseItems[0].isHidden = !g.isPaused
        pauseItems[1].isHidden = g.isManuallyPaused
        pauseItems[2].isHidden = g.isManuallyPaused
        pauseItems[3].isHidden = !g.isManuallyPaused
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.run()
