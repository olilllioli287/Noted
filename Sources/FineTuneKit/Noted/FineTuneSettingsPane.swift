// Noted: 把上游的設定頁（一般／音訊／快捷鍵／關於）放進 Noted 的合併設定視窗。
// 內容就是上游原本的 SwiftUI 檢視，這裡只負責把它們需要的物件接好。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
import SwiftUI

public struct FineTuneSettingsPane: View {
    public enum Tab: Sendable { case general, audio, shortcuts, about }

    private let tab: Tab
    @ObservedObject private var module = FineTuneModule.shared

    public init(_ tab: Tab) { self.tab = tab }

    public var body: some View {
        if tab == .about {
            AboutTab()
        } else if let c = module.settingsContext {
            Group {
                switch tab {
                case .general:
                    GeneralTab(settings: c.settings, onResetAll: {
                        c.engine.handleSettingsReset()
                        c.volumeMonitor.setSystemFollowDefault()
                    })
                case .audio:
                    AudioTab(settings: c.settings, audioEngine: c.engine, deviceVolumeMonitor: c.volumeMonitor)
                case .shortcuts:
                    ShortcutsTab(settings: c.settings, accessibility: c.accessibility, mediaKeyStatus: c.mediaKeyStatus,
                                 mediaKeyMonitor: c.mediaKeyMonitor, shortcutsRegistry: c.shortcutsRegistry)
                case .about:
                    EmptyView()
                }
            }
            // 測試（只算不做）時只看不碰：這幾頁的控制項會直接寫到真的裝置與系統設定
            .allowsHitTesting(!module.isDryRun)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "speaker.slash").font(.system(size: 22)).foregroundStyle(.secondary)
                Text(module.state == .standby ? "獨立版 FineTune 還在執行" : "音量功能沒有在執行")
                Text(module.state == .standby ? "結束它之後，這裡的設定才會出現。" : "在「音量」頁打開之後，這裡的設定才會出現。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
