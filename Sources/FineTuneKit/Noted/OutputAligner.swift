// Noted: 同時輸出到多個裝置時，把延遲小的裝置往後推，對齊最慢的那個。
// 本檔是 FineTuneKit（GPL-3.0）的一部分。設計見 docs/notch-suite-設計.md 8.5。
import AudioToolbox
import Foundation

/// 存進音訊設定檔的對齊設定
struct OutputAlignmentState: Codable, Equatable, Sendable {
    /// 同時輸出時對齊各裝置的延遲
    var enabled = true
    /// 每個裝置的手動微調（UID → 毫秒，正值＝這個裝置再晚一點）
    var trimMs: [String: Double] = [:]

    static let trimRange: ClosedRange<Double> = -300...300

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trimMs = (try c.decodeIfPresent([String: Double].self, forKey: .trimMs) ?? [:])
            .filter { $0.value.isFinite }
            .mapValues { min(max($0, Self.trimRange.lowerBound), Self.trimRange.upperBound) }
    }
}

/// tap 控制器建 aggregate 時讀的目前設定（只在主執行緒讀寫）
@MainActor
enum OutputAlignmentConfig {
    static var state = OutputAlignmentState()
}

enum OutputAlignment {
    /// 環狀緩衝區留多久的聲音；延遲最多到這個值減一個 IO 區塊
    static let ringSeconds = 2.0
    /// 套用的延遲上限（毫秒）
    static let maxDelayMs = 1500.0

    /// 每個裝置要加多少延遲（毫秒）。
    /// 延遲最大的裝置當基準（加 0），其他裝置加「最大值減自己的值」，再加各自的手動微調；
    /// 微調讓某個值變成負的時候，全部一起往後挪，讓最小的剛好是 0（延遲不能是負的）。
    static func delaysMs(latenciesMs: [Double], trimsMs: [Double]) -> [Double] {
        guard !latenciesMs.isEmpty else { return [] }
        let clean = latenciesMs.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let slowest = clean.max() ?? 0
        var delays: [Double] = []
        for (i, latency) in clean.enumerated() {
            let trim = i < trimsMs.count && trimsMs[i].isFinite ? trimsMs[i] : 0
            delays.append(slowest - latency + trim)
        }
        let lowest = delays.min() ?? 0
        return delays.map { min(max($0 - lowest, 0), maxDelayMs) }
    }

    /// 一個輸出裝置回報的輸出延遲（毫秒）：裝置延遲＋安全偏移＋第一個輸出串流的延遲，用它自己的取樣率換算。
    /// 讀不到的項目當 0；取樣率讀不到回 nil。
    static func reportedLatencyMs(of device: AudioDeviceID) -> Double? {
        guard let rate = try? device.readNominalSampleRate(), rate > 0 else { return nil }
        let deviceLatency: UInt32 = (try? device.read(kAudioDevicePropertyLatency, scope: .output, defaultValue: UInt32(0))) ?? 0
        let safety: UInt32 = (try? device.read(kAudioDevicePropertySafetyOffset, scope: .output, defaultValue: UInt32(0))) ?? 0
        var streamLatency: UInt32 = 0
        let streams: [AudioObjectID] = (try? device.readArray(kAudioDevicePropertyStreams, scope: .output, defaultValue: AudioObjectID(0))) ?? []
        if let first = streams.first {
            streamLatency = (try? first.read(kAudioStreamPropertyLatency, defaultValue: UInt32(0))) ?? 0
        }
        return Double(deviceLatency + safety + streamLatency) / rate * 1000
    }
}

/// 即時執行緒上用的延遲線：一份處理好的立體聲寫進環狀緩衝區，每個輸出串流照自己的延遲讀出來。
///
/// 執行緒：`init`／`setDelays` 在主執行緒；`distribute` 只在 HAL 的 IO 執行緒（同一個 IOProc，不會同時進來兩次）。
/// 兩邊只共用 `target`（對齊的 Int32，單一寫入者），跟上游 `ProcessTapController` 的 nonisolated(unsafe) 欄位同一種做法。
/// `distribute` 不配置記憶體、不鎖、不呼叫 ObjC。
final class OutputAligner: @unchecked Sendable {
    static let maxOutputs = 8
    /// 一次 IO 最多處理幾個 frame（HAL 的緩衝區通常是 512，最大設到 4096 上下）
    static let maxBlockFrames = 8192

    let sampleRate: Double
    /// 環狀緩衝區的 frame 數（2 的次方）
    let capacity: Int
    private let mask: Int
    private let ring: UnsafeMutablePointer<Float>
    /// 給上游 `processMappedBuffers` 寫「處理好的立體聲」用的暫存區（maxBlockFrames × 2）
    let scratch: UnsafeMutablePointer<Float>
    private let target: UnsafeMutablePointer<Int32>
    private let current: UnsafeMutablePointer<Int32>
    private let previous: UnsafeMutablePointer<Int32>
    private let fadeLeft: UnsafeMutablePointer<Int32>
    private let fadeFrames: Int32
    private var writePos = 0
    /// 環狀緩衝區現在整個是 0（靜音期間只清一次）
    private var flushed = true

