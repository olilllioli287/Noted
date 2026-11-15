import AppKit

/// 檢查表提醒：最後用的任務還有沒勾的項目，就每隔一段時間從瀏海提醒一次
final class ReminderController {
    static let shared = ReminderController()
    private var lastReset = Date()
    private var timer: Timer?
    private var suspended = false
    private(set) var lastStatus = ""

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                              (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSuspended(value) }
        }
        let dc = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screensaver.didstart", true),
                              ("com.apple.screenIsUnlocked", false), ("com.apple.screensaver.didstop", false)] {
            dc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.setSuspended(value) }
        }
    }

    private func setSuspended(_ v: Bool) {
        suspended = v
        if !v { reset() }  // 回來之後重新計時，不要一回來就跳
    }

    func reset() { lastReset = Date() }

    var nextFireDate: Date { lastReset.addingTimeInterval(TimeInterval(Prefs.shared.reminderMinutes * 60)) }

    /// 給設定畫面看的目前狀態
    var status: String {
        let p = Prefs.shared
        if !p.reminderEnabled { return "提醒已關閉" }
        if suspended { return "等待你從鎖定、螢幕保護程式或睡眠狀態返回" }
        guard let t = Store.shared.current, !t.uncheckedItems.isEmpty else { return "沒有需要提醒的檢查表項目" }
        if AppDelegate.shared.controllers.contains(where: \.isExpanded) { return "你正在使用這個任務，提醒會先等待" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return "「\(t.title)」還剩 \(t.uncheckedItems.count) 項，\(f.string(from: nextFireDate)) 提醒"
    }

    private func tick() {
        let p = Prefs.shared
        // 玩遊戲暫停中不提醒，也不重新計時：恢復後下一輪（15 秒內）補提醒
        guard p.reminderEnabled, !suspended, !GamePause.shared.isPaused else { return }
        let ctrls = AppDelegate.shared.controllers
        if ctrls.contains(where: \.isExpanded) { reset(); return }
        guard Date() >= nextFireDate else { return }
        fire()
    }

    /// 立即提醒（設定裡的「試試提醒」也走這裡）
    @discardableResult
    func fire(demo: Bool = false) -> Bool {
        let store = Store.shared
        var info: ReminderInfo?
        if let t = store.current, !t.uncheckedItems.isEmpty {
            info = ReminderInfo(taskID: t.id, title: t.title, count: t.uncheckedItems.count)
        } else if demo, let t = store.current ?? store.activeTasks.first {
            info = ReminderInfo(taskID: t.id, title: t.title, count: max(t.uncheckedItems.count, 1))
        }
        guard let info else { reset(); return false }
        // 顯示在游標所在的螢幕，沒有就用第一個
        let mouse = NSEvent.mouseLocation
        let ctrls = AppDelegate.shared.controllers
        let target = ctrls.first { $0.screen.frame.contains(mouse) } ?? ctrls.first
        target?.showReminder(info)
        reset()
        return target != nil
    }
}
