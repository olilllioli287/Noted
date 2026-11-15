import Foundation
import Testing
@testable import Noted

@Suite
struct StorePersistenceTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NotedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func unreadableStoreIsNeverOverwritten() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("store.json")
        try Data("not json".utf8).write(to: file)
        let store = Store(dir: dir)
        #expect(store.loadError != nil)
        store.scheduleSave()
        store.saveNow()
        #expect(String(data: try Data(contentsOf: file), encoding: .utf8) == "not json")
    }

    @Test
    func validStoreCanBeSaved() throws {
        let dir = try temporaryDirectory()
        let store = Store(dir: dir)
        store.saveNow()
        let file = dir.appendingPathComponent("store.json")
        let data = try Data(contentsOf: file)
        #expect(String(data: data, encoding: .utf8)?.contains("Noted") == true)
    }
}
