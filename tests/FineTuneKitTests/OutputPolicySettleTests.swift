import AudioToolbox
import AppKit
import Foundation
import Testing
@testable import FineTuneKit

@MainActor
private final class SettleAudioDeviceMonitor: AudioDeviceProviding {
    var outputDevices: [AudioDevice] = []
    var inputDevices: [AudioDevice] = []
    var onDeviceDisconnected: ((String, String) -> Void)?
    var onDeviceConnected: ((String, String) -> Void)?
    var onInputDeviceDisconnected: ((String, String) -> Void)?
    var onInputDeviceConnected: ((String, String) -> Void)?
    func device(for uid: String) -> AudioDevice? { outputDevices.first { $0.uid == uid } }
    func inputDevice(for uid: String) -> AudioDevice? { inputDevices.first { $0.uid == uid } }
    func start() {}
    func stop() {}
}

@MainActor
private final class SettleVolumeMonitor: DeviceVolumeProviding {
    var defaultDeviceID: AudioDeviceID = 1
    var defaultDeviceUID: String? = "settle.device"
    var defaultInputDeviceUID: String?
    var volumes: [AudioDeviceID: Float] = [:]
    var muteStates: [AudioDeviceID: Bool] = [:]
    var onVolumeChanged: ((AudioDeviceID, Float) -> Void)?
    var onMuteChanged: ((AudioDeviceID, Bool) -> Void)?
    var onDefaultDeviceChanged: ((String) -> Void)?
    var onDefaultInputDeviceChanged: ((String) -> Void)?
    func setDefaultDevice(_ deviceID: AudioDeviceID) -> Bool { defaultDeviceID = deviceID; return true }
    func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool { true }
    func setVolume(for deviceID: AudioDeviceID, to volume: Float) { volumes[deviceID] = volume }
    func setMute(for deviceID: AudioDeviceID, to muted: Bool) -> Bool { muteStates[deviceID] = muted; return true }
    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier { .software }
    func start() {}
    func stop() {}
}

@MainActor
@Suite
struct OutputPolicySettleTests {
    private let uid = "settle.device"
    private let deviceID: AudioDeviceID = 1

    private func makePolicy(
        bluetooth: Bool = true,
        recordedMute: Bool = false
    ) throws -> (OutputPolicy, SettleAudioDeviceMonitor, SettleVolumeMonitor, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputPolicySettle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let deviceMonitor = SettleAudioDeviceMonitor()
        deviceMonitor.outputDevices = [AudioDevice(id: deviceID, uid: uid, name: "Example output", icon: nil, supportsAutoEQ: false)]
        let volumeMonitor = SettleVolumeMonitor()
        volumeMonitor.volumes[deviceID] = 0.5
        volumeMonitor.muteStates[deviceID] = recordedMute
        var initial = OutputPolicyState()
        initial.armed = true
        initial.selected = [uid]
        initial.volumes[uid] = 0.5
        initial.userMutes[uid] = recordedMute
        let settings = SettingsManager(directory: directory)
        settings.outputPolicyState = initial
        let policy = OutputPolicy(
            settingsManager: settings,
            deviceMonitor: deviceMonitor,
            volumeMonitor: volumeMonitor,
            transportResolver: { _ in bluetooth ? .bluetooth : .usb }
        )
        policy.dryRun = true
        return (policy, deviceMonitor, volumeMonitor, directory)
    }

    private func withPolicy<T>(bluetooth: Bool = true, recordedMute: Bool = false, _ body: (OutputPolicy, SettleVolumeMonitor) throws -> T) throws -> T {
        let (policy, _, volumeMonitor, directory) = try makePolicy(bluetooth: bluetooth, recordedMute: recordedMute)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(policy, volumeMonitor)
    }

    @Test func bluetoothMuteDuringSettleIsRememberedWithoutEnforceAndKeepsVolumeSettle() throws {
        try withPolicy { policy, _ in
            policy.deviceConnected(uid)
            // deviceConnected 本身 enforce 一次；以下只比較事件前後的 dryRunLog 增量。
            let count = policy.dryRunLog.count
            policy.externalMuteChanged(deviceID, true)
            #expect(policy.state.userMutes[uid] == true)
            #expect(policy.dryRunLog.count == count)
            policy.externalVolumeChanged(deviceID, 0.7)
            #expect(policy.state.volumes[uid] == 0.5)
        }
    }

