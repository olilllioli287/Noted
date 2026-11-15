import AppKit
import SwiftUI

/// 瀏海形狀：上緣兩角往外翹，下緣圓角
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var open = false   // true：不畫上緣那條（只有左右和底部）
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let t = min(top, r.width / 4), b = min(bottom, r.height / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        if !open { p.closeSubpath() }
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        let r = m.shapeRect, w = m.windowFrame
        ZStack(alignment: .topLeading) {
            shaped
                .frame(width: max(r.width, 1), height: max(r.height, 1))
                .offset(x: r.minX - w.minX, y: w.maxY - r.maxY)
        }
        .frame(width: w.width, height: w.height, alignment: .topLeading)
    }

    private var expanded: Bool { m.state == .expanded }
    private var flare: CGFloat { m.hasNotch ? (expanded ? 12 : 6) : 0 }
    /// 科幻藍的外框只畫在「長出來的東西」上（展開的面板、新截圖提示）；收起與小提示維持黑色，才接得上實體瀏海
    private var hudFrame: Bool { prefs.isHUD && (expanded || m.state == .shot) }
    private var fill: Color {
        if hudFrame { return HUDLook.background.swiftUI }
        return expanded ? prefs.panelBackground.swiftUI : .black
    }
    private var hudCut: CGFloat { expanded ? 18 : 12 }

    @ViewBuilder private var shaped: some View {
        let shape: AnyShape = hudFrame
            ? (m.hasNotch ? AnyShape(HUDNotchShape(top: flare, cut: hudCut)) : AnyShape(ChamferRect(cut: hudCut, corners: .all)))
            : (m.hasNotch
                ? AnyShape(NotchShape(top: flare, bottom: expanded ? 22 : (m.state == .collapsed ? 9 : 16)))
                : AnyShape(RoundedRectangle(cornerRadius: expanded ? 18 : (m.state == .collapsed ? m.shapeRect.height / 2 : 16), style: .continuous)))
        ZStack {
            shape.fill(fill)
            if hudFrame {
                if expanded { HUDGrid().clipShape(shape) }
                // 青藍外框加外發光；有瀏海時頂端那條貼著螢幕邊，不畫
                (m.hasNotch ? AnyShape(HUDNotchShape(top: flare, cut: hudCut, open: true)) : shape)
                    .stroke(HUDLook.lineColor.opacity(0.9), lineWidth: 1.2)
                    .shadow(color: HUDLook.lineColor.opacity(0.7), radius: 5)
            } else if !m.hasNotch {
                shape.stroke(Color.white.opacity(expanded ? 0.08 : 0.22), lineWidth: 1)
            }
            if m.hasNotch && m.state == .hover {
                // 瀏海提示：跟膠囊一樣的細白邊，左右延伸到頂，上緣不畫
                NotchShape(top: flare, bottom: 16, open: true)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    .transition(.opacity)
            }
            content
                .padding(.horizontal, flare)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipShape(shape)
                .hudFont(prefs.isHUD)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(m.state == .collapsed ? 0 : 0.35), radius: 12, y: 4)
    }

    @ViewBuilder private var content: some View {
        switch m.state {
        case .collapsed:
            if !m.hasNotch {
                Image(systemName: "square.and.pencil").font(.system(size: 10 * prefs.notchScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .hover:
            VStack(spacing: 0) {
                Spacer(minLength: m.hasNotch ? m.notchSize.height : 0)
                Label("按一下即可使用", systemImage: "square.and.pencil")
                    .font(.system(size: 11 * prefs.notchScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, m.hasNotch ? 6 : 0)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .drop:
            VStack(spacing: 0) {
                Spacer(minLength: m.hasNotch ? m.notchSize.height : 0)
                HStack(spacing: 6) {
                    Image(systemName: m.dropDone ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                        .foregroundStyle(m.dropDone ? .green : .white)
                    Text(m.dropDone ? "已加入「\(m.dropTitle)」" : "放開即可加入「\(m.dropTitle)」")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12 * prefs.notchScale, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.bottom, m.hasNotch ? 8 : 0)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .reminder:
            VStack(spacing: 0) {
                Spacer(minLength: m.hasNotch ? m.notchSize.height : 0)
                if let r = m.reminder {
                    HStack(spacing: 8) {
                        Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(Font(prefs.fontStyle.font(size: 12.5 * prefs.notchScale, bold: true))).lineLimit(1)
                            Text("檢查表還剩 \(r.count) 項 · 按一下打開").font(.system(size: 10.5 * prefs.notchScale)).opacity(0.7)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.bottom, m.hasNotch ? 8 : 0)
                }
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .shot:
            VStack(spacing: 0) {
                Spacer(minLength: m.hasNotch ? m.notchSize.height : 6)
                SuiteHost.peekView()
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        case .expanded:
            // 內容固定用展開後的大小排版，動畫時只裁切、縮放，不重新排版（重排會卡）
            SuitePanel(m: m)
                .frame(width: max(m.expandedSize.width - 2 * flare, 1), height: max(m.expandedSize.height, 1))
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.08)),
                    removal: .opacity.combined(with: .scale(scale: 0.4, anchor: .top)).animation(.easeIn(duration: 0.18))))
        }
    }
}

// MARK: 展開後的面板

struct PanelContent: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var store = Store.shared
    @State private var resizeStart: (mouse: NSPoint, w: Double, h: Double)?
    /// 放在三欄面板的中間那欄：調整大小的把手由外層負責，標題不要長到瀏海底下
    var inSuite = false

    private var fg: Color { prefs.textColor.swiftUI }
    private var barHeight: CGFloat { m.hasNotch ? m.notchSize.height : 32 * prefs.notchScale }

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.loadError ?? store.saveError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            topBar.frame(height: barHeight)
            Group {
                if m.confirmDelete { deleteConfirm }
                else if m.showList { TaskListView(m: m) }
                else if let t = store.current { editorArea(t) }
                else { emptyState }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .foregroundStyle(fg)
        .overlay(alignment: .bottomTrailing) { if !inSuite { resizeGrip } }
        .overlay {
            if let hud = m.hud {
                Text(hud).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .transition(.opacity)
            }
        }
    }

    // 上方工具列：瀏海擋住的中間留空
    private var topBar: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { m.showList.toggle(); m.showDeleted = false } } label: {
                HStack(spacing: 4) {
                    Image(systemName: m.showList ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    Text(store.current?.title ?? "沒有任務").font(Font(prefs.fontStyle.font(size: 12, bold: true))).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(fg.opacity(prefs.isHUD ? 0 : 0.08), in: Capsule())
                .hudCell(prefs.isHUD, active: m.showList)
                .frame(maxWidth: inSuite ? 170 : nil, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("任務列表")
            Spacer(minLength: m.hasNotch ? m.notchSize.width + 12 : 8)
            Menu {
                ForEach(LineFormat.allCases, id: \.self) { f in
                    Button { NoteTextView.active?.applyFormat(f) } label: { Label(f.label, systemImage: f.symbol) }
                }
            } label: { Text("Aa").font(.system(size: 13, weight: .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(minWidth: 22, minHeight: 22).hudCell(prefs.isHUD)
                .help("文字樣式")
            bar("plus", "新增任務") { store.newTask(); m.showList = false; m.focusToken += 1 }
            bar(m.pinned ? "pin.fill" : "pin", m.pinned ? "取消釘選瀏海" : "釘選瀏海") { m.pinned.toggle() }
            bar("macwindow", "打開任務視窗") { AppDelegate.shared.openTaskWindow(nil) }
            bar("gearshape", "設定") { AppDelegate.shared.openSettings(nil) }
            Menu {
                Button(prefs.reminderEnabled ? "關閉提醒" : "開啟提醒") { prefs.reminderEnabled.toggle() }
                if let t = store.current {
                    Button(t.isFavorite ? "從我的最愛移除" : "加入我的最愛") { store.toggleFavorite(t.id) }
                    Menu("移到檔案夾") {
                        Button("全部（最上層）") { store.move(t.id, toFolder: store.defaultFolder.id) }
                        ForEach(store.folderTree(), id: \.folder.id) { item in
                            Button(String(repeating: "　", count: item.depth) + item.folder.name) { store.move(t.id, toFolder: item.folder.id) }
                        }
                    }
                    Button("拷貝全文") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.body, forType: .string)
                    }
                    Divider()
                    Button("刪除任務⋯") { m.controller?.askDelete() }
                }
                Divider()
                Button("最近刪除") { m.showList = true; m.showDeleted = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(minWidth: 22, minHeight: 22).hudCell(prefs.isHUD)
                .help("更多動作")
        }
        .font(.system(size: 13))
        .tint(fg)
        .padding(.horizontal, 8)
    }

    private func bar(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).hudCell(prefs.isHUD).help(help)
    }

    private func editorArea(_ t: NoteTask) -> some View {
        VStack(spacing: 6) {
            NoteEditor(taskID: t.id, onEscape: { m.controller?.goBack(collapseAtTop: true) }, focusToken: m.focusToken)
            if !t.cards.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(t.cards) { c in CardView(card: c, taskID: t.id) }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: 78)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("直接從瀏海記下來").font(.system(size: 15, weight: .semibold))
            Text("在需要的那一刻，快速記下筆記、檢查表和待辦事項。").font(.system(size: 12)).opacity(0.6)
            Button("新增任務") { store.newTask(); m.focusToken += 1 }
            if !store.deletedTasks.isEmpty { Button("查看最近刪除") { m.showList = true; m.showDeleted = true } }
        }
    }

    private var deleteConfirm: some View {
        VStack(spacing: 12) {
            Text("要刪除這個任務嗎？").font(.system(size: 15, weight: .semibold))
            Text("「\(store.current?.title ?? "")」會移到「最近刪除」。").font(Font(prefs.fontStyle.font(size: 12))).opacity(0.7)
            HStack {
                Button("取消（Esc）") { m.confirmDelete = false; m.focusToken += 1 }
                Button("刪除（Return）") { m.controller?.confirmDelete() }.tint(.red)
            }
        }
    }

    private var resizeGrip: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold)).opacity(0.3)
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .help("調整大小")
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    let p = NSEvent.mouseLocation
                    if resizeStart == nil { resizeStart = (p, prefs.panelWidth, prefs.panelHeight) }
                    guard let s = resizeStart else { return }
                    let k = prefs.notchScale
                    prefs.panelWidth = min(max(s.w + Double(p.x - s.mouse.x) * 2 / k, 360), 1100)
                    prefs.panelHeight = min(max(s.h - Double(p.y - s.mouse.y) / k, 180), 900)
                    m.controller?.refreshGeometry()
                }
                .onEnded { _ in resizeStart = nil })
            .padding(4)
    }
}

