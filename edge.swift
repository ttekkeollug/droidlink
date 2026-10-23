// edge: droidlink 본체. 연결 창(USB·Wi-Fi·블루투스, 커서·스크롤 속도, 폰 위치)을 보여 주고,
// 맥 화면 끝 ↔ 폰 화면 끝으로 커서·키보드·트랙패드를 넘긴다.
// 폰에는 scrcpy 서버만 띄우고, 맥의 입력은 이 앱이 직접 가상 USB 키보드·마우스(UHID)로 보낸다 — scrcpy 창이나 앱은 뜨지 않는다.
// 사용: edge   (ANDROID_SERIAL로 기기 지정 가능). droidlink.app으로 묶으면 Finder에서 바로 실행된다.
import AppKit

let edgeMargin = 1.0      // 맥 화면 끝 판정 여유(px)
let armX = 30.0           // 폰에서 돌아가는 쪽 끝으로부터 이만큼 안쪽에 들어가야 복귀 판정 시작
let returnInset = 40.0    // 맥으로 돌아올 때 화면 끝에서 띄울 거리
let launchSerial = ProcessInfo.processInfo.environment["ANDROID_SERIAL"].flatMap { $0.isEmpty ? nil : $0 }  // droidlink IP:PORT로 지정한 기기
let env = URL(fileURLWithPath: "/usr/bin/env")
signal(SIGPIPE, SIG_IGN)

// MARK: 도구 위치 — droidlink.app 안의 adb·scrcpy-server를 쓰고, 없으면(저장소에서 바로 실행) .build의 것과 Homebrew adb를 쓴다.
// Finder에서 실행한 앱은 PATH에 Homebrew가 없어서 직접 넣어 준다.
let scrcpyVersion = "5.0.1"  // 서버 파일과 버전이 정확히 같아야 한다 (build-app.sh의 scrcpy_version)
let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
let bundledTools = Bundle.main.resourceURL.map { $0.appendingPathComponent("scrcpy").path }
    .flatMap { FileManager.default.isExecutableFile(atPath: $0 + "/adb") ? $0 : nil }