    @Test func matchingSweepMuteIsIgnoredWithoutFlagOrEnforce() throws {
        try withPolicy(recordedMute: true) { policy, volumeMonitor in
            policy.deviceConnected(uid)
            // deviceConnected 本身 enforce 一次；以下只比較事件前後的 dryRunLog 增量。
            let count = policy.dryRunLog.count
            policy.externalMuteChanged(deviceID, true)
            #expect(policy.state.userMutes[uid] == true)
            #expect(policy.dryRunLog.count == count)
            // 之後裝置真的被解除靜音（假裝置的狀態要跟著變，enforce 才看得到差異）：旗標沒設，照舊蓋回。
            volumeMonitor.muteStates[deviceID] = false
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.dryRunLog.count > count)
        }
    }

    @Test func firstBluetoothUnmuteBeforeAcceptedMuteIsEnforced() throws {
        try withPolicy(recordedMute: true) { policy, volumeMonitor in
            policy.deviceConnected(uid)
            // deviceConnected 本身 enforce 一次；以下只比較事件前後的 dryRunLog 增量。
            let count = policy.dryRunLog.count
            volumeMonitor.muteStates[deviceID] = false   // 裝置真的被解除靜音
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.state.userMutes[uid] == true)
            #expect(policy.dryRunLog.count > count)
        }
    }

    @Test func afterAcceptedMuteAChangedUnmuteIsRecorded() throws {
        try withPolicy { policy, _ in
            policy.deviceConnected(uid)
            policy.externalMuteChanged(deviceID, true)
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.state.userMutes[uid] == false)
        }
    }

    @Test func disconnectResetsSettleMuteFlag() throws {
        try withPolicy { policy, volumeMonitor in
            policy.deviceConnected(uid)
            policy.externalMuteChanged(deviceID, true)       // 接受使用者的靜音、設旗標
            #expect(policy.state.userMutes[uid] == true)
            policy.deviceDisconnected(uid)                    // 斷線：旗標與適用集合都清掉
            policy.deviceConnected(uid)                       // 重連：新的穩定期
            volumeMonitor.muteStates[deviceID] = false        // 裝置重連時自己回報沒靜音
            let count = policy.dryRunLog.count
            policy.externalMuteChanged(deviceID, false)
            // 旗標已重設：這次是「解除靜音」而不是使用者第二次操作，要蓋回而且不改記錄。
            #expect(policy.state.userMutes[uid] == true)
            #expect(policy.dryRunLog.count > count)
        }
    }

    /// 面板自己改了靜音（與記的不同）→ 設旗標：之後同一個穩定期內的「取消靜音」被當成使用者的操作，不蓋回。
    @Test func localMuteChangeSetsFlagSoLaterUnmuteIsRecordedNotEnforced() throws {
        try withPolicy { policy, volumeMonitor in
            policy.deviceConnected(uid)
            volumeMonitor.muteStates[deviceID] = true
            policy.localWrite(deviceID)
            #expect(policy.state.userMutes[uid] == true)
            let count = policy.dryRunLog.count
            volumeMonitor.muteStates[deviceID] = false
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.state.userMutes[uid] == false)   // 記成使用者的取消靜音
            #expect(policy.dryRunLog.count == count)        // 沒有蓋回
        }
    }

    /// 面板只調音量（靜音值沒變）→ 不設旗標：穩定期內的「取消靜音」照原行為蓋回。
    @Test func localVolumeOnlyChangeDoesNotSetFlag() throws {
        try withPolicy(recordedMute: true) { policy, volumeMonitor in
            policy.deviceConnected(uid)
            volumeMonitor.volumes[deviceID] = 0.6
            policy.localWrite(deviceID)
            #expect(policy.state.volumes[uid] == 0.6)
            #expect(policy.state.userMutes[uid] == true)
            let count = policy.dryRunLog.count
            volumeMonitor.muteStates[deviceID] = false      // 裝置自己回報解除靜音
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.state.userMutes[uid] == true)    // 沒有被改寫
            #expect(policy.dryRunLog.count > count)         // 蓋回
        }
    }

    @Test func localWriteOutsideSettleRecordsMuteNormally() throws {
        try withPolicy { policy, volumeMonitor in
            var clock = Date(timeIntervalSince1970: 1_000)
            policy.now = { clock }
            policy.deviceConnected(uid)
            // 把時鐘撥到穩定期外，不必真的等 5 秒。
            clock = clock.addingTimeInterval(OutputPolicy.bluetoothSettleSeconds + 1)
            volumeMonitor.muteStates[deviceID] = true
            policy.localWrite(deviceID)
            #expect(policy.state.userMutes[uid] == true)
            // 旗標沒被設：穩定期外的靜音變化照原行為記進 userMutes。
            policy.externalMuteChanged(deviceID, false)
            #expect(policy.state.userMutes[uid] == false)
        }
    }

    @Test func nonBluetoothMuteDuringSettleKeepsOriginalEnforcement() throws {
        try withPolicy(bluetooth: false) { policy, volumeMonitor in
            policy.deviceConnected(uid)
            let count = policy.dryRunLog.count
            volumeMonitor.muteStates[deviceID] = true   // 裝置真的被靜音了
            policy.externalMuteChanged(deviceID, true)
            #expect(policy.state.userMutes[uid] == false)
            #expect(policy.dryRunLog.count > count)
        }
    }
}
