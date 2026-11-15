import AppKit
import Combine
import SwiftUI
import ShotLineKit

struct Card: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var order: Int
    var isDefault = false
    var parentID: UUID?   // nil＝最上層；預設檔案夾就是最上層本身
}

/// 任務列的底色
enum TaskColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, pink, gray
    var id: String { rawValue }
    var label: String {
        switch self {
        case .red: "紅色"; case .orange: "橙色"; case .yellow: "黃色"; case .green: "綠色"
        case .blue: "藍色"; case .purple: "紫色"; case .pink: "粉紅色"; case .gray: "灰色"
        }
    }
    var color: Color {
        switch self {
        case .red: Color(red: 0.93, green: 0.30, blue: 0.30); case .orange: Color(red: 0.98, green: 0.58, blue: 0.22)
        case .yellow: Color(red: 0.96, green: 0.80, blue: 0.25); case .green: Color(red: 0.30, green: 0.78, blue: 0.42)
        case .blue: Color(red: 0.30, green: 0.55, blue: 0.95); case .purple: Color(red: 0.62, green: 0.42, blue: 0.92)
        case .pink: Color(red: 0.95, green: 0.45, blue: 0.70); case .gray: Color(white: 0.55)
        }
    }
}

struct NoteTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var body: String
    var folderID: UUID
    var order: Double
    var favoriteOrder: Int?
    var createdAt = Date()
    var modifiedAt = Date()
    var deletedAt: Date?
    var cards: [Card] = []
    var color: String?

    var taskColor: TaskColor? { color.flatMap(TaskColor.init(rawValue:)) }

    var title: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = LineFormat.strip(String(line)).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return cards.first.map { String($0.text.prefix(30)) } ?? "未命名"
    }
    var uncheckedItems: [String] {
        body.split(separator: "\n").compactMap { $0.hasPrefix(LineFormat.unchecked) ? String($0.dropFirst(2)) : nil }
    }
    var isFavorite: Bool { favoriteOrder != nil }
}

/// 每行開頭的格式記號。內容就是純文字，好讀也好匯出。
enum LineFormat: String, CaseIterable {
    case body, heading, checklist, bullet, numbered, dash
    static let unchecked = "☐ ", checked = "☑ "
    var label: String {
        switch self {
        case .body: "內文"; case .heading: "標題"; case .checklist: "檢查表"
        case .bullet: "項目符號列表"; case .numbered: "編號列表"; case .dash: "虛線列表"
        }
    }
    var symbol: String {
        switch self {
        case .body: "text.alignleft"; case .heading: "textformat.size"; case .checklist: "checklist"
        case .bullet: "list.bullet"; case .numbered: "list.number"; case .dash: "list.dash"
        }
    }
    func prefix(number: Int = 1) -> String {
        switch self {
        case .body: ""; case .heading: "# "; case .checklist: LineFormat.unchecked
        case .bullet: "• "; case .numbered: "\(number). "; case .dash: "– "
        }
    }
    /// 回傳 (格式, 前綴長度)
    static func detect(_ line: String) -> (LineFormat, Int) {
        if line.hasPrefix("# ") { return (.heading, 2) }
        if line.hasPrefix(unchecked) || line.hasPrefix(checked) { return (.checklist, 2) }
        if line.hasPrefix("• ") { return (.bullet, 2) }
        if line.hasPrefix("– ") { return (.dash, 2) }
        var digits = 0
        for c in line { if c.isASCII && c.isNumber { digits += 1 } else { break } }
        if digits > 0 && digits < 4 {
            let rest = line.dropFirst(digits)
            if rest.hasPrefix(". ") { return (.numbered, digits + 2) }
        }
        return (.body, 0)
    }
    static func strip(_ line: String) -> String {
        let (_, n) = detect(line)
        return String(line.dropFirst(n))
    }
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var tasks: [NoteTask] = []
    @Published private(set) var folders: [Folder] = []
    @Published var currentTaskID: UUID? { didSet { scheduleSave() } }

    private struct FileData: Codable {
        var version = 1
        var folders: [Folder]
        var tasks: [NoteTask]
        var currentTaskID: UUID?
    }

    let dir: URL
    private var fileURL: URL { dir.appendingPathComponent("store.json") }
    private var saveWork: DispatchWorkItem?
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?