struct CardView: View {
    let card: Card
    let taskID: UUID
    @ObservedObject var prefs = Prefs.shared
    @State private var copied = false

    var body: some View {
        let fg = prefs.textColor.swiftUI
        VStack(alignment: .leading, spacing: 4) {
            Text(card.text).font(Font(prefs.fontStyle.font(size: 11.5))).lineLimit(3).frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(copied ? "已拷貝" : relativeTime(card.createdAt)).font(.system(size: 10)).opacity(0.5)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(card.text, forType: .string); copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("拷貝卡片文字")
                Button { Store.shared.deleteCard(card.id, in: taskID) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("刪除卡片")
            }
            .font(.system(size: 10))
        }
        .padding(8)
        .frame(width: 180, height: 70)
        .background {
            if prefs.isHUD {
                ChamferRect(cut: 8).fill(HUDLook.lineColor.opacity(0.07))
                    .overlay(ChamferRect(cut: 8).strokeBorder(HUDLook.lineColor.opacity(0.45), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fg.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(fg.opacity(0.1)))
            }
        }
    }
}

func relativeTime(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "剛剛" }
    if s < 3600 { return "\(Int(s / 60)) 分鐘前" }
    let f = DateFormatter(); f.locale = Locale(identifier: "zh_TW")
    let cal = Calendar.current
    if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
    if cal.isDateInYesterday(d) { f.dateFormat = "HH:mm"; return "昨天 \(f.string(from: d))" }
    f.dateFormat = "M/d HH:mm"; return f.string(from: d)
}