setenv("PATH", (bundledTools.map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:" +
       (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"), 1)
let serverPath = [bundledTools.map { $0 + "/scrcpy-server" }, exeDir + "/.build/scrcpy-\(scrcpyVersion)/aarch64/scrcpy-server"]
    .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }

// MARK: 설정 — 스크롤 속도는 맥에 저장, 커서 속도는 폰의 pointer_speed 설정(-7~7)을 직접 바꾼다.
var scrollSpeed = UserDefaults.standard.object(forKey: "scrollSpeed") as? Double ?? 4  // 1~10
var scrollPointsPerStep: Double { 200 / scrollSpeed }  // 안드로이드 휠 한 칸에 해당하는 맥 스크롤 거리(pt)

// MARK: adb
func run(_ args: [String]) -> String {  // 짧은 명령을 기다렸다가 결과를 받는다
    let p = Process(), pipe = Pipe()
    p.executableURL = env
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
func adb(_ args: [String]) -> String { run(["adb"] + args) }
func adbSucceeds(_ args: [String]) -> Bool {  // 출력이 아니라 종료 코드로 성공을 본다 (adb push는 결과를 stderr에 쓴다)
    let p = Process()
    p.executableURL = env
    p.arguments = ["adb"] + args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
let missingTools = (run(["which", "adb"]).isEmpty ? ["adb"] : []) + (serverPath == nil ? ["scrcpy-server"] : [])

// 계속 열어 두는 `adb shell`. 스크롤과 제스처를 다른 채널로 보내서 서로 기다리지 않게 한다.
var shells: [String: (process: Process, input: FileHandle)] = [:]
func androidShell(_ command: String, channel: String = "gesture", _ name: String? = nil) {
    if shells[channel] == nil {
        let p = Process(), pipe = Pipe()
        p.executableURL = env
        p.arguments = ["adb", "shell"]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        shells[channel] = (p, pipe.fileHandleForWriting)
    }
    shells[channel]?.input.write(Data("\(command)\n".utf8))
    if let name { print("  제스처: \(name)") }
}
func androidKey(_ code: Int, _ name: String) { androidShell("input keyevent \(code)", name) }

// "Physical size: 1080x2340" / "Override size: ..." 중 마지막 값 (덮어쓴 해상도가 있으면 그것)
func parseSize(_ text: String) -> (w: Int, h: Int)? {
    guard let last = text.split(separator: "\n").last(where: { $0.contains("size:") }),
          let dims = last.split(separator: " ").last?.split(separator: "x"), dims.count == 2,
          let w = Int(dims[0]), let h = Int(dims[1]) else { return nil }
    return (w, h)
}
assert(parseSize("Physical size: 1080x2340\nOverride size: 720x1560")! == (720, 1560))

// 폴러 출력 한 줄: "<deviceId> <x> <y>"
func parsePos(_ line: String) -> (x: Double, y: Double)? {
    let f = line.split(separator: " ").compactMap { Double($0) }
    return f.count == 3 ? (f[1], f[2]) : nil
}
assert(parsePos("16 257.995 2308.08")! == (257.995, 2308.08))

// MARK: scrcpy 서버 프로토콜 (scrcpy 5.0.1, 빅엔디언)
// UHID_CREATE: 12, id u16, vendor u16, product u16, 이름 길이 u8 + 이름, 디스크립터 길이 u16 + 디스크립터
// UHID_INPUT:  13, id u16, 보고서 길이 u16 + 보고서
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func uhidCreate(id: Int, descriptor: [UInt8]) -> [UInt8] { [12] + be16(id) + be16(0) + be16(0) + [0] + be16(descriptor.count) + descriptor }
func uhidInput(id: Int, report: [UInt8]) -> [UInt8] { [13] + be16(id) + be16(report.count) + report }
assert(uhidInput(id: 2, report: [1, 2]) == [13, 0, 2, 0, 2, 1, 2])
assert(uhidCreate(id: 1, descriptor: [9]) == [12, 0, 1, 0, 0, 0, 0, 0, 0, 1, 9])

let keyboardID = 1, mouseID = 2
// scrcpy의 hid_keyboard.c / hid_mouse.c와 같은 표준 부트 키보드·마우스 디스크립터
let keyboardDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x01, 0x05, 0x08, 0x19, 0x01,
    0x29, 0x05, 0x75, 0x01, 0x95, 0x05, 0x91, 0x02, 0x75, 0x03, 0x95, 0x01, 0x91, 0x01, 0x05, 0x07,
    0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, 0x95, 0x06, 0x81, 0x00, 0xC0,
]
let mouseDescriptor: [UInt8] = [
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x05,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
    0x81, 0x06, 0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81,
    0x06, 0xC0, 0xC0,
]

// 폰에 scrcpy 서버를 영상·소리 없이 띄우고 adb 터널로 제어 소켓 하나만 연결한다.
final class ScrcpyServer {
    let serial: String
    let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
    var process: Process?, fd: Int32 = -1, port = 0
    var deviceName = ""

    init(serial: String) { self.serial = serial }

    // 백그라운드에서 부른다. 실패하면 이유를 돌려준다.
    func start(onClose: @escaping () -> Void) -> String? {
        guard let serverPath else { return "scrcpy-server 파일이 없습니다" }
        guard adbSucceeds(["-s", serial, "push", serverPath, "/data/local/tmp/scrcpy-server.jar"]) else {
            return "폰에 서버를 보내지 못했습니다 · USB/무선 디버깅 허용을 확인하세요"
        }
        guard let p = Int(adb(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])) else { return "adb 터널을 만들지 못했습니다" }
        port = p
        let proc = Process()
        proc.executableURL = env
        proc.arguments = ["adb", "-s", serial, "shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/",
                          "com.genymobile.scrcpy.Server", scrcpyVersion, "scid=\(scid)", "log_level=info",
                          "video=false", "audio=false", "tunnel_forward=true", "stay_awake=true",
                          "clipboard_autosync=false", "power_on=false"]
        guard (try? proc.run()) != nil else { return "adb를 실행할 수 없습니다" }
        process = proc

        // 터널은 서버가 듣기 전에도 연결되므로, 서버가 보내는 첫 1바이트를 받아야 준비된 것이다
        for _ in 0..<100 {
            if let s = connectAndReadByte() { fd = s; break }
            usleep(100_000)
        }
        guard fd >= 0 else { stop(); return "서버에 연결하지 못했습니다" }
        var name = [UInt8](repeating: 0, count: 64)  // 기기 이름 64바이트
        guard recvAll(&name) else { stop(); return "서버 응답이 없습니다" }
        deviceName = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)

        send(uhidCreate(id: keyboardID, descriptor: keyboardDescriptor))
        send(uhidCreate(id: mouseID, descriptor: mouseDescriptor))

        // 서버가 보내는 메시지(키보드 LED 등)는 읽어서 버린다. 끊기면 알린다.
        let readFD = fd
        Thread {
            var buf = [UInt8](repeating: 0, count: 1024)
            while recv(readFD, &buf, buf.count, 0) > 0 {}
            DispatchQueue.main.async(execute: onClose)
        }.start()
        return nil
    }

    private func connectAndReadByte() -> Int32? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        var byte: UInt8 = 0
        if ok && recv(s, &byte, 1, 0) == 1 { return s }
        close(s)
        return nil
    }

    private func recvAll(_ buf: inout [UInt8]) -> Bool {
        var got = 0
        let total = buf.count
        while got < total {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, total - got, 0) }
            if n <= 0 { return false }
            got += n
        }
        return true
    }

    func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return }
            sent += n
        }
    }

    // 소켓이 닫히면 서버도 스스로 끝난다
    func stop() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        process?.terminate()
        if port != 0 { let p = port, s = serial; DispatchQueue.global().async { _ = adb(["-s", s, "forward", "--remove", "tcp:\(p)"]) } }
    }
}

