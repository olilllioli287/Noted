import XCTest
@testable import Noted

final class GamePauseTests: XCTestCase {
    private let rules = GamePauseRules(keywords: GamePauseRules.defaultKeywords, useCategory: true, useFullscreen: false)

    func testStarCraftUnderWineMatchesByExecutablePath() {
        let app = FrontAppInfo(bundleID: nil, name: "wine",
                               executablePath: "/Users/x/Library/Application Support/SC2-Wine/engine/bin/wine",
                               arguments: ["wine", "C:\\Program Files (x86)\\StarCraft II\\Versions\\Base1\\SC2_x64.exe"])
        XCTAssertNotNil(rules.match(app))
    }

    func testWineGameMatchesByArgumentsOnly() {
        let only = GamePauseRules(keywords: ["GenshinImpact"], useCategory: false, useFullscreen: false)
        let app = FrontAppInfo(bundleID: nil, name: "preloader", executablePath: "/opt/x/bin/preloader",
                               arguments: ["preloader", "Z:\\games\\GenshinImpact.exe"])
        XCTAssertNotNil(only.match(app))
    }

    func testOrdinaryAppsDoNotMatch() {
        for (id, name, path) in [("com.apple.Safari", "Safari", "/Applications/Safari.app/Contents/MacOS/Safari"),
                                 ("com.apple.Terminal", "終端機", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
                                 ("com.hnc.Discord", "Discord", "/Applications/Discord.app/Contents/MacOS/Discord")] {
            let app = FrontAppInfo(bundleID: id, name: name, executablePath: path, arguments: [path],
                                   category: "public.app-category.productivity", coversScreen: true)
            XCTAssertNil(rules.match(app), name)
        }
    }

    func testKeywordIsCaseInsensitiveAndBlankIgnored() {
        let r = GamePauseRules(keywords: ["  ", "league OF legends"], useCategory: false, useFullscreen: false)
        XCTAssertNotNil(r.match(FrontAppInfo(bundleID: "com.riotgames.LeagueofLegends.GameClient", name: "League of Legends")))
        XCTAssertNil(r.match(FrontAppInfo(bundleID: "com.apple.finder", name: "Finder")))
    }

    func testCategoryGames() {
        let app = FrontAppInfo(bundleID: "com.example.g", name: "G", category: "public.app-category.strategy-games")
        XCTAssertNotNil(rules.match(app))
        var off = rules; off.useCategory = false
        XCTAssertNil(off.match(app))
        XCTAssertNotNil(rules.match(FrontAppInfo(name: "H", category: "public.app-category.games")))
    }

    func testFullscreenOnlyWhenEnabled() {
        let app = FrontAppInfo(bundleID: "com.apple.QuickTimePlayerX", name: "QuickTime Player", coversScreen: true)
        XCTAssertNil(rules.match(app))
        var on = rules; on.useFullscreen = true
        XCTAssertNotNil(on.match(app))
    }

    func testParseProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { bytes.append(contentsOf: $0) }
        bytes += Array("/bin/wine".utf8) + [0, 0, 0]
        bytes += Array("wine".utf8) + [0] + Array("SC2_x64.exe".utf8) + [0] + Array("HOME=/x".utf8) + [0]
        XCTAssertEqual(GamePause.parseProcArgs(bytes), ["wine", "SC2_x64.exe"])
        XCTAssertEqual(GamePause.parseProcArgs([1, 0]), [])
        XCTAssertFalse(GamePause.processArguments(getpid()).isEmpty)
    }
}
