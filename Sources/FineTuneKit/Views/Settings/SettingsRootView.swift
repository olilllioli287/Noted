// FineTune/Views/Settings/SettingsRootView.swift
import SwiftUI

@MainActor
struct SettingsRootView: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry
    @ObservedObject var updateManager: UpdateManager

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case general, audio, shortcuts, updates, about
        var id: Self { self }
    }

    @State private var selection: Section = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab(
                settings: settings,
                onResetAll: {
                    audioEngine.handleSettingsReset()
                    deviceVolumeMonitor.setSystemFollowDefault()
                }
            )
            .tabItem { Label("一般", systemImage: "gearshape") }
            .tag(Section.general)

            AudioTab(
                settings: settings,
                audioEngine: audioEngine,
                deviceVolumeMonitor: deviceVolumeMonitor
            )
            .tabItem { Label("音訊", systemImage: "speaker.wave.2") }
            .tag(Section.audio)

            ShortcutsTab(
                settings: settings,
                accessibility: accessibility,
                mediaKeyStatus: mediaKeyStatus,
                mediaKeyMonitor: mediaKeyMonitor,
                shortcutsRegistry: shortcutsRegistry
            )
            .tabItem { Label("快速鍵", systemImage: "command") }
            .tag(Section.shortcuts)

            // Noted: 「更新」分頁沒搬（Sparkle 是更新 FineTune 自己用的）

            AboutTab()
                .tabItem { Label("關於", systemImage: "info.circle") }
                .tag(Section.about)
        }
        .frame(width: 720, height: 560)
        .preferredColorScheme(settings.appSettings.appearance.swiftUIColorScheme)
        .background(WindowAppearanceBridge(appearance: settings.appSettings.appearance.nsAppearance))
        .background(WindowTitleBridge(title: "FineTune 設定"))
    }
}
