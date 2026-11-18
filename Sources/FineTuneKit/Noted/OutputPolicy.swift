// Noted: 輸出選取策略。FineTune 原本沒有這個檔；併進 Noted 時新增。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。
//
// 三條隨時成立的規則（「接管」之後才生效，見 OutputPolicyState.armed）：
//   1. 沒勾選的輸出裝置一律靜音。只要它接著就是靜音，不是等聲音跑過去才處理。
//   2. 勾選的裝置：靜音＝使用者自己設的；重新連上時音量還原成它自己記住的值。
//   3. 系統預設輸出一定在勾選的裝置裡；不在，就切到勾選裡排最前面的那個。
// 輸出裝置採單選；「跟隨預設」的 App 仍由 AudioEngine 套用既有路由。
import AudioToolbox
import Foundation
import os

// MARK: - 存檔的狀態

struct OutputPolicyState: Codable, Equatable, Sendable {
    /// 使用者第一次在面板勾選或取消勾選之後才是 true。之前完全不動裝置，行為跟原本的 FineTune 一樣。
    var armed = false
    /// 勾選的輸出裝置（UID）
    var selected: [String] = []
    /// 每個裝置自己記住的音量（UID → 0…1）
    var volumes: [String: Float] = [:]
    /// 每個裝置使用者自己設的靜音
    var userMutes: [String: Bool] = [:]
    /// 因為「沒勾選」而被靜音的裝置。結束或重開時用來還原。
    var policyMuted: [String] = []
    /// 因硬體靜音不可用而被寫成 0 的裝置。
    var volumeMuted: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? false
        selected = try c.decodeIfPresent([String].self, forKey: .selected) ?? []
        volumes = (try c.decodeIfPresent([String: Float].self, forKey: .volumes) ?? [:])
            .filter { $0.value.isFinite }.mapValues { max(0, min(1, $0)) }
        userMutes = try c.decodeIfPresent([String: Bool].self, forKey: .userMutes) ?? [:]
        policyMuted = try c.decodeIfPresent([String].self, forKey: .policyMuted) ?? []
        volumeMuted = try c.decodeIfPresent([String].self, forKey: .volumeMuted) ?? []
    }
}

// MARK: - 純決策（不碰 CoreAudio，可以直接測）

/// 一個接著的輸出裝置現在的樣子
struct PolicyDevice: Equatable, Sendable {
    var uid: String
    var volume: Float
    var muted: Bool
}

enum PolicyAction: Equatable, Sendable {
    case setMute(uid: String, muted: Bool)
    case setVolume(uid: String, volume: Float)
    case setDefault(uid: String)
}

enum OutputPolicyPlanner {
    /// 音量差多少以內當成一樣（裝置會把值取整）
    static let volumeTolerance: Float = 0.015

    static func nextSelection(current: [String], toggled: String) -> [String] {
        current == [toggled] ? [] : [toggled]
    }

    static func collapse(selected: [String], defaultUID: String?, orderedUIDs: [String]) -> [String] {
        guard selected.count > 1 else { return selected }
        if let defaultUID, selected.contains(defaultUID) { return [defaultUID] }
        let selectedSet = Set(selected)
        if let first = orderedUIDs.first(where: selectedSet.contains) { return [first] }
        return [selected.min()!]
    }

    /// 勾選而且接著的裝置，照 `connected` 的順序（呼叫端先照優先順序排好）。
    static func targets(state: OutputPolicyState, connected: [String]) -> [String] {
        let selected = Set(state.selected)
        return connected.filter { selected.contains($0) }
    }

