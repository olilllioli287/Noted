import AudioToolbox
import Foundation
import Testing
@testable import FineTuneKit

// 延遲對齊：規劃（哪個裝置延遲多少）與延遲線本身。

@Suite struct OutputAlignmentPlanTests {
    @Test func 最慢的裝置不延遲_其他補到一樣() {
        // 使用者的例子：藍牙耳機 160 毫秒、MacBook 喇叭 16.6 毫秒
        let d = OutputAlignment.delaysMs(latenciesMs: [160, 16.6], trimsMs: [0, 0])
        #expect(d[0] == 0)
        #expect(abs(d[1] - 143.4) < 0.001)
    }

    @Test func 順序反過來結果跟著裝置走() {
        let d = OutputAlignment.delaysMs(latenciesMs: [16.6, 160], trimsMs: [0, 0])
        #expect(abs(d[0] - 143.4) < 0.001)
        #expect(d[1] == 0)
    }

    @Test func 正的微調讓那個裝置更晚() {
        let d = OutputAlignment.delaysMs(latenciesMs: [160, 16.6], trimsMs: [0, 30])
        #expect(d[0] == 0)
        #expect(abs(d[1] - 173.4) < 0.001)
    }

    @Test func 微調讓最慢的裝置要更早時_改成其他裝置少延遲一點() {
        // 耳機 -40：等於喇叭少延遲 40
        let d = OutputAlignment.delaysMs(latenciesMs: [160, 16.6], trimsMs: [-40, 0])
        #expect(d[0] == 0)
        #expect(abs(d[1] - 183.4) < 0.001)
        // 喇叭 -200：喇叭不能是負的，變成耳機多延遲
        let e = OutputAlignment.delaysMs(latenciesMs: [160, 16.6], trimsMs: [0, -200])
        #expect(abs(e[0] - 56.6) < 0.001)
        #expect(e[1] == 0)
    }

    @Test func 讀不到延遲當零_單一裝置不延遲_上限() {
        #expect(OutputAlignment.delaysMs(latenciesMs: [.nan, 100], trimsMs: []) == [100, 0])
        #expect(OutputAlignment.delaysMs(latenciesMs: [42], trimsMs: [0]) == [0])
        #expect(OutputAlignment.delaysMs(latenciesMs: [], trimsMs: []) == [])
        #expect(OutputAlignment.delaysMs(latenciesMs: [5000, 0], trimsMs: [0, 0]) == [0, OutputAlignment.maxDelayMs])
    }

    @Test func 舊設定檔沒有這一段_預設開_微調會被夾在範圍內() throws {
        let empty = try JSONDecoder().decode(OutputAlignmentState.self, from: Data("{}".utf8))
        #expect(empty.enabled && empty.trimMs.isEmpty)
        let s = try JSONDecoder().decode(OutputAlignmentState.self, from: Data(#"{"enabled":false,"trimMs":{"a":999,"b":-20}}"#.utf8))
        #expect(!s.enabled)
        #expect(s.trimMs == ["a": 300, "b": -20])
    }

    @MainActor @Test func 對齊開著時多裝置改用_non_stacked_關著或串流數不明時維持_stacked() {
        func plan(_ uids: [String], align: Bool, streams: [String: Int] = [:]) -> ProcessTapController.AggregatePlan {
            ProcessTapController.planAggregate(outputUIDs: uids, expand: { _ in nil },
                                               outputStreamCount: { streams[$0] ?? 1 }, alignMirrored: align)
        }
        #expect(plan(["bt", "mac"], align: true).isStacked == false)
        #expect(plan(["bt", "mac"], align: false).isStacked == true)
        #expect(plan(["bt"], align: true).isStacked == true)                       // 單一裝置照上游
        #expect(plan(["bt", "usb"], align: true, streams: ["usb": 2]).isStacked == true)   // 多串流裝置：不對齊
        #expect(plan(["bt", "gone"], align: true, streams: ["gone": 0]).isStacked == true) // 讀不到：不對齊
    }
}

/// 測試用的輸出緩衝區清單
private final class Outputs {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    init(channels: [Int], frames: Int) {
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (i, ch) in channels.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * ch)
            p.initialize(repeating: -1, count: frames * ch)
            storage.append(p)
            list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: UnsafeMutableRawPointer(p))
        }
    }
    deinit { storage.forEach { $0.deallocate() }; free(list.unsafeMutablePointer) }
    func sample(_ buffer: Int, _ index: Int) -> Float { storage[buffer][index] }
}

@Suite struct OutputAlignerTests {
    /// 連續餵一個「第 k 個 frame 的值＝k+1」的訊號，回傳每個輸出收到的左聲道
    private func run(_ aligner: OutputAligner, blocks: Int, frames: Int, channels: [Int], onBlock: (Int) -> Void = { _ in }) -> [[Float]] {
        let outs = Outputs(channels: channels, frames: frames)
        var got = [[Float]](repeating: [], count: channels.count)
        var k: Float = 1
        for b in 0..<blocks {
            onBlock(b)
            for i in 0..<frames { aligner.scratch[i * 2] = k; aligner.scratch[i * 2 + 1] = -k; k += 1 }
            aligner.distribute(frameCount: frames, to: outs.list)
            for (j, ch) in channels.enumerated() {
                for i in 0..<frames { got[j].append(outs.sample(j, i * ch)) }
            }
        }
        return got
    }

