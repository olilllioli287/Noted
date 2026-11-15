import AppKit

/// Hands the keyboard back to the app you were in once ShotLine is done with
/// it.
///
/// ShotLine comes to the front for Markup, Quick Look, Trim, the shortcut
/// window, the guide and its alerts. When the last of those closes, macOS is
/// left to pick the next app on its own, and an input method can miss that
/// the app you were typing in is back: vChewing then keeps a stale session
/// and Shift no longer switches between Chinese and English there
/// (vChewing issue #618). Bringing that app back explicitly gives the input
/// method a clean activation.
@MainActor
final class FocusReturn {
    enum ActivationPlan: Equatable {
        case leaveAlone
        case bringForward
        case ignore
    }

    nonisolated static func activationPlan(targetPID: pid_t, frontPID: pid_t?, myPID: pid_t) -> ActivationPlan {
        guard targetPID != myPID else { return .ignore }
        return frontPID == targetPID ? .leaveAlone : .bringForward
    }

    static let shared = FocusReturn()

    /// The last app other than ShotLine that was in front.
    /// Held strongly: the object from the notification is not kept anywhere
    /// else, so a weak reference would be gone at once.
    private var previous: NSRunningApplication?
    private var check: DispatchWorkItem?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != .current { FocusReturn.shared.previous = app }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previous = front }
        // A window of ours closing or giving up the keyboard may leave
        // ShotLine in front with nothing to type into.
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FocusReturn.shared.scheduleCheck() }
            }
        }
    }

    /// Markup fades its blur after the editor goes, so this looks again a few
    /// times before deciding.
    func scheduleCheck(attempt: Int = 0) {
        check?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.giveBackIfIdle(attempt: attempt) }
        }
        check = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Noted: 瀏海面板展開打字中、或 Noted 自己的視窗開著時，不把鍵盤交回去。
    var hostBusy: () -> Bool = { false }

    private func giveBackIfIdle(attempt: Int) {
        guard NSApp.isActive, !hostBusy() else { return }
        if hasWindowInUse {
            // Something of ours is still open (or still fading out).
            if attempt < 8 { scheduleCheck(attempt: attempt + 1) }
            return
        }
        guard let app = previous, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
        log.notice("Gave the keyboard back to \(app.bundleIdentifier ?? "?", privacy: .public)")
    }

    /// A photo dropped on another app's window brings that window to the
    /// front, so typing goes on in the text field it last had. A drop does
    /// not activate anything by itself: the app you were in stayed in front,
    /// or none did, and vChewing lost track of where Shift should go.
    func bringForward(windowAt point: NSPoint) {
        guard let target = Self.window(at: point) else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let plan = Self.activationPlan(targetPID: target.pid, frontPID: frontPID, myPID: myPID)
        guard plan != .ignore else { return }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return }
        // The app you dropped on is already in front: nothing of ours should
        // step in, or its text field loses the keyboard. Only point the
        // keyboard at the field under the drop, when Accessibility allows.
        if plan == .leaveAlone {
            if AXIsProcessTrusted() { Self.focusTextElement(at: point, pid: target.pid) }
            log.notice("already in front")
            return
        }
        if AXIsProcessTrusted() {
            // With Accessibility the exact window comes up, even in an app
            // with several.
            let element = AXUIElementCreateApplication(target.pid)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement],
               let window = windows.first(where: { Self.frame(of: $0) == target.frame }) {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        // Activation is ours to hand over only while we are active, so
        // ShotLine steps in front for a moment and yields at once.
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        app.activate()
        log.notice("Brought \(app.bundleIdentifier ?? "?", privacy: .public) forward after a drop")
        // The field can only take the keyboard once its app is in front.
        if AXIsProcessTrusted() {
            let pid = target.pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { Self.focusTextElement(at: point, pid: pid) }
            }
        }
    }

    /// Focus a text control under the drop point without synthesizing input.
    /// Only a control of the app that took the drop, only one that is enabled
    /// and accepts focus: a read-only log next to the input box stays alone.
    private static func focusTextElement(at point: NSPoint, pid: pid_t) {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return }
        let x = Float(point.x), y = Float(primaryMaxY - point.y)
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, x, y, &found) == .success, var element = found else { return }
        let roles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"]
        for level in 0...6 {
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return }
            AXUIElementSetMessagingTimeout(element, 0.3)
            var roleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success else { return }
            if let role = roleValue as? String, roles.contains(role) {
                var settable = DarwinBoolean(false)
                var enabledValue: CFTypeRef?
                let enabled = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) != .success
                    || (enabledValue as? Bool ?? true)
                guard enabled,
                      AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return }
                var focusedValue: CFTypeRef?
                let alreadyFocused = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedValue) == .success
                    && (focusedValue as? Bool ?? false)
                if !alreadyFocused { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
                return
            }
            if level == 6 { return }
            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue, CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return }
            element = unsafeDowncast(parentValue as AnyObject, to: AXUIElement.self)
        }
    }

    /// The frontmost ordinary window of another app under a point in
    /// AppKit screen coordinates, with its frame in top-left coordinates.
    private static func window(at point: NSPoint) -> (pid: pid_t, frame: CGRect)? {
        guard let main = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let p = CGPoint(x: point.x, y: main.frame.maxY - point.y)
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(p) else { continue }
            return (pid, frame)
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// A visible window that can take the keyboard, other than the line and
    /// the capture animation, which never activate the app.
    private var hasWindowInUse: Bool {
        if QuickLook.shared.isVisible || Markup.shared.isOnScreen { return true }
        if NSApp.modalWindow != nil { return true }
        return NSApp.windows.contains { w in
            w.isVisible && w.alphaValue > 0.05 && w.canBecomeKey && !w.styleMask.contains(.nonactivatingPanel)
        }
    }
}
