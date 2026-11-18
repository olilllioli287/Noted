import AppKit
import Foundation
import Testing
@testable import ShotLineKit

/// 截圖一出現就要馬上收（不再等 0.2 秒），但寫到一半的圖不能收、也不能漏。
@Suite(.serialized)
@MainActor
struct ScreenshotWatcherTests {
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/claude-501/noted-watcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<300 { for y in 0..<200 { rep.setColor(NSColor(red: CGFloat(x) / 300, green: CGFloat(y) / 200, blue: 0.4, alpha: 1), atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    /// 等到條件成立或逾時（讓主執行緒的資料夾事件有機會跑）
    private func wait(_ seconds: Double, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func finishedImageIsReportedWithoutWaitingTwoTenths() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [(URL, Date)] = []
        let watcher = ScreenshotWatcher(folder: dir, anyImage: true, onNew: { reported.append(($0, Date())) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))   // 讓監看先就緒
        let data = try pngData()
        let written = Date()
        try data.write(to: dir.appendingPathComponent("Screenshot.png"), options: .atomic)
        await wait(1) { !reported.isEmpty }
        watcher.stop()
        #expect(reported.count == 1)
        let delay = reported.first.map { $0.1.timeIntervalSince(written) } ?? 99
        #expect(delay < 0.15, "收到的延遲 \(delay) 秒；原本固定要等 0.2 秒")
    }

    @Test func halfWrittenImageWaitsUntilItIsCompleteAndIsReportedOnce() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [URL] = []
        let watcher = ScreenshotWatcher(folder: dir, anyImage: true, onNew: { reported.append($0) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        let data = try pngData()
        let file = dir.appendingPathComponent("Half.png")
        try data.prefix(data.count - 20).write(to: file)     // 少了結尾（IEND），還沒寫完
        try await Task.sleep(for: .milliseconds(120))
        #expect(reported.isEmpty, "寫到一半的圖不能先收")
        try data.write(to: file)                              // 補完
        await wait(1.5) { !reported.isEmpty }
        try await Task.sleep(for: .milliseconds(500))         // 之後的補掃不能再報一次
        watcher.stop()
        #expect(reported.count == 1)
    }

    @Test func brokenImageIsStillReportedEventually() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [URL] = []
        let watcher = ScreenshotWatcher(folder: dir, anyImage: true, onNew: { reported.append($0) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("Broken.png"))   // 永遠解不開
        await wait(2) { !reported.isEmpty }
        watcher.stop()
        #expect(reported.count == 1, "解不開的檔案不能永遠被卡住，最多晚一點照樣報")
    }

    /// macOS 的「這是截圖」標記
    private func tag(_ url: URL) {
        let value = Data("1".utf8)
        _ = value.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
    }

    @Test func screenshotTaggedJustAfterItAppearsOnTheDesktopIsNotMissed() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [URL] = []
        let watcher = ScreenshotWatcher(folder: dir, tagged: true, onNew: { reported.append($0) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        let file = dir.appendingPathComponent("Screenshot.png")
        try pngData().write(to: file)                          // 先出現、還沒標記
        try await Task.sleep(for: .milliseconds(50))
        tag(file)                                              // 標記晚一點才到
        await wait(1.5) { !reported.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        watcher.stop()
        #expect(reported.count == 1, "標記晚到的真截圖不能被當成別的圖而永遠錯過")
    }

    @Test func untaggedImageOnTheDesktopIsStillIgnored() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [URL] = []
        let watcher = ScreenshotWatcher(folder: dir, tagged: true, onNew: { reported.append($0) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        try pngData().write(to: dir.appendingPathComponent("Downloaded.png"))   // 從頭到尾沒有截圖標記
        try await Task.sleep(for: .milliseconds(900))
        watcher.stop()
        #expect(reported.isEmpty, "不是截圖的圖不能掛上來")
    }

    @Test func formatsWithoutAnEndMarkerStillWaitTheOldTwoTenths() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [(URL, Date)] = []
        let watcher = ScreenshotWatcher(folder: dir, anyImage: true, onNew: { reported.append(($0, Date())) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        let written = Date()
        try Data(repeating: 1, count: 2000).write(to: dir.appendingPathComponent("Shot.heic"))   // 沒有簡單的結尾記號
        try await Task.sleep(for: .milliseconds(120))
        #expect(reported.isEmpty, "HEIC 這類格式要照原本的保護，放滿 0.2 秒才收")
        await wait(1) { !reported.isEmpty }
        watcher.stop()
        #expect(reported.count == 1)
        #expect((reported.first?.1.timeIntervalSince(written) ?? 0) >= 0.19)
    }

    @Test func manyFolderEventsDoNotReportAHalfWrittenImageEarly() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        var reported: [Date] = []
        let watcher = ScreenshotWatcher(folder: dir, anyImage: true, onNew: { _ in reported.append(Date()) }, onChange: {})
        watcher.start()
        try await Task.sleep(for: .milliseconds(300))
        let data = try pngData()
        let file = dir.appendingPathComponent("Slow.png")
        try data.prefix(100).write(to: file)
        // 每 20 毫秒又寫一點（每次都會引來資料夾事件），寫了 0.3 秒才寫完
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        let rest = data.dropFirst(100)
        let step = max(1, rest.count / 14)
        var offset = rest.startIndex
        while offset < rest.endIndex {
            let end = min(rest.endIndex, offset + step)
            handle.write(rest[offset..<end])
            offset = end
            if offset < rest.endIndex {
                try await Task.sleep(for: .milliseconds(20))
                #expect(reported.isEmpty, "還沒寫完不能報（事件再多也一樣）")
            }
        }
        try handle.close()
        await wait(1) { !reported.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        watcher.stop()
        #expect(reported.count == 1)
    }
}
