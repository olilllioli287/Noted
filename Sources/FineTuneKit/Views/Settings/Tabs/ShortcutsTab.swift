// FineTune/Views/Settings/Tabs/ShortcutsTab.swift
import SwiftUI
import KeyboardShortcuts

@MainActor
struct ShortcutsTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var accessibility: AccessibilityPermissionService
    @Bindable var mediaKeyStatus: MediaKeyStatus
    let mediaKeyMonitor: MediaKeyMonitor
    let shortcutsRegistry: ShortcutsRegistry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                volumeSection
                mediaKeysSection
                hotkeysSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: settings.appSettings.mediaKeyControlEnabled) { _, _ in
            mediaKeyMonitor.reconcile()
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("音量") {
            SettingsRow(
                "音量調整幅度",
                description: "每按一次按鍵要調整多少音量，適用於媒體鍵、自訂快速鍵和彈出面板中的方向鍵。"
            ) {
                Picker("", selection: $settings.appSettings.volumeHotkeyStep) {
                    ForEach(VolumeHotkeyStep.allCases) { step in
                        Text(step.description).tag(step)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - Media Keys

    private var mediaKeysSection: some View {
        SettingsSection("媒體鍵") {
            SettingsRow(
                "使用媒體鍵控制",
                description: "使用 F11／F12（或音量鍵）控制 FineTune"
            ) {
                Toggle("", isOn: $settings.appSettings.mediaKeyControlEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if !accessibility.isTrustedCached {
                SettingsRowDivider()
                AccessibilityPromptStrip(accessibility: accessibility)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if mediaKeyStatus.isOffline {
                SettingsRowDivider()
                MediaKeyOfflineCard {
                    mediaKeyMonitor.reconcile()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            if settings.appSettings.mediaKeyControlEnabled && accessibility.isTrustedCached {
                SettingsRowDivider()
                SettingsRow(
                    "音量提示樣式",
                    description: "音量指示器的顯示方式"
                ) {
                    HUDStyleSegmentedControl(selection: $settings.appSettings.hudStyle)
                }
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysSection: some View {
        SettingsSection("快速鍵") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsRowDivider() }
                SettingsRow(
                    action.displayName,
                    description: description(for: action)
                ) {
                    KeyboardShortcuts.Recorder(
                        for: shortcutsRegistry.name(for: action),
                        onChange: shortcutsRegistry.recordCallback(for: action)
                    )
                }
            }
        }
    }

    private func description(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopup: "顯示或隱藏選單列面板"
        case .targetAppVolumeUp: "調高播放音訊的 App 音量"
        case .targetAppVolumeDown: "調低播放音訊的 App 音量"
        case .targetAppMuteToggle: "切換播放音訊的 App 靜音狀態"
        }
    }
}
