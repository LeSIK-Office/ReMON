// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReMON",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "ReMON", targets: ["ReMON"])],
    targets: [
        // 시스템 SQLite(Codex 상태 DB 읽기 전용) · zlib(압축된 Claude 기록 앞부분) — 외부 패키지 없이 SDK 라이브러리만.
        .target(name: "ReMONCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]),
        .executableTarget(name: "ReMON", dependencies: ["ReMONCore"]),
        .executableTarget(name: "ReMONChecks", dependencies: ["ReMONCore"], path: "Tests/ReMONChecks"),
        .executableTarget(name: "DummyAgent", path: "Tests/DummyAgent")
    ],
    swiftLanguageModes: [.v5]
)
