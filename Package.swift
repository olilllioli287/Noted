// swift-tools-version:6.2
import PackageDescription

// Noted 三合一：筆記（Noted）＋截圖（ShotLineKit，MIT）＋音量（FineTuneKit，GPL-3.0）
let package = Package(
    name: "Noted",
    platforms: [.macOS("15.4")],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Noted",
            dependencies: ["ShotLineKit", "FineTuneKit", "KeyboardShortcuts"],
            path: "Sources/Noted",
            swiftSettings: [.swiftLanguageMode(.v5), .define("NOTED_PUBLIC")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ShotLineKit",
            path: "Sources/ShotLineKit",
            exclude: ["LICENSE"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 上游 FineTune 的編譯設定：Swift 6、Approachable Concurrency、MemberImportVisibility、ENABLE_TCC_SPI
        .target(
            name: "FineTuneKit",
            dependencies: ["KeyboardShortcuts"],
            path: "Sources/FineTuneKit",
            exclude: ["LICENSE"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .define("ENABLE_TCC_SPI"),
            ]
        ),
        .testTarget(
            name: "NotedTests",
            dependencies: ["Noted", "ShotLineKit"],
            path: "tests/NotedTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FineTuneKitTests",
            dependencies: ["FineTuneKit"],
            path: "tests/FineTuneKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
