// Noted：通話類 App 不建立 process tap，避免切換通話音訊模式時造成爆音。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
import Foundation

enum VoiceCallApps {
    /// 完全相同，或是它底下的子行程（例如 com.hnc.Discord.helper.Renderer）
    private static let bundleIDRoots = [
        "com.hnc.Discord", "us.zoom", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "jp.naver.line.mac", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "com.skype.skype", "net.whatsapp.WhatsApp", "org.whispersystems.signal-desktop",
        "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.facebook.archon",
    ]

    static func contains(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDRoots.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }
}
