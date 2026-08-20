// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipHistory",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // AppKit を含む非UIロジック（設定・DB・BLOB管理・履歴ストア・正規化・クリップボード監視）。
        // ユニットテストはこのターゲットのうち AppKit に依存しない部分のみを対象にする。
        .target(
            name: "ClipHistoryCore",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // 実行可能ターゲット。メニューバー常駐アプリ本体。
        .executableTarget(
            name: "ClipHistory",
            dependencies: [
                "ClipHistoryCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ClipHistoryCoreTests",
            dependencies: [
                "ClipHistoryCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