    /// 現在的狀態離三條規則差多少，就回傳要做哪些事。已經符合就回傳空的。
    /// - devices: 接著的輸出裝置，照優先順序
    /// - restoreVolumeFor: 這些裝置剛連上，音量要還原成記住的值
    static func plan(
        state: OutputPolicyState,
        devices: [PolicyDevice],
        defaultUID: String?,
        restoreVolumeFor: Set<String> = []
    ) -> [PolicyAction] {
        guard state.armed else { return [] }
        let selected = Set(state.selected)
        var actions: [PolicyAction] = []

        for device in devices {
            if selected.contains(device.uid) {
                if restoreVolumeFor.contains(device.uid), let remembered = state.volumes[device.uid],
                   abs(remembered - device.volume) > volumeTolerance {
                    actions.append(.setVolume(uid: device.uid, volume: remembered))
                }
                let wantMute = state.userMutes[device.uid] ?? false
                if device.muted != wantMute {
                    actions.append(.setMute(uid: device.uid, muted: wantMute))
                }
            } else if !device.muted {
                actions.append(.setMute(uid: device.uid, muted: true))
            }
        }

        let targets = targets(state: state, connected: devices.map(\.uid))
        if let first = targets.first, let defaultUID, !targets.contains(defaultUID) {
            actions.append(.setDefault(uid: first))
        } else if let first = targets.first, defaultUID == nil {
            actions.append(.setDefault(uid: first))
        }
        return actions
    }
}

/// 策略靜音的判斷：接管後，tap 沒掛在任何一台選中（而且接著）的裝置上就要靜音。
enum PolicyMuteRule {
    static func shouldMute(armed: Bool, targets: [String], tapDevices: [String]) -> Bool {
        armed && Set(targets).isDisjoint(with: tapDevices)
    }
}

enum SettleMuteAction: Equatable {
    case recordUserMuteAndSetFlag
    case recordUserMute
    case enforce
    case ignore
}

enum SettleMuteRule {
    static func decide(
        armed: Bool,
        selected: Bool,
        isBluetooth: Bool,
        settling: Bool,
        flagSet: Bool,
        muted: Bool,
        recordedMute: Bool
    ) -> SettleMuteAction {
        // 判斷順序不能換（見規格第 4 節）：沒勾選與非藍牙都要先於「回報值相同就忽略」，
        // 否則沒勾選的裝置被別人解除靜音時（回報值剛好等於預設的 false）會漏掉重新靜音。
        guard armed else { return .ignore }
        guard selected else { return .enforce }
        guard isBluetooth else { return settling ? .enforce : .recordUserMute }
        guard settling else { return .recordUserMute }
        if muted == recordedMute { return .ignore }
        if flagSet { return .recordUserMute }
        return muted ? .recordUserMuteAndSetFlag : .enforce
    }
}

/// 決定「跟隨預設」tap 的路由與策略靜音狀態。
enum FollowPlanner {
    static func plan(armed: Bool, targets: [String], defaultUID: String?) -> (devices: [String], policyMuted: Bool) {
        guard armed else { return (defaultUID.map { [$0] } ?? [], false) }
        guard !targets.isEmpty else { return ([], true) }
        return (targets, false)
    }
}

// MARK: - 搶時間用的守衛（不經主執行緒）

/// 直接在自己的佇列上聽 HAL 的「裝置清單變了」「預設輸出變了」，收到當下就把規則 1、3 套上去，
/// 新出現的勾選裝置順手還原音量與靜音。只處理有硬體靜音／音量的裝置；
/// DDC 與軟體音量的裝置由主執行緒上的 OutputPolicy.enforce() 補做。
final class OutputGuard: @unchecked Sendable {
    struct Snapshot: Sendable {
        var active = false
        var selected: Set<String> = []
        var volumes: [String: Float] = [:]
        var userMutes: [String: Bool] = [:]
        /// 優先順序（UID）
        var order: [String] = []
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var known: Set<AudioDeviceID> = []
    private let queue = DispatchQueue(label: "com.local.noted.output-guard", qos: .userInteractive)
    private var devicesBlock: AudioObjectPropertyListenerBlock?
    private var defaultBlock: AudioObjectPropertyListenerBlock?
    private let logger = Logger(subsystem: "com.local.noted", category: "OutputGuard")

    /// 守衛動了東西之後呼叫（在守衛的佇列上），讓主執行緒那邊接著整理。
    var onActed: (@Sendable () -> Void)?

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func update(_ new: Snapshot) {
        lock.lock(); snapshot = new; lock.unlock()
    }