    private convenience init() {
        let dir: URL
        if let test = DevBuild.environment["NOTED_DATA_DIR"] {
            dir = URL(fileURLWithPath: test, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("瀏海筆記", isDirectory: true)
        }
        self.init(dir: dir)
    }

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: 讀寫

    private func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let f = try dec.decode(FileData.self, from: data)
                folders = f.folders; tasks = f.tasks; currentTaskID = f.currentTaskID
            } catch {
                // 讀不懂就先把原檔留一份，不覆蓋
                let bad = dir.appendingPathComponent("store-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                do {
                    try FileManager.default.copyItem(at: fileURL, to: bad)
                    loadError = "讀不到筆記檔，原檔已備份到 \(bad.lastPathComponent)，Noted 這次不會寫入筆記，避免蓋掉原檔"
                } catch {
                    loadError = "讀不到筆記檔，而且備份失敗，Noted 這次不會寫入筆記，請先自行保留 store.json"
                }
            }
        }
        if !folders.contains(where: \.isDefault) {
            folders.insert(Folder(name: "預設檔案夾", order: 0, isDefault: true), at: 0)
        }
        // 最近刪除超過 30 天就清掉
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        tasks.removeAll { ($0.deletedAt ?? .distantFuture) < cutoff }
        if tasks.isEmpty {
            tasks.append(NoteTask(body: "# Noted\n在這裡記下工作筆記和待辦事項。\n☐ 試試勾選這一行\n", folderID: defaultFolder.id, order: 0))
        }
        if current == nil { currentTaskID = activeTasks.first?.id }
        // 讀不懂的壞檔不進每日備份輪替，以免擠掉好的備份
        if loadError == nil { dailyBackup() }
    }

    func scheduleSave() {
        guard loadError == nil else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        guard loadError == nil else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(FileData(folders: folders, tasks: tasks, currentTaskID: currentTaskID)) else {
            saveError = "筆記存檔失敗：無法編碼"
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "筆記存檔失敗：\(error.localizedDescription)"
        }
    }

    private func dailyBackup() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let bdir = dir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: bdir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
        let target = bdir.appendingPathComponent("store-\(fmt.string(from: Date())).json")
        if !FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.copyItem(at: fileURL, to: target)
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: bdir.path)) ?? []).sorted()
        for f in files.dropLast(14) { try? FileManager.default.removeItem(at: bdir.appendingPathComponent(f)) }
    }

    // MARK: 查詢

    var defaultFolder: Folder { folders.first(where: \.isDefault)! }
    var sortedFolders: [Folder] { folders.sorted { $0.order < $1.order } }
    var activeTasks: [NoteTask] { tasks.filter { $0.deletedAt == nil }.sorted { $0.order < $1.order } }
    var deletedTasks: [NoteTask] { tasks.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! } }
    var current: NoteTask? { task(currentTaskID) }

    func task(_ id: UUID?) -> NoteTask? {
        guard let id else { return nil }
        return tasks.first { $0.id == id && $0.deletedAt == nil }
    }

    /// 離開最近刪除後，確保目前選取屬於目的任務清單。
    func selectActiveTaskIfNeeded(in folder: UUID? = nil) {
        let list = orderedTasks(in: folder)
        if let currentTaskID, list.contains(where: { $0.id == currentTaskID }) { return }
        currentTaskID = list.first?.id
    }

    /// 我的最愛在前，其餘照順序；folder 為 nil 表示全部
    func orderedTasks(in folder: UUID?) -> [NoteTask] {
        let list = activeTasks.filter { folder == nil || $0.folderID == folder }
        let fav = list.filter(\.isFavorite).sorted { $0.favoriteOrder! < $1.favoriteOrder! }
        return fav + list.filter { !$0.isFavorite }
    }

    // MARK: 修改

    private func mutate(_ id: UUID, touch: Bool = true, _ f: (inout NoteTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        f(&tasks[i])
        if touch { tasks[i].modifiedAt = Date() }
        scheduleSave()
    }

    @discardableResult
    func newTask(folder: UUID? = nil, body: String = "") -> NoteTask {
        let minOrder = (tasks.map(\.order).min() ?? 0) - 1
        let t = NoteTask(body: body, folderID: folder ?? current?.folderID ?? defaultFolder.id, order: minOrder)
        tasks.append(t)
        currentTaskID = t.id
        scheduleSave()
        return t
    }

    func updateBody(_ id: UUID, _ body: String) {
        guard let t = tasks.first(where: { $0.id == id }), t.body != body else { return }
        mutate(id) { $0.body = body }
    }

    func delete(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }), task.deletedAt == nil else { return }
        mutate(id, touch: false) { $0.deletedAt = Date(); $0.favoriteOrder = nil }
        if currentTaskID == id { currentTaskID = orderedTasks(in: nil).first?.id }
    }
    func restore(_ id: UUID) {
        let folderOK = folders.contains { $0.id == tasks.first(where: { $0.id == id })?.folderID }
        mutate(id, touch: false) { $0.deletedAt = nil; if !folderOK { $0.folderID = self.defaultFolder.id } }
    }
    func purge(_ id: UUID) { tasks.removeAll { $0.id == id }; scheduleSave() }
    func purgeAllDeleted() { tasks.removeAll { $0.deletedAt != nil }; scheduleSave() }
    func restoreAllDeleted() { for t in deletedTasks { restore(t.id) } }

    func toggleFavorite(_ id: UUID) {
        guard let t = task(id) else { return }
        if t.isFavorite { mutate(id, touch: false) { $0.favoriteOrder = nil } }
        else {
            let next = (tasks.compactMap(\.favoriteOrder).max() ?? -1) + 1
            mutate(id, touch: false) { $0.favoriteOrder = next }
        }
    }
    func moveFavorite(_ id: UUID, by delta: Int) {
        var favs = orderedTasks(in: nil).filter(\.isFavorite).map(\.id)
        guard let i = favs.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < favs.count else { return }
        favs.swapAt(i, j)
        for (n, fid) in favs.enumerated() { mutate(fid, touch: false) { $0.favoriteOrder = n } }
    }
    func move(_ id: UUID, toFolder folder: UUID) { mutate(id, touch: false) { $0.folderID = folder } }
    /// 把畫面上看到的這幾個任務照新順序排；其他檔案夾的任務位置不動
    func reorder(_ newIDs: [UUID]) {
        var all = activeTasks.map(\.id)
        let set = Set(newIDs)
        let slots = all.indices.filter { set.contains(all[$0]) }
        guard slots.count == newIDs.count else { return }
        for (k, slot) in slots.enumerated() { all[slot] = newIDs[k] }
        for (n, tid) in all.enumerated() { mutate(tid, touch: false) { $0.order = Double(n) } }
    }
    func reorderFavorites(_ newIDs: [UUID]) {
        var all = orderedTasks(in: nil).filter(\.isFavorite).map(\.id)
        let set = Set(newIDs)
        let slots = all.indices.filter { set.contains(all[$0]) }
        guard slots.count == newIDs.count else { return }
        for (k, slot) in slots.enumerated() { all[slot] = newIDs[k] }
        for (n, fid) in all.enumerated() { mutate(fid, touch: false) { $0.favoriteOrder = n } }
    }
    func moveInList(_ id: UUID, by delta: Int) {
        var list = activeTasks.map(\.id)
        guard let i = list.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < list.count else { return }
        list.swapAt(i, j)
        for (n, tid) in list.enumerated() { mutate(tid, touch: false) { $0.order = Double(n) } }
    }

    func addCard(_ text: String, to id: UUID? = nil) -> NoteTask {
        let target = task(id ?? currentTaskID) ?? newTask()
        mutate(target.id) { $0.cards.insert(Card(text: text), at: 0) }
        currentTaskID = target.id
        return task(target.id)!
    }
    func deleteCard(_ card: UUID, in id: UUID) { mutate(id) { $0.cards.removeAll { $0.id == card } } }

    @discardableResult
    func newFolder(_ name: String, parent: UUID? = nil) -> Folder {
        let p = parent == defaultFolder.id ? nil : parent
        let f = Folder(name: name, order: (folders.map(\.order).max() ?? 0) + 1, parentID: p)
        folders.append(f); scheduleSave(); return f
    }

    // MARK: 巢狀檔案夾（預設檔案夾＝最上層）

    func folder(_ id: UUID?) -> Folder? { folders.first { $0.id == id } }

    /// 某一層底下的子檔案夾；parent 為 nil 或預設檔案夾都代表最上層
    func subfolders(of parent: UUID?) -> [Folder] {
        let p = parent == defaultFolder.id ? nil : parent
        return folders.filter { !$0.isDefault && $0.parentID == p }.sorted { $0.order < $1.order }
    }
    /// 從最上層走到這個檔案夾的路徑（不含預設檔案夾）
    func folderPath(_ id: UUID?) -> [Folder] {
        var out: [Folder] = []
        var cur = folder(id)
        var guardCount = 0
        while let f = cur, !f.isDefault, guardCount < 64 {
            out.insert(f, at: 0); cur = folder(f.parentID); guardCount += 1
        }
        return out
    }
    func descendants(of id: UUID) -> Set<UUID> {
        var out: Set<UUID> = []
        var stack = [id]
        while let x = stack.popLast() {
            for c in folders where c.parentID == x && !out.contains(c.id) { out.insert(c.id); stack.append(c.id) }
        }
        return out
    }
    /// 整棵樹攤平（給選單和側邊欄用），深度從 0 開始
    func folderTree() -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, _ d: Int) {
            for f in subfolders(of: parent) { out.append((f, d)); walk(f.id, d + 1) }
        }
        walk(nil, 0)
        return out
    }
    /// 這個檔案夾（含所有子檔案夾）裡的任務數
    func taskCount(inTree id: UUID) -> Int {
        let ids = descendants(of: id).union([id])
        return activeTasks.filter { ids.contains($0.folderID) }.count
    }
    func moveFolder(_ id: UUID, to parent: UUID?) {
        let p = parent == defaultFolder.id ? nil : parent
        guard let i = folders.firstIndex(where: { $0.id == id }), !folders[i].isDefault,
              p != id, !(p.map { descendants(of: id).contains($0) } ?? false) else { return }
        folders[i].parentID = p; scheduleSave()
    }
    func moveFolderInList(_ id: UUID, by delta: Int) {
        guard let f = folder(id) else { return }
        var sibs = subfolders(of: f.parentID).map(\.id)
        guard let i = sibs.firstIndex(of: id), sibs.indices.contains(i + delta) else { return }
        sibs.swapAt(i, i + delta)
        for (n, sid) in sibs.enumerated() { if let k = folders.firstIndex(where: { $0.id == sid }) { folders[k].order = n } }
        scheduleSave()
    }
    func setColor(_ id: UUID, _ c: TaskColor?) { mutate(id, touch: false) { $0.color = c?.rawValue } }
    func renameFolder(_ id: UUID, _ name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name; scheduleSave()
    }
    /// 刪除檔案夾：裡面的任務和子檔案夾往上一層搬，不會刪掉任務
    func deleteFolder(_ id: UUID) {
        guard let f = folders.first(where: { $0.id == id }), !f.isDefault else { return }
        let up = f.parentID ?? defaultFolder.id
        for t in tasks where t.folderID == id { mutate(t.id, touch: false) { $0.folderID = up } }
        for i in folders.indices where folders[i].parentID == id { folders[i].parentID = f.parentID }
        folders.removeAll { $0.id == id }; scheduleSave()
    }

    // MARK: 匯入／匯出

    func importTasks(_ items: [(folder: String?, task: NoteTask)]) -> Int {
        var n = 0
        for var item in items {
            if tasks.contains(where: { $0.id == item.task.id }) { continue }  // 重複匯入就跳過
            if let name = item.folder, !name.isEmpty {
                let f = folders.first { $0.name == name } ?? newFolder(name)
                item.task.folderID = f.id
            } else { item.task.folderID = defaultFolder.id }
            tasks.append(item.task); n += 1
        }
        scheduleSave()
        return n
    }

    func exportMarkdown(to url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for t in activeTasks {
            var md = t.body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                let s = String(line)
                if s.hasPrefix(LineFormat.unchecked) { return "- [ ] " + s.dropFirst(2) }
                if s.hasPrefix(LineFormat.checked) { return "- [x] " + s.dropFirst(2) }
                if s.hasPrefix("• ") || s.hasPrefix("– ") { return "- " + s.dropFirst(2) }
                return s
            }.joined(separator: "\n")
            if !t.cards.isEmpty { md += "\n\n---\n" + t.cards.map { "> " + $0.text.replacingOccurrences(of: "\n", with: "\n> ") }.joined(separator: "\n\n") }
            let safe = t.title.replacingOccurrences(of: "/", with: "／").prefix(60)
            try md.write(to: url.appendingPathComponent("\(safe)-\(t.id.uuidString.prefix(4)).md"), atomically: true, encoding: .utf8)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
