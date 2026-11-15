import AppKit
import SwiftUI

/// shot＝新截圖提示：瀏海長出一小塊，掛著最新的幾張截圖
enum NotchState { case collapsed, hover, drop, reminder, shot, expanded }

struct ReminderInfo: Equatable { let taskID: UUID; let title: String; let count: Int }

final class PanelModel: ObservableObject {
    @Published var state: NotchState = .collapsed
    @Published var showList = false
    @Published var showDeleted = false
    @Published var listFolder: UUID?   // 列表正在看的檔案夾；nil＝最上層（預設檔案夾）
    var forward: [NavState] = []       // 側鍵「前進」用：退回時把離開的畫面記在這
    var effectiveFolder: UUID { listFolder ?? Store.shared.defaultFolder.id }
    @Published var pinned = false
    @Published var hud: String?
    @Published var confirmDelete = false
    @Published var reminder: ReminderInfo?
    @Published var dropTitle = ""
    @Published var dropDone = false
    @Published var windowFrame: CGRect = .zero
    @Published var shapeRect: CGRect = .zero
    @Published var expandedSize: CGSize = .zero
    @Published var focusToken = 0
    /// 面板太窄、三欄擠不下時一次看一欄：0 音量、1 筆記、2 截圖
    @Published var suiteTab = 1
    /// 新截圖提示要畫幾張
    @Published var shotCount = 1
    let hasNotch: Bool
    let notchSize: CGSize
    weak var controller: NotchController?
    init(hasNotch: Bool, notchSize: CGSize) { self.hasNotch = hasNotch; self.notchSize = notchSize }
}

/// 面板目前看的畫面：編輯某個任務，或列表的某一層
struct NavState: Equatable {
    var list: Bool
    var deleted: Bool
    var folder: UUID?
    var task: UUID?
}

final class NotchPanel: NSPanel {
    var allowKey = false
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func keyDown(with e: NSEvent) {
        if keyHandler?(e) == true { return }
        super.keyDown(with: e)
    }
}

/// 收起時蓋在瀏海／膠囊上：處理游標停留、點一下、拖曳膠囊、拖放文字
final class InteractionView: NSView {
    weak var controller: NotchController?
    private var downAt: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // 進出只是通知；真正要不要展開，看游標是不是在形狀裡面
    override func mouseEntered(with e: NSEvent) { if !dragging { controller?.pointerChanged() } }
    override func mouseExited(with e: NSEvent) { if !dragging { controller?.pointerChanged() } }
    override func mouseMoved(with e: NSEvent) { if !dragging { controller?.pointerChanged() } }
    override func mouseDown(with e: NSEvent) {
        guard controller?.model.shapeRect.contains(NSEvent.mouseLocation) == true else { downAt = nil; return }
        downAt = NSEvent.mouseLocation; dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let start = downAt, let c = controller, !c.model.hasNotch else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 3 { dragging = true; c.beginDrag() }
        if dragging { c.drag(by: CGSize(width: p.x - start.x, height: p.y - start.y)) }
    }
    override func mouseUp(with e: NSEvent) {
        guard downAt != nil else { return }
        if dragging { controller?.endDrag() } else { controller?.click() }
        dragging = false; downAt = nil
    }
    override func rightMouseDown(with e: NSEvent) { controller?.showContextMenu(e, in: self) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { controller?.dropEntered() ?? [] }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { Prefs.shared.textDrop ? .copy : [] }
    override func draggingExited(_ s: NSDraggingInfo?) { controller?.dropExited() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let text = s.draggingPasteboard.string(forType: .string) else { return false }
        return controller?.performDrop(text) ?? false
    }
}

final class NotchController {
    let screen: NSScreen
    let screenKey: String
    let model: PanelModel
    let window: NotchPanel
    private let interaction = InteractionView()
    private var notchRect: CGRect = .zero      // 實體瀏海或膠囊在螢幕上的位置
    private var token = 0
    private var dragStart: CGRect = .zero
    private var leaveWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var prevApp: NSRunningApplication?
    private var mouseWasInside = false   // 展開後滑鼠進過面板，才開始算「移開就收起」
    private var hudWork: DispatchWorkItem?
    private var reminderWork: DispatchWorkItem?
    private var shotWork: DispatchWorkItem?
    /// 游標正停在新截圖提示上（這時計時取消，移開才重新算）
    private var shotHovering = false
    /// 測試用：視窗整個搬到畫面外（配合 debug 的 snap 截圖），不擋到正在用的螢幕
    static var debugOffscreen = false
    static var menuTracking = false
    static var debugHold = false   // 測試用：不因游標位置自動收回

