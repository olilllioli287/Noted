import Foundation
import Testing
@testable import FineTuneKit

// 輸出選取策略的純決策。裝置用使用者舉的例子：MacBook 喇叭、耳機。
private let mac = "BuiltInSpeakerDevice"
private let phones = "Headphones"

private func state(selected: [String], volumes: [String: Float] = [:], userMutes: [String: Bool] = [:], armed: Bool = true) -> OutputPolicyState {
    var s = OutputPolicyState()
    s.armed = armed
    s.selected = selected
    s.volumes = volumes
    s.userMutes = userMutes
    return s
}

@Suite struct OutputPolicyPlannerTests {
    @Test func volumeMutedDeviceDoesNotRecordObservedVolume() {
        #expect(OutputPolicy.shouldRecordVolume(uid: "uid.a", volumeMuted: ["uid.a"]) == false)
        #expect(OutputPolicy.shouldRecordVolume(uid: "uid.b", volumeMuted: ["uid.a"]) == true)
    }
    @Test func toggle決策為單選() {
        #expect(OutputPolicyPlanner.nextSelection(current: [], toggled: mac) == [mac])
        #expect(OutputPolicyPlanner.nextSelection(current: [mac], toggled: mac) == [])
        #expect(OutputPolicyPlanner.nextSelection(current: [mac], toggled: phones) == [phones])
    }

    @Test func 舊設定多選收斂成單選() {
        #expect(OutputPolicyPlanner.collapse(selected: [mac, phones], defaultUID: phones, orderedUIDs: [mac, phones]) == [phones])
        #expect(OutputPolicyPlanner.collapse(selected: [mac, phones], defaultUID: "other", orderedUIDs: [phones, mac]) == [phones])
        #expect(OutputPolicyPlanner.collapse(selected: [mac, phones], defaultUID: "other", orderedUIDs: []) == [mac])
        #expect(OutputPolicyPlanner.collapse(selected: [], defaultUID: mac, orderedUIDs: [mac]) == [])
        #expect(OutputPolicyPlanner.collapse(selected: [phones], defaultUID: mac, orderedUIDs: [mac]) == [phones])
    }

