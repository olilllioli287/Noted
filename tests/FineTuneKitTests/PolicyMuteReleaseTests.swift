import Foundation
import Testing
@testable import FineTuneKit

@Suite
struct PolicyMuteReleaseTests {
    @Test
    func extractsMutedUIDs() {
        let json: [String: Any] = ["outputPolicy": ["policyMuted": ["uid.a", "uid.b"], "armed": true]]
        #expect(PolicyMuteRelease.mutedUIDs(in: json) == ["uid.a", "uid.b"])
    }

    @Test
    func clearsMuteStateAndPreservesOtherKeys() throws {
        let json: [String: Any] = ["other": ["keep": 7], "outputPolicy": ["policyMuted": ["uid.a"], "volumeMuted": ["uid.b"], "armed": true, "selected": ["uid.c"]]]
        let changed = try #require(PolicyMuteRelease.clearingMuteState(in: json) as? [String: Any])
        let policy = try #require(changed["outputPolicy"] as? [String: Any])
        #expect(policy["policyMuted"] as? [String] == [])
        #expect(policy["volumeMuted"] as? [String] == [])
        #expect(policy["armed"] as? Bool == false)
        #expect(policy["selected"] as? [String] == ["uid.c"])
        #expect((changed["other"] as? [String: Int])?["keep"] == 7)
    }

    @Test
    func pendingCountUsesUIDUnion() {
        let json: [String: Any] = ["outputPolicy": ["policyMuted": ["uid.a", "uid.b"], "volumeMuted": ["uid.b", "uid.c"]]]
        #expect(PolicyMuteRelease.pendingCount(in: json) == 3)
    }

    @Test
    func pendingCountIncludesOnlyVolumeMutedUIDs() {
        let json: [String: Any] = ["outputPolicy": ["policyMuted": [String](), "volumeMuted": ["uid.a"]]]
        #expect(PolicyMuteRelease.pendingCount(in: json) == 1)
    }

    @Test
    func oldOutputPolicyStateDecodesWithoutVolumeMuted() throws {
        let oldJSON = #"{"armed":true,"selected":["uid.a"],"volumes":{"uid.a":0.4},"userMutes":{},"policyMuted":[]}"#
        let decoded = try JSONDecoder().decode(OutputPolicyState.self, from: Data(oldJSON.utf8))
        #expect(decoded.volumeMuted.isEmpty)
    }
}
