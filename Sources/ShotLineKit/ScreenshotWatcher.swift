import Foundation

/// Watches the folder macOS saves screenshots to and reports new ones.
/// ShotLine never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept real screenshots, tagged by macOS with an
    /// extended attribute. In a dedicated folder, any image counts.
    private let onlyTaggedScreenshots: Bool
    /// Screen recordings carry no tag, so they are only picked up in
    /// ShotLine's own folder, where nothing else is saved.
    private let acceptsRecordings: Bool
    private var known: Set<String>?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// A `start()` that is still waiting on the folder, off the main thread.
    private var starting = false
    /// A folder listing that is still on its way, off the main thread.
    private var listing = false
    /// A capture landed while that listing was in flight.
    private var missed = false
    /// `stop()` arrived while one of the two was still pending.
    private var stopped = false
    /// 還沒能收的檔案（沒寫完、錄影與其他格式、標記還沒到）第一次被看到的時間。
    /// 用時間不用次數：事件來幾次都一樣，保護時間固定。
    private var firstSeen: [String: Date] = [:]
    /// 錄影與 HEIC／TIFF 這類沒有簡單結尾記號的格式，第一次看到後要放多久才收（原本固定等 0.2 秒）
    private static let settleAge: TimeInterval = 0.2
    /// PNG／JPEG 一直沒寫完（或根本是壞圖）最多放多久就照報，不能永遠卡著
    private static let giveUpAge: TimeInterval = 0.6
    private let onNew: (URL) -> Void
    private let onChange: () -> Void

    /// How recently a file on the Desktop must have been created to count
    /// as a screenshot just taken.
    private static let freshness: TimeInterval = 15

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    /// `anyImage` takes every new image even on the Desktop, for a folder
    /// the user chose to watch.
    /// `tagged` is for tests: treat any folder like the Desktop, where only tagged screenshots count.
    init(folder: URL? = nil, anyImage: Bool = false, tagged: Bool = false, onNew: @escaping (URL) -> Void, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.folder = folder ?? Self.screenshotFolder()
        onlyTaggedScreenshots = tagged || (!anyImage
            && self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path)
        acceptsRecordings = self.folder.standardizedFileURL.path == Inbox.folder.standardizedFileURL.path
    }

    static func screenshotFolder() -> URL {
        if ShotLineModule.testDirectory != nil { return Inbox.folder }
        let fm = FileManager.default
        // Read fresh through cfprefsd: inbox mode changes this value at runtime.
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let domain = "com.apple.screencapture" as CFString
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        if let raw, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Anything created after the app launched counts as new, even if it
    /// landed before the watcher was ready (macOS may be asking for Desktop
    /// access at that moment).
    private let launchDate = Date()

    /// The folder is opened off the main thread, because `open()` blocks while
    /// macOS asks whether ShotLine may look inside it. On the Desktop that is
    /// the consent prompt, and it waits for an answer. Asking from
    /// `applicationDidFinishLaunching` meant the app had not finished launching
    /// while that was pending: no status item appeared, and the signal sources
    /// that put the screenshot settings back never ran.
    func start() {
        stopped = false
        guard source == nil, !starting else { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(self.folder.path, O_EVTONLY)
            DispatchQueue.main.async { self.watch(fd) }
        }
    }

    /// Starts watching, then reads the folder. The watcher is live before the
    /// listing begins, so a capture that lands in between is not lost.
    private func watch(_ fd: Int32) {
        starting = false
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            NSLog("Noted/ShotLine: cannot watch \(folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        refresh()
    }

    /// Safe to call while `start()` or a listing is still pending: the file
    /// descriptor is closed as soon as it arrives, and a listing that lands
    /// afterwards is dropped.
    func stop() {
        stopped = true
        missed = false
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        // 檔案改名完成的那一刻資料夾事件就來了，馬上掃一次，不再等 0.2 秒（那會讓截圖慢整整 0.2 秒才出現）。
        // 馬上掃的只收「圖解得開、寫完了」的；沒寫完的放著，再補一次延遲的掃描（跟原本一樣）抓後到的與錄影。
        refresh()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Reads the folder off the main thread. Sorting by creation date and
    /// reading it back costs one filesystem call per file, and this folder can
    /// be the Desktop, so none of it belongs on the main thread.
    private func refresh() {
        guard !listing else {
            missed = true
            return
        }
        listing = true
        let known = self.known
        let firstSeen = self.firstSeen
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let now = Date()
            let files = self.listFolder()
            let settled = files.filter { self.creationDate($0) < self.launchDate }
            let candidates = files.filter { self.isCandidate($0) }
            let fresh = Set(candidates.filter { -self.creationDate($0).timeIntervalSinceNow < Self.freshness }.map(\.path))
            // 新出現的候選要能收才收：PNG／JPEG 看檔尾寫完沒（拖太久就照報）；錄影與其他格式放滿 settleAge 再收
            // （錄影從一開始錄就有檔案）。已經認識的、啟動前就有的不用再查。
            let seen = known ?? Set(settled.map(\.path))
            let ready = Set(candidates.filter { url in
                if seen.contains(url.path) { return true }
                let age = now.timeIntervalSince(firstSeen[url.path] ?? now)
                return Self.isReady(url, age: age)
            }.map(\.path))
            // Desktop：macOS 可能在改名之後才補上「這是截圖」的標記。剛出現、還沒標記的圖先不記進「已知」，
            // 等一下再看（放滿 settleAge 為止），不然馬上掃到的那次會把真的截圖當成別的圖永遠錯過。
            let untagged: Set<String> = !onlyTaggedScreenshots ? [] : Set(files.filter { url in
                Self.imageExtensions.contains(url.pathExtension.lowercased()) && !seen.contains(url.path)
                    && !self.isScreenCapture(url) && -self.creationDate(url).timeIntervalSinceNow < Self.freshness
                    && now.timeIntervalSince(firstSeen[url.path] ?? now) < Self.settleAge
            }.map(\.path))
            DispatchQueue.main.async { self.adopt(files, settled, candidates, fresh, ready, untagged) }
        }
    }

    /// 這個新檔案現在能收了嗎（`age`＝第一次看到它到現在幾秒）。
    /// PNG 以 IEND 區塊結尾、JPEG 以 FFD9 結尾，這兩種寫完才會出現，所以看檔尾，寫完就收，不必等。
    /// ImageIO 的狀態不可靠（截斷的 PNG 它也說完整）。其他格式（HEIC、TIFF…）與錄影沒有這麼簡單的記號，
    /// 放滿 settleAge（跟原本等 0.2 秒一樣的保護）。PNG／JPEG 拖超過 giveUpAge 還沒寫完就照報，壞圖不能永遠卡著。
    /// macOS 自己存截圖是先寫暫存檔再改名，改名的那一刻就是完整的。
    private static func isReady(_ url: URL, age: TimeInterval) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg"].contains(ext), !isRecording(url) else { return age >= settleAge }
        return endsComplete(url, ext: ext) || age >= giveUpAge
    }

    private static func endsComplete(_ url: URL, ext: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 12 else { return false }
        let count = UInt64(ext == "png" ? 12 : 64)
        try? handle.seek(toOffset: size - min(size, count))
        guard let tail = try? handle.readToEnd() else { return false }
        if ext == "png" {
            return Array(tail) == [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        }
        // JPEG：FFD9 之後最多只有一點補零
        var end = tail.count
        while end > 0, tail[tail.startIndex + end - 1] == 0 { end -= 1 }
        return end >= 2 && tail[tail.startIndex + end - 2] == 0xFF && tail[tail.startIndex + end - 1] == 0xD9
    }

    /// Takes a finished listing, reports what is new, then runs the listing
    /// that was asked for while this one was in flight.
    private func adopt(_ files: [URL], _ settled: [URL], _ candidates: [URL], _ fresh: Set<String>, _ ready: Set<String>,
                       _ untagged: Set<String>) {
        listing = false
        guard !stopped else { return }
        // The first listing adopts everything that was already there when the
        // app launched. Later ones compare against the previous listing.
        let first = known == nil
        let base = known ?? Set(settled.map(\.path))
        var deferred = Set<String>()
        let now = Date()
        for url in candidates where !base.contains(url.path) {
            // On the Desktop, a screenshot renamed or moved there is an old
            // file under a new name; only one just taken is new.
            if onlyTaggedScreenshots && !first && !fresh.contains(url.path) { continue }
            if !ready.contains(url.path) {
                if firstSeen[url.path] == nil { firstSeen[url.path] = now }
                deferred.insert(url.path)
                continue
            }
            firstSeen[url.path] = nil
            onNew(url)
        }
        for path in untagged {
            if firstSeen[path] == nil { firstSeen[path] = now }
            deferred.insert(path)
        }
        firstSeen = firstSeen.filter { deferred.contains($0.key) }   // 收了的、不再等的就忘掉，不留著
        // 先放著的不記進「已知」，下一次掃描才會再看它，不會漏
        known = Set(files.map(\.path)).subtracting(deferred)
        if !first { onChange() }
        if !deferred.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refresh() }
        }
        if missed {
            missed = false
            refresh()
        }
    }

    private func listFolder() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func isCandidate(_ url: URL) -> Bool {
        if isRecording(url) { return acceptsRecordings }
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return onlyTaggedScreenshots ? isScreenCapture(url) : true
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}