    func start() {
        guard devicesBlock == nil else { return }
        known = Set((try? AudioObjectID.readDeviceList()) ?? [])
        let devices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sweep() }
        let def: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sweep() }
        var a = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, devices)
        var b = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &b, queue, def)
        devicesBlock = devices
        defaultBlock = def
    }

    func stop() {
        if let block = devicesBlock {
            var a = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
        if let block = defaultBlock {
            var b = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &b, queue, block)
        }
        devicesBlock = nil
        defaultBlock = nil
    }

    /// 在守衛的佇列上跑。
    private func sweep() {
        lock.lock(); let snap = snapshot; lock.unlock()
        let ids = (try? AudioObjectID.readDeviceList()) ?? []
        defer { known = Set(ids) }
        guard snap.active else { return }

        var acted = false
        var connected: [String: AudioDeviceID] = [:]
        for id in ids where id.hasOutputStreams() && !id.isAggregateDevice() && !id.isHidden() {
            guard let uid = try? id.readDeviceUID() else { continue }
            connected[uid] = id
            if !snap.selected.contains(uid) {
                if !id.readMuteState(), id.setMuteState(true) { acted = true }
            } else if !known.contains(id) {
                // 勾選的裝置剛連上：還原它自己記住的音量與靜音
                if let volume = snap.volumes[uid], id.hasOutputVolumeControl() {
                    if id.setOutputVolumeScalar(volume) { acted = true }
                }
                let wantMute = snap.userMutes[uid] ?? false
                if id.readMuteState() != wantMute, id.setMuteState(wantMute) { acted = true }
            }
        }

        if let current = try? AudioDeviceID.readDefaultOutputDevice(),
           let currentUID = try? current.readDeviceUID(),
           !snap.selected.contains(currentUID),
           let anchor = snap.order.first(where: { snap.selected.contains($0) && connected[$0]?.isDeviceAlive() == true }),
           let anchorID = connected[anchor] {
            do {
                try AudioDeviceID.setDefaultOutputDevice(anchorID)
                acted = true
            } catch {
                logger.error("Guard could not restore default output: \(error.localizedDescription)")
            }
        }
        if acted { onActed?() }
    }
}

// MARK: - 主執行緒上的策略

@Observable
@MainActor
final class OutputPolicy {
    nonisolated static func shouldRecordVolume(uid: String, volumeMuted: Set<String>) -> Bool {
        !volumeMuted.contains(uid)
    }
    private let settingsManager: SettingsManager
    private let deviceMonitor: any AudioDeviceProviding
    private let volumeMonitor: any DeviceVolumeProviding
    private let guardian = OutputGuard()
    private let logger = Logger(subsystem: "com.local.noted", category: "OutputPolicy")

    private(set) var state: OutputPolicyState {
        didSet {
            guard state != oldValue else { return }
            settingsManager.outputPolicyState = state
            pushSnapshot()
        }
    }

    /// 勾選（以及接上的裝置）變了，AudioEngine 要重新安排「跟隨預設」的 App。
    @ObservationIgnored var onTargetsChanged: (() -> Void)?

    /// true＝只算要做什麼、記在 `dryRunLog`，不真的動裝置。測試用。
    @ObservationIgnored var dryRun = false
    @ObservationIgnored private(set) var dryRunLog: [String] = []
    /// 嘗試硬體靜音與音量歸零都失敗的輸出裝置；僅供 UI 提示，不存檔。
    private(set) var unmutableDevices: Set<String> = []
    @ObservationIgnored private var volumeMutedDevices: Set<String> = [] {
        didSet {
            let persisted = volumeMutedDevices.sorted()
            guard state.volumeMuted != persisted else { return }
            var next = state
            next.volumeMuted = persisted
            state = next
            settingsManager.flushSync()
        }
    }

    /// 剛連上的裝置：這段時間內音量被別人改掉會再蓋回去，也不會當成使用者的操作記下來。
    @ObservationIgnored private var settleUntil: [String: Date] = [:]
    @ObservationIgnored private var settleRewrites: [String: Int] = [:]
    /// 時鐘，測試用來把時間往後撥，不必真的等穩定期過完。
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var settleMuteUIDs: Set<String> = []
    @ObservationIgnored private var settleMuteFlags: Set<String> = []
    private let transportResolver: (AudioDeviceID) -> TransportType
    /// 策略自己正在寫裝置（可能巢狀），這段時間的回呼不是使用者的操作
    @ObservationIgnored private var writeDepth = 0
    private var isWriting: Bool { writeDepth > 0 }
    /// 剛被勾起來的裝置：下一次套用時把音量還原成它自己記住的值
    @ObservationIgnored private var restoreOnce: Set<String> = []
    @ObservationIgnored private var started = false