// MARK: 面板裡的任務列表

struct TaskListView: View {
    @ObservedObject var m: PanelModel
    @ObservedObject var store = Store.shared
    @ObservedObject var prefs = Prefs.shared
    @State private var newFolderName: String?
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmPurge: UUID?
    @State private var dragID: UUID?
    @State private var dragFrom: Int?
    @State private var dragDY: CGFloat = 0
    @State private var rowHeight: CGFloat = 30

    private var fg: Color { prefs.textColor.swiftUI }

    var body: some View {
        VStack(spacing: 6) {
            header
            if m.showDeleted { deletedList } else { taskList }
        }
        .padding(.horizontal, 8)
    }

    /// 麵包屑：最上層 › 學校 › 課程；右邊是新增檔案夾和最近刪除
    private var header: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb("全部", icon: "house", selected: m.listFolder == nil && !m.showDeleted) { open(folder: nil) }
                    ForEach(store.folderPath(m.listFolder)) { f in
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.35)
                        crumb(f.name, icon: nil, selected: f.id == m.listFolder && !m.showDeleted, usesContentFont: true) { open(folder: f.id) }
                    }
                    if m.showDeleted {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(0.35)
                        crumb("最近刪除", icon: "trash", selected: true) {}
                    }
                }
            }
            Spacer(minLength: 4)
            if !m.showDeleted {
                Button { newFolderName = "" } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("在這一層新增檔案夾")
            }
            Button {
                m.controller?.clearForward()
                if m.showDeleted {
                    store.selectActiveTaskIfNeeded(in: m.effectiveFolder)
                } else {
                    store.currentTaskID = store.deletedTasks.first?.id
                }
                withAnimation(.easeOut(duration: 0.15)) { m.showDeleted.toggle() }
            } label: {
                Image(systemName: m.showDeleted ? "trash.fill" : "trash")
            }.buttonStyle(.plain).help("最近刪除")
        }
        .font(.system(size: 11.5))
        .frame(height: 26)
    }

    private func crumb(_ s: String, icon: String?, selected: Bool, usesContentFont: Bool = false, action a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(s).font(usesContentFont ? Font(prefs.fontStyle.font(size: 11.5 * prefs.notchScale)) : nil).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(fg.opacity(selected ? 0.16 : 0.05), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func open(folder: UUID?) {
        m.controller?.clearForward()
        store.selectActiveTaskIfNeeded(in: folder)
        withAnimation(.easeOut(duration: 0.15)) { m.listFolder = folder; m.showDeleted = false }
    }

    /// 移到檔案夾的選單：整棵樹縮排列出
    @ViewBuilder private func folderMenu(exclude: Set<UUID> = [], _ pick: @escaping (UUID?) -> Void) -> some View {
        Button("全部（最上層）") { pick(nil) }
        ForEach(store.folderTree().filter { !exclude.contains($0.folder.id) }, id: \.folder.id) { item in
            Button(String(repeating: "　", count: item.depth) + item.folder.name) { pick(item.folder.id) }
        }
    }

    private func folderRow(_ f: Folder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 12)).opacity(0.7).frame(width: 24, alignment: .leading)
            if renaming == f.id {
                TextField("檔案夾名稱", text: $renameText).textFieldStyle(.plain)
                    .onSubmit { if !renameText.isEmpty { store.renameFolder(f.id, renameText) }; renaming = nil }
            } else {
                Text(f.name).font(Font(prefs.fontStyle.font(size: 13, bold: true))).lineLimit(1)
            }
            Spacer()
            let n = store.taskCount(inTree: f.id)
            if n > 0 { Text("\(n)").font(.system(size: 10.5)).opacity(0.45) }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.35)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(fg.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { open(folder: f.id) }
        .contextMenu {
            Button("重新命名") { renameText = f.name; renaming = f.id }
            Button("上移") { store.moveFolderInList(f.id, by: -1) }
            Button("下移") { store.moveFolderInList(f.id, by: 1) }
            Menu("移到") { folderMenu(exclude: store.descendants(of: f.id).union([f.id])) { store.moveFolder(f.id, to: $0) } }
            Divider()
            Button("刪除檔案夾（裡面的東西移到上一層）") { store.deleteFolder(f.id) }
        }
    }

    private var taskList: some View {
        let list = store.orderedTasks(in: m.effectiveFolder)
        let favCount = list.filter(\.isFavorite).count
        let subs = store.subfolders(of: m.listFolder)
        return ScrollView {
            VStack(spacing: 2) {
                if let name = newFolderName {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12)).frame(width: 24, alignment: .leading)
                        TextField("檔案夾名稱，按 Return 建立", text: Binding(get: { name }, set: { newFolderName = $0 }))
                            .textFieldStyle(.plain)
                            .onSubmit { if let n = newFolderName, !n.isEmpty { store.newFolder(n, parent: m.listFolder) }; newFolderName = nil }
                            .onExitCommand { newFolderName = nil }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                }
                ForEach(subs) { f in folderRow(f) }
                if !subs.isEmpty && !list.isEmpty { Color.clear.frame(height: 4) }
                if list.isEmpty && subs.isEmpty { Text("這個檔案夾還沒有任務").font(.system(size: 12)).opacity(0.5).padding(.top, 20) }
                ForEach(Array(list.enumerated()), id: \.element.id) { i, t in
                    if i == 0 && favCount > 0 { section("我的最愛") }
                    if i == favCount && favCount > 0 { section("其他任務") }
                    row(t, index: i + 1, list: list, favCount: favCount)
                }
                Button { store.newTask(folder: m.effectiveFolder); m.controller?.clearForward(); m.showList = false; m.focusToken += 1 } label: {
                    Label("新增任務", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, 8)
                }.buttonStyle(.plain).opacity(0.7)
            }
        }
    }

    private func section(_ s: String) -> some View {
        Text(s).font(.system(size: 10.5, weight: .semibold)).opacity(0.45)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6).padding(.horizontal, 8)
    }

    // 按住拖曳排序：只在同一區（我的最愛／其他任務）裡移動
    private func sectionRange(_ i: Int, favCount: Int, total: Int) -> ClosedRange<Int> {
        i < favCount ? 0...(favCount - 1) : favCount...(total - 1)
    }
    private func dragTarget(favCount: Int, total: Int) -> Int? {
        guard let id = dragID, let from = dragFrom else { return nil }
        _ = id
        let r = sectionRange(from, favCount: favCount, total: total)
        let step = Int((dragDY / max(rowHeight + 2, 1)).rounded())
        return min(max(from + step, r.lowerBound), r.upperBound)
    }

    private func row(_ t: NoteTask, index: Int, list: [NoteTask], favCount: Int) -> some View {
        let selected = t.id == store.currentTaskID
        let i = index - 1
        let dragging = dragID == t.id
        var shift: CGFloat = 0
        if let from = dragFrom, let to = dragTarget(favCount: favCount, total: list.count), !dragging,
           sectionRange(from, favCount: favCount, total: list.count).contains(i) {
            if from < i && i <= to { shift = -(rowHeight + 2) }
            if to <= i && i < from { shift = rowHeight + 2 }
        }
        return HStack(spacing: 8) {
            Text(index <= 9 ? "⌘\(index)" : "").font(.system(size: 10, design: .rounded)).opacity(0.35).frame(width: 24, alignment: .leading)
            Text(t.title).font(Font(prefs.fontStyle.font(size: 13, bold: selected))).lineLimit(1)
            Spacer()
            let n = t.uncheckedItems.count
            if n > 0 { Text("\(n)").font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 1).background(fg.opacity(0.1), in: Capsule()) }
            if !t.cards.isEmpty { Image(systemName: "rectangle.stack").font(.system(size: 10)).opacity(0.5) }
            if t.isFavorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(rowFill(t, selected: selected, dragging: dragging), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { rowHeight = $0 } }
        .offset(y: dragging ? dragDY : shift)
        .scaleEffect(dragging ? 1.02 : 1)
        .shadow(color: .black.opacity(dragging ? 0.3 : 0), radius: 6, y: 2)
        .zIndex(dragging ? 1 : 0)
        .animation(dragging ? nil : .easeOut(duration: 0.15), value: shift)
        .onTapGesture {
            m.controller?.clearForward()
            store.currentTaskID = t.id
            withAnimation(.easeOut(duration: 0.15)) { m.showList = false }
            m.focusToken += 1
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { v in
                if dragID == nil { dragID = t.id; dragFrom = i }
                dragDY = v.translation.height
            }
            .onEnded { _ in
                if let from = dragFrom, let to = dragTarget(favCount: favCount, total: list.count), from != to {
                    var ids = list.map(\.id)
                    let moved = ids.remove(at: from)
                    ids.insert(moved, at: to)
                    let favIDs = Array(ids.prefix(favCount)), others = Array(ids.dropFirst(favCount))
                    if from < favCount { store.reorderFavorites(favIDs) } else { store.reorder(others) }
                }
                dragID = nil; dragFrom = nil; dragDY = 0
            })
        .contextMenu {
            Button(t.isFavorite ? "從我的最愛移除" : "加入我的最愛") { store.toggleFavorite(t.id) }
            if t.isFavorite {
                Button("將我的最愛上移") { store.moveFavorite(t.id, by: -1) }
                Button("將我的最愛下移") { store.moveFavorite(t.id, by: 1) }
            } else {
                Button("上移") { store.moveInList(t.id, by: -1) }
                Button("下移") { store.moveInList(t.id, by: 1) }
            }
            Menu("底色") {
                Button("無") { store.setColor(t.id, nil) }
                ForEach(TaskColor.allCases) { c in Button(c.label) { store.setColor(t.id, c) } }
            }
            Menu("移到檔案夾") { folderMenu { store.move(t.id, toFolder: $0 ?? store.defaultFolder.id) } }
            Divider()
            Button("刪除任務") { store.delete(t.id) }
        }
    }

    private func rowFill(_ t: NoteTask, selected: Bool, dragging: Bool) -> Color {
        if let c = t.taskColor?.color { return c.opacity(dragging ? 0.5 : (selected ? 0.42 : 0.28)) }
        return fg.opacity(dragging ? 0.16 : (selected ? 0.1 : 0))
    }

    private var deletedList: some View {
        let list = store.deletedTasks
        return VStack(spacing: 4) {
            HStack {
                Text("移到「最近刪除」30 天後會被永久刪除。").font(.system(size: 10.5)).opacity(0.5)
                Spacer()
                if !list.isEmpty {
                    Button("全部復原") { store.restoreAllDeleted() }.buttonStyle(.plain).font(.system(size: 11))
                    Button(confirmPurge == UUID.zero ? "確定全部永久刪除？" : "全部刪除") {
                        if confirmPurge == UUID.zero { store.purgeAllDeleted(); confirmPurge = nil } else { confirmPurge = UUID.zero }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    if list.isEmpty { Text("最近刪除是空的").font(.system(size: 12)).opacity(0.5).padding(.top, 20) }
                    ForEach(list) { t in
                        HStack {
                            Text(t.title).font(Font(prefs.fontStyle.font(size: 13))).lineLimit(1)
                            Spacer()
                            Text(relativeTime(t.deletedAt!)).font(.system(size: 10)).opacity(0.4)
                            Button("復原") { store.restore(t.id) }.buttonStyle(.plain).font(.system(size: 11))
                            Button(confirmPurge == t.id ? "確定？" : "永久刪除") {
                                if confirmPurge == t.id { store.purge(t.id); confirmPurge = nil } else { confirmPurge = t.id }
                            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.red)
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                    }
                }
            }
        }
    }
}

extension UUID { static let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) }