    @Test func 還沒接管時什麼都不做() {
        let s = state(selected: [], armed: false)
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false)]
        #expect(OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac).isEmpty)
    }

    @Test func 沒勾選的裝置被靜音() {
        let s = state(selected: [phones])
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false), PolicyDevice(uid: phones, volume: 0.5, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: phones)
        #expect(plan == [.setMute(uid: mac, muted: true)])
    }

    /// 「我已經讓 macbook 暗掉了，斷開耳機後還是一樣不會外放」
    @Test func 只勾耳機_耳機斷線後喇叭本來就是靜音_不用做任何事() {
        let s = state(selected: [phones], volumes: [mac: 1, phones: 0.5])
        // 耳機走了，macOS 把預設輸出切回喇叭；喇叭之前已經被策略靜音
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: true)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac)
        #expect(plan.isEmpty)
        #expect(OutputPolicyPlanner.targets(state: s, connected: [mac]).isEmpty)
    }

    /// 「複選兩個（50% 耳機、0% macbook），耳機斷開，macbook 有聲音但是 0%」
    @Test func 兩個都勾_耳機斷線後喇叭維持自己的零音量() {
        let s = state(selected: [mac, phones], volumes: [mac: 0, phones: 0.5])
        let devices = [PolicyDevice(uid: mac, volume: 0, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac)
        #expect(plan.isEmpty)   // 不解除靜音以外的事、不動音量
        #expect(OutputPolicyPlanner.targets(state: s, connected: [mac]) == [mac])
    }

    @Test func 都不勾_全部靜音_預設輸出不動() {
        let s = state(selected: [])
        let devices = [PolicyDevice(uid: mac, volume: 0.8, muted: false), PolicyDevice(uid: phones, volume: 0.5, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac)
        #expect(plan == [.setMute(uid: mac, muted: true), .setMute(uid: phones, muted: true)])
    }

    @Test func 預設輸出被改到沒勾選的裝置_切回勾選裡的第一個() {
        let s = state(selected: [phones])
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: true), PolicyDevice(uid: phones, volume: 0.5, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac)
        #expect(plan == [.setDefault(uid: phones)])
    }

    @Test func 預設輸出已經在勾選裡就不動() {
        let s = state(selected: [mac, phones])
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false), PolicyDevice(uid: phones, volume: 0.5, muted: false)]
        #expect(OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: phones).isEmpty)
        #expect(OutputPolicyPlanner.targets(state: s, connected: [mac, phones]) == [mac, phones])
    }

    @Test func 重新連上_還原自己記住的音量() {
        let s = state(selected: [mac, phones], volumes: [mac: 1, phones: 0.5])
        // 耳機重連，韌體把音量報成 1.0
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false), PolicyDevice(uid: phones, volume: 1, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac, restoreVolumeFor: [phones])
        #expect(plan == [.setVolume(uid: phones, volume: 0.5)])
        // 不在「剛連上」的期間，音量差異是使用者自己調的，不蓋回去
        #expect(OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac).isEmpty)
    }

    /// 裝置一直接著、沒勾選時被策略靜音；重新勾起來：解除靜音＋還原它自己記住的音量
    @Test func 重新勾起來_解除靜音並還原音量() {
        let s = state(selected: [mac, phones], volumes: [mac: 1, phones: 0.5], userMutes: [phones: false])
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false), PolicyDevice(uid: phones, volume: 0.9, muted: true)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac, restoreVolumeFor: [phones])
        #expect(plan == [.setVolume(uid: phones, volume: 0.5), .setMute(uid: phones, muted: false)])
    }

    /// 記住的是 0%：重新勾起來也還是 0%，不會因為解除靜音就有聲音
    @Test func 記住零音量的裝置重新勾起來還是零() {
        let s = state(selected: [mac], volumes: [mac: 0], userMutes: [mac: false])
        let devices = [PolicyDevice(uid: mac, volume: 0.5, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac, restoreVolumeFor: [mac])
        #expect(plan == [.setVolume(uid: mac, volume: 0)])
    }

    @Test func 重連的裝置沒勾選_只靜音不動音量() {
        let s = state(selected: [mac], volumes: [mac: 1, phones: 0.5])
        let devices = [PolicyDevice(uid: mac, volume: 1, muted: false), PolicyDevice(uid: phones, volume: 1, muted: false)]
        let plan = OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: mac, restoreVolumeFor: [phones])
        #expect(plan == [.setMute(uid: phones, muted: true)])
    }

    @Test func 勾選的裝置_靜音照使用者自己設的() {
        let s = state(selected: [mac], userMutes: [mac: true])
        #expect(OutputPolicyPlanner.plan(state: s, devices: [PolicyDevice(uid: mac, volume: 0.4, muted: true)], defaultUID: mac).isEmpty)
        #expect(OutputPolicyPlanner.plan(state: s, devices: [PolicyDevice(uid: mac, volume: 0.4, muted: false)], defaultUID: mac)
                == [.setMute(uid: mac, muted: true)])
        // 之前被策略靜音、現在勾起來：解除靜音
        let s2 = state(selected: [mac], userMutes: [mac: false])
        #expect(OutputPolicyPlanner.plan(state: s2, devices: [PolicyDevice(uid: mac, volume: 0.4, muted: true)], defaultUID: mac)
                == [.setMute(uid: mac, muted: false)])
    }

    @Test func 音量差在取整誤差內不重寫() {
        let s = state(selected: [phones], volumes: [phones: 0.5])
        let devices = [PolicyDevice(uid: phones, volume: 0.51, muted: false)]
        #expect(OutputPolicyPlanner.plan(state: s, devices: devices, defaultUID: phones, restoreVolumeFor: [phones]).isEmpty)
    }

    @Test func 舊設定檔沒有這一段也讀得進來() throws {
        let decoded = try JSONDecoder().decode(OutputPolicyState.self, from: Data("{}".utf8))
        #expect(decoded == OutputPolicyState())
        let bad = try JSONDecoder().decode(OutputPolicyState.self, from: Data(#"{"volumes":{"a":7,"b":-1}}"#.utf8))
        #expect(bad.volumes == ["a": 1, "b": 0])
    }
}

@Suite struct FollowPlannerTests {
    @Test func 斷線目標過濾後為空則策略靜音() {
        let plan = FollowPlanner.plan(armed: true, targets: [], defaultUID: "x")
        #expect(plan.policyMuted)
    }

    @Test func 接管且沒有目標時不送出並策略靜音() {
        let plan = FollowPlanner.plan(armed: true, targets: [], defaultUID: "system")
        #expect(plan.devices.isEmpty)
        #expect(plan.policyMuted)
    }

    @Test func 接管且有目標時送到目標且不靜音() {
        let plan = FollowPlanner.plan(armed: true, targets: ["chosen"], defaultUID: "system")
        #expect(plan.devices == ["chosen"])
        #expect(!plan.policyMuted)
    }

    @Test func 未接管時跟隨系統預設且不靜音() {
        let plan = FollowPlanner.plan(armed: false, targets: ["ignored"], defaultUID: "system")
        #expect(plan.devices == ["system"])
        #expect(!plan.policyMuted)
    }

    @Test func 接管無目標且沒有系統預設() {
        let plan = FollowPlanner.plan(armed: true, targets: [], defaultUID: nil)
        #expect(plan.devices.isEmpty)
        #expect(plan.policyMuted)
    }
}

@Suite struct PolicyMuteRuleTests {
    @Test func 沒接管不靜音() {
        #expect(!PolicyMuteRule.shouldMute(armed: false, targets: [], tapDevices: ["A"]))
    }
    @Test func 接管且無目標_靜音() {
        #expect(PolicyMuteRule.shouldMute(armed: true, targets: [], tapDevices: ["A"]))
    }
    @Test func tap還掛在沒選的裝置_即使已有目標也先靜音() {
        #expect(PolicyMuteRule.shouldMute(armed: true, targets: ["B"], tapDevices: ["A"]))
    }
    @Test func tap已在選中的裝置_不靜音() {
        #expect(!PolicyMuteRule.shouldMute(armed: true, targets: ["B"], tapDevices: ["B"]))
        #expect(!PolicyMuteRule.shouldMute(armed: true, targets: ["B"], tapDevices: ["A", "B"]))
    }
}

