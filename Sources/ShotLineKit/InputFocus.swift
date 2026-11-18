import AppKit
import ApplicationServices
import os

/// 某個 App 裡「要把游標放回去的輸入框」。
/// 只讀輔助使用（AX）屬性、只設 AXFocused，不模擬滑鼠、不打字。需要輔助使用權限。
public final class RememberedInput: @unchecked Sendable {
    public let pid: pid_t
    let element: AXUIElement
    public let role: String
    /// true：使用者明確放在這個輸入框上（拖放時放開點底下的文字欄位），焦點在別的文字欄位也要還給它。
    /// false：只是那個 App 原本最後在用的輸入框，焦點已經在別的文字欄位就不動。
    public let force: Bool
    /// 輸入框所在的視窗：記住之後焦點若在同一個 App 的別的視窗，就不動
    let window: AXUIElement?

    init(pid: pid_t, element: AXUIElement, role: String, force: Bool) {
        self.pid = pid; self.element = element; self.role = role; self.force = force
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            window = unsafeDowncast(value as AnyObject, to: AXUIElement.self)
        } else { window = nil }
    }
}

/// 把輸入框的焦點在「被點擊或拖放弄丟之後」還回去：記住 App 最後在用的輸入框，過一小段時間再看，
/// 焦點跑掉了（不在任何輸入框）而且前景還是同一個 App，就把焦點設回去。
public enum InputFocus {
    nonisolated static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let queue = DispatchQueue(label: "local.noted.input-focus", qos: .userInitiated)
    /// 新的一輪（新的拖放、新的展開）開始或取消時加一，舊的排程檢查看到編號變了就不做
    private nonisolated(unsafe) static var generation = 0
    private static let lock = NSLock()
    private static func bumpGeneration() -> Int { lock.lock(); defer { lock.unlock() }; generation += 1; return generation }
    private static var currentGeneration: Int { lock.lock(); defer { lock.unlock() }; return generation }
    /// 取消還在排隊的檢查（例如又展開了面板）
    public static func cancelPending() { _ = bumpGeneration() }

    private static let log = Logger(subsystem: "com.local.noted", category: "InputFocus")

    /// 目前有沒有輔助使用權限（只查詢，不會跳出詢問）
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public enum Action: Equatable {
        case skip(String)
        case set(String)
        public var isSet: Bool { if case .set(_) = self { return true } else { return false } }
    }

    /// 這一刻要不要把焦點設回去。純判斷，不碰系統，方便測試。
    /// 前提：前景仍是同一個 App、Noted 不是前景。之後：
    /// - 焦點不是記住的元素：不是文字角色就設；是別的文字角色時，只有強制記住（放開點底下的輸入框）才設。
    /// - 焦點就是記住的元素：放開後第一次檢查再單向設一次（原生 AXTextField 除外，免得文字被全選）；
    ///   之後只有「視窗或元素的 AXFocused 是否」才補設，兩者都是 true（或讀不到）就不動。
    nonisolated static func decide(rememberedPID: pid_t, frontPID: pid_t?, myPID: pid_t,
                                   currentIsText: Bool, currentIsTarget: Bool, force: Bool,
                                   windowFocused: Bool? = nil, elementFocused: Bool? = nil,
                                   isFirstCheck: Bool = false, role: String = "") -> Action {
        guard frontPID == rememberedPID else { return .skip("前景不是原本的 App") }
        guard frontPID != myPID else { return .skip("前景是 Noted") }
        if currentIsTarget {
            if windowFocused == false || elementFocused == false { return .set("視窗或元素的 AXFocused 是否") }
            if isFirstCheck && role != "AXTextField" { return .set("放開後第一次補設") }
            return .skip("焦點已經在")
        }
        if currentIsText && !force { return .skip("焦點在別的輸入框") }
        return .set("焦點不在輸入框")
    }

    // MARK: 記住

