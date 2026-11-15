import AppKit
import SwiftUI
import KeyboardShortcuts
import ShotLineKit
import FineTuneKit

// 合併的設定視窗（第二輪需求 4）：原本的「Noted 設定」六個分頁、「音量設定（FineTune）」視窗、
// 右欄選單裡的截圖選項，全部收進這一個視窗，左邊側邊欄分頁。設計見 docs/notch-suite-設計.md 8.6。

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, layout, notes, audio, shots, shortcuts, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "一般"; case .appearance: "外觀"; case .layout: "版面"; case .notes: "筆記"
        case .audio: "音量"; case .shots: "截圖"; case .shortcuts: "快速鍵"; case .about: "關於"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"; case .appearance: "paintpalette"; case .layout: "rectangle.split.3x1"
        case .notes: "square.and.pencil"; case .audio: "speaker.wave.2"; case .shots: "tshirt"
        case .shortcuts: "keyboard"; case .about: "info.circle"
        }
    }
    /// 這一頁裡面再分的小分頁（沒有就是空的）
    var subs: [String] {
        switch self {
        case .audio: ["輸出", "一般", "音訊"]
        case .shortcuts: ["Noted", "音量的全域快捷鍵"]
        default: []
        }
    }
}

/// 設定視窗現在看哪一頁（從別處打開設定時可以指定）
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var pane: SettingsPane = .general { didSet { if pane != oldValue { sub = 0 } } }
    @Published var sub = 0
}

struct UnifiedSettingsView: View {
    static let defaultSize = NSSize(width: 820, height: 600)

    @ObservedObject var nav = SettingsNav.shared
    @ObservedObject var prefs = Prefs.shared