// MARK: 가상 키보드 — 맥 키코드를 HID 사용 코드로. 맥 습관대로 쓰도록 Cmd ↔ Ctrl을 바꿔 보낸다 (Cmd+C → 안드로이드 Ctrl+C).
let hidUsage: [Int64: UInt8] = [
    0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19, 10: 0x64,
    11: 0x05, 12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17, 18: 0x1E, 19: 0x1F, 20: 0x20,
    21: 0x21, 22: 0x23, 23: 0x22, 24: 0x2E, 25: 0x26, 26: 0x24, 27: 0x2D, 28: 0x25, 29: 0x27, 30: 0x30,
    31: 0x12, 32: 0x18, 33: 0x2F, 34: 0x0C, 35: 0x13, 36: 0x28, 37: 0x0F, 38: 0x0D, 39: 0x34, 40: 0x0E,
    41: 0x33, 42: 0x31, 43: 0x36, 44: 0x38, 45: 0x11, 46: 0x10, 47: 0x37, 48: 0x2B, 49: 0x2C, 50: 0x35,
    51: 0x2A, 53: 0x29, 57: 0x39,
    122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42,
    109: 0x43, 103: 0x44, 111: 0x45,
    114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
    71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C,
    87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61, 82: 0x62, 65: 0x63,
]
// 수정 키: 맥 키코드 → (눌림을 알려 주는 맥 장치별 플래그 비트, HID 수정 키 비트)
let hidModifier: [Int64: (macBit: UInt64, hidBit: UInt8)] = [
    55: (0x08, 0x01), 54: (0x10, 0x10),      // 왼/오른 Cmd → 왼/오른 Ctrl
    59: (0x01, 0x08), 62: (0x2000, 0x80),    // 왼/오른 Ctrl → 왼/오른 Meta
    56: (0x02, 0x02), 60: (0x04, 0x20),      // Shift
    58: (0x20, 0x04), 61: (0x40, 0x40),      // Option → Alt
]
var hidMods: UInt8 = 0, hidKeys: [UInt8] = []
func keyboardReport() -> [UInt8] { [hidMods, 0] + hidKeys + [UInt8](repeating: 0, count: 6 - hidKeys.count) }
func sendKeyboard() { server?.send(uhidInput(id: keyboardID, report: keyboardReport())) }

// 맥 키 이벤트 하나를 HID 상태에 반영한다. 보낼 게 있으면 true.
func applyKey(type: CGEventType, keycode: Int64, flags: UInt64, isRepeat: Bool) -> Bool {
    if type == .flagsChanged {
        if let m = hidModifier[keycode] {
            if flags & m.macBit != 0 { hidMods |= m.hidBit } else { hidMods &= ~m.hidBit }
            return true
        }
        return false  // 한/영(Caps Lock)은 handleTap에서 따로 처리
    }
    guard !isRepeat, let usage = hidUsage[keycode] else { return false }  // 키 반복은 안드로이드가 알아서 한다
    if type == .keyDown { if !hidKeys.contains(usage) && hidKeys.count < 6 { hidKeys.append(usage) } }
    else { hidKeys.removeAll { $0 == usage } }
    return true
}
do {  // Cmd+C → Ctrl(0x01) + C(0x06)
    _ = applyKey(type: .flagsChanged, keycode: 55, flags: 0x100008, isRepeat: false)
    _ = applyKey(type: .keyDown, keycode: 8, flags: 0x100008, isRepeat: false)
    assert(keyboardReport() == [0x01, 0, 0x06, 0, 0, 0, 0, 0])
    _ = applyKey(type: .keyUp, keycode: 8, flags: 0x100008, isRepeat: false)
    _ = applyKey(type: .flagsChanged, keycode: 55, flags: 0, isRepeat: false)
    assert(keyboardReport() == [0, 0, 0, 0, 0, 0, 0, 0])
}

// MARK: 가상 마우스 — 맥 마우스 이동량을 그대로 보낸다 (한 보고서에 ±127까지라 나눠서)
var hidButtons: UInt8 = 0
func sendMouse(dx: Int, dy: Int) {
    var dx = dx, dy = dy
    repeat {
        let x = max(-127, min(127, dx)), y = max(-127, min(127, dy))
        server?.send(uhidInput(id: mouseID, report: [hidButtons, UInt8(bitPattern: Int8(x)), UInt8(bitPattern: Int8(y)), 0, 0]))
        dx -= x; dy -= y
    } while dx != 0 || dy != 0
}
// 한/영: 맥에서는 Caps Lock 키가 한/영 전환이다. 갤럭시(삼성 키보드)는 물리 키보드에서 Shift+Space로 한/영을 바꾸므로 그렇게 보낸다.
// 키 하나에 이벤트가 두 번 오는 경우가 있어 0.3초 안의 반복은 무시한다.
let languageSwitchCombo: (mods: UInt8, key: UInt8) = (0x02, 0x2C)  // 왼쪽 Shift + Space
var lastLanguageSwitch = Date.distantPast
func sendLanguageSwitch() {
    guard Date().timeIntervalSince(lastLanguageSwitch) > 0.3 else { return }
    lastLanguageSwitch = Date()
    let saved = hidMods
    hidMods |= languageSwitchCombo.mods; sendKeyboard()
    hidKeys.append(languageSwitchCombo.key); sendKeyboard()
    hidKeys.removeAll { $0 == languageSwitchCombo.key }; sendKeyboard()
    hidMods = saved; sendKeyboard()
    print("  한/영")
}

func releaseAll() {  // 맥으로 돌아올 때 눌린 채 남는 키·버튼이 없게
    hidKeys = []; hidMods = 0; hidButtons = 0
    sendKeyboard(); sendMouse(dx: 0, dy: 0)
}

