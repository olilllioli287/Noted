// FineTune/Views/Settings/Tabs/GeneralTab.swift
import SwiftUI

@MainActor
struct GeneralTab: View {
    @Bindable var settings: SettingsManager
    let onResetAll: () -> Void

    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                generalSection
                menuBarSection
                dataSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .confirmationDialog(
            "要重設所有設定嗎？",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("重設", role: .destructive) { onResetAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("這項操作無法復原。")
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsSection("一般") {
            SettingsRow(
                "登入時開啟",
                description: "登入時自動啟動 FineTune"
            ) {
                Toggle("", isOn: $settings.appSettings.launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "外觀",
                description: "跟隨 macOS，或固定使用淺色／深色"
            ) {
                ThemeTilePicker(selection: $settings.appSettings.appearance)
            }
            SettingsRowDivider()
            SettingsRow(
                "裝置斷線通知",
                description: "音訊裝置斷線時顯示通知"
            ) {
                Toggle("", isOn: $settings.appSettings.showDeviceDisconnectAlerts)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        SettingsSection("選單列") {
            SettingsRow(
                "圖示樣式",
                description: "FineTune 在選單列中的顯示方式"
            ) {
                IconStyleSegmentedControl(selection: $settings.appSettings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(
                "彈出面板大小",
                description: "較小可顯示更多內容，較大看起來更寬鬆。"
            ) {
                PopupSizeTilePicker(selection: $settings.appSettings.popupSize)
            }
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        SettingsSection("資料") {
            SettingsRow(
                "重設所有設定",
                description: "清除所有音量、EQ 和裝置路由設定"
            ) {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Text("重設")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            }
        }
    }
}
