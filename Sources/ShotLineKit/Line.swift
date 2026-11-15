import AppKit
import AVFoundation
import Combine
import os

let log = Logger(subsystem: "com.local.noted", category: "shotline")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    /// Noted: 收進截圖資料夾後這張還留在右欄，所以路徑會變。
    var url: URL
    /// Noted: Noted 自己收好的截圖（已經搬到截圖資料夾）。雙擊、叉叉一樣是丟垃圾桶。
    var managed = false
    var thumb: NSImage
    /// When the file was last saved, to notice an edit made in another app.
    var modified: Date? = nil
    /// 這張截圖掛上右欄的時間，用於重開後接續自動收好的倒數。
    var hungAt = Date()
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// Taken off the line while it is open in Markup or the trimming
    /// window. It hangs again when the editor closes.
    var away = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { ShotLineKit.isRecording(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.away == b.away && a.thumb === b.thumb
            && a.url == b.url && a.managed == b.managed
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID? {
        didSet { if draggingID == nil, oldValue != nil { trimIfOver() } }
    }
    @Published var pressedID: UUID? {
        didSet { if pressedID == nil, oldValue != nil { trimIfOver() } }
    }
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8
    /// How many photos fit across the screen. With Keep on line set, the
    /// line can hold more, and the rest are reached by scrolling.
    var visibleCount = 8
    /// How far the line is scrolled towards older photos, in points; 0 shows
    /// the newest.
    @Published var scroll: CGFloat = 0

    /// Keep on line, from the menu bar: how many photos the line keeps, or
    /// nil for as many as fit across the screen.
    nonisolated static let keepChoices = [25, 50, 100]
    nonisolated static var keepOnLine: Int? {
        get {
            let n = UserDefaults.standard.integer(forKey: "keepOnLine")
            return keepChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepOnLine") }
    }


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let managedKey = "peggedManaged"

    /// 收好（搬到截圖資料夾）之後要不要留在右欄。存的鍵是反過來的 "leaveAfterKeep"（true＝收好後從右欄拿掉）。
    /// 還沒存過時預設不留（右欄收完就淨空）；舊版預設是留，所以舊使用者由 migrateShotKeep10minIfNeeded 明確改過。
    nonisolated static var staysAfterKeep: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: "leaveAfterKeep") == nil ? false : !d.bool(forKey: "leaveAfterKeep")
        }
        set { UserDefaults.standard.set(!newValue, forKey: "leaveAfterKeep") }
    }

    /// 首次升級採用 10 分鐘自動收好與收好後拿下；之後保留使用者設定。
    nonisolated static func migrateShotKeep10minIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "shotKeep10minMigrated") else { return }
        defaults.set(600.0, forKey: "keepDelay")
        defaults.set(true, forKey: "leaveAfterKeep")
        defaults.set(true, forKey: "shotKeep10minMigrated")
    }

    /// Noted: 拖出去、對方收下之後不保留（不收進截圖資料夾，過 10 分鐘丟垃圾桶）。預設開。
    nonisolated static var discardsAfterSend: Bool {
        get { !UserDefaults.standard.bool(forKey: "keepAfterSend") }
        set { UserDefaults.standard.set(!newValue, forKey: "keepAfterSend") }
    }

    /// Noted: 等著丟垃圾桶的檔（路徑 → 到期時間）。存起來，App 中途結束，下次啟動補做。
    private static let pendingTrashKey = "pendingTrash"

    /// 檔案在磁碟上的身分（卷宗＋inode）。同一個路徑後來換成別的檔，身分就不一樣。
    nonisolated static func fileIdentity(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// 等著丟垃圾桶的清單：路徑 → [到期時間, 檔案身分]
    private static var pendingTrash: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: pendingTrashKey) as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: pendingTrashKey) }
    }

    /// 這個路徑上「現在這個檔」是不是正在等著丟垃圾桶
    static func isPendingTrash(_ url: URL) -> Bool {
        guard let entry = pendingTrash[url.path] else { return false }
        return entry["id"] == fileIdentity(url.path)
    }

    static func scheduleTrash(_ url: URL, after delay: TimeInterval = sentGrace) {
        guard let identity = fileIdentity(url.path) else { return }
        pendingTrash[url.path] = ["due": String(Date().addingTimeInterval(delay).timeIntervalSince1970), "id": identity]
        armTrash(url.path, after: delay)
    }

    private static func armTrash(_ path: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            var pending = pendingTrash
            // 被取消（或已處理）就不動
            guard let entry = pending.removeValue(forKey: path) else { return }
            pendingTrash = pending
            // 路徑上已經不是當初那個檔（被搬走、同名的新檔）就不丟
            guard let identity = fileIdentity(path), identity == entry["id"] else { return }
            do {
                try moveToTrash(URL(fileURLWithPath: path))
                log.notice("Trashed a sent capture: \((path as NSString).lastPathComponent, privacy: .public)")
            } catch {
                log.error("Could not trash a sent capture \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 啟動時呼叫：上次沒等到時間就結束的，接著等（過期的馬上丟垃圾桶）。
    static func resumePendingTrash() {
        let now = Date().timeIntervalSince1970
        for (path, entry) in pendingTrash { armTrash(path, after: (Double(entry["due"] ?? "") ?? now) - now) }
    }

    /// Noted: 這張丟掉時要不要進垃圾桶：還在收件匣的、或 Noted 收好的。
    func trashesOnDiscard(_ id: UUID) -> Bool {
        isInInbox(id) || (items.first { $0.id == id }?.managed ?? false)
    }

    init() {
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !Line.isPendingTrash(url) else { return nil }
        guard !items.contains(where: { $0.url == url && !$0.falling }), !justKept.contains(url.path),
              !wasHung(url), let thumb = makeThumbnail(url) else { return nil }
        if let file = fileID(url) { hungFiles.insert(file) }
        var item = Pegged(url: url, thumb: thumb, modified: modificationDate(url))
        item.flying = flying
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems { _ = letGoOldest() }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        if isInInbox(item.id) { scheduleKeep(item.id) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    /// Called when a photo was dragged into an app, so the line goes back up.
    var onSent: (() -> Void)?

    /// Called when an edited photo hangs again, so the line comes down to show
    /// it, with where the editor showed it when it should fly back.
    var onRehung: ((UUID, CGRect?) -> Void)?

    /// `falls: false` makes it vanish at once instead of falling off the screen.
    func drop(_ id: UUID, quietly: Bool = false, falls: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        if falls { onFall?(items[i]) }
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// The photos hung before (left) or after (right) this one.
    func neighbours(of id: UUID, toTheLeft: Bool) -> [Pegged] {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return [] }
        return toTheLeft ? Array(live[..<i]) : Array(live[(i + 1)...])
    }

    /// Takes down everything on one side of a photo. Each one goes the way
    /// of its own corner button: to the Trash from ShotLine's folder, and
    /// only off the line from anywhere else.
    func takeDown(_ id: UUID, toTheLeft: Bool) {
        takeDown(neighbours(of: id, toTheLeft: toTheLeft))
    }

    /// One after another, and only the first makes a sound.
    private func takeDown(_ live: [Pegged]) {
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                guard let self else { return }
                // Noted: 整批拿下時，已經收進截圖資料夾的（managed）只從右欄拿下、檔案不動。
                // 只有對單一張雙擊或按叉叉才會把收好的檔丟垃圾桶。
                if self.items.first(where: { $0.id == item.id })?.managed == true {
                    self.drop(item.id, quietly: n > 0)
                } else {
                    self.discard(item.id, quietly: n > 0)
                }
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    /// Those saved again, like an edit in Preview, show the new version.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
        for i in items.indices where !items[i].falling {
            let modified = modificationDate(items[i].url)
            guard modified != items[i].modified, let thumb = makeThumbnail(items[i].url) else { continue }
            items[i].thumb = thumb
            items[i].modified = modified
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        held.insert(id)
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            try Line.moveToTrash(item.url)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in ShotLine's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        if trashesOnDiscard(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// Moves along a line that holds more than fit, from a scroll gesture.
    func scroll(by delta: CGFloat) {
        let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
        let next = min(most, max(0, scroll + delta))
        if next != scroll { scroll = next }
    }

    /// After Keep on line is lowered, the oldest photos past it go the way
    /// of a full line.
    func trim() {
        let before = items.count
        while liveCount > maxItems, letGoOldest() {}
        // 只有真的移掉東西、且使用者本來就在開頭時才歸零；否則維持原位置（夾在合法範圍內）
        if items.count != before, scroll == 0 {
            scroll = 0
        } else {
            let most = CGFloat(max(0, items.count - visibleCount)) * Layout.spacing
            let clamped = min(most, max(0, scroll))
            if clamped != scroll { scroll = clamped }
        }
        // 全部都在忙時繩子會暫時超過上限，過一會兒再補跑一次
        // 不再每 2 秒輪詢：忙碌結束的地方（拖曳／按住／滑鼠離開／選單／編輯器／QuickLook）會呼叫 trimIfOver，
        // 這裡只留一個 30 秒的保底
        if liveCount > maxItems, !trimRetryScheduled {
            trimRetryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                self.trimRetryScheduled = false
                self.trim()
            }
        }
    }

    private var trimRetryScheduled = false

    /// 某個「忙碌」狀態剛結束時呼叫：繩子超過上限才補整理。
    /// 晚一個 runloop 再跑，等忙碌旗標（例如 GrabView.isDragging）都已經放掉
    func trimIfOver() {
        guard liveCount > maxItems else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.liveCount > self.maxItems else { return }
            self.trim()
        }
    }

    /// A capture in ShotLine's folder is kept rather than trashed, so a full
    /// line never throws away a screenshot, edited or not.
    private func letGo(_ id: UUID) -> Bool {
        if isInInbox(id), !keep(id, quietly: true, leaving: true) { return false }   // 搬不走就留在繩上，不能讓檔案掉出繩子
        drop(id, quietly: true)
        return true
    }

    /// Lets the oldest photo go; one that cannot be kept stays and the next
    /// oldest is tried. False when none could go.
    private func letGoOldest() -> Bool {
        for item in items where !item.falling {
            // 正在 Markup 標示或剪裁的照片不能被搬走，會讓編輯器存不了檔
            // 也跳過被外部程式開著的、正在拖曳／按住／QuickLook 的照片
            if isBusy(item) || held.contains(item.id) { continue }
            if letGo(item.id) { return true }
        }
        return false
    }

    /// Inbox mode: keep a capture by moving it to the screenshots folder
    /// macOS used before. The corner checkmark does it at once, and every
    /// capture does it by itself `keepDelay` seconds after it was hung.
    @discardableResult
    func keep(_ id: UUID, quietly: Bool = false, leaving: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id && !$0.falling }) else { return false }
        if let target = moveToKeepFolder(item.url) {
            // Noted: 預設留在右欄，改指到搬過去的位置；leaving（繩子滿了）或設定關掉時才拿下來
            if Line.staysAfterKeep && !leaving {
                repoint(id, to: target)
            } else {
                drop(id, quietly: true)
            }
            return true
        } else if !quietly {
            NSSound.beep()
        }
        return false
    }

    /// Noted: 檔案已經搬到 target，這張留在右欄並改指過去。
    private func repoint(_ id: UUID, to target: URL) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        keepTimers[id] = nil
        items[i].url = target
        items[i].managed = true
        items[i].modified = modificationDate(target)
        save()
    }

    private func moveToKeepFolder(_ url: URL) -> URL? {
        let folder = Inbox.keepFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            log.notice("Kept \(url.lastPathComponent, privacy: .public) in \(folder.path, privacy: .public)")
            markJustKept(target)
            return target
        } catch {
            log.error("Could not keep \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A watcher on the keep folder, like the one on the Desktop, would see
    /// a kept file arrive and hang it all over again.
    private func markJustKept(_ target: URL) {
        let path = target.path
        justKept.insert(path)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.justKept.remove(path) }
    }

    /// How long a sent capture keeps its path in ShotLine's folder.
    nonisolated static let sentGrace: TimeInterval = {
        // Noted: 測試時（只在 NOTED_SHOT_TEST_DIR 模式）可以用 NOTED_SHOT_GRACE 縮短等待
        if ShotLineModule.testDirectory != nil,
           let s = DevBuild.environment["NOTED_SHOT_GRACE"], let v = TimeInterval(s) { return v }
        return 600
    }()

    /// Noted: 丟垃圾桶。測試時改成搬到暫存資料夾的 trash/，不把測試檔丟進使用者的垃圾桶。
    nonisolated static func moveToTrash(_ url: URL) throws {
        if let test = ShotLineModule.testDirectory {
            let dir = test.appendingPathComponent("trash", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
        } else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    /// Keeps a capture that was dragged into an app without taking it from
    /// under that app. Discord and other Chromium apps read the dropped file
    /// only when they upload it, and a file moved by then stalls the upload.
    /// So the screenshots folder gets a hard link, the same file under a
    /// second name, and the path in ShotLine's folder goes away later.
    @discardableResult
    private func keepSent(_ url: URL) -> URL? {
        let folder = Inbox.keepFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.linkItem(at: url, to: target)
            log.notice("Kept \(url.lastPathComponent, privacy: .public) in \(folder.path, privacy: .public), linked")
            markJustKept(target)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sentGrace) {
                try? FileManager.default.removeItem(at: url)
            }
            return target
        } catch {
            // Another volume, say: a move is all there is.
            return moveToKeepFolder(url)
        }
    }

    /// Dragged into an app, which has its copy: the photo vanishes and the
    /// line goes back up at once. A capture's file moves on to the screenshots
    /// folder, while the app can still read it where it was. A photo being
    /// edited stays, as with the timer.
    func sent(_ id: UUID) {
        guard !held.contains(id), let item = items.first(where: { $0.id == id && !$0.falling }) else { return }
        let inInbox = isInInbox(id)
        // Noted: 「拖出去成功後不保留」（預設開）：這張從右欄拿掉，檔案不收進截圖資料夾。
        // 原路徑先留 sentGrace（10 分鐘）給 Discord 這類晚一點才讀檔的 App，時間到再丟垃圾桶（不是永久刪除）。
        // 只丟「還在收件匣、還沒收進截圖資料夾」的檔。已經收進截圖資料夾的（managed）和另外監看的資料夾裡的檔，
        // 只從右欄拿下、檔案不動：那些已經是使用者資料夾裡的東西了。
        if Line.discardsAfterSend {
            drop(id, quietly: true, falls: false)
            onSent?()
            if inInbox { Line.scheduleTrash(item.url) }
            return
        }
        // Noted: 留在右欄時，拖給 App 之後這張不消失，只是檔案收進截圖資料夾
        if Line.staysAfterKeep {
            if inInbox, let target = keepSent(item.url) { repoint(id, to: target) }
            onSent?()
            return
        }
        drop(id, quietly: true, falls: false)
        onSent?()
        guard inInbox else { return }
        keepSent(item.url)
    }

    /// Put away after, from the menu bar: seconds before a capture moves on
    /// by itself and the line goes back up, or nil for never.
    nonisolated static let keepDelayChoices: [TimeInterval] = [15, 30, 180, 600]
    nonisolated static var keepDelay: TimeInterval? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "keepDelay") != nil else { return 600 }
            let n = defaults.double(forKey: "keepDelay")
            return keepDelayChoices.contains(n) ? n : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "keepDelay") }
    }

    /// The photo the pointer is over. Not published: only the timer reads it.
    var hoveredID: UUID? {
        didSet { if hoveredID == nil, oldValue != nil { trimIfOver() } }
    }

    /// The timer each capture is waiting on. A new timer replaces the old
    /// one, and one that no longer matches does nothing when it fires.
    private var keepTimers: [UUID: UUID] = [:]

    /// 測試與排程共用：延遲扣除掛上後經過的牆上時間。
    nonisolated static func keepRemaining(hungAt: Date, delay: TimeInterval, now: Date) -> TimeInterval {
        max(0, delay - now.timeIntervalSince(hungAt))
    }

    /// 改延遲後以原掛上時間重算，不重設倒數。
    func restartKeepTimers() {
        for item in items where !item.falling && !item.away && isInInbox(item.id) { scheduleKeep(item.id) }
    }

    /// Moves a capture from ShotLine's folder once its time is up. While it
    /// is being held, dragged, edited or looked at, it waits a little longer.
    private func scheduleKeep(_ id: UUID, after delay: TimeInterval? = Line.keepDelay) {
        guard let delay else {
            keepTimers[id] = nil
            return
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let timer = UUID()
        keepTimers[id] = timer
        let remaining = delay == 2 ? 2 : Self.keepRemaining(hungAt: item.hungAt, delay: delay, now: Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + max(remaining, 0.001)) { [weak self] in
            guard let self, self.keepTimers[id] == timer, !self.held.contains(id), self.isInInbox(id),
                  let item = self.items.first(where: { $0.id == id && !$0.falling }) else { return }
            let currentDelay = Line.keepDelay
            if let currentDelay {
                let left = Self.keepRemaining(hungAt: item.hungAt, delay: currentDelay, now: Date())
                if left > 1 { self.scheduleKeep(id, after: currentDelay); return }
            } else { self.keepTimers[id] = nil; return }
            if self.isBusy(item) {
                self.scheduleKeep(id, after: 2)
            } else {
                self.keep(id, quietly: true)
            }
        }
    }

    private func isBusy(_ item: Pegged) -> Bool {
        draggingID == item.id || pressedID == item.id || hoveredID == item.id
            || GrabView.isDragging || GrabView.isShowingMenu
            || Markup.shared.isEditing(item.url) || Trim.shared.isEditing(item.url)
            || QuickLook.shared.isVisible
    }

    /// Photos opened in another app, like Preview. Moving the file would pull
    /// it out from under the editor and the edit could not be saved, so these
    /// stay until the checkmark or the menu moves them. Markup and trimming
    /// say when they are done, so those photos come back instead.
    private var held: Set<UUID> = []

    /// Files ShotLine has just moved to the screenshots folder.
    private var justKept: Set<String> = []

    /// Every file hung since launch, by its identity on disk rather than its
    /// path. A photo dragged to the Desktop, or renamed there, is the same
    /// file under a new name, and a watcher would otherwise hang it again.
    private var hungFiles: Set<String> = []

    private func wasHung(_ url: URL) -> Bool {
        fileID(url).map(hungFiles.contains) ?? false
    }

    /// The volume and inode: kept by a move or a rename, new for a copy.
    private func fileID(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Click: open the photo in the system Markup editor. Markup does not
    /// edit video, so a recording opens in the trimming editor instead.
    /// Its timer stops, and once the editor is up the photo leaves the line
    /// for it (`takeAway`); Done or Escape hangs it again with the full time
    /// ahead of it.
    func markup(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling && !$0.away }) else { return }
        let item = items[i]
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            // Markup edits one file at a time.
            if Markup.shared.isOpen {
                NSSound.beep()
                return
            }
            guard Markup.shared.edit(item.url) else {
                // Opened in Preview instead, which never says when it is done.
                held.insert(id)
                return
            }
        }
        keepTimers[id] = nil
    }

    /// The editor is up: the photo leaves the line to fly into it.
    func takeAway(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id && !$0.falling }) else { return }
        if hoveredID == id { hoveredID = nil }
        hitRects[id] = nil
        items[i].away = true
    }

    /// The editor is closing: the photo flies back from where it showed it.
    func editClosing(_ url: URL, from area: CGRect) {
        rehang(url, from: area)
    }

    /// The editor has closed and any edit is saved. A photo still away, from
    /// an editor that closed without warning, hangs again now.
    func editEnded(_ url: URL, from area: CGRect?) {
        if items.contains(where: { $0.url == url && $0.away && !$0.falling }) {
            rehang(url, from: area)
        } else {
            reloadThumbnail(for: url)
        }
        trimIfOver()
    }

    /// The photo hangs again, showing any edit, flying back from the editor
    /// when it knows where that was.
    private func rehang(_ url: URL, from area: CGRect?) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }) else { return }
        if let thumb = makeThumbnail(url) {
            items[i].thumb = thumb
            items[i].modified = modificationDate(url)
        }
        let wasAway = items[i].away
        items[i].away = false
        if wasAway && area != nil { items[i].flying = true }
        let id = items[i].id
        if isInInbox(id) { scheduleKeep(id) }
        onRehung?(id, wasAway ? area : nil)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
        items[i].modified = modificationDate(url)
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let records = items.filter { !$0.falling }.map { ["path": $0.url.path, "hungAt": String($0.hungAt.timeIntervalSince1970), "managed": $0.managed ? "1" : "0"] }
        UserDefaults.standard.set(records, forKey: storeKey)
        UserDefaults.standard.set(items.filter { !$0.falling && $0.managed }.map(\.url.path), forKey: managedKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let loadedAt = Date()
        let defaults = UserDefaults.standard
        let legacyPaths = defaults.stringArray(forKey: storeKey) ?? []
        let records = defaults.array(forKey: storeKey) as? [[String: String]] ?? []
        let restoringLegacy = !legacyPaths.isEmpty || records.contains { $0["hungAt"] == nil }
        let paths = legacyPaths.isEmpty ? records.compactMap { $0["path"] } : legacyPaths
        let managed = Set(UserDefaults.standard.stringArray(forKey: managedKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            var item = Pegged(url: url, thumb: thumb, modified: modificationDate(url))
            item.managed = managed.contains(path)
            if let record = records.first(where: { $0["path"] == path }) {
                item.hungAt = Date(timeIntervalSince1970: Double(record["hungAt"] ?? "") ?? loadedAt.timeIntervalSince1970)
                item.managed = record["managed"] == "1" || item.managed
            } else { item.hungAt = loadedAt }
            items.append(item)
            if let file = fileID(url) { hungFiles.insert(file) }
        }
        // Captures left in ShotLine's folder at the last quit get their time too.
        for item in items where isInInbox(item.id) { scheduleKeep(item.id) }
        if restoringLegacy { save() }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func modificationDate(_ url: URL) -> Date? {
        // Not URL.resourceValues: those are cached, and the edit would go unseen.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = 320) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
