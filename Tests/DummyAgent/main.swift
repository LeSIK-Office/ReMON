import Darwin
import Foundation

// 시험 전용 더미 에이전트. 실제 세션·앱 대신 종료·연출 시험에 쓴다(사양 12장).
// 사용: <이름> --children N --cpu P --lifetime S
// SIGTERM을 받으면 자식에게 SIGTERM을 보내고 정상 종료한다. 안전을 위해 lifetime(기본 600초) 뒤 스스로 끝난다.
var children: [pid_t] = []
// --child-arg <값>: 자식 인자에 덧붙인다(여러 번). 자기 인자에서는 빼서 자식용 플래그(--ignore-term 등)가 부모에 걸리지 않게 한다.
var childArgs: [String] = []
var ownArguments: [String] = []
var scan = 0
while scan < CommandLine.arguments.count {
    let word = CommandLine.arguments[scan]
    if word == "--child-arg", scan + 1 < CommandLine.arguments.count { childArgs.append(CommandLine.arguments[scan + 1]); scan += 2 } else { ownArguments.append(word); scan += 1 }
}
let arguments = ownArguments
func value(_ flag: String, _ fallback: Double) -> Double {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return Double(arguments[index + 1]) ?? fallback
}
let childCount = Int(value("--children", 2))
let cpu = max(0, min(50, value("--cpu", 0)))
let lifetime = value("--lifetime", 600)
// --child-binary <경로>: 자식을 /bin/sleep 대신 이 실행 파일로 띄운다(시스템 경로가 아닌 보조 프로세스 시험용).
// 자식은 덧붙인 인자 뒤에 --children 0 --lifetime(부모+5초)을 받는다.
let childBinary = arguments.firstIndex(of: "--child-binary").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }

for _ in 0..<childCount {
    var pid: pid_t = 0
    let program = childBinary ?? "/bin/sleep"
    let words = childBinary == nil ? [program, String(Int(lifetime) + 5)] : [program] + childArgs + ["--children", "0", "--lifetime", String(Int(lifetime) + 5)]
    let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    if posix_spawn(&pid, program, nil, nil, argv, environ) == 0 { children.append(pid) }
    argv.forEach { free($0) }
}

// --listen-tcp <포트> / --listen-udp <포트>: 127.0.0.1에 소켓을 열어 둔다(0 = 임의 포트, 리슨 포트 감지 시험용). 외부 인터페이스는 열지 않는다.
var sockets: [Int32] = []
for (flag, type) in [("--listen-tcp", SOCK_STREAM), ("--listen-udp", SOCK_DGRAM)] {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count, let port = UInt16(arguments[index + 1]) else { continue }
    let fd = socket(AF_INET, type, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if bound == 0, type == SOCK_STREAM { listen(fd, 8) }
    sockets.append(fd)
}

signal(SIGTERM, SIG_IGN)
// --ignore-term: SIGTERM에 응답하지 않는 고집 센 프로세스(SIGKILL 단계 시험용)
let ignoreTerm = arguments.contains("--ignore-term")
let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
source.setEventHandler {
    guard !ignoreTerm else { return }
    for child in children { kill(child, SIGTERM) }
    exit(0)
}
source.resume()
// --hold-file <경로>: 파일을 열어 둔다(열린 파일 보호 시험용)
var heldFile: FileHandle?
if let index = arguments.firstIndex(of: "--hold-file"), index + 1 < arguments.count {
    FileManager.default.createFile(atPath: arguments[index + 1], contents: Data("held".utf8))
    heldFile = FileHandle(forReadingAtPath: arguments[index + 1])
}

let started = Date()
DispatchQueue.global().async {
    while Date().timeIntervalSince(started) < lifetime {
        // 최적화가 쓰기 전용 전역 변수를 없애 파일이 바로 닫히던 문제: 반복마다 사용해 열린 상태를 유지한다.
        if let handle = heldFile { _ = handle.offsetInFile }
        if cpu > 0 {
            let busyUntil = Date().addingTimeInterval(0.1 * cpu / 100)
            var x = 1.0
            while Date() < busyUntil { x = x * 1.000001 + 1 }
            usleep(useconds_t(100_000 * (1 - cpu / 100)))
            _ = x
        } else {
            usleep(200_000)
        }
    }
    for child in children { kill(child, SIGTERM) }
    exit(0)
}
dispatchMain()