    /// - Parameter delayFrames: 每個輸出緩衝區（照 aggregate 的輸出串流順序）要延遲幾個 frame
    init(sampleRate: Double, delayFrames: [Int]) {
        let rate = sampleRate > 0 ? sampleRate : 48000
        self.sampleRate = rate
        var cap = 1
        while Double(cap) < rate * OutputAlignment.ringSeconds { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        ring = .allocate(capacity: cap * 2)
        ring.initialize(repeating: 0, count: cap * 2)
        scratch = .allocate(capacity: Self.maxBlockFrames * 2)
        scratch.initialize(repeating: 0, count: Self.maxBlockFrames * 2)
        target = .allocate(capacity: Self.maxOutputs)
        current = .allocate(capacity: Self.maxOutputs)
        previous = .allocate(capacity: Self.maxOutputs)
        fadeLeft = .allocate(capacity: Self.maxOutputs)
        fadeFrames = Int32(max(32, rate * 0.02))
        for i in 0..<Self.maxOutputs {
            let d = Int32(clamp(i < delayFrames.count ? delayFrames[i] : 0))
            target[i] = d; current[i] = d; previous[i] = d; fadeLeft[i] = 0
        }
    }

    deinit {
        ring.deallocate(); scratch.deallocate()
        target.deallocate(); current.deallocate(); previous.deallocate(); fadeLeft.deallocate()
    }

    private func clamp(_ frames: Int) -> Int {
        min(max(frames, 0), capacity - Self.maxBlockFrames - 1)
    }

    /// 主執行緒：改延遲。IO 執行緒下一個區塊開始用約 20 毫秒交叉淡化換過去。
    func setDelays(_ delayFrames: [Int]) {
        for i in 0..<Self.maxOutputs {
            target[i] = Int32(clamp(i < delayFrames.count ? delayFrames[i] : 0))
        }
    }

    /// IO 執行緒：這一輪沒有聲音要送（靜音中）。把延遲線整個清空並前進，輸出由呼叫端自己清成 0。
    /// 整個清空（不是只寫這一輪的靜音）是因為靜音可能比延遲短：只寫這一輪的話，解除靜音後還會吐出靜音前的聲音。
    /// 清空只在進入靜音的第一輪做一次（約 0.7 MB 的 memset），之後每輪只前進。
    func advanceSilence(frameCount: Int) {
        let n = min(max(frameCount, 0), Self.maxBlockFrames)
        if !flushed {
            memset(ring, 0, capacity * 2 * MemoryLayout<Float>.size)
            flushed = true
        }
        writePos = (writePos &+ n) & mask
    }

    /// 目前最大的目標延遲（毫秒）
    var maxDelayMs: Double {
        var m: Int32 = 0
        for i in 0..<Self.maxOutputs { m = max(m, target[i]) }
        return Double(m) / sampleRate * 1000
    }

    /// 測試用：目前各輸出的目標延遲
    var targetDelays: [Int] { (0..<Self.maxOutputs).map { Int(target[$0]) } }

    /// IO 執行緒：`scratch` 裡前 `frameCount` 個 frame（立體聲交錯）是這一輪處理好的聲音，
    /// 寫進環狀緩衝區，再照每個輸出的延遲填到 `outputs`。
    /// `gain` 在延遲之後才乘（交叉淡化用）：所有輸出同一個時間點一起淡，不會有的早有的晚。
    func distribute(frameCount: Int, to outputs: UnsafeMutableAudioBufferListPointer, gain: Float = 1) {
        let n = min(max(frameCount, 0), Self.maxBlockFrames)
        flushed = false
        let start = writePos
        for i in 0..<n {
            let w = ((start &+ i) & mask) &* 2
            ring[w] = scratch[i &* 2]
            ring[w &+ 1] = scratch[i &* 2 &+ 1]
        }
        let fadeTotal = Float(fadeFrames)
        for j in 0..<outputs.count {
            let buffer = outputs[j]
            guard let data = buffer.mData else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let channels = max(1, Int(buffer.mNumberChannels))
            let totalSamples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = min(n, totalSamples / channels)
            let slot = min(j, Self.maxOutputs - 1)

            // 延遲改了，而且上一次的淡化已經做完：開始新的淡化
            let wanted = target[slot]
            if wanted != current[slot], fadeLeft[slot] == 0 {
                previous[slot] = current[slot]
                current[slot] = wanted
                fadeLeft[slot] = fadeFrames
            }
            let delay = Int(current[slot]), oldDelay = Int(previous[slot])
            var fade = fadeLeft[slot]

            for i in 0..<frames {
                let r = ((start &+ i &- delay) & mask) &* 2
                var left = ring[r], right = ring[r &+ 1]
                if fade > 0 {
                    let o = ((start &+ i &- oldDelay) & mask) &* 2
                    let g = Float(fade) / fadeTotal   // 舊位置的比重，1 → 0
                    left = left * (1 - g) + ring[o] * g
                    right = right * (1 - g) + ring[o &+ 1] * g
                    fade -= 1
                }
                left *= gain; right *= gain
                let base = i &* channels
                if channels == 1 {
                    out[base] = (left + right) * 0.5
                } else {
                    out[base] = left
                    out[base &+ 1] = right
                    if channels > 2 { for ch in 2..<channels { out[base &+ ch] = 0 } }
                }
            }
            fadeLeft[slot] = fade
            let written = frames * channels
            if written < totalSamples {
                memset(out.advanced(by: written), 0, (totalSamples - written) * MemoryLayout<Float>.size)
            }
        }
        writePos = (start &+ n) & mask
    }
}