    static let settleSeconds: TimeInterval = 2
    static let bluetoothSettleSeconds: TimeInterval = 5
    static let maxSettleRewrites = 6

    init(
        settingsManager: SettingsManager,
        deviceMonitor: any AudioDeviceProviding,
        volumeMonitor: any DeviceVolumeProviding,
        transportResolver: @escaping (AudioDeviceID) -> TransportType = { $0.readTransportType() }
    ) {
        self.settingsManager = settingsManager
        self.deviceMonitor = deviceMonitor
        self.volumeMonitor = volumeMonitor
        self.transportResolver = transportResolver
        self.state = settingsManager.outputPolicyState
        self.volumeMutedDevices = []
        self.volumeMutedDevices = Set(settingsManager.outputPolicyState.volumeMuted)
    }

    // MARK: 給畫面用

    var isArmed: Bool { state.armed }

    /// 這個裝置有沒有勾。還沒接管時，顯示成「只勾了系統預設輸出」。
    func isSelected(_ uid: String) -> Bool {
        if state.armed { return state.selected.contains(uid) }
        return uid == volumeMonitor.defaultDeviceUID
    }

    /// 接著的輸出裝置，照優先順序
    var orderedDevices: [AudioDevice] {
        let devices = deviceMonitor.outputDevices
        let order = settingsManager.devicePriorityOrder
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return devices.sorted {
            let a = rank[$0.uid] ?? Int.max, b = rank[$1.uid] ?? Int.max
            return a != b ? a < b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// 勾選而且接著的裝置（UID），照優先順序。沒接管時是 nil（AudioEngine 照原本的做法走）。
    var targets: [String]? {
        guard state.armed else { return nil }
        return OutputPolicyPlanner.targets(state: state, connected: orderedDevices.map(\.uid))
    }

    /// 音量鍵、HUD 滑桿要調的裝置。接管後只有勾選的；都沒勾就是空的（不能去動沒勾選的裝置）。
    var targetDeviceIDs: [AudioDeviceID] {
        guard let targets else {
            let id = volumeMonitor.defaultDeviceID
            return id.isValid ? [id] : []
        }
        return targets.compactMap { deviceMonitor.device(for: $0)?.id }
    }

    // MARK: 使用者的操作

    func toggle(_ uid: String) {
        let current = state.armed ? state.selected : [volumeMonitor.defaultDeviceUID].compactMap { $0 }
        let nextSelection = OutputPolicyPlanner.nextSelection(current: current, toggled: uid)
        setSelected(Set(nextSelection), justSelected: nextSelection == [uid] ? uid : nil)
    }

    func setSelected(_ uids: Set<String>, justSelected: String? = nil) {
        var next = state
        let orderedUIDs = orderedDevices.map(\.uid)
        let singleSelection = OutputPolicyPlanner.collapse(
                selected: Array(uids),
                defaultUID: volumeMonitor.defaultDeviceUID,
                orderedUIDs: settingsManager.devicePriorityOrder + orderedUIDs
        )
        if !next.armed {
            // 第一次接管：先把每個裝置現在的音量與靜音記下來，接管的當下不改變任何正在出聲的裝置
            next.armed = true
            for device in deviceMonitor.outputDevices {
                if Self.shouldRecordVolume(uid: device.uid, volumeMuted: volumeMutedDevices) {
                    next.volumes[device.uid] = volumeMonitor.volumes[device.id] ?? next.volumes[device.uid]
                }
                next.userMutes[device.uid] = volumeMonitor.muteStates[device.id] ?? false
            }
        }
        next.selected = singleSelection
        unmutableDevices.subtract(singleSelection)
        // 勾起來就是要聽：解除它的靜音，音量還原成它自己記住的值（0% 還是 0%）
        if let justSelected {
            next.userMutes[justSelected] = false
            restoreOnce.insert(justSelected)
        }
        state = next
        onTargetsChanged?()
        enforce()
    }

    /// 照畫面上現在這樣（只勾系統預設輸出）開始接管。
    func armWithCurrentDefault() {
        guard !state.armed else { return }
        setSelected(Set([volumeMonitor.defaultDeviceUID].compactMap { $0 }))
    }

    /// 停止接管：把被策略靜音的裝置還原，之後行為回到原本的 FineTune。
    func disarm() {
        guard state.armed else { return }
        releasePolicyMutes()
        unmutableDevices.subtract(Set(state.selected))
        var next = state
        next.volumeMuted = volumeMutedDevices.sorted()
        next.armed = false
        next.policyMuted = []
        state = next
        onTargetsChanged?()
    }

    // MARK: 啟動與結束

    func start() {
        guard !started else { return }
        started = true
        // 啟動時以裝置現在的音量為準（Noted 沒在跑的時候使用者可能調過）
        var next = state
        volumeMutedDevices = Set(next.volumeMuted)
        if next.armed, next.selected.count > 1 {
            next.selected = OutputPolicyPlanner.collapse(
                selected: next.selected,
                defaultUID: volumeMonitor.defaultDeviceUID,
                orderedUIDs: settingsManager.devicePriorityOrder + orderedDevices.map(\.uid)
            )
            logger.info("Collapsed multiple selected output devices to \(next.selected.first ?? "none")")
        }
        for device in deviceMonitor.outputDevices {
            if Self.shouldRecordVolume(uid: device.uid, volumeMuted: volumeMutedDevices), let volume = volumeMonitor.volumes[device.id] { next.volumes[device.uid] = volume }
        }
        state = next
        guardian.onActed = { [weak self] in
            Task { @MainActor [weak self] in self?.enforce() }
        }
        pushSnapshot()
        if !dryRun { guardian.start() }
        enforce()
    }

    /// App 要結束：**不**解除沒勾選裝置的靜音。
    /// 使用者要的是「耳機斷線後不外放」，Noted 結束之後這件事也要成立：
    /// 如果結束時幫喇叭解除靜音，之後一拔耳機就外放了。
    /// 代價是 Noted 結束後那些裝置維持靜音，要用的話在系統裡解除（按音量鍵就會解除），或先在設定按「停止接管」。
    func shutdown() {
        guardian.stop()
        settingsManager.flushSync()
    }

    /// 只在使用者按「停止接管」時用：把因為沒勾選而靜音的裝置解除靜音。
    private func releasePolicyMutes() {
        guard state.armed, !dryRun else { return }
        writeDepth += 1
        defer { writeDepth -= 1 }
        var remainingVolumeMuted = volumeMutedDevices
        var remainingPolicyMuted = Set(state.policyMuted)
        for uid in state.policyMuted {
            guard let device = deviceMonitor.device(for: uid) else { continue }
            if volumeMutedDevices.contains(uid), let remembered = state.volumes[uid] {
                volumeMonitor.setVolume(for: device.id, to: remembered)
                remainingVolumeMuted.remove(uid)
            }
            if volumeMonitor.setMute(for: device.id, to: false) { remainingPolicyMuted.remove(uid) }
            else if !volumeMonitor.muteStates[device.id, default: false] { remainingPolicyMuted.remove(uid) }
        }
        remainingPolicyMuted.subtract(Set(volumeMutedDevices.filter { state.volumes[$0] == nil }))
        for uid in volumeMutedDevices where !state.policyMuted.contains(uid) {
            guard let device = deviceMonitor.device(for: uid), let remembered = state.volumes[uid] else { continue }
            volumeMonitor.setVolume(for: device.id, to: remembered)
            remainingVolumeMuted.remove(uid)
        }
        let knownVolumes = Set(state.volumes.keys)
        remainingVolumeMuted.formIntersection(knownVolumes)
        volumeMutedDevices = remainingVolumeMuted
        unmutableDevices.removeAll()
        var next = state
        next.policyMuted = remainingPolicyMuted.sorted()
        state = next
        settingsManager.flushSync()
    }

    // MARK: 事件（AudioEngine 轉進來）

    func deviceConnected(_ uid: String) {
        settleMuteFlags.remove(uid)
        let transport = deviceMonitor.device(for: uid).map { transportResolver($0.id) }
        if transport == .bluetooth || transport == .bluetoothLE {
            settleMuteUIDs.insert(uid)
        } else {
            settleMuteUIDs.remove(uid)
        }
        let seconds = (transport == .bluetooth || transport == .bluetoothLE) ? Self.bluetoothSettleSeconds : Self.settleSeconds
        settleUntil[uid] = now().addingTimeInterval(seconds)
        settleRewrites[uid] = 0
        enforce()
        onTargetsChanged?()
    }

    func deviceDisconnected(_ uid: String) {
        unmutableDevices.remove(uid)
        settleMuteUIDs.remove(uid)
        settleMuteFlags.remove(uid)
        settleUntil[uid] = nil
        enforce()
        onTargetsChanged?()
    }

    func defaultChanged(_ uid: String) {
        enforce()
        onTargetsChanged?()
    }

    /// HAL 回報的音量變化（系統音量鍵、控制中心、耳機自己、別的 App）
    func externalVolumeChanged(_ deviceID: AudioDeviceID, _ volume: Float) {
        // 策略自己寫出去的（沒有硬體音量的裝置，靜音會同步回報「音量 0」）不是使用者的操作
        guard !isWriting,
              let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
        if isSettling(uid) {
            guard state.armed, (settleRewrites[uid] ?? 0) < Self.maxSettleRewrites else { return }
            settleRewrites[uid, default: 0] += 1
            enforce()
        } else {
            var next = state
            if Self.shouldRecordVolume(uid: uid, volumeMuted: volumeMutedDevices) { next.volumes[uid] = volume }
            state = next
        }
    }

    func externalMuteChanged(_ deviceID: AudioDeviceID, _ muted: Bool) {
        guard state.armed, !isWriting,
              let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
        let settling = isSettling(uid)
        let action = SettleMuteRule.decide(
            armed: state.armed,
            selected: state.selected.contains(uid),
            isBluetooth: settleMuteUIDs.contains(uid),
            settling: settling,
            flagSet: settleMuteFlags.contains(uid),
            muted: muted,
            recordedMute: state.userMutes[uid] ?? false
        )
        switch action {
        case .recordUserMuteAndSetFlag:
            var next = state
            next.userMutes[uid] = muted
            state = next
            settleMuteFlags.insert(uid)
            let elapsed = Self.bluetoothSettleSeconds - (settleUntil[uid].map { $0.timeIntervalSince(now()) } ?? 0)
            logger.info("Accepted Bluetooth mute during settling for uid=\(uid, privacy: .public), reconnect=\(elapsed, privacy: .public)s")
        case .recordUserMute:
            var next = state
            next.userMutes[uid] = muted
            state = next
        case .enforce:
            enforce()
        case .ignore:
            break
        }
    }

    /// App 自己（面板、音量鍵、HUD）寫了音量或靜音
    func localWrite(_ deviceID: AudioDeviceID) {
        guard !isWriting, let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
        var next = state
        if let volume = volumeMonitor.volumes[deviceID] { next.volumes[uid] = volume }
        if state.armed, state.selected.contains(uid) {
            let muted = volumeMonitor.muteStates[deviceID] ?? false
            next.userMutes[uid] = muted
            if settleMuteUIDs.contains(uid), isSettling(uid), muted != (state.userMutes[uid] ?? false) {
                settleMuteFlags.insert(uid)
            }
        }
        state = next
        // 沒勾選的裝置被解除靜音的話，蓋回去
        if state.armed, !state.selected.contains(uid) { enforce() }
    }

    private func isSettling(_ uid: String) -> Bool {
        guard let until = settleUntil[uid] else { return false }
        if now() < until { return true }
        settleUntil[uid] = nil
        return false
    }

    // MARK: 套用

    private func currentDevices() -> [PolicyDevice] {
        orderedDevices.compactMap { device in
            // 斷線到一半的裝置不碰
            guard device.id.isDeviceAlive() || dryRun else { return nil }
            // 裝置剛出現時，音量監看的快取還沒填（它晚一輪主迴圈才讀）。
            // 這時直接問硬體，不能把「還不知道」當成「音量 0、沒靜音」。
            let volume = volumeMonitor.volumes[device.id]
                ?? (device.id.hasOutputVolumeControl() ? device.id.readOutputVolumeScalar() : 1)
            let muted = volumeMonitor.muteStates[device.id] ?? device.id.readMuteState()
            return PolicyDevice(uid: device.uid, volume: volume, muted: muted)
        }
    }

    /// 算出現在離規則差多少，補上。已經符合就什麼都不做。
    func enforce() {
        guard state.armed else { return }
        // 裝置清單或優先順序可能變了，守衛那邊的資料跟著更新
        pushSnapshot()
        // 沒有硬體音量的裝置，解除靜音時音量監看會自己把音量改成它存的舊值；
        // 所以套用完再對一次，還差就再補（最多兩輪）。
        for _ in 0..<2 {
            guard applyOnce() else { break }
        }
        restoreOnce.removeAll()
    }

    /// 回傳這一輪有沒有動到裝置
    private func applyOnce() -> Bool {
        let devices = currentDevices()
        let restoring = Set(devices.map(\.uid).filter { isSettling($0) }).union(restoreOnce)
        let plannedActions = OutputPolicyPlanner.plan(state: state, devices: devices,
                                               defaultUID: volumeMonitor.defaultDeviceUID,
                                               restoreVolumeFor: restoring)
        let actions = plannedActions.filter { action in
            if case .setMute(let uid, true) = action, volumeMutedDevices.contains(uid),
               let device = devices.first(where: { $0.uid == uid }), device.volume <= 0.01 { return false }
            return true
        }
        // 記下哪些裝置是被策略靜音的
        let selected = Set(state.selected)
        for uid in volumeMutedDevices where selected.contains(uid) {
            if let device = deviceMonitor.device(for: uid), let remembered = state.volumes[uid] {
                volumeMonitor.setVolume(for: device.id, to: remembered)
                volumeMutedDevices.remove(uid)
            }
        }
        var policyMuted = Set(state.policyMuted)
        for device in devices {
            if selected.contains(device.uid) { policyMuted.remove(device.uid) }
        }
        for case .setMute(let uid, true) in actions where !selected.contains(uid) { policyMuted.insert(uid) }
        if policyMuted != Set(state.policyMuted) {
            var next = state
            next.policyMuted = policyMuted.sorted()
            state = next
        }
        guard !actions.isEmpty else { return false }

        if dryRun {
            dryRunLog.append(contentsOf: actions.map { "\($0)" })
            return false
        }
        writeDepth += 1
        defer { writeDepth -= 1 }
        for action in actions {
            switch action {
            case .setMute(let uid, let muted):
                guard let device = deviceMonitor.device(for: uid) else { continue }
                if !muted, volumeMutedDevices.remove(uid) != nil, let remembered = state.volumes[uid] {
                    volumeMonitor.setVolume(for: device.id, to: remembered)
                }
                if volumeMonitor.setMute(for: device.id, to: muted) {
                    unmutableDevices.remove(uid)
                } else if muted {
                    // 備援音量寫入必須留在 writeDepth 保護區，保留 state.volumes 原值。
                    if state.volumes[uid] == nil, let current = volumeMonitor.volumes[device.id] {
                        var remembered = state
                        remembered.volumes[uid] = current
                        state = remembered
                    }
                    volumeMonitor.setVolume(for: device.id, to: 0)
                    let silent: Bool
                    switch volumeMonitor.outputVolumeBackend(for: device.id) {
                    case .hardware:
                        silent = device.id.hasOutputVolumeControl() && device.id.readOutputVolumeScalar() <= 0.01
                    case .ddc:
                        silent = (volumeMonitor.volumes[device.id] ?? 1) == 0
                    case .software:
                        silent = (volumeMonitor.volumes[device.id] ?? 1) == 0
                    }
                    if silent {
                        volumeMutedDevices.insert(uid)
                        unmutableDevices.remove(uid)
                    } else { unmutableDevices.insert(uid) }
                } else {
                    unmutableDevices.remove(uid)
                }
            case .setVolume(let uid, let volume):
                if let device = deviceMonitor.device(for: uid) { volumeMonitor.setVolume(for: device.id, to: volume) }
            case .setDefault(let uid):
                if let device = deviceMonitor.device(for: uid) { volumeMonitor.setDefaultDevice(device.id) }
            }
        }
        logger.info("Output policy applied \(actions.count) action(s)")
        return true
    }

    private func pushSnapshot() {
        guardian.update(OutputGuard.Snapshot(
            active: state.armed && !dryRun,
            selected: Set(state.selected),
            volumes: state.volumes,
            userMutes: state.userMutes,
            order: orderedDevices.map(\.uid)
        ))
    }
}
