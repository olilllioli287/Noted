import Testing
@testable import FineTuneKit

@Suite struct VoiceCallAppsTests {
    @Test func Discord本體與子行程都列入() {
        #expect(VoiceCallApps.contains(bundleID: "com.hnc.Discord"))
        #expect(VoiceCallApps.contains(bundleID: "com.hnc.Discord.helper"))
        #expect(VoiceCallApps.contains(bundleID: "com.hnc.Discord.helper.Renderer"))
    }

    @Test func Zoom與一般App() {
        #expect(VoiceCallApps.contains(bundleID: "us.zoom.xos"))
        #expect(!VoiceCallApps.contains(bundleID: "com.google.Chrome"))
        #expect(!VoiceCallApps.contains(bundleID: "com.spotify.client"))
        #expect(!VoiceCallApps.contains(bundleID: nil))
    }

    @Test func 其他通話App與子行程() {
        #expect(VoiceCallApps.contains(bundleID: "com.tinyspeck.slackmacgap.helper"))
        #expect(VoiceCallApps.contains(bundleID: "com.microsoft.teams2.helper"))
        #expect(VoiceCallApps.contains(bundleID: "com.apple.FaceTime"))
        #expect(VoiceCallApps.contains(bundleID: "jp.naver.line.mac"))
    }

    @Test func 名字只是開頭相同的不算() {
        #expect(!VoiceCallApps.contains(bundleID: "com.hnc.DiscordFake"))
        #expect(!VoiceCallApps.contains(bundleID: "us.zoomer.app"))
    }
}