    /// 記住那個 App 現在的焦點元素，是輸入框（文字角色或 AXEditable）才記。沒權限或讀不到回傳 nil。
    public static func capture(pid: pid_t) -> RememberedInput? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let role = textRole(of: element) else { return nil }
        return RememberedInput(pid: pid, element: element, role: role, force: false)
    }

    /// 放開點底下（螢幕左上角座標）如果有輸入框就記它：只收放開那個 App 自己的、可用的、可設焦點的，
    /// 從那一點往上最多找 6 層。唯讀的記錄欄位旁邊的 log 不算。
    public static func captureTarget(atTopLeft point: CGPoint, pid: pid_t) -> RememberedInput? {
        guard isTrusted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success, var element = found else { return nil }
        for level in 0...6 {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.3)
            if let role = textRole(of: element) {
                var settable = DarwinBoolean(false)
                let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
                // 繼承了 AXEditable 的內層節點可能不能設焦點：不放棄，繼續往上找真正的輸入框
                if enabled, AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
                   settable.boolValue {
                    return RememberedInput(pid: pid, element: element, role: role, force: true)
                }
            }
            if level == 6 { return nil }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = unsafeDowncast(parent as AnyObject, to: AXUIElement.self)
        }
        return nil
    }

    /// 在背景記住那個 App 目前的輸入框（AX 呼叫可能要等，不卡住主執行緒），記好後回主執行緒交給 completion。
    public static func captureAsync(pid: pid_t, completion: @escaping @MainActor (RememberedInput?) -> Void) {
        queue.async {
            let remembered = capture(pid: pid)
            log.notice("[FOCUS] 展開前 trusted=\(isTrusted, privacy: .public) 記住=\(remembered?.role ?? "沒有", privacy: .public)")
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(remembered) } }
        }
    }

    // MARK: 還原

    /// 拖放成功、而且已經把鍵盤交給對方之後呼叫：記下放開點底下的輸入框（沒有就記那個 App 原本的輸入框），
    /// 之後分幾次檢查、必要時還原。失焦通常在放開後 1.7 秒左右才發生（實測），所以檢查要拖到 2.6 秒。
    /// 使用者之後自己點了別處、或開始下一次拖曳，這一輪就取消，不拉回去。
    @MainActor public static func restoreAfterDrop(atTopLeft point: CGPoint, pid: pid_t) {
        installClickWatcher()
        let gen = armCancelOnClick()
        queue.asyncAfter(deadline: .now() + 3) { disarmCancelOnClick(gen) }
        queue.async {
            let remembered = captureTarget(atTopLeft: point, pid: pid) ?? capture(pid: pid)
            log.notice("[FOCUS] 拖放 trusted=\(isTrusted, privacy: .public) 記住=\(remembered?.role ?? "沒有", privacy: .public)\(remembered?.force == true ? "（放開點底下）" : "", privacy: .public)")
            guard let remembered else { return }
            run(remembered, label: "拖放", delays: [0.1, 0.25, 0.8, 1.4, 2.0, 2.6], observeFirst: true, gen: gen)
        }
    }

    /// 之後分幾次檢查（秒，從現在算起）：目前焦點跑掉了就設回去。每次都留一行 log（不記任何文字內容）。
    public static func schedule(_ remembered: RememberedInput, label: String, delays: [TimeInterval]) {
        run(remembered, label: label, delays: delays, observeFirst: false, gen: bumpGeneration())
    }

    private static func run(_ remembered: RememberedInput, label: String, delays: [TimeInterval], observeFirst: Bool, gen: Int) {
        for (index, delay) in delays.enumerated() {
            let observe = observeFirst && index == 0
            let first = observeFirst && index == 1   // 只有拖放那一輪有「第一次補設」
            queue.asyncAfter(deadline: .now() + delay) {
                guard gen == currentGeneration else { return }   // 已被新的一輪取代、取消，或使用者自己點了別處
                check(remembered, label: label, delay: delay, observeOnly: observe, isFirst: first)
            }
        }
    }

    // 放開之後使用者自己點了別處：取消這一輪（只有拖放這一輪才這樣）
    private nonisolated(unsafe) static var cancelOnClickGen: Int?
    private nonisolated(unsafe) static var clickMonitor: Any?
    /// 開新一輪並登記「使用者點別處就取消」，兩件事在同一把鎖裡做完
    private static func armCancelOnClick() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        cancelOnClickGen = generation
        return generation
    }
    private static func disarmCancelOnClick(_ gen: Int) {
        lock.lock(); defer { lock.unlock() }
        if cancelOnClickGen == gen { cancelOnClickGen = nil }
    }
    @MainActor private static func installClickWatcher() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            lock.lock()
            let cancel = cancelOnClickGen != nil && cancelOnClickGen == generation
            if cancel { generation += 1 }
            cancelOnClickGen = nil
            lock.unlock()
            if cancel { log.notice("[FOCUS] 使用者點了別處，取消這一輪還原") }
        }
    }

    private static func check(_ remembered: RememberedInput, label: String, delay: TimeInterval, observeOnly: Bool, isFirst: Bool) {
        var front: NSRunningApplication?
        var own = ""
        DispatchQueue.main.sync {
            front = NSWorkspace.shared.frontmostApplication
            own = ownWindowState()
        }
        let app = AXUIElementCreateApplication(remembered.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetMessagingTimeout(remembered.element, 0.3)
        var currentRole = "-"
        var currentIsText = false
        var currentIsTarget = false
        if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, 0.3)
            currentRole = (attribute(element, kAXRoleAttribute) as? String) ?? "-"
            currentIsText = textRole(of: element) != nil
            currentIsTarget = CFEqual(element, remembered.element)
        }
        // 焦點視窗跟輸入框所在的視窗不同（同一個 App 的別的視窗）：不動
        var otherWindow = false
        var windowFocused: Bool?
        if let focusedWindow = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            let fw = unsafeDowncast(focusedWindow as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(fw, 0.3)
            windowFocused = attribute(fw, kAXFocusedAttribute) as? Bool
            if let rememberedWindow = remembered.window { otherWindow = !CFEqual(fw, rememberedWindow) }
        }
        let elementFocused = attribute(remembered.element, kAXFocusedAttribute) as? Bool
        var action = decide(rememberedPID: remembered.pid, frontPID: front?.processIdentifier,
                            myPID: ProcessInfo.processInfo.processIdentifier,
                            currentIsText: currentIsText, currentIsTarget: currentIsTarget, force: remembered.force,
                            windowFocused: windowFocused, elementFocused: elementFocused,
                            isFirstCheck: isFirst, role: remembered.role)
        if otherWindow, action.isSet { action = .skip("焦點在同 App 的別的視窗") }
        if observeOnly, action.isSet { action = .skip("只記錄現況") }
        var result = "-"
        if action.isSet {
            // 只對輸入框所在的那一個視窗做 AXRaise（同 App 有兩個視窗時不動別的）
            if windowFocused == false, let window = remembered.window {
                AXUIElementSetMessagingTimeout(window, 0.3)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(remembered.element, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue {
                result = String(AXUIElementSetAttributeValue(remembered.element, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)
            } else {
                result = "元素已不能設焦點"
            }
        }
        func yesNo(_ value: Bool?) -> String { value.map { $0 ? "是" : "否" } ?? "?" }
        let bundle = front?.bundleIdentifier ?? "?"
        let what: String
        switch action {
        case .set(let reason): what = "設回（\(reason)）"
        case .skip(let reason): what = "不動（\(reason)）"
        }
        let theirs = targetWindowState(app)
        log.notice("[FOCUS] \(label, privacy: .public) +\(delay, format: .fixed(precision: 2))s 前景=\(bundle, privacy: .public) 目前焦點=\(currentRole, privacy: .public)\(currentIsTarget ? "（就是記住的）" : "", privacy: .public) 元素AXFocused=\(yesNo(elementFocused), privacy: .public) 視窗AXFocused=\(yesNo(windowFocused), privacy: .public) → \(what, privacy: .public) 結果碼=\(result, privacy: .public) ｜Noted：\(own, privacy: .public) ｜對方：\(theirs, privacy: .public)")
    }

    /// Noted 自己的鍵盤狀態：是不是作用中、哪個視窗握著 key、各可見視窗的 key／main 狀態（只寫類別名，不寫標題或內容）
    @MainActor private static func ownWindowState() -> String {
        let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "無"
        let main = NSApp.mainWindow.map { String(describing: type(of: $0)) } ?? "無"
        let visible = NSApp.windows.filter { $0.isVisible }.map {
            "\(type(of: $0))\($0.isKeyWindow ? "[key]" : "")\($0.canBecomeKey ? "" : "(不能key)")"
        }.joined(separator: ",")
        return "isActive=\(NSApp.isActive) keyWindow=\(key) mainWindow=\(main) 可見=[\(visible)]"
    }

    /// 對方 App 的狀態：是不是前景、焦點視窗是不是 main／focused、輸入框本身的 AXFocused
    private static func targetWindowState(_ app: AXUIElement) -> String {
        func flag(_ element: AXUIElement, _ name: String) -> String {
            guard let value = attribute(element, name) as? Bool else { return "?" }
            return value ? "是" : "否"
        }
        var text = "AXFrontmost=\(flag(app, "AXFrontmost"))"
        if let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            let w = unsafeDowncast(window as AnyObject, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(w, 0.3)
            text += " 視窗AXMain=\(flag(w, kAXMainAttribute)) 視窗AXFocused=\(flag(w, kAXFocusedAttribute))"
        } else { text += " 無焦點視窗" }
        return text
    }

    // MARK: AX 小工具

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// 這個元素是輸入框的話回傳它的角色：文字角色，或 AXEditable 為 true（網頁、Electron 的輸入框有時是別的角色）。
    private static func textRole(of element: AXUIElement) -> String? {
        let role = (attribute(element, kAXRoleAttribute) as? String) ?? ""
        if textRoles.contains(role) { return role }
        if (attribute(element, "AXEditable") as? Bool) == true { return role.isEmpty ? "AXEditable" : role }
        return nil
    }
}