    var isExpanded: Bool { model.state == .expanded }
    private var scale: CGFloat { CGFloat(Prefs.shared.notchScale) }

    init(screen: NSScreen) {
        self.screen = screen
        screenKey = NotchController.key(for: screen)
        let f = screen.frame
        var hasNotch = false
        var size = CGSize(width: 120, height: 22)
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            hasNotch = true
            size = CGSize(width: f.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        model = PanelModel(hasNotch: hasNotch, notchSize: size)
        window = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        model.controller = self
        let host = NSHostingView(rootView: NotchRootView(m: model))
        host.sizingOptions = []
        let root = NSView()
        host.autoresizingMask = [.width, .height]
        interaction.autoresizingMask = [.width, .height]
        interaction.controller = self
        root.addSubview(host)
        root.addSubview(interaction)
        window.contentView = root
        window.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }

        placeNotch()
        model.shapeRect = shapeRect(for: .collapsed)
        setWindowFrame(fullFrame())
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.mouseMoved() } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.mouseMoved(); return e } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedElsewhere() } as Any)
        // 滑鼠側鍵：3＝後退、4＝前進
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] e in
            guard let self, self.model.state == .expanded, e.window === self.window else { return e }
            switch e.buttonNumber {
            case 3: self.goBack(collapseAtTop: false); return nil
            case 4: self.goForward(); return nil
            default: return e
            }
        } as Any)
    }

    func teardown() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        window.orderOut(nil)
    }

    static func key(for screen: NSScreen) -> String {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, u) as String
        }
        return screen.localizedName
    }

    // MARK: 位置

    private func placeNotch() {
        let f = screen.frame
        if model.hasNotch {
            notchRect = CGRect(x: f.midX - model.notchSize.width / 2, y: f.maxY - model.notchSize.height,
                               width: model.notchSize.width, height: model.notchSize.height)
        } else {
            let s = CGSize(width: 120 * scale, height: 22 * scale)
            let pos = Prefs.shared.capsulePosition(for: screenKey) ?? CGPoint(x: 0.5, y: 0)
            let r = CGRect(x: f.minX + pos.x * f.width - s.width / 2, y: f.maxY - pos.y * f.height - s.height, width: s.width, height: s.height)
            notchRect = clampToScreen(r)
        }
    }

    private func clampToScreen(_ r: CGRect) -> CGRect {
        let f = screen.frame
        var r = r
        r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
        r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
        return r
    }

    private func size(for s: NotchState, shotCount: Int? = nil) -> CGSize {
        let n = notchRect.size
        switch s {
        case .collapsed: return n
        case .hover: return CGSize(width: n.width + 70 * scale, height: n.height + 28 * scale)
        case .drop: return CGSize(width: max(n.width + 150 * scale, 300 * scale), height: n.height + 44 * scale)
        case .reminder: return CGSize(width: max(n.width + 170 * scale, 340 * scale), height: n.height + 54 * scale)
        case .shot:
            let peek = SuiteHost.peekSize(count: shotCount ?? model.shotCount)
            return CGSize(width: max(n.width + 40, peek.width), height: (model.hasNotch ? n.height : 6) + peek.height)
        case .expanded:
            let suite = SuitePrefs.shared
            if suite.threeColumns {
                // 三欄面板：大小照螢幕的比例（預設寬 82%、高 39%）
                let f = screen.frame
                let w = max(f.width * CGFloat(suite.widthRatio), n.width + 300)
                let h = max(f.height * CGFloat(suite.heightRatio), 240)
                return CGSize(width: min(w, f.width - 20), height: min(h, f.height - 60))
            }
            let w = max(CGFloat(Prefs.shared.panelWidth) * scale, n.width + 300)
            return CGSize(width: min(w, screen.frame.width - 20), height: min(CGFloat(Prefs.shared.panelHeight) * scale, screen.frame.height - 60))
        }
    }

    /// 膠囊太靠下面時面板改往上開
    var opensUpward: Bool {
        !model.hasNotch && notchRect.maxY - size(for: .expanded).height < screen.frame.minY + 8
    }

    private func shapeRect(for s: NotchState, shotCount: Int? = nil) -> CGRect {
        let sz = size(for: s, shotCount: shotCount)
        let f = screen.frame
        let x = min(max(notchRect.midX - sz.width / 2, f.minX + (s == .collapsed ? 0 : 6)), f.maxX - sz.width - (s == .collapsed ? 0 : 6))
        let y = opensUpward ? notchRect.minY : notchRect.maxY - sz.height
        return CGRect(x: x, y: y, width: sz.width, height: sz.height)
    }

    private func setWindowFrame(_ r: CGRect) {
        let f = r.intersection(screen.frame)
        window.setFrame(NotchController.debugOffscreen ? f.offsetBy(dx: 0, dy: -20000) : f, display: true)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { model.windowFrame = f }
    }

    /// 視窗固定蓋住所有狀態會用到的範圍，動畫時不再改視窗大小（改大小會卡一下）。
    /// 形狀以外的地方用 ignoresMouseEvents 讓滑鼠穿過去。
    private func fullFrame() -> CGRect {
        let all: [NotchState] = [.collapsed, .hover, .drop, .reminder, .shot, .expanded]
        // 新截圖提示最多三張，視窗先留夠三張的位置
        return all.map { shapeRect(for: $0, shotCount: 3) }.reduce(notchRect) { $0.union($1) }.insetBy(dx: -24, dy: -24)
    }

    /// 新截圖提示時視窗縮到只有提示那一塊。
    /// 拖曳截圖期間這個視窗沒機會切回「不接滑鼠」，視窗有多大，「放開會被當成放在自己 App 裡、送不出去」的範圍就有多大。
    private func windowFrame(for s: NotchState) -> CGRect {
        s == .shot ? shapeRect(for: .shot).insetBy(dx: -24, dy: -24) : fullFrame()
    }

    private func transition(to s: NotchState) {
        // 離開提示：先把視窗放回完整範圍，動畫才有地方畫
        if model.state == .shot, s != .shot { setWindowFrame(fullFrame()) }
        if s == .shot { setWindowFrame(windowFrame(for: .shot)) }
        if s != .shot { shotHovering = false }
        let target = shapeRect(for: s)
        model.expandedSize = shapeRect(for: .expanded).size
        // 展開帶一點彈性；收起不彈，直接縮回瀏海的形狀
        let anim: Animation = s == .expanded ? .spring(response: 0.38, dampingFraction: 0.82)
            : (model.state == .expanded ? .spring(response: 0.34, dampingFraction: 1.0) : .spring(response: 0.3, dampingFraction: 0.92))
        withAnimation(anim) {
            model.state = s
            model.shapeRect = target
        }
        // 新截圖提示上的照片要自己接滑鼠（拖曳、單擊、雙擊），所以這時也把互動層拿掉
        interaction.isHidden = (s == .expanded || s == .shot)
        token += 1
        pointerChanged()
    }

    /// 改了面板大小或縮放時，直接套到現在的形狀
    func refreshGeometry() {
        if !model.hasNotch, model.state != .expanded { placeNotch() }
        let target = shapeRect(for: model.state)
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { model.shapeRect = target; model.expandedSize = shapeRect(for: .expanded).size }
        setWindowFrame(windowFrame(for: model.state))
    }

    // MARK: 游標停留與點擊

    func hoverBegan() {
        guard model.state == .collapsed, !GamePause.shared.isPaused else { return }
        if Prefs.shared.hoverHaptic { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        transition(to: .hover)
    }
    func hoverEnded() {
        if model.state == .hover { transition(to: .collapsed) }
    }

    func click() {
        guard !GamePause.shared.isPaused else { return }
        if model.state == .reminder, let r = model.reminder {
            expand(task: r.taskID)
        } else {
            expand()
        }
    }

    func beginDrag() {
        dragStart = notchRect
        if model.state != .collapsed {
            model.state = .collapsed
            token += 1
        }
    }
    func drag(by d: CGSize) {
        notchRect = clampToScreen(dragStart.offsetBy(dx: d.width, dy: d.height))
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { model.shapeRect = notchRect }
        setWindowFrame(fullFrame())
    }
    func endDrag() {
        let f = screen.frame
        Prefs.shared.setCapsulePosition(CGPoint(x: (notchRect.midX - f.minX) / f.width, y: (f.maxY - notchRect.maxY) / f.height), for: screenKey)
    }
    func resetCapsule() {
        guard !model.hasNotch else { return }
        Prefs.shared.setCapsulePosition(CGPoint(x: 0.5, y: 0), for: screenKey)
        placeNotch()
        refreshGeometry()
    }

    func showContextMenu(_ e: NSEvent, in view: NSView) {
        let m = NSMenu()
        m.addItem(withTitle: "打開筆記", action: #selector(AppDelegate.openPanelFromMenu(_:)), keyEquivalent: "").representedObject = self
        m.addItem(withTitle: "新增任務", action: #selector(AppDelegate.newTaskFromMenu(_:)), keyEquivalent: "").representedObject = self
        if !model.hasNotch {
            m.addItem(withTitle: "膠囊放回上方中央", action: #selector(AppDelegate.resetCapsuleFromMenu(_:)), keyEquivalent: "").representedObject = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: "任務視窗⋯", action: #selector(AppDelegate.openTaskWindow(_:)), keyEquivalent: "")
        m.addItem(withTitle: "設定⋯", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(m, with: e, for: view)
    }

    // MARK: 展開／收起

    func expand(task: UUID? = nil, activate: Bool = true) {
        if let task { Store.shared.currentTaskID = task }
        AppDelegate.shared.controllers.filter { $0 !== self }.forEach { $0.collapse(restoreFocus: false) }
        reminderWork?.cancel()
        shotWork?.cancel(); shotWork = nil
        model.reminder = nil
        model.confirmDelete = false
        if model.state != .expanded {
            model.suiteTab = 1   // 窄螢幕一次一欄時，打開先看筆記
            mouseWasInside = model.shapeRect.contains(NSEvent.mouseLocation)
            if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current { prevApp = front }
            transition(to: .expanded)
        }
        guard activate else { return }   // 測試用：只展開畫面，不搶鍵盤
        window.allowKey = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.focusToken += 1
        ReminderController.shared.reset()
    }

    func collapse(restoreFocus: Bool = true) {
        leaveWork?.cancel()
        guard model.state != .collapsed else { return }
        let wasExpanded = model.state == .expanded
        Store.shared.saveNow()
        model.confirmDelete = false
        transition(to: .collapsed)
        guard wasExpanded else { return }
        SuiteHost.panelDidCollapse()
        window.makeFirstResponder(nil)
        window.allowKey = false
        window.resignKey()
        ReminderController.shared.reset()
        if restoreFocus, NSApp.isActive, !AppDelegate.shared.hasOpenWindows {
            if let p = prevApp, !p.isTerminated { p.activate() } else { NSApp.hide(nil); window.orderFrontRegardless() }
        }
        prevApp = nil
    }

    func togglePin() { model.pinned.toggle() }

    /// 收起時：游標真的進到瀏海／膠囊裡才展開提示；提示時：離開提示形狀就收回。
    /// 形狀外的透明邊不接滑鼠，點擊直接穿過去給下面的 App。
    func pointerChanged() {
        let p = NSEvent.mouseLocation
        // 玩遊戲暫停中：面板沒展開就整個不接滑鼠，游標甩到頂端也不會有反應
        if GamePause.shared.isPaused, model.state != .expanded {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
            return
        }
        let inside = model.shapeRect.contains(p)
        // 展開時按著滑鼠（例如拖右下角調大小）不切換，免得拖到一半斷掉
        if !(model.state == .expanded && NSEvent.pressedMouseButtons != 0), window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }
        if NotchController.debugHold { return }
        switch model.state {
        case .collapsed:
            if notchRect.contains(p), NSEvent.pressedMouseButtons == 0 { hoverBegan() }
        case .hover:
            if !model.shapeRect.insetBy(dx: -2, dy: -2).contains(p) { hoverEnded() }
        case .shot:
            // 游標在提示上：計時取消；移開：從頭算滿整段
            let over = model.shapeRect.insetBy(dx: -6, dy: -6).contains(p)
            if over, !shotHovering {
                shotHovering = true
                shotWork?.cancel(); shotWork = nil
            } else if !over, shotHovering, !SuiteHost.shotBusy {
                shotHovering = false
                scheduleShotDismiss(after: SuitePrefs.shared.shotPeekSeconds)
            }
        default: break
        }
    }

    private func mouseMoved() {
        pointerChanged()
        guard model.state == .expanded, !model.pinned, Prefs.shared.collapseOnLeave else { return }
        // 按著滑鼠（拖右下角調大小、拉滑桿拉出面板外）時不算離開
        guard NSEvent.pressedMouseButtons == 0 else { leaveWork?.cancel(); leaveWork = nil; return }
        let p = NSEvent.mouseLocation
        // 拖著截圖、或游標在音量的完整面板上，都算還在面板裡
        if model.shapeRect.insetBy(dx: -28, dy: -28).contains(p) || SuiteHost.keepsPanelOpen(at: p) {
            mouseWasInside = true
            leaveWork?.cancel(); leaveWork = nil
            return
        }
        guard mouseWasInside, leaveWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.leaveWork = nil
            if NotchController.menuTracking || NoteTextView.active?.hasMarkedText() == true || self.model.confirmDelete { return }
            let now = NSEvent.mouseLocation
            if !self.model.shapeRect.insetBy(dx: -28, dy: -28).contains(now), !SuiteHost.keepsPanelOpen(at: now) { self.collapse() }
        }
        leaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func clickedElsewhere() {
        guard model.state == .expanded, !model.pinned, !NotchController.menuTracking else { return }
        let p = NSEvent.mouseLocation
        if !model.shapeRect.contains(p), !SuiteHost.keepsPanelOpen(at: p) { collapse() }
    }

    // MARK: 新截圖提示

    /// 截圖剛掛上：瀏海長出一小塊，掛著最新的幾張，停幾秒；游標在上面或正在拖就不收。
    func showShot(count: Int) {
        guard !GamePause.shared.isPaused else { return }
        guard model.state == .collapsed || model.state == .hover || model.state == .shot else { return }
        model.shotCount = min(max(count, 1), 3)
        transition(to: .shot)
        // 停留時間跟「收進截圖資料夾」（Line.keepDelay）是兩個計時器，這裡只管提示
        if !shotHovering { scheduleShotDismiss(after: SuitePrefs.shared.shotPeekSeconds) }
    }

    /// 暫停狀態變了：開始暫停就把冒出來的提示收掉，並重設要不要接滑鼠
    func pauseChanged() {
        if GamePause.shared.isPaused, model.state != .expanded, model.state != .collapsed {
            if model.state == .shot, SuiteHost.shotBusy {
                // 正在拖提示上的截圖：先不收（收掉會把拖曳來源的畫面拿走），放開後一秒內收
                shotHovering = false
                scheduleShotDismiss(after: 1)
            } else {
                shotWork?.cancel(); shotWork = nil
                reminderWork?.cancel()
                model.reminder = nil
                transition(to: .collapsed)
            }
        }
        pointerChanged()
    }

    private func scheduleShotDismiss(after seconds: TimeInterval) {
        shotWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .shot else { return }
            self.shotWork = nil
            if NotchController.debugHold || SuiteHost.shotBusy
                || self.model.shapeRect.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
                self.scheduleShotDismiss(after: 1)
            } else {
                self.transition(to: .collapsed)
            }
        }
        shotWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// 提示上的截圖被拖走或丟掉了：沒東西可掛就收起來，還有就照新的張數重排。
    func refreshShot(count: Int) {
        guard model.state == .shot else { return }
        if count == 0 { shotWork?.cancel(); shotWork = nil; transition(to: .collapsed) }
        else if min(count, 3) != model.shotCount {
            model.shotCount = min(count, 3)
            transition(to: .shot)
            // transition 裡的 pointerChanged 已經照游標位置決定要不要計時；
            // 這裡只補「游標不在上面、卻沒有計時器」的情況，免得剩下的永遠掛著
            if !shotHovering, shotWork == nil { scheduleShotDismiss(after: SuitePrefs.shared.shotPeekSeconds) }
        }
    }

    // MARK: 拖放文字

    func dropEntered() -> NSDragOperation {
        guard Prefs.shared.textDrop, model.state != .expanded, !GamePause.shared.isPaused else { return [] }
        model.dropTitle = Store.shared.current?.title ?? "新任務"
        model.dropDone = false
        transition(to: .drop)
        return .copy
    }
    func dropExited() {
        if model.state == .drop, !model.dropDone { transition(to: .collapsed) }
    }
    func performDrop(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let task = Store.shared.addCard(t)
        if Prefs.shared.textDropSound { Sounds.play("Pop") }
        withAnimation(.easeOut(duration: 0.2)) { model.dropTitle = task.title; model.dropDone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.model.state == .drop else { return }
            self.transition(to: .collapsed)
        }
        return true
    }

    // MARK: 提醒

    func showReminder(_ info: ReminderInfo) {
        guard model.state == .collapsed || model.state == .hover, !GamePause.shared.isPaused else { return }
        model.reminder = info
        transition(to: .reminder)
        if Prefs.shared.reminderSound { Sounds.play("Glass") }
        reminderWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .reminder else { return }
            if self.window.frame.contains(NSEvent.mouseLocation) { self.showReminderLater() ; return }
            self.transition(to: .collapsed)
            self.model.reminder = nil
        }
        reminderWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }
    private func showReminderLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.model.state == .reminder else { return }
            if !self.window.frame.contains(NSEvent.mouseLocation) { self.transition(to: .collapsed); self.model.reminder = nil }
            else { self.showReminderLater() }
        }
    }

    // MARK: 按鍵與 HUD

    private func handleKey(_ e: NSEvent) -> Bool {
        if model.confirmDelete {
            switch e.keyCode {
            case 36, 76: confirmDelete(); return true
            case 53: model.confirmDelete = false; model.focusToken += 1; return true
            default: return true
            }
        }
        if e.keyCode == 53 { goBack(collapseAtTop: true); return true }
        return false
    }

    // MARK: 上一層／前進（Esc 與滑鼠側鍵）

    private var nav: NavState {
        NavState(list: model.showList, deleted: model.showDeleted, folder: model.listFolder, task: Store.shared.currentTaskID)
    }
    private func apply(_ s: NavState) {
        withAnimation(.easeOut(duration: 0.15)) {
            model.showList = s.list
            model.showDeleted = s.deleted
            model.listFolder = s.folder
        }
        if let t = s.task, Store.shared.task(t) != nil { Store.shared.currentTaskID = t }
        if !s.list { model.focusToken += 1 } else { window.makeFirstResponder(nil) }
    }

    /// 編輯中 → 任務所在檔案夾的列表 → 上一層檔案夾 → … → 最上層；最上層再按 Esc 才收起
    func goBack(collapseAtTop: Bool) {
        if model.confirmDelete { model.confirmDelete = false; model.focusToken += 1; return }
        let cur = nav
        var next = cur
        if !cur.list {
            let f = Store.shared.current?.folderID
            next.list = true; next.deleted = false
            next.folder = f == Store.shared.defaultFolder.id ? nil : f
        } else if cur.deleted {
            next.deleted = false
        } else if let f = cur.folder {
            let p = Store.shared.folder(f)?.parentID
            next.folder = p
        } else {
            if collapseAtTop { collapse() }
            return
        }
        model.forward.append(cur)
        apply(next)
    }

    func goForward() {
        guard let s = model.forward.popLast() else { return }
        apply(s)
    }

    /// 使用者自己點了別的地方，前進紀錄就作廢
    func clearForward() { model.forward.removeAll() }

    func askDelete() {
        guard Store.shared.current != nil else { return }
        window.makeFirstResponder(nil)
        withAnimation(.easeOut(duration: 0.15)) { model.confirmDelete = true }
    }
    func confirmDelete() {
        if let id = Store.shared.currentTaskID { Store.shared.delete(id) }
        withAnimation(.easeOut(duration: 0.15)) { model.confirmDelete = false }
        model.focusToken += 1
    }

    func flashHUD(_ text: String) {
        withAnimation(.easeOut(duration: 0.12)) { model.hud = text }
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.25)) { self?.model.hud = nil } }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    func selectTask(number n: Int) {
        let list = Store.shared.orderedTasks(in: model.effectiveFolder)
        guard n >= 1, n <= list.count else { return }
        Store.shared.currentTaskID = list[n - 1].id
        model.showList = false
        model.focusToken += 1
        flashHUD("任務 \(n)")
    }

    func launchTease() {
        transition(to: .hover)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.model.state == .hover, !self.window.frame.contains(NSEvent.mouseLocation) else { return }
            self.transition(to: .collapsed)
        }
    }
}

enum Sounds {
    private static var cache: [String: NSSound] = [:]
    static func play(_ name: String) {
        let s = cache[name] ?? NSSound(named: NSSound.Name(name))
        cache[name] = s
        s?.stop()
        s?.play()
    }
}
