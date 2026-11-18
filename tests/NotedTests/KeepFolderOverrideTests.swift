import Foundation
import Testing
@testable import ShotLineKit

/// 使用者自選收好位置：選得到、不能用的擋下、不見了退回預設、不碰 inboxSavedSettings。
@Suite(.serialized)
struct KeepFolderOverrideTests {
    private let overrideKey = "inboxKeepFolderOverride"
    private let savedKey = "inboxSavedSettings"

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/claude-501/noted-keepfolder-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 前後都清掉，不留測試的鍵
    private func clean(_ body: () throws -> Void) rethrows {
        let d = UserDefaults.standard
        let beforeOverride = d.object(forKey: overrideKey), beforeSaved = d.object(forKey: savedKey)
        d.removeObject(forKey: overrideKey)
        defer {
            if let beforeOverride { d.set(beforeOverride, forKey: overrideKey) } else { d.removeObject(forKey: overrideKey) }
            if let beforeSaved { d.set(beforeSaved, forKey: savedKey) } else { d.removeObject(forKey: savedKey) }
        }
        try body()
    }

    @Test func choosingUsableFolderTakesEffect() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        clean {
            #expect(Inbox.setCustomKeepFolder(dir))
            #expect(Inbox.keepFolder.standardizedFileURL == dir.standardizedFileURL)
            #expect(Inbox.unusableCustomKeepPath == nil)
        }
    }

    @Test func resetGoesBackToDefaultRule() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        clean {
            let defaultFolder = Inbox.keepFolder
            #expect(Inbox.setCustomKeepFolder(dir))
            Inbox.resetCustomKeepFolder()
            #expect(Inbox.customKeepPath == nil)
            #expect(Inbox.keepFolder == defaultFolder)
        }
    }

    @Test func missingFolderIsRefusedAndNotSaved() {
        clean {
            let missing = URL(fileURLWithPath: "/private/tmp/claude-501/noted-no-such-\(UUID().uuidString)", isDirectory: true)
            #expect(!Inbox.setCustomKeepFolder(missing))
            #expect(Inbox.customKeepPath == nil)
        }
    }

    @Test func plainFileIsRefused() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        clean {
            #expect(!Inbox.setCustomKeepFolder(file))
        }
    }

    @Test func unwritableFolderIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        clean {
            #expect(!Inbox.setCustomKeepFolder(dir))
        }
    }

    @Test func inboxFolderItselfAndInsideAreRefused() throws {
        // 用暫存的「假收件匣」：資料夾真的存在、可寫，才會走到收件匣排除那一行
        let inbox = try scratch(); defer { try? FileManager.default.removeItem(at: inbox) }
        let sub = inbox.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = inbox.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        defer { try? FileManager.default.removeItem(at: link) }
        let sibling = inbox.deletingLastPathComponent().appendingPathComponent(inbox.lastPathComponent + "-other", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        #expect(!Inbox.usableKeepFolder(inbox, inbox: inbox))
        #expect(!Inbox.usableKeepFolder(sub, inbox: inbox))
        #expect(!Inbox.usableKeepFolder(link, inbox: inbox))          // 指進收件匣的捷徑也擋
        #expect(Inbox.usableKeepFolder(sibling, inbox: inbox))        // 名字只是前綴相同的兄弟資料夾要放行
    }

    @Test func vanishedFolderFallsBackAndReportsIt() throws {
        let dir = try scratch()
        try clean {
            let defaultFolder = Inbox.keepFolder
            #expect(Inbox.setCustomKeepFolder(dir))
            try FileManager.default.removeItem(at: dir)
            #expect(Inbox.keepFolder == defaultFolder)
            #expect(Inbox.unusableCustomKeepPath.map { URL(fileURLWithPath: $0).lastPathComponent } == dir.lastPathComponent)
            // 資料夾回來了就又生效，不需要重選
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(Inbox.keepFolder.standardizedFileURL == dir.standardizedFileURL)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func overrideNeverTouchesSavedSystemSettings() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        clean {
            let saved: [String: Any] = ["location": "/Users/example/Pictures", "thumbnail": true]
            UserDefaults.standard.set(saved, forKey: savedKey)
            #expect(Inbox.setCustomKeepFolder(dir))
            Inbox.resetCustomKeepFolder()
            let after = UserDefaults.standard.dictionary(forKey: savedKey)
            #expect(after?["location"] as? String == "/Users/example/Pictures")
            #expect(after?["thumbnail"] as? Bool == true)
        }
    }
}