// MARK: 맥 커서 잡기 — 폰에 있는 동안 맥 커서를 멈추고 숨긴다 (이동량은 이벤트로 계속 들어온다)
// 배경 앱도 커서를 숨길 수 있게 하는 비공개 설정 (Synergy 등이 쓰는 방식). 없으면 커서가 화면 끝에 보인 채 멈춘다.
do {
    typealias DefaultConnection = @convention(c) () -> Int32
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    let any = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
    if let c = dlsym(any, "_CGSDefaultConnection"), let s = dlsym(any, "CGSSetConnectionProperty") {
        let cid = unsafeBitCast(c, to: DefaultConnection.self)()
        _ = unsafeBitCast(s, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
var cursorHidden = false
func captureMacCursor(_ on: Bool) {
    CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
    if on != cursorHidden {
        _ = on ? CGDisplayHideCursor(CGMainDisplayID()) : CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = on
    }
}

// MARK: 연결 상태 (C 콜백에서도 읽으므로 전역 변수)
var server: ScrcpyServer?, ready = false
var screenSize: (w: Int, h: Int)?  // ponytail: 화면 크기는 연결할 때 한 번만 읽는다. 폰을 돌리면 슬라이드 위치가 어긋남
var onAndroid = false, armed = false, androidPos: (x: Double, y: Double)?
var enterY = 0.0, poller: Process?
let ui = UI()

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
func rightEdge() -> Double { NSScreen.screens.map { $0.frame.maxX }.max() ?? 0 }
func leftEdge() -> Double { NSScreen.screens.map { $0.frame.minX }.min() ?? 0 }

// 폰 위치: 맥의 오른쪽(기본)이면 맥 오른쪽 끝 → 폰, 폰 왼쪽 끝 → 맥. 왼쪽이면 반대.
var phoneOnLeft = UserDefaults.standard.bool(forKey: "phoneOnLeft")
var androidWidth: Double?  // 폰 화면의 지금 가로 폭 (가로 모드면 길어진다)
func atMacEdge(_ x: Double) -> Bool { phoneOnLeft ? x <= leftEdge() + edgeMargin : x >= rightEdge() - edgeMargin }
// 폰 커서가 맥으로 돌아가는 쪽 끝에서 얼마나 떨어져 있는지
func distanceFromReturnEdge(_ x: Double, width: Double) -> Double { phoneOnLeft ? width - 1 - x : x }

// 폰 커서 위치는 dumpsys input의 hover 상태에서 읽는다.
// 다시 연결하면 이전 가상 마우스 기록이 남으므로 가장 최근(가장 큰 DeviceId) 것을 쓴다.
// ponytail: dumpsys를 0.1초마다 폴링. 폰 CPU가 아깝다면 안드로이드 쪽 접근성 서비스로 교체.
func startPoller() {
    let p = Process(), pipe = Pipe()
    p.executableURL = env
    p.arguments = ["adb", "shell", """
        while :; do d=$(dumpsys input 2>/dev/null)
        echo "$d" | sed -n 's/.*DeviceId(\\([0-9]*\\)).*MOUSE) at (\\([0-9.]*\\), \\([0-9.]*\\)).*/\\1 \\2 \\3/p' | sort -n | tail -n1
        echo "$d" | sed -n 's/.*Viewport INTERNAL.*logicalFrame=\\[0, 0, \\([0-9]*\\), [0-9]*\\].*/W \\1/p' | head -n1
        sleep 0.1; done
        """]
    p.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { h in
        let lines = String(decoding: h.availableData, as: UTF8.self).split(separator: "\n")
        let width = lines.last { $0.hasPrefix("W ") }.flatMap { Double($0.dropFirst(2)) }
        let pos = lines.compactMap { parsePos(String($0)) }.last
        DispatchQueue.main.async {
            if let width { androidWidth = width }
            if let pos { androidPos = pos }
        }
    }
    try? p.run()
    poller = p
}

func enter() {
    enterY = cursor().y
    onAndroid = true; armed = false; androidPos = nil; scrollAcc = 0
    captureMacCursor(true)
    sendMouse(dx: 0, dy: 0)  // 폰 커서를 보이게
    startPoller()
    print("→ 폰")
}

func leave(_ why: String = "") {
    print("→ 맥" + why)
    onAndroid = false
    poller?.terminate(); poller = nil
    releaseAll()
    captureMacCursor(false)
    CGWarpMouseCursorPosition(CGPoint(x: phoneOnLeft ? leftEdge() + returnInset : rightEdge() - returnInset, y: enterY))
}

// MARK: 기기 고르기 — USB가 꽂혀 있으면 USB, 없으면 무선(폰이 Wi-Fi로 알리는 주소 → 마지막으로 쓴 주소)
var savedAddress: String? {
    get { UserDefaults.standard.string(forKey: "wirelessAddress") }
    set { UserDefaults.standard.set(newValue, forKey: "wirelessAddress") }
}
var serial = ""  // 지금 연결된 기기. ANDROID_SERIAL로도 넣어서 adb 명령이 모두 이 기기로 간다

func devices() -> [String] {  // `adb devices`에서 사용 가능한(device 상태) 기기들
    adb(["devices"]).split(separator: "\n").dropFirst().compactMap { line in
        let f = line.split(separator: "\t")
        return f.count == 2 && f[1] == "device" ? String(f[0]) : nil
    }
}
func isWireless(_ s: String) -> Bool { s.contains(":") || s.contains("._tcp") }

// `adb mdns services` 줄: "<이름>\t_adb-tls-pairing._tcp\t192.168.0.5:37199"
func mdnsAddress(_ service: String, _ text: String) -> String? {
    text.split(separator: "\n").last { $0.contains(service) }?.split(whereSeparator: \.isWhitespace).last.map(String.init)
}
assert(mdnsAddress("_adb-tls-pairing", "List of discovered mdns services\nadb-R3-x\t_adb-tls-pairing._tcp\t192.168.0.5:37199") == "192.168.0.5:37199")

// `ip -f inet addr show wlan0` 의 "inet 192.168.0.5/24 brd ..." 에서 IP
func parseWlanIP(_ text: String) -> String? {
    guard let r = text.range(of: #"inet ([0-9.]+)/"#, options: .regularExpression) else { return nil }
    return String(text[r].dropFirst(5).dropLast())
}
assert(parseWlanIP("    inet 192.168.45.110/24 brd 192.168.45.255 scope global wlan0") == "192.168.45.110")

func adbConnect(_ address: String) -> Bool {
    guard adb(["connect", address]).contains("connected to") else { return false }  // "already connected to"도 포함
    savedAddress = address
    return true
}

// 블루투스 테더링: 맥에 생긴 블루투스 네트워크의 게이트웨이가 폰이다.
// `networksetup -listallhardwareports`의 "Hardware Port: Bluetooth PAN\nDevice: en5" 블록에서 장치를 찾는다.
func bluetoothDevices(_ ports: String) -> [String] {
    ports.components(separatedBy: "\n\n").filter { $0.localizedCaseInsensitiveContains("bluetooth") }.compactMap { block in
        block.split(separator: "\n").first { $0.hasPrefix("Device: ") }.map { String($0.dropFirst(8)) }
    }
}
assert(bluetoothDevices("Hardware Port: Wi-Fi\nDevice: en0\n\nHardware Port: Bluetooth PAN\nDevice: en5\nEthernet Address: x") == ["en5"])
func bluetoothPhoneAddress() -> String? {
    bluetoothDevices(run(["networksetup", "-listallhardwareports"]))
        .lazy.map { run(["ipconfig", "getoption", $0, "router"]) }.first { !$0.isEmpty }
}

// wireless: nil이면 자동(USB 우선), 값이 있으면 무선만 — 빈 문자열이면 주소를 찾아서, 아니면 그 주소로
func pickDevice(wireless: String?) -> String? {
    if wireless == nil {
        if let launchSerial { return !isWireless(launchSerial) || adbConnect(launchSerial) ? launchSerial : nil }
        let list = devices()
        if let usb = list.first(where: { !isWireless($0) }) { return usb }
        if let any = list.first { return any }
    }
    let typed = wireless.flatMap { $0.isEmpty ? nil : $0 }
    let candidates = typed.map { [$0] } ?? [mdnsAddress("_adb-tls-connect", adb(["mdns", "services"])), savedAddress].compactMap { $0 }
    return candidates.first(where: adbConnect)
}

// MARK: 연결 / 연결 해제
var connecting = false, pendingWireless: String?
func connect(wireless: String? = nil) {
    guard server == nil, !connecting else { return }
    connecting = true
    ui.update(wireless == nil ? "연결 중…" : "무선 연결 중…")
    DispatchQueue.global().async {
        guard let picked = pickDevice(wireless: wireless) else {
            DispatchQueue.main.async {
                connecting = false
                ui.update(wireless == nil ? "연결 실패 · USB 케이블을 꽂거나, 폰에서 무선 디버깅을 켜고 '무선 연결'을 누르세요"
                                          : "무선 연결 실패 · Wi-Fi: 무선 디버깅이 켜져 있고 같은 Wi-Fi인지, 처음이면 페어링 먼저 · 블루투스: [무선 준비 (5555)]를 먼저")
            }
            return
        }
        setenv("ANDROID_SERIAL", picked, 1)
        let s = ScrcpyServer(serial: picked)
        // 직전 연결의 정리가 폰에서 덜 끝나 실패하는 경우가 있어 한 번만 다시 시도한다
        var error = s.start(onClose: disconnected)
        if error != nil { sleep(1); error = s.start(onClose: disconnected) }
        let size = parseSize(adb(["shell", "wm", "size"]))
        let speed = Double(adb(["shell", "settings", "get", "system", "pointer_speed"]))
        DispatchQueue.main.async {
            connecting = false
            if let error { ui.update("연결 실패 · \(error)"); return }
            serial = picked; server = s; ready = true; screenSize = size
            if let speed { ui.cursorSlider.doubleValue = speed }
            ui.update("연결됨 · \(s.deviceName.isEmpty ? "안드로이드" : s.deviceName) · \(isWireless(picked) ? "Wi-Fi" : "USB")")
        }
    }
}

// 이미 연결돼 있으면 끊고 나서 무선으로 다시 연결
func reconnectWireless(_ address: String) {
    if server != nil { pendingWireless = address; disconnect() } else { connect(wireless: address) }
}

func disconnect() { server?.stop() }  // 소켓이 닫히면 disconnected()가 불린다

func disconnected() {
    guard server != nil else { return }
    if onAndroid { leave(" (연결 끊김)") }
    server?.stop(); server = nil; ready = false
    shells.values.forEach { $0.process.terminate() }; shells = [:]
    ui.update("연결 안 됨")
    if let next = pendingWireless { pendingWireless = nil; connect(wireless: next) }
}

// MARK: 스크롤 — 맥 스크롤 이벤트는 버리고 이동량을 모아 30ms마다 폰의 `input mouse scroll`(소수 단위 가능, 약 20ms)로
// 커서 위치에 보낸다. 가상 휠은 한 칸 단위라 트랙패드처럼 부드럽게 안 된다.
var scrollAcc = 0.0

// MARK: 이벤트 탭 — 폰에 있는 동안 맥의 키·마우스·스크롤·제스처 이벤트를 모두 가로채 폰으로 보낸다 (맥에서는 아무 일도 안 일어남)
let debugKeys = ProcessInfo.processInfo.environment["DROIDLINK_DEBUG"] != nil  // 키 이벤트를 터미널에 찍는다
let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31]  // 회전·제스처 시작/끝·제스처·확대(독 스와이프)·스와이프
let mouseMoveTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
let mouseButtonTypes: [CGEventType: (bit: UInt8, down: Bool)] = [
    .leftMouseDown: (0x01, true), .leftMouseUp: (0x01, false), .rightMouseDown: (0x02, true), .rightMouseUp: (0x02, false),
]
var tap: CFMachPort?
let tapMask = ([CGEventType.keyDown, .keyUp, .flagsChanged, .scrollWheel, .otherMouseDown, .otherMouseUp]
               + mouseMoveTypes + Array(mouseButtonTypes.keys)).map { $0.rawValue }
    .reduce(gestureTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }) { $0 | (1 << CGEventMask($1)) }

func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard onAndroid else { return Unmanaged.passUnretained(event) }
    // 비상 탈출: Cmd+Option+Esc (맥 강제 종료 단축키)
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53,
       event.flags.contains([.maskCommand, .maskAlternate]) {
        leave(" (Cmd+Option+Esc)")
        return nil
    }
    if mouseMoveTypes.contains(type) {
        sendMouse(dx: Int(event.getIntegerValueField(.mouseEventDeltaX)), dy: Int(event.getIntegerValueField(.mouseEventDeltaY)))
    } else if let b = mouseButtonTypes[type] ?? (type == .otherMouseDown || type == .otherMouseUp
                ? (UInt8(1 << min(4, max(2, event.getIntegerValueField(.mouseEventButtonNumber)))), type == .otherMouseDown) : nil) {
        if b.down { hidButtons |= b.bit } else { hidButtons &= ~b.bit }
        sendMouse(dx: 0, dy: 0)
    } else if type == .scrollWheel {
        let v = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let h = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        if abs(v) >= abs(h) { scrollAcc += v / scrollPointsPerStep }  // 가로 위주 움직임은 두 손가락 슬라이드가 맡는다
    } else if type == .keyDown || type == .keyUp || type == .flagsChanged {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if debugKeys { print("  키 이벤트 type=\(type.rawValue) keycode=\(keycode) flags=0x\(String(event.flags.rawValue, radix: 16))") }
        if keycode == 57 {  // 한/영(Caps Lock)
            if type != .keyUp { sendLanguageSwitch() }
        } else if applyKey(type: type, keycode: keycode, flags: event.flags.rawValue,
                           isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            sendKeyboard()
        }
    }
    return nil  // 제스처 포함 모두 맥에는 전달하지 않는다
}

// MARK: 트랙패드 제스처 — 폰에 있을 때 손가락 제스처를 안드로이드 동작으로 바꾼다.
// 두 손가락 가로: 화면 슬라이드(터치 스와이프). 두 손가락 세로: 위의 스크롤.
// 세 손가락 이상, 맥과 같은 느낌: 오른쪽 = 뒤로, 왼쪽 = 앞으로, 위 = 최근 앱(Mission Control), 아래 = 홈.
let swipeDistance = 0.12  // 세 손가락: 트랙패드 폭 대비 이동 비율. 너무 민감/둔하면 조절
let slideDistance = 0.15  // 두 손가락 가로 슬라이드 판정 거리

func androidSlide(toLeft: Bool) {
    guard let (w, h) = screenSize else { return }
    let (from, to) = toLeft ? (w * 4 / 5, w / 5) : (w / 5, w * 4 / 5)
    androidShell("input swipe \(from) \(h / 2) \(to) \(h / 2) 120", toLeft ? "← 슬라이드" : "→ 슬라이드")
}

var gestureStart: (x: Double, y: Double, fingers: Int)?, gestureFired = false
func handleTouches(_ n: Int, _ x: Double, _ y: Double) {
    if n == 0 { gestureStart = nil; gestureFired = false; return }
    guard onAndroid, n >= 2, !gestureFired else { return }
    // 손가락 수가 바뀌면(2→3 등) 그 지점부터 다시 잰다
    guard let s = gestureStart, s.fingers == n else { gestureStart = (x, y, n); return }
    let dx = x - s.x, dy = y - s.y
    if n == 2 {
        guard abs(dx) > slideDistance, abs(dx) > 2 * abs(dy) else { return }  // 세로 스크롤과 구분
        gestureFired = true
        androidSlide(toLeft: dx < 0)  // 맥 자연스러운 스크롤처럼 손가락 방향 그대로
        return
    }
    guard max(abs(dx), abs(dy)) > swipeDistance else { return }
    gestureFired = true
    if abs(dx) > abs(dy) {
        dx > 0 ? androidKey(4, "뒤로") : androidKey(125, "앞으로")
    } else {
        dy > 0 ? androidKey(187, "최근 앱") : androidKey(3, "홈")
    }
}

// 비공개 MultitouchSupport 프레임워크로 손가락 좌표를 읽는다 (BetterTouchTool 등이 쓰는 방식).
// 손가락 구조체는 96바이트, 정규화 좌표 x,y는 32/36 바이트 위치의 Float (y는 위로 갈수록 커짐).
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
func onTouchFrame(_ touches: UnsafeMutableRawPointer?, _ n: Int32) -> Int32 {
    guard let touches else { return 0 }
    var x = 0.0, y = 0.0
    for f in 0..<Int(n) {
        x += Double(touches.load(fromByteOffset: f * 96 + 32, as: Float.self))
        y += Double(touches.load(fromByteOffset: f * 96 + 36, as: Float.self))
    }
    let count = Int(n)
    if count > 0 { x /= Double(count); y /= Double(count) }
    DispatchQueue.main.async { handleTouches(count, x, y) }
    return 0
}
func startMultitouch() {
    let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(mt, name).map { unsafeBitCast($0, to: T.self) } }
    guard let createList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>).self),
          let register = sym("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void).self),
          let start = sym("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self) else {
        print("트랙패드 제스처를 읽을 수 없습니다 (MultitouchSupport 없음)."); return
    }
    let devices = createList().takeRetainedValue()
    for i in 0..<CFArrayGetCount(devices) {
        let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(devices, i)!)
        register(dev) { _, touches, n, _, _ in onTouchFrame(touches, n) }
        start(dev, 0)
    }
}

