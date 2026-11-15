// FineTune/Views/Components/PermissionBannerView.swift
import SwiftUI

struct PermissionBannerView: View {
    let permission: AudioRecordingPermission

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)

                Text("需要音訊擷取權限")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                if permission.status == .denied {
                    Text("請前往「系統設定」→「隱私權與安全性」→「螢幕與系統錄音」開啟權限")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }

                actionButton
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }

    @ViewBuilder
    private var actionButton: some View {
        if permission.status == .denied {
            Button("打開系統設定") {
                openSystemAudioSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button("授予權限") {
                permission.request()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
