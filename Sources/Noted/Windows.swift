import AppKit
import SwiftUI
import ServiceManagement
import Combine
import KeyboardShortcuts

final class AppWindow: NSWindow {}

func makeWindow<V: View>(_ title: String, size: NSSize, resizable: Bool, view: V) -> AppWindow {
    let w = AppWindow(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.contentViewController = NSHostingController(rootView: view)
    w.setContentSize(size)
    w.center()
    return w
}

// MARK: 任務視窗

struct TaskWindowView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var prefs = Prefs.shared
    @State private var folder: UUID?
    @State private var showDeleted = false
    @State private var search = ""

    var body: some View {
        HSplitView {
            List {
                sidebarRow("全部任務", icon: "tray.full", selected: folder == nil && !showDeleted) {
                    folder = nil; showDeleted = false; store.selectActiveTaskIfNeeded()
                }
                Section("檔案夾") {
                    let root = store.defaultFolder
                    sidebarRow(root.name, icon: "folder", selected: folder == root.id && !showDeleted) {
                        folder = root.id; showDeleted = false; store.selectActiveTaskIfNeeded(in: root.id)
                    }
                    ForEach(store.folderTree(), id: \.folder.id) { item in
                        let f = item.folder
                        sidebarRow(f.name, icon: "folder", selected: folder == f.id && !showDeleted) {
                            folder = f.id; showDeleted = false; store.selectActiveTaskIfNeeded(in: f.id)
                        }
                            .padding(.leading, CGFloat(item.depth + 1) * 12)
                            .contextMenu { Button("刪除檔案夾（裡面的東西移到上一層）") { store.deleteFolder(f.id); folder = nil } }
                    }
                }
                sidebarRow("最近刪除", icon: "trash", selected: showDeleted) {
                    store.currentTaskID = store.deletedTasks.first?.id
                    showDeleted = true
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150, idealWidth: 170, maxWidth: 240)

            VStack(spacing: 0) {
                TextField("搜尋", text: $search).textFieldStyle(.roundedBorder).padding(8)
                List(selection: Binding(get: { store.currentTaskID }, set: { if let v = $0 { store.currentTaskID = v } })) {
                    ForEach(listed) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if let c = t.taskColor { Circle().fill(c.color).frame(width: 8, height: 8) }
                                if t.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                                Text(t.title).lineLimit(1)
                            }
                            Text(relativeTime(t.modifiedAt) + (t.uncheckedItems.isEmpty ? "" : " · 還剩 \(t.uncheckedItems.count) 項"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(t.id)
                        .contextMenu { rowMenu(t) }
                    }
                    .onMove(perform: showDeleted || !search.isEmpty ? nil : { from, to in
                        var list = listed
                        list.move(fromOffsets: from, toOffset: to)
                        store.reorderFavorites(list.filter(\.isFavorite).map(\.id))
                        store.reorder(list.filter { !$0.isFavorite }.map(\.id))
                    })
                }
                HStack {
                    Button { store.newTask(folder: folder) } label: { Image(systemName: "plus") }.help("新增任務（⌘ N）")
                    Spacer()
                    if showDeleted && !store.deletedTasks.isEmpty {
                        Button("全部復原") { store.restoreAllDeleted() }
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)

            Group {
                if showDeleted, let id = store.currentTaskID, let t = store.tasks.first(where: { $0.id == id && $0.deletedAt != nil }) {
                    ScrollView { Text(t.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else if let t = store.current {
                    NoteEditor(taskID: t.id)
                        .padding(8)
                } else {
                    Text("未選取任務").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            .background(prefs.panelBackground.swiftUI)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private var listed: [NoteTask] {
        let base = showDeleted ? store.deletedTasks : store.orderedTasks(in: folder)
        guard !search.isEmpty else { return base }
        return base.filter { $0.body.localizedCaseInsensitiveContains(search) || $0.cards.contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }

    @ViewBuilder private func rowMenu(_ t: NoteTask) -> some View {
        if t.deletedAt != nil {
            Button("復原") { store.restore(t.id) }
            Button("永久刪除") { store.purge(t.id) }
        } else {
            Button(t.isFavorite ? "從我的最愛移除" : "加入我的最愛") { store.toggleFavorite(t.id) }
            Menu("底色") {
                Button("無") { store.setColor(t.id, nil) }
                ForEach(TaskColor.allCases) { c in Button(c.label) { store.setColor(t.id, c) } }
            }
            Menu("移到檔案夾") {
                Button(store.defaultFolder.name) { store.move(t.id, toFolder: store.defaultFolder.id) }
                ForEach(store.folderTree(), id: \.folder.id) { item in
                    Button(String(repeating: "　", count: item.depth + 1) + item.folder.name) { store.move(t.id, toFolder: item.folder.id) }
                }
            }
            Button("刪除任務") { store.delete(t.id) }
        }
    }

    private func sidebarRow(_ s: String, icon: String, selected: Bool, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Label(s, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .fontWeight(selected ? .semibold : .regular)
    }
}

// MARK: 設定

// 設定視窗本體在 SettingsWindow.swift（第二輪：三個設定視窗合成一個）。
// 這裡是各頁用到的區塊；每個都只回傳 Section，由外層的 Form 包起來。

/// 設定裡「玩遊戲時暫停」那一段
struct GamePauseSettings: View {
    @ObservedObject var pause = GamePause.shared
    @State private var newKeyword = ""

    var body: some View {
        Section("玩遊戲時暫停") {
            Toggle("前景是遊戲時，瀏海不展開、不冒提示", isOn: $pause.detectGames)
            Text(pause.statusText + " 暫停時截圖照樣收、音量的輸出規則照樣運作，只是頂端不會長東西出來。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("App 自己標示為遊戲的也算", isOn: $pause.useCategory).disabled(!pause.detectGames)
            Toggle("任何全螢幕 App 都暫停（看全螢幕影片時也會暫停）", isOn: $pause.useFullscreen).disabled(!pause.detectGames)
            VStack(alignment: .leading, spacing: 4) {
                Text("程序名稱關鍵字（比對前景 App 的名稱、路徑與啟動參數，不分大小寫）").font(.caption).foregroundStyle(.secondary)
                ForEach(pause.keywords, id: \.self) { k in
                    HStack {
                        Text(k).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { pause.keywords.removeAll { $0 == k } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("移除")
                    }
                }
                HStack {
                    TextField("新增關鍵字，例如遊戲的程序名稱", text: $newKeyword).onSubmit(addKeyword)
                    Button("加入", action: addKeyword).disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("回復預設") { pause.keywords = GamePauseRules.defaultKeywords }
                }
            }
            .disabled(!pause.detectGames)
            HStack {
                if pause.isManuallyPaused { Button("恢復") { pause.resumeManual() } }
                else {
                    Button("暫停 30 分鐘") { pause.pauseManually(minutes: 30) }
                    Button("暫停到我恢復") { pause.pauseManually(minutes: nil) }
                }
            }
            KeyboardShortcuts.Recorder("切換暫停的快速鍵", name: .notedTogglePause)
        }
    }

    private func addKeyword() {
        let k = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !pause.keywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) else { newKeyword = ""; return }
        pause.keywords.append(k)
        newKeyword = ""
    }
}

struct GeneralSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Group {
            Section("顯示瀏海或膠囊") {
                ForEach(NSScreen.screens, id: \.self) { s in
                    let key = NotchController.key(for: s)
                    Toggle(s.localizedName + (s.safeAreaInsets.top > 0 ? "（瀏海）" : "（膠囊）"), isOn: Binding(
                        get: { !prefs.disabledDisplays.contains(key) },
                        set: { on in
                            if on { prefs.disabledDisplays.removeAll { $0 == key } } else { prefs.disabledDisplays.append(key) }
                            AppDelegate.shared.rebuildControllers()
                        }))
                }
                Text("沒有瀏海的螢幕會顯示一顆膠囊，可以直接拖到任何位置，位置會分螢幕記住。在膠囊上按右鍵可以放回上方中央。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("瀏海") {
                Toggle("游標停留時觸覺回饋", isOn: $prefs.hoverHaptic)
                Toggle("滑鼠移開面板時自動收起（釘選時不收）", isOn: $prefs.collapseOnLeave)
                Toggle("儲存拖放到瀏海上的文字", isOn: $prefs.textDrop)
                Toggle("拖放音效", isOn: $prefs.textDropSound).disabled(!prefs.textDrop)
                Text("把其他 App 裡選取的文字拖到收起的瀏海上，會變成卡片存進你最後用的任務。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GamePauseSettings()
            Section("啟動") {
                Toggle("登入 Mac 時自動開啟", isOn: Binding(get: { launchAtLogin }, set: { v in
                    do {
                        if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch { loginError = error.localizedDescription }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

struct AppearanceSettings: View {
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        Group {
            Section("介面風格") {
                Picker("風格", selection: $prefs.uiStyle) { ForEach(UIStyle.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                Text(prefs.isHUD
                     ? "科幻藍：深藍半透明底、青藍發光外框、斜切角按鈕、等寬字。這個風格開著時，下面的背景和文字顏色暫時不作用（設定值會留著，切回去就恢復）；筆記內文的字體照你選的。"
                     : "切換後馬上套用到面板、新截圖提示和這個設定視窗。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("推薦主題") {
                HStack(spacing: 8) {
                    ForEach(PanelTheme.all) { t in
                        Button { prefs.apply(t) } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8).fill(t.surface.background.swiftUI)
                                    .overlay(Text("Aa 字").font(Font(t.font.font(size: 14)))
                                        .foregroundStyle((t.surface.isLight ? NSColor(red: 0.13, green: 0.14, blue: 0.2, alpha: 1) : t.tint.color).swiftUI))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.4)))
                                    .frame(width: 80, height: 44)
                                Text(t.name).font(.caption)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                // 科幻藍開著時主題的背景與文字顏色看不出來，按了卻會把原本的選擇蓋掉，所以先擋住
                .disabled(prefs.isHUD).opacity(prefs.isHUD ? 0.4 : 1)
            }
            Section("面板") {
                Picker("背景", selection: $prefs.surface) { ForEach(Surface.allCases) { Text($0.label).tag($0) } }
                    .disabled(prefs.isHUD)
                Picker("字體", selection: $prefs.fontStyle) { ForEach(FontStyle.allCases) { Text($0.label).tag($0) } }
                Picker("文字顏色", selection: $prefs.tint) { ForEach(TextTint.allCases) { Text($0.label).tag($0) } }
                    .disabled(prefs.surface.isLight || prefs.isHUD)
                Toggle("墨水輸入（新打的字慢慢浮現）", isOn: $prefs.inkInput)
                Text("在奶油和紙張背景上，文字一律用墨色。開啟「減少動態效果」時不顯示墨水輸入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("大小") {
                HStack {
                    Text("文字大小")
                    Slider(value: Binding(get: { Double(prefs.textSizeIndex) }, set: { prefs.textSizeIndex = Int($0.rounded()) }), in: 0...Double(textSizes.count - 1), step: 1)
                    Text(textSizes[prefs.textSizeIndex].name).frame(width: 36)
                }
                HStack {
                    Text("瀏海縮放")
                    Slider(value: $prefs.notchScale, in: 0.8...1.4, step: 0.05) { editing in
                        if !editing { AppDelegate.shared.controllers.forEach { $0.refreshGeometry() } }
                    }
                    Text(String(format: "%.0f%%", prefs.notchScale * 100)).frame(width: 44)
                }
                Button("面板大小回復預設") {
                    prefs.panelWidth = 560; prefs.panelHeight = 340
                    AppDelegate.shared.controllers.forEach { $0.refreshGeometry() }
                }
            }
            Section("預覽") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("週五上線").font(Font(prefs.fontStyle.font(size: prefs.textSize * 1.3, bold: true)))
                    Text("☑ 重新截圖").font(Font(prefs.fontStyle.font(size: prefs.textSize))).strikethrough().opacity(0.5)
                    Text("☐ 上傳測試版本").font(Font(prefs.fontStyle.font(size: prefs.textSize)))
                }
                .foregroundStyle(prefs.textColor.swiftUI)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(prefs.panelBackground.swiftUI, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct ReminderSettings: View {
    @ObservedObject var prefs = Prefs.shared
    @State private var custom = ""
    @State private var error: String?
    @State private var status = ReminderController.shared.status
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            Section("提醒") {
                Toggle("啟用提醒", isOn: $prefs.reminderEnabled)
                Text("你最後使用的任務還有沒勾的檢查表項目時，會從瀏海提醒你。打開面板時不會提醒，收起後重新計時。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("提醒間隔") {
                Picker("每隔", selection: $prefs.reminderMinutes) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) 分鐘").tag($0) }
                    if ![15, 30, 60, 120].contains(prefs.reminderMinutes) { Text("自訂 · \(prefs.reminderMinutes) 分鐘").tag(prefs.reminderMinutes) }
                }
                HStack {
                    TextField("自訂 1–1440 分鐘", text: $custom).frame(width: 140)
                        .onSubmit(applyCustom)
                    Button("套用", action: applyCustom)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section {
                Toggle("音效", isOn: $prefs.reminderSound)
                HStack {
                    Button("試聽") { Sounds.play("Glass") }
                    Button("試試提醒") {
                        AppDelegate.shared.settingsWindow?.orderBack(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ReminderController.shared.fire(demo: true) }
                    }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onReceive(timer) { _ in status = ReminderController.shared.status }
    }

    private func applyCustom() {
        guard let v = Int(custom.trimmingCharacters(in: .whitespaces)), (1...1440).contains(v) else {
            error = "請輸入 1 到 1,440 之間的整數。先前的間隔不會改變。"; return
        }
        error = nil
        prefs.reminderMinutes = v
        ReminderController.shared.reset()
    }
}

struct ShortcutSettings: View {
    private let rows: [(String, String, String)] = [
        ("瀏海面板", "Esc", "關閉列表，或收起面板"),
        ("瀏海面板", "⌘ 1 – 9", "選擇任務 1–9"),
        ("瀏海面板", "⌘ N", "新增任務"),
        ("瀏海面板", "⌘ ⌫", "游標在編輯器裡：刪到行首；游標不在編輯器：刪除目前的任務（Return 確認、Esc 取消）"),
        ("瀏海面板", "⌘ L", "打開任務列表"),
        ("瀏海面板", "⌘ P", "釘選／取消釘選"),
        ("筆記格式", "⌘ ⇧ H", "切換標題"),
        ("筆記格式", "⌘ ⇧ L", "切換檢查表"),
        ("筆記格式", "⌘ ⇧ 8", "項目符號列表"),
        ("筆記格式", "⌘ ⇧ 7", "編號列表"),
        ("筆記格式", "⌘ ⇧ -", "虛線列表"),
        ("筆記格式", "⌘ ⇧ 0", "內文"),
        ("筆記編輯器", "Return", "延續列表；空白項目按 Return 結束列表"),
        ("筆記編輯器", "⇧ Return", "只插入換行"),
        ("顯示方式", "⌘ = ／ ⌘ -", "放大／縮小文字"),
        ("App", "⌘ 0", "打開任務視窗"),
        ("App", "⌘ ,", "打開設定"),
        ("App", "⌘ W", "關閉視窗"),
    ]
    var body: some View {
        Table(rows.map { ShortcutRow(scope: $0.0, key: $0.1, action: $0.2) }) {
            TableColumn("範圍", value: \.scope).width(80)
            TableColumn("快速鍵", value: \.key).width(90)
            TableColumn("動作", value: \.action)
        }
    }
}
struct ShortcutRow: Identifiable { let id = UUID(); let scope, key, action: String }

struct DataSettings: View {
    @ObservedObject var store = Store.shared
    @State private var message: String?

    var body: some View {
        Group {
            #if !NOTED_PUBLIC
            Section("從 GlideNote 匯入") {
                Text("讀取 GlideNote 的本機與 iCloud 資料庫（會先複製一份再讀，不會動到原檔）。重複匯入會自動略過已匯入的任務。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("匯入") {
                    do {
                        let items = try GlideNoteImporter.run()
                        let n = store.importTasks(items)
                        message = "找到 \(items.count) 個任務，匯入 \(n) 個。"
                    } catch { message = "匯入失敗：\(error.localizedDescription)" }
                }
                .disabled(!GlideNoteImporter.available)
                if !GlideNoteImporter.available { Text("找不到 GlideNote 的資料。").font(.caption) }
            }
            #endif
            Section("匯出與備份") {
                Button("匯出成 Markdown⋯") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.prompt = "匯出到這裡"
                    if p.runModal() == .OK, let url = p.url {
                        do { try store.exportMarkdown(to: url); message = "已匯出到 \(url.path)" }
                        catch { message = "匯出失敗：\(error.localizedDescription)" }
                    }
                }
                Button("打開資料夾") { NSWorkspace.shared.open(store.dir) }
                Text("筆記存在 \(store.dir.path)/store.json，每天第一次開啟時自動備份到 backups（留 14 天）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Section { Text(message).font(.callout) } }
        }
    }
}
