// 讓 FineTune 未啟動時仍能解除輸出策略留下的硬體靜音。
import AudioToolbox
import Foundation

public enum PolicyMuteRelease {
    public static func pendingCount(in json: Any?) -> Int {
        guard let policy = (json as? [String: Any])?["outputPolicy"] as? [String: Any] else { return 0 }
        let policyMuted = Set(policy["policyMuted"] as? [String] ?? [])
        let volumeMuted = Set(policy["volumeMuted"] as? [String] ?? [])
        return policyMuted.union(volumeMuted).count
    }

    public static func mutedUIDs(in json: Any?) -> [String]? {
        guard let root = json as? [String: Any],
              let policy = root["outputPolicy"] as? [String: Any],
              let uids = policy["policyMuted"] as? [String] else { return nil }
        return uids
    }

    static func clearingMuteState(in json: Any) -> Any? {
        guard var root = json as? [String: Any], var policy = root["outputPolicy"] as? [String: Any] else { return nil }
        policy["policyMuted"] = [String]()
        policy["volumeMuted"] = [String]()
        policy["armed"] = false
        root["outputPolicy"] = policy
        return root
    }

    public static func readSettings() -> Any? {
        let url = FineTuneStorage.directory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    public static func releaseStoredMutes() -> Int {
        let url = FineTuneStorage.directory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data),
              let policy = (json as? [String: Any])?["outputPolicy"] as? [String: Any],
              let changed = clearingMuteState(in: json),
              JSONSerialization.isValidJSONObject(changed) else { return 0 }

        let uids = mutedUIDs(in: json) ?? []
        let volumeMutedValues = policy["volumeMuted"] as? [String] ?? []
        var released = 0
        var pendingPolicyMuted = Set(uids)
        let volumes = policy["volumes"] as? [String: NSNumber] ?? [:]
        let volumeMuted = Set(volumeMutedValues)
        var pendingVolumeMuted = volumeMuted
        for uid in Set(uids).union(volumeMuted) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = AudioObjectID(kAudioObjectUnknown)
            var translated = uid as CFString
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafePointer(to: &translated) { pointer in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                           UInt32(MemoryLayout<CFString?>.size), pointer, &size, &device)
            }
            guard status == noErr, device != kAudioObjectUnknown else { continue }
            var didRelease = false
            if volumeMuted.contains(uid), let volume = volumes[uid]?.floatValue {
                let restored = setVolume(volume, device: device)
                didRelease = restored || didRelease
                if restored { pendingVolumeMuted.remove(uid) }
            }
            let unmuted = setMute(false, device: device)
            didRelease = unmuted || didRelease
            if unmuted || !hasMuteProperty(device) { pendingPolicyMuted.remove(uid) }
            if !didRelease, !hasMuteProperty(device), !volumeMuted.contains(uid),
               let volume = volumes[uid]?.floatValue {
                didRelease = setVolume(volume, device: device)
            }
            if didRelease { released += 1 }
        }
        for uid in volumeMuted where volumes[uid] == nil {
            pendingVolumeMuted.remove(uid)
        }
        guard var finalRoot = changed as? [String: Any],
              var finalPolicy = finalRoot["outputPolicy"] as? [String: Any] else { return 0 }
        finalPolicy["policyMuted"] = pendingPolicyMuted.sorted()
        finalPolicy["volumeMuted"] = pendingVolumeMuted.sorted()
        finalRoot["outputPolicy"] = finalPolicy
        guard JSONSerialization.isValidJSONObject(finalRoot),
              let finalOutput = try? JSONSerialization.data(withJSONObject: finalRoot, options: [.prettyPrinted, .sortedKeys]) else { return 0 }
        do { try finalOutput.write(to: url, options: .atomic) } catch { return 0 }
        return released
    }

    private static func setMute(_ muted: Bool, device: AudioObjectID) -> Bool {
        var any = false
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2, 3, 4, 5, 6, 7, 8] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr { any = true }
        }
        return any
    }

    private static func hasMuteProperty(_ device: AudioObjectID) -> Bool {
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2, 3, 4, 5, 6, 7, 8] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            if AudioObjectHasProperty(device, &address) { return true }
        }
        return false
    }

    private static func setVolume(_ volume: Float, device: AudioObjectID) -> Bool {
        var any = false
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2, 3, 4, 5, 6, 7, 8] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                guard AudioObjectHasProperty(device, &address) else { continue }
                var value = volume
                if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr { any = true }
            }
        }
        return any
    }
}