// MARK: 창 — 연결/연결 해제, 무선 연결, 커서 속도, 스크롤 속도, 폰 위치
final class UI: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let status = NSTextField(wrappingLabelWithString: "연결 안 됨")
    lazy var connectButton = NSButton(title: "연결", target: self, action: #selector(connectTapped))
    lazy var disconnectButton = NSButton(title: "연결 해제", target: self, action: #selector(disconnectTapped))
    lazy var pairButton = NSButton(title: "페어링", target: self, action: #selector(pairTapped))
    lazy var wirelessButton = NSButton(title: "무선 연결", target: self, action: #selector(wirelessTapped))
    lazy var openPortButton = NSButton(title: "무선 준비 (5555)", target: self, action: #selector(openPortTapped))
    lazy var bluetoothButton = NSButton(title: "블루투스 연결", target: self, action: #selector(bluetoothTapped))
    let addressField = NSTextField(string: savedAddress ?? "")
    let codeField = NSTextField(string: "")
    lazy var cursorSlider = slider(-7, 7, 0, #selector(cursorChanged))
    lazy var sideControl = NSSegmentedControl(labels: ["왼쪽", "오른쪽"], trackingMode: .selectOne,
                                              target: self, action: #selector(sideChanged))
    let hint = NSTextField(wrappingLabelWithString: "")
    lazy var scrollSlider = slider(1, 10, scrollSpeed, #selector(scrollChanged))

    func slider(_ min: Double, _ max: Double, _ value: Double, _ action: Selector) -> NSSlider {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        s.numberOfTickMarks = Int(max - min) + 1
        s.allowsTickMarkValuesOnly = true
        s.isContinuous = false  // 손을 뗄 때 한 번 적용
        s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return s
    }

    func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return NSStackView(views: [label, control])
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        status.font = .boldSystemFont(ofSize: 13)
        status.widthAnchor.constraint(equalToConstant: 300).isActive = true
        sideControl.selectedSegment = phoneOnLeft ? 0 : 1
        updateHint()
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        addressField.placeholderString = "비우면 자동으로 찾기 (IP:포트)"
        codeField.placeholderString = "6자리 (처음 한 번)"
        for f in [addressField, codeField] { f.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        let wirelessHint = NSTextField(wrappingLabelWithString:
            "무선: 폰 개발자 옵션 → 무선 디버깅 켜기 → '페어링 코드로 기기 페어링'의 코드를 넣고 [페어링] → [무선 연결]. " +
            "또는 USB로 꽂은 채 [무선 준비 (5555)]를 누르면 케이블을 뽑아도 됩니다 (폰을 재부팅하면 다시 필요).\n" +
            "블루투스: [무선 준비 (5555)]를 한 번 한 뒤, 폰에서 블루투스 테더링을 켜고 맥 블루투스 설정에서 폰을 네트워크로 연결 → [블루투스 연결]. Wi-Fi보다 느립니다.")
        wirelessHint.textColor = .secondaryLabelColor
        wirelessHint.font = .systemFont(ofSize: 11)
        wirelessHint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let stack = NSStackView(views: [
            status,
            NSStackView(views: [connectButton, disconnectButton]),
            row("무선 주소", addressField),
            row("페어링 코드", codeField),
            NSStackView(views: [pairButton, wirelessButton]),
            NSStackView(views: [openPortButton, bluetoothButton]),
            wirelessHint,
            row("커서 속도", cursorSlider),
            row("스크롤 속도", scrollSlider),
            row("폰 위치", sideControl),
            hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        window.title = "droidlink"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !missingTools.isEmpty {
            update("\(missingTools.joined(separator: ", ")) 없음 · ./build-app.sh로 만든 droidlink.app을 쓰세요")
            connectButton.isEnabled = false
            return
        }
        update("연결 안 됨")
        connect()
    }

    var warnedPermission = false
    func warnPermission() {
        guard !warnedPermission else { return }
        warnedPermission = true
        status.stringValue = "손쉬운 사용 권한이 필요합니다 · 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 droidlink를 지웠다가 다시 켜고, 앱을 다시 여세요"
    }

    func update(_ text: String) {
        let connected = server != nil
        status.stringValue = text
        connectButton.isEnabled = !connected && !connecting
        disconnectButton.isEnabled = connected
        cursorSlider.isEnabled = connected
    }

    func updateHint() {
        let (mac, phone) = phoneOnLeft ? ("왼쪽", "오른쪽") : ("오른쪽", "왼쪽")
        hint.stringValue = "맥 화면 \(mac) 끝으로 커서를 밀면 폰으로, 폰 화면 \(phone) 끝으로 밀면 맥으로 돌아옵니다. 막히면 Cmd+Option+Esc."
    }
    @objc func sideChanged() {
        phoneOnLeft = sideControl.selectedSegment == 0
        UserDefaults.standard.set(phoneOnLeft, forKey: "phoneOnLeft")
        updateHint()
    }

    @objc func connectTapped() { connect() }
    @objc func wirelessTapped() { reconnectWireless(addressField.stringValue.trimmingCharacters(in: .whitespaces)) }

    // 안드로이드 11+ 무선 디버깅 페어링. 주소는 폰이 Wi-Fi로 알리는 페어링 주소를 자동으로 찾고, 못 찾으면 입력한 주소를 쓴다.
    @objc func pairTapped() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        let typed = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { status.stringValue = "폰에 표시된 페어링 코드를 입력하세요"; return }
        status.stringValue = "페어링 중…"
        DispatchQueue.global().async {
            let address = mdnsAddress("_adb-tls-pairing", adb(["mdns", "services"])) ?? (typed.isEmpty ? nil : typed)
            let out = address.map { adb(["pair", $0, code]) } ?? ""
            DispatchQueue.main.async {
                if out.contains("Successfully paired") {
                    self.codeField.stringValue = ""
                    if typed == address { self.addressField.stringValue = "" }  // 페어링 포트는 연결 포트와 다르다
                    self.status.stringValue = "페어링 완료 · [무선 연결]을 누르세요"
                } else if address == nil {
                    self.status.stringValue = "폰의 페어링 화면을 못 찾았습니다 · 폰에서 '페어링 코드로 기기 페어링'을 열어 두거나, 그 화면의 IP:포트를 무선 주소에 넣으세요"
                } else {
                    self.status.stringValue = "페어링 실패 · 코드를 확인하세요"
                }
            }
        }
    }

    // 연결된 폰(USB 우선)의 adb를 포트 5555로 열어 둔다. 케이블을 뽑아도 Wi-Fi·블루투스로 연결할 수 있다 (재부팅 전까지).
    // 폰이 Wi-Fi에 있으면 바로 그 주소로 다시 연결한다.
    @objc func openPortTapped() {
        status.stringValue = "무선 준비 중…"
        DispatchQueue.global().async {
            let list = devices()
            guard let device = list.first(where: { !isWireless($0) }) ?? list.first else {
                DispatchQueue.main.async { self.status.stringValue = "USB 케이블로 폰을 먼저 연결하세요" }; return
            }
            let ip = parseWlanIP(adb(["-s", device, "shell", "ip", "-f", "inet", "addr", "show", "wlan0"]))
            _ = adb(["-s", device, "tcpip", "5555"])
            sleep(2)  // 폰의 adb가 다시 시작될 때까지
            DispatchQueue.main.async {
                guard let ip else {
                    self.status.stringValue = "포트 5555 열림 · 케이블을 뽑고 블루투스 테더링을 연결한 뒤 [블루투스 연결]을 누르세요"; return
                }
                self.addressField.stringValue = "\(ip):5555"
                reconnectWireless("\(ip):5555")
            }
        }
    }

    @objc func bluetoothTapped() {
        status.stringValue = "블루투스 네트워크 찾는 중…"
        DispatchQueue.global().async {
            let phone = bluetoothPhoneAddress()
            DispatchQueue.main.async {
                guard let phone else {
                    self.status.stringValue = "블루투스 네트워크가 없습니다 · 폰에서 블루투스 테더링을 켜고, 맥의 블루투스 설정에서 폰을 네트워크로 연결하세요"; return
                }
                reconnectWireless("\(phone):5555")
            }
        }
    }
    @objc func disconnectTapped() { disconnect() }
    @objc func cursorChanged() {
        let speed = Int(cursorSlider.doubleValue.rounded())
        DispatchQueue.global().async { _ = adb(["shell", "settings", "put", "system", "pointer_speed", "\(speed)"]) }
    }
    @objc func scrollChanged() {
        scrollSpeed = scrollSlider.doubleValue.rounded()
        UserDefaults.standard.set(scrollSpeed, forKey: "scrollSpeed")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) {
        if onAndroid { leave() }
        poller?.terminate()
        shells.values.forEach { $0.process.terminate() }
        server?.stop()
    }
}

// MARK: 시작
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("손쉬운 사용 권한이 필요합니다: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 이 앱(또는 터미널)을 켜고 다시 실행하세요.")
}
tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: tapMask,
                        callback: { _, type, event, _ in handleTap(type, event) }, userInfo: nil)
if let tap {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
} else {
    print("입력 가로채기 실패: 손쉬운 사용 권한을 확인하세요.")
}
startMultitouch()

// 터미널에서 Ctrl+C로 끝내도 커서와 연결이 정리되게 한다
let signalSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
    guard onAndroid, abs(scrollAcc) >= 0.05, let pos = androidPos else { return }
    androidShell(String(format: "input mouse scroll %.0f %.0f --axis VSCROLL,%.3f", pos.x, pos.y, scrollAcc), channel: "scroll")
    scrollAcc = 0
}

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    guard ready else { return }
    if !onAndroid {
        // 입력을 가로챌 수 없으면(권한 없음) 폰에서 돌아올 방법이 없으니 넘어가지 않는다
        guard tap != nil, AXIsProcessTrusted() else { ui.warnPermission(); return }
        if atMacEdge(cursor().x) { enter() }
        return
    }
    guard let x = androidPos?.x else { return }
    let d = distanceFromReturnEdge(x, width: androidWidth ?? Double(screenSize?.w ?? 1080))
    if d > armX { armed = true }  // 안쪽으로 한 번 들어간 뒤에만 돌아가는 쪽 끝을 인정한다
    if armed && d <= 1.5 { leave() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = ui
app.run()