    @Test func 各輸出照自己的延遲出來_延遲零的原樣通過() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [0, 700])
        let got = run(aligner, blocks: 4, frames: 512, channels: [2, 2])
        #expect(got[0][0] == 1 && got[0][1500] == 1501)
        // 第二個輸出前 700 個 frame 是靜音，之後是 700 個 frame 以前的訊號
        #expect(got[1][0..<700].allSatisfy { $0 == 0 })
        #expect(got[1][700] == 1 && got[1][1500] == 801 && got[1][2047] == 1348)
    }

    @Test func 右聲道_單聲道與多聲道輸出() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [0, 0, 0])
        let outs = Outputs(channels: [2, 1, 4], frames: 4)
        for i in 0..<4 { aligner.scratch[i * 2] = 0.5; aligner.scratch[i * 2 + 1] = 0.25 }
        aligner.distribute(frameCount: 4, to: outs.list)
        #expect(outs.sample(0, 0) == 0.5 && outs.sample(0, 1) == 0.25)
        #expect(outs.sample(1, 0) == 0.375)                                   // 單聲道：左右平均
        #expect(outs.sample(2, 0) == 0.5 && outs.sample(2, 1) == 0.25 && outs.sample(2, 2) == 0 && outs.sample(2, 3) == 0)
    }

    @Test func 繞過環狀緩衝區的尾端還是對的() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [300])
        let blocks = aligner.capacity / 512 + 8          // 寫超過一整圈
        let got = run(aligner, blocks: blocks, frames: 512, channels: [2])
        let last = blocks * 512 - 1
        #expect(got[0][last] == Float(last + 1 - 300))
        #expect(got[0][aligner.capacity + 5] == Float(aligner.capacity + 5 + 1 - 300))
    }

    @Test func 改延遲時交叉淡化_之後穩定在新延遲_過程不跳到範圍外() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [100])
        let got = run(aligner, blocks: 8, frames: 512, channels: [2]) { b in
            if b == 2 { aligner.setDelays([400]) }
        }
        #expect(got[0][1023] == 1024 - 100)                 // 改之前
        let after = 4 * 512                                  // 淡化（約 960 個 frame）做完之後
        #expect(got[0][after] == Float(after + 1 - 400))
        // 淡化期間每個值都落在舊位置與新位置的值之間
        for i in 1024..<(1024 + 960) {
            let old = Float(i + 1 - 100), new = Float(i + 1 - 400)
            #expect(got[0][i] <= old + 0.01 && got[0][i] >= new - 0.01)
        }
    }

    @Test func 延遲超過緩衝區會被夾住_多出來的輸出不延遲_靜音會把緩衝區沖掉() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [10_000_000])
        #expect(aligner.targetDelays[0] == aligner.capacity - OutputAligner.maxBlockFrames - 1)
        #expect(aligner.targetDelays[1] == 0)

        let b = OutputAligner(sampleRate: 48000, delayFrames: [256])
        _ = run(b, blocks: 1, frames: 512, channels: [2])
        b.advanceSilence(frameCount: 512)
        let outs = Outputs(channels: [2], frames: 512)
        for i in 0..<1024 { b.scratch[i] = 9 }
        b.distribute(frameCount: 512, to: outs.list)
        // 靜音之後的第一輪：前 256 個 frame 讀到的是靜音期間寫的 0，不是靜音前的聲音
        #expect((0..<256).allSatisfy { outs.sample(0, $0 * 2) == 0 })
        #expect(outs.sample(0, 256 * 2) == 9)
    }
}

@Suite struct OutputAlignerGainTests {
    @Test func 增益乘在延遲之後_各輸出同一個時間點一起變() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [0, 300])
        let outs = Outputs(channels: [2, 2], frames: 512)
        for i in 0..<1024 { aligner.scratch[i] = 1 }
        aligner.distribute(frameCount: 512, to: outs.list, gain: 1)
        for i in 0..<1024 { aligner.scratch[i] = 1 }
        aligner.distribute(frameCount: 512, to: outs.list, gain: 0.25)
        // 第二輪：兩個輸出都已經有聲音，而且都是 0.25（延遲的那個不會還停在舊的增益）
        #expect(outs.sample(0, 0) == 0.25 && outs.sample(1, 0) == 0.25 && outs.sample(1, 511 * 2) == 0.25)
        #expect(abs(aligner.maxDelayMs - 6.25) < 0.001)
    }

    @Test func 靜音比延遲短_解除後也不會吐出靜音前的聲音() {
        let aligner = OutputAligner(sampleRate: 48000, delayFrames: [2000])
        let outs = Outputs(channels: [2], frames: 512)
        for _ in 0..<8 {
            for i in 0..<1024 { aligner.scratch[i] = 7 }
            aligner.distribute(frameCount: 512, to: outs.list)
        }
        aligner.advanceSilence(frameCount: 512)          // 只靜音 512 個 frame，比延遲 2000 短
        var heardOld = false
        for _ in 0..<3 {                                  // 接下來 1536 個 frame 都還在延遲之內
            for i in 0..<1024 { aligner.scratch[i] = 3 }
            aligner.distribute(frameCount: 512, to: outs.list)
            for i in 0..<512 where outs.sample(0, i * 2) == 7 { heardOld = true }
        }
        #expect(!heardOld)
    }
}