    private var hud: Bool { prefs.isHUD }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            if hud {
                Rectangle().fill(HUDLook.lineColor.opacity(0.5)).frame(width: 1).shadow(color: HUDLook.lineColor.opacity(0.6), radius: 3)
            } else {
                Divider()
            }
            VStack(spacing: 0) {
                if !nav.pane.subs.isEmpty {
                    Picker("", selection: $nav.sub) {
                        ForEach(Array(nav.pane.subs.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background {
            if hud {
                ZStack { HUDLook.backgroundSolid.swiftUI; HUDGrid() }.ignoresSafeArea()
            }
        }
        .hudFont(hud)
        .tint(hud ? HUDLook.lineColor : nil)
        .preferredColorScheme(hud ? .dark : nil)
        .background(SettingsWindowStyler(hud: hud))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: hud ? 6 : 2) {
            ForEach(SettingsPane.allCases) { pane in
                let selected = nav.pane == pane
                Button { nav.pane = pane } label: {
                    Label(pane.title, systemImage: pane.icon)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .tracking(hud ? 2 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(hud ? (selected ? Color.white : HUDLook.text.swiftUI) : (selected ? Color.white : Color.primary))
                        .background {
                            if !hud {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear)
                            }
                        }
                        .hudCell(hud, active: selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 150)
    }

    @ViewBuilder private var detail: some View {
        switch nav.pane {
        case .general: form { GeneralSettings() }
        case .appearance: form { AppearanceSettings() }
        case .layout: form { LayoutSettings() }
        case .notes: form { ReminderSettings(); DataSettings() }
        case .audio:
            switch nav.sub {
            case 1: FineTuneSettingsPane(.general)
            case 2: FineTuneSettingsPane(.audio)
            default: form { AudioSettings() }
            }
        case .shots: form { ShotSettings() }
        case .shortcuts:
            if nav.sub == 1 { FineTuneSettingsPane(.shortcuts) } else { ShortcutSettings().padding(16) }
        case .about: AboutPane()
        }
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(hud ? .hidden : .automatic)
    }
}

/// 科幻藍時把視窗本身也換成深色、標題列透明（SwiftUI 的底色才會延伸到標題列）
private struct SettingsWindowStyler: NSViewRepresentable {
    let hud: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let hud = hud
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.titlebarAppearsTransparent = hud
            window.backgroundColor = hud ? HUDLook.backgroundSolid : .windowBackgroundColor
            window.appearance = hud ? NSAppearance(named: .darkAqua) : nil
        }
    }
}

// MARK: - 版面

struct LayoutSettings: View {
    @ObservedObject var suite = SuitePrefs.shared

    private func refreshPanels() { AppDelegate.shared.controllers.forEach { $0.refreshGeometry() } }

    var body: some View {
        Section("面板") {
            Toggle("三欄面板（音量｜筆記｜截圖）", isOn: Binding(get: { suite.threeColumns }, set: { suite.threeColumns = $0; refreshPanels() }))
            ratio("寬度（佔螢幕）", $suite.widthRatio, 0.4...0.98)
            ratio("高度（佔螢幕）", $suite.heightRatio, 0.2...0.9)
            ratio("音量欄", $suite.leftRatio, 0.15...0.4)
            ratio("截圖欄", $suite.rightRatio, 0.15...0.4)
            Button("回復預設大小") { suite.resetLayout(); refreshPanels() }
            Text("面板寬度不到 820 點的螢幕（例如 iPhone 當副螢幕）會改成一次看一欄。也可以直接拖面板右下角調整大小。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func ratio(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range) { editing in if !editing { refreshPanels() } }
            Text(String(format: "%.0f%%", value.wrappedValue * 100)).monospacedDigit().frame(width: 44)
        }
    }
}

// MARK: - 音量（Noted 這一層的；上游的選項在「一般」「音訊」兩個小分頁）

struct AudioSettings: View {
    @ObservedObject var suite = SuitePrefs.shared
    @ObservedObject var audio = FineTuneModule.shared
    @State private var refreshToken = 0

    var body: some View {
        Section("音量（FineTune）") {
            let stored = PolicyMuteRelease.readSettings()
            let pendingCount = PolicyMuteRelease.pendingCount(in: stored)
            let _ = refreshToken
            Toggle("啟用", isOn: Binding(get: { suite.audioEnabled }, set: { SuiteHost.setAudioEnabled($0) }))
            Text("通話 App 不經過 Noted，避免進語音時爆音").font(.caption).foregroundStyle(.secondary)
            Text(status).font(.caption).foregroundStyle(.secondary)
            if !suite.audioEnabled, pendingCount > 0 {
                Button("解除被靜音的輸出裝置（\(pendingCount) 個）") {
                    if audio.state == .running { audio.disarmOutputPolicy() }
                    else { _ = PolicyMuteRelease.releaseStoredMutes() }
                    refreshToken &+= 1
                }
                .disabled(audio.state == .standby)
                if audio.state == .standby {
                    Text("獨立版 FineTune 還在執行，請先結束它再解除。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("解除因輸出策略而靜音的裝置，並清除已記錄的接管狀態。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if audio.state == .running {
            Section("輸出裝置的接管") {
                if audio.outputPolicyArmed {
                    Button("停止接管輸出裝置") { FineTuneModule.shared.disarmOutputPolicy() }
                    Text("停止後，被取消勾選而靜音的裝置會解除靜音，行為回到原本的 FineTune（點哪個哪個是預設輸出）。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("還沒接管。在面板左欄勾選任何一個裝置就會開始。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("EQ、AutoEQ、各 App 的輸出、輸入裝置在面板左欄右上角的完整面板裡。其他音量選項在上面的「一般」「音訊」兩頁，全域快捷鍵在「快速鍵」頁。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        switch audio.state {
        case .running: !suite.audioEnabled ? "已關閉，目前還在執行，下次開啟 Noted 時才會停止。" : (audio.needsCapturePermission ? "執行中。還沒有「螢幕與系統錄音」權限：各 App 音量不能用。" : "執行中。")
        case .standby: "獨立版 FineTune 還在執行，結束它之後這裡會自動接手。"
        case .off: suite.audioEnabled ? "尚未啟動。" : "已關閉。關閉在下次開啟 Noted 時生效。"
        }
    }
}

// MARK: - 截圖

struct ShotSettings: View {
    @ObservedObject var suite = SuitePrefs.shared
    @ObservedObject var shot = ShotLineModule.shared

    var body: some View {
        Section("截圖（ShotLine）") {
            Toggle("啟用", isOn: Binding(get: { suite.shotEnabled }, set: { SuiteHost.setShotEnabled($0) }))
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        Section("瀏海提示") {
            Toggle("截圖後在瀏海提示", isOn: $suite.shotPeek)
            HStack {
                Text("提示停留").frame(width: 110, alignment: .leading)
                // 不用 step：60 格刻度會擠成一排線；改成放手的值取整數
                Slider(value: Binding(get: { suite.shotPeekSeconds }, set: { suite.shotPeekSeconds = $0.rounded() }), in: SuitePrefs.shotPeekRange)
                Text("\(Int(suite.shotPeekSeconds)) 秒").monospacedDigit().frame(width: 44)
            }
            .disabled(!suite.shotPeek)
            Text("游標停在提示上不計時，移開後重新算。這跟下面「自動收進截圖資料夾」的時間是分開的。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if shot.state == .running {
            Section("截圖怎麼處理") {
                Toggle("接管系統截圖（截完馬上掛上，不經過桌面）", isOn: Binding(get: { shot.inboxEnabled }, set: { shot.inboxEnabled = $0 }))
                    .disabled(ShotLineModule.testDirectory != nil)   // 測試模式只看暫存資料夾（原本右欄選單也是鎖住的）
                Toggle("拷貝的圖片也掛上", isOn: Binding(get: { shot.clipboardEnabled }, set: { shot.clipboardEnabled = $0 }))
                Picker("自動收進截圖資料夾", selection: Binding(get: { shot.keepDelay ?? 0 }, set: { shot.keepDelay = $0 == 0 ? nil : $0 })) {
                    ForEach(ShotLineModule.keepDelayChoices, id: \.self) { s in
                        Text(s < 60 ? "\(Int(s)) 秒後" : "\(Int(s / 60)) 分鐘後").tag(s)
                    }
                    Text("不自動收").tag(0.0)
                }
                Toggle("收進截圖資料夾後還留在右欄（最多 \(ShotLineModule.columnCapacity) 張）", isOn: Binding(get: { shot.staysAfterKeep }, set: { shot.staysAfterKeep = $0 }))
                Toggle("拖出去成功後不保留", isOn: Binding(get: { shot.discardsAfterSend }, set: { shot.discardsAfterSend = $0 }))
                Text("拖給別的 App 或資料夾、對方收下之後，那張不收進截圖資料夾，從右欄拿掉；檔案留 10 分鐘（有些 App 晚一點才讀檔）再移到垃圾桶。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("音效", isOn: Binding(get: { shot.soundOn }, set: { shot.soundOn = $0 }))
            }
            Section("另外監看的資料夾") {
                let folders = ShotLineModule.extraFolderPaths
                if folders.isEmpty { Text("沒有。").foregroundStyle(.secondary) }
                ForEach(folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("打開") { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) }
                        Button("停止監看") { shot.removeExtraFolder(path) }
                    }
                }
                Button("加入資料夾⋯") { shot.addExtraFolder() }.disabled(!shot.canAddExtraFolder)
                Text("存進這些資料夾的新圖片也會掛上來，最多 \(ShotLineModule.maxExtraFolders) 個。").font(.caption).foregroundStyle(.secondary)
            }
            Section("位置") {
                HStack {
                    Text("收好的截圖放在 \((shot.keepFolder.path as NSString).abbreviatingWithTildeInPath)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打開") { NSWorkspace.shared.open(shot.keepFolder) }
                }
            }
        }
    }

    private var status: String {
        switch shot.state {
        case .running: "執行中。"
        case .standby: "獨立版 ShotLine 還在執行，結束它之後這裡會自動接手。"
        case .off: "已關閉。"
        }
    }
}

// MARK: - 關於

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 0) {
            FineTuneSettingsPane(.about)
            Text("Noted 三合一＝瀏海筆記＋ShotLine（MIT）＋FineTune（GPL-3.0）。含 FineTune 的程式碼，所以整個 App 如果要散布，要以 GPL-3.0 釋出原始碼；自己用沒有這個問題。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.bottom, 16)
        }
    }
}

// MARK: - 測試用截圖

enum SettingsSnapshot {
    /// 把設定視窗的某一頁畫在畫面外的無邊框視窗，存成 PNG。不出現在螢幕上、不搶焦點。
    static func take(to path: String, pane: SettingsPane, sub: Int) {
        SettingsNav.shared.pane = pane
        SettingsNav.shared.sub = sub
        let size = UnifiedSettingsView.defaultSize
        let window = NSWindow(contentRect: NSRect(x: 0, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = Prefs.shared.isHUD ? NSAppearance(named: .darkAqua) : NSApp.effectiveAppearance
        window.backgroundColor = .windowBackgroundColor
        // 只畫 view 不會帶到視窗的底色，所以這裡自己墊一層（真的設定視窗不需要）
        let host = NSHostingView(rootView: UnifiedSettingsView().frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            window.orderOut(nil)
        }
    }
}
