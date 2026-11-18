import Testing
@testable import FineTuneKit

@Suite
struct SettleMuteRuleTests {
    @Test func bluetoothSettlingFlagUnsetChangedMuteTrueIsAccepted() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: true, flagSet: false, muted: true, recordedMute: false) == .recordUserMuteAndSetFlag)
    }

    @Test func bluetoothSettlingFlagUnsetChangedUnmuteIsEnforced() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: true, flagSet: false, muted: false, recordedMute: true) == .enforce)
    }

    @Test func bluetoothSettlingFlagSetChangedMuteIsRecorded() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: true, flagSet: true, muted: true, recordedMute: false) == .recordUserMute)
    }

    @Test func bluetoothSettlingFlagSetChangedUnmuteIsRecorded() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: true, flagSet: true, muted: false, recordedMute: true) == .recordUserMute)
    }

    @Test func matchingRecordedMuteIsIgnoredForEveryFlagAndMuteValue() {
        for flagSet in [false, true] {
            for muted in [false, true] {
                #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: true, flagSet: flagSet, muted: muted, recordedMute: muted) == .ignore)
            }
        }
    }

    @Test func outsideSettlingRecordsChangedMute() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: false, flagSet: false, muted: true, recordedMute: false) == .recordUserMute)
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: false, flagSet: false, muted: false, recordedMute: true) == .recordUserMute)
    }

    @Test func unarmedIsIgnoredByMuteCallback() {
        #expect(SettleMuteRule.decide(armed: false, selected: true, isBluetooth: true, settling: true, flagSet: false, muted: true, recordedMute: false) == .ignore)
    }

    /// 回歸：沒勾選的裝置被別人解除靜音時，回報值（false）剛好等於預設記錄（false），仍然必須重新靜音（規則 1）。
    @Test func unselectedDeviceIsEnforcedEvenWhenReportMatchesRecordedMute() {
        for settling in [false, true] {
            for bluetooth in [false, true] {
                #expect(SettleMuteRule.decide(armed: true, selected: false, isBluetooth: bluetooth, settling: settling, flagSet: false, muted: false, recordedMute: false) == .enforce)
            }
        }
    }

    /// 非藍牙的已勾選裝置：穩定期內即使回報值與記錄相同也照原行為 enforce。
    @Test func nonBluetoothSettlingEnforcesEvenWhenReportMatchesRecordedMute() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: false, settling: true, flagSet: false, muted: false, recordedMute: false) == .enforce)
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: false, settling: true, flagSet: false, muted: true, recordedMute: true) == .enforce)
    }

    /// 非藍牙且穩定期外（有線裝置、App 啟動前就連著的裝置）：照原行為記成使用者的靜音。
    @Test func nonBluetoothOutsideSettlingRecordsMute() {
        for muted in [false, true] {
            #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: false, settling: false, flagSet: false, muted: muted, recordedMute: !muted) == .recordUserMute)
        }
    }

    @Test func bluetoothOutsideSettlingRecordsMuteEvenWhenFlagIsSet() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: true, settling: false, flagSet: true, muted: true, recordedMute: false) == .recordUserMute)
    }

    @Test func unselectedDeviceIsEnforced() {
        #expect(SettleMuteRule.decide(armed: true, selected: false, isBluetooth: true, settling: true, flagSet: false, muted: true, recordedMute: false) == .enforce)
    }

    @Test func nonBluetoothSettlingMuteChangesAreEnforced() {
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: false, settling: true, flagSet: false, muted: true, recordedMute: false) == .enforce)
        #expect(SettleMuteRule.decide(armed: true, selected: true, isBluetooth: false, settling: true, flagSet: false, muted: false, recordedMute: true) == .enforce)
    }
}
