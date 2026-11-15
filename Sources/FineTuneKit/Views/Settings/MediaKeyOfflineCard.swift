// FineTune/Views/Settings/MediaKeyOfflineCard.swift
import SwiftUI

/// Inline card shown when `MediaKeyStatus.isOffline` is `true` (kernel-stall path only;
/// AX revocation surfaces via the permission card instead).
@MainActor
struct MediaKeyOfflineCard: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: DesignTokens.Dimensions.settingsIconWidth, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text("媒體鍵目前無法使用")
                        .font(DesignTokens.Typography.rowNameBold)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                }

                Text("系統已停用 FineTune 的按鍵監聽，通常是電腦睡眠喚醒或主執行緒停頓後發生。請重試以重新啟用。")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                        Text("重試")
                    }
                    .font(DesignTokens.Typography.pickerText)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                }
                .buttonStyle(.plain)
                .glassButtonStyle()
                .padding(.top, 2)
                .accessibilityHint("重新啟用媒體鍵監聽。")
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("媒體鍵目前無法使用。請重試以重新啟用按鍵監聽。")
    }
}

// MARK: - Previews

#Preview("Offline Card") {
    PreviewContainer {
        MediaKeyOfflineCard(onRetry: {})
            .frame(width: 420)
            .padding()
    }
}
