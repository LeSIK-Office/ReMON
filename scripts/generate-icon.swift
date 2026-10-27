// ReMON 앱 아이콘 생성: 엄지척(따봉) 하는 픽셀 직원(32×32 픽셀을 정수 배율로 키움).
// 그림은 앱 코드 한 곳에서만 그린다 — CharacterArt의 thumbsUp 자세 + AppIcon(둥근 사각 · 하늘 배경 · 마루 띠 · 반짝이).
// 실행 중 Dock 아이콘(사용자마다 무작위 직원)과 같은 그림 코드라, 번들 아이콘은 그중 '기본 직원'(코랄 후드)이다.
// 이 스크립트는 앱을 빌드하고 `ReMON --render-icon`으로 iconset을 만든 뒤 iconutil로 Resources/ReMON.icns를 갱신한다.
// 사용: swift scripts/generate-icon.swift                → Resources/ReMON.icns 갱신
//       swift scripts/generate-icon.swift <폴더.iconset>  → iconset PNG만 만든다
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = root
    do { try process.run() } catch { print("실행 실패: \(tool) \(error)"); return 1 }
    process.waitUntilExit()
    return process.terminationStatus
}

guard run("/usr/bin/swift", ["build", "--product", "ReMON"]) == 0 else { print("빌드 실패"); exit(1) }
let explicit = CommandLine.arguments.dropFirst().first
let iconset = explicit ?? FileManager.default.temporaryDirectory.appendingPathComponent("ReMON-\(ProcessInfo.processInfo.processIdentifier).iconset").path
guard run(root.appendingPathComponent(".build/debug/ReMON").path, ["--render-icon", iconset]) == 0 else { print("iconset 생성 실패"); exit(1) }
if explicit == nil {
    let icns = root.appendingPathComponent("Resources/ReMON.icns").path
    guard run("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", icns]) == 0 else { print("iconutil 실패"); exit(1) }
    try? FileManager.default.removeItem(atPath: iconset)
    print("icns: \(icns)")
} else {
    print("iconset: \(iconset)")
}
