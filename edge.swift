// edge: droidlink 본체. scrcpy를 띄우고 끄는 창(USB·Wi-Fi·블루투스 연결, 커서·스크롤 속도)을 보여 주고,
// 맥 화면 오른쪽 끝 ↔ 안드로이드 화면 왼쪽 끝으로 커서·키보드·트랙패드를 넘긴다.
// 사용: edge [--mirror]   (ANDROID_SERIAL로 기기 지정 가능). droidlink.app으로 묶으면 Finder에서 바로 실행된다.
import AppKit

let edgeMargin = 1.0      // 맥 오른쪽 끝 판정 여유(px)
let armX = 30.0           // 안드로이드에서 이만큼 오른쪽으로 들어가야 복귀 판정 시작
let returnInset = 40.0    // 맥으로 돌아올 때 오른쪽 끝에서 띄울 거리
let mirror = CommandLine.arguments.contains("--mirror")
let launchSerial = ProcessInfo.processInfo.environment["ANDROID_SERIAL"].flatMap { $0.isEmpty ? nil : $0 }  // droidlink IP:PORT로 지정한 기기
let env = URL(fileURLWithPath: "/usr/bin/env")
signal(SIGPIPE, SIG_IGN)
// Finder에서 실행한 앱은 PATH에 Homebrew가 없어서 adb/scrcpy를 못 찾는다
setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"), 1)

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
let missingTools = ["adb", "scrcpy"].filter { run(["which", $0]).isEmpty }

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

// MARK: 연결 상태 (C 콜백에서도 읽으므로 전역 변수)
var scrcpyProcess: Process?, scrcpy: NSRunningApplication?, pid: pid_t = 0
var deviceName = "", screenSize: (w: Int, h: Int)?  // ponytail: 화면 크기는 연결할 때 한 번만 읽는다. 폰을 돌리면 슬라이드 위치가 어긋남
var onAndroid = false, armed = false, androidPos: (x: Double, y: Double)?
var previousApp: NSRunningApplication?, enterY = 0.0, poller: Process?, enteredAt = Date()
let ui = UI()

func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
func rightEdge() -> Double { NSScreen.screens.map { $0.frame.maxX }.max() ?? 0 }

func scrcpyWindowCenter() -> CGPoint? {
    let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
        if let b = w[kCGWindowBounds as String] as CFTypeRef?,
           let rect = CGRect(dictionaryRepresentation: b as! CFDictionary) {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
    }
    return nil
}

func click(at p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

// 폰 커서 위치는 dumpsys input의 hover 상태에서 읽는다.
// scrcpy를 재시작하면 이전 가상 마우스 기록이 남으므로 가장 최근(가장 큰 DeviceId) 것을 쓴다.
// ponytail: dumpsys를 0.1초마다 폴링. 폰 CPU가 아깝다면 안드로이드 쪽 접근성 서비스로 교체.
func startPoller() {
    let p = Process(), pipe = Pipe()
    p.executableURL = env
    p.arguments = ["adb", "shell", "while :; do dumpsys input 2>/dev/null | sed -n 's/.*DeviceId(\\([0-9]*\\)).*MOUSE) at (\\([0-9.]*\\), \\([0-9.]*\\)).*/\\1 \\2 \\3/p' | sort -n | tail -n1; sleep 0.1; done"]
    p.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { h in
        let text = String(decoding: h.availableData, as: UTF8.self)
        if let pos = text.split(separator: "\n").compactMap({ parsePos(String($0)) }).last {
            DispatchQueue.main.async { androidPos = pos }
        }
    }
    try? p.run()
    poller = p
}

func enter() {
    guard let scrcpy, let center = scrcpyWindowCenter() else { return }
    if let front = NSWorkspace.shared.frontmostApplication, front != scrcpy { previousApp = front }
    enterY = cursor().y
    onAndroid = true; armed = false; androidPos = nil; enteredAt = Date(); scrollAcc = 0
    scrcpy.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { click(at: center) }  // 클릭하면 scrcpy가 마우스를 잡는다
    startPoller()
    print("→ 폰 (이전 앱: \(previousApp?.localizedName ?? "-"))")
}

func leave(activatePrevious: Bool) {
    print(activatePrevious ? "→ 맥 (폰 왼쪽 끝)" : "→ 맥 (scrcpy 포커스 잃음)")
    onAndroid = false
    poller?.terminate(); poller = nil
    if activatePrevious {  // 포커스를 잃으면 scrcpy가 마우스를 놓는다
        // macOS는 활성 앱만 다른 앱에 포커스를 넘길 수 있어서, 먼저 이 앱을 활성화한 뒤 이전 앱으로 넘긴다
        NSApp.activate(ignoringOtherApps: true)
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
    }
    CGWarpMouseCursorPosition(CGPoint(x: rightEdge() - returnInset, y: enterY))
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
var connecting = false, pendingWireless: String?, retried = false
func connect(wireless: String? = nil) {
    guard scrcpyProcess == nil, !connecting else { return }
    connecting = true
    ui.update(wireless == nil ? "연결 중…" : "무선 연결 중…")
    DispatchQueue.global().async {
        let picked = pickDevice(wireless: wireless)
        DispatchQueue.main.async {
            connecting = false
            if let picked { launchScrcpy(picked) } else {
                ui.update(wireless == nil ? "연결 실패 · USB 케이블을 꽂거나, 폰에서 무선 디버깅을 켜고 '무선 연결'을 누르세요"
                                          : "무선 연결 실패 · Wi-Fi: 무선 디버깅이 켜져 있고 같은 Wi-Fi인지, 처음이면 페어링 먼저 · 블루투스: [무선 준비 (5555)]를 먼저")
            }
        }
    }
}

func launchScrcpy(_ device: String) {
    serial = device
    setenv("ANDROID_SERIAL", device, 1)
    var args = ["scrcpy", "--serial", device, "--keyboard=uhid", "--mouse=uhid", "--stay-awake", "--always-on-top",
                "--shortcut-mod=rsuper", "--window-title=droidlink 입력"]
    if !mirror { args += ["--no-video", "--no-audio", "--window-width=240", "--window-height=80"] }
    let p = Process()
    p.executableURL = env
    p.arguments = args
    p.terminationHandler = { _ in DispatchQueue.main.async { disconnected() } }
    guard (try? p.run()) != nil else { ui.update("scrcpy를 실행할 수 없습니다"); return }
    scrcpyProcess = p; pid = p.processIdentifier
    ui.update("연결 중… (\(isWireless(device) ? "Wi-Fi" : "USB"))")
    DispatchQueue.global().async {
        let name = adb(["shell", "getprop", "ro.product.model"])
        let size = parseSize(adb(["shell", "wm", "size"]))
        let speed = Double(adb(["shell", "settings", "get", "system", "pointer_speed"]))
        DispatchQueue.main.async {
            deviceName = name; screenSize = size
            if let speed { ui.cursorSlider.doubleValue = speed }
        }
    }
}

// 이미 연결돼 있으면 끊고 나서 무선으로 다시 연결
func reconnectWireless(_ address: String) {
    if scrcpyProcess != nil { pendingWireless = address; disconnect() } else { connect(wireless: address) }
}

// 이 앱이 띄운 scrcpy는 SIGTERM/SIGINT를 무시해서, 맥 앱 종료 요청으로 끄고 안 되면 강제 종료한다.
func disconnect() {
    guard let p = scrcpyProcess else { return }
    retried = true  // 직접 끊은 것이니 다시 시도하지 않는다
    if let app = scrcpy ?? NSRunningApplication(processIdentifier: p.processIdentifier), app.terminate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
    } else {
        kill(p.processIdentifier, SIGKILL)
    }
}

func disconnected() {
    if onAndroid { leave(activatePrevious: true) }
    let wasConnected = scrcpy != nil
    scrcpyProcess = nil; scrcpy = nil; pid = 0
    shells.values.forEach { $0.process.terminate() }; shells = [:]
    if let next = pendingWireless { pendingWireless = nil; connect(wireless: next); return }
    // 직전 연결의 정리가 폰에서 덜 끝나 바로 실패하는 경우가 있어 한 번만 다시 시도한다
    if !wasConnected && !retried {
        retried = true
        ui.update("다시 연결 중…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { launchScrcpy(serial) }
        return
    }
    retried = false
    ui.update(wasConnected ? "연결 안 됨" : "연결 실패 · 폰에서 USB/무선 디버깅 허용을 확인하세요")
}

// MARK: 스크롤 — scrcpy 2.7의 가상 휠은 트랙패드 스크롤을 제대로 못 옮긴다
// (작은 스크롤은 0칸, 스크롤 이벤트 하나가 휠 20칸이 되기도 함). 그래서 맥 스크롤 이벤트는 버리고
// 이동량을 모아 30ms마다 폰의 `input mouse scroll`(소수 단위 가능, 약 20ms)로 커서 위치에 보낸다.
var scrollAcc = 0.0

// MARK: 키보드 — 폰에 있을 때는 모든 키를 scrcpy에만 보내서 맥 단축키(Cmd+Tab, Cmd+Space…)가 맥에서 실행되지 않게 한다.
// 맥 습관 그대로 쓰도록 Cmd ↔ Ctrl을 바꿔 보낸다: Cmd+C → 안드로이드 Ctrl+C.
let swapKeycodes: [Int64: Int64] = [55: 59, 59: 55, 54: 62, 62: 54]  // 왼쪽/오른쪽 Cmd ↔ Ctrl
func swapCmdCtrl(_ raw: UInt64) -> UInt64 {
    let pairs: [(UInt64, UInt64)] = [(0x100000, 0x40000), (0x8, 0x1), (0x10, 0x2000)]  // Cmd↔Ctrl 플래그, 왼쪽, 오른쪽
    var r = raw
    for (a, b) in pairs {
        r &= ~(a | b)
        if raw & a != 0 { r |= b }
        if raw & b != 0 { r |= a }
    }
    return r
}
assert(swapCmdCtrl(0x100008) == 0x40001)

// 회전·제스처 시작/끝·제스처·확대(독 스와이프)·스와이프: 폰에 있을 때는 맥이 반응하지 않게 버린다.
let gestureTypes: [UInt32] = [18, 19, 20, 29, 30, 31]
var tap: CFMachPort?
let tapMask = ([CGEventType.keyDown, .keyUp, .flagsChanged, .scrollWheel].map { $0.rawValue } + gestureTypes)
    .reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }
func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard onAndroid else { return Unmanaged.passUnretained(event) }
    if gestureTypes.contains(type.rawValue) { return nil }
    if type == .scrollWheel {
        let v = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let h = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        if abs(v) >= abs(h) { scrollAcc += v / scrollPointsPerStep }  // 가로 위주 움직임은 두 손가락 슬라이드가 맡는다
        return nil
    }
    guard let e = event.copy() else { return nil }
    e.flags = CGEventFlags(rawValue: swapCmdCtrl(event.flags.rawValue))
    if let k = swapKeycodes[e.getIntegerValueField(.keyboardEventKeycode)] { e.setIntegerValueField(.keyboardEventKeycode, value: k) }
    e.postToPid(pid)
    return nil
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

// MARK: 창 — 연결/연결 해제, 무선 연결, 커서 속도, 스크롤 속도
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
        let hint = NSTextField(wrappingLabelWithString: "맥 화면 오른쪽 끝으로 커서를 밀면 폰으로, 폰 화면 왼쪽 끝으로 밀면 맥으로 돌아옵니다.")
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
            update("\(missingTools.joined(separator: ", ")) 없음 · 터미널에서 brew install scrcpy android-platform-tools 를 실행한 뒤 다시 여세요")
            connectButton.isEnabled = false
            return
        }
        update("연결 안 됨")
        connect()
    }

    func update(_ text: String) {
        let connected = scrcpyProcess != nil
        status.stringValue = text
        connectButton.isEnabled = !connected
        disconnectButton.isEnabled = connected
        cursorSlider.isEnabled = connected
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
        poller?.terminate()
        shells.values.forEach { $0.process.terminate() }
        if let p = scrcpyProcess { kill(p.processIdentifier, SIGKILL) }  // 앱이 끝나는 중이라 기다리지 않는다
    }
}

// MARK: 시작
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("손쉬운 사용 권한이 필요합니다: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 이 터미널을 켜고 다시 실행하세요.")
}
tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: tapMask,
                        callback: { _, type, event, _ in handleTap(type, event) }, userInfo: nil)
if let tap {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
} else {
    print("키보드 가로채기 실패: 손쉬운 사용 권한을 확인하세요. (단축키가 맥에서도 실행됩니다)")
}
startMultitouch()

// 터미널에서 Ctrl+C로 끝내도 scrcpy까지 정리되게 한다
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
    // scrcpy 창이 뜨면 연결 완료
    if scrcpy == nil, pid != 0, scrcpyWindowCenter() != nil {
        scrcpy = NSRunningApplication(processIdentifier: pid)
        ui.update("연결됨 · \(deviceName.isEmpty ? "안드로이드" : deviceName) · \(isWireless(serial) ? "Wi-Fi" : "USB")")
    }
    guard let scrcpy else { return }
    if !onAndroid {
        if cursor().x >= rightEdge() - edgeMargin { enter() }
        return
    }
    // 다른 이유로 scrcpy 창이 포커스를 잃은 경우
    if !scrcpy.isActive && Date().timeIntervalSince(enteredAt) > 1 { leave(activatePrevious: false); return }
    guard let x = androidPos?.x else { return }
    // 들어올 때 scrcpy 창으로 커서를 옮기며 생기는 큰 왼쪽 이동이 폰 커서를 왼쪽 끝으로 보낸다.
    // 그 직후의 위치로 판정하면 바로 돌아오므로, 들어온 뒤 잠시 지나서 오른쪽으로 들어간 것만 인정한다.
    if x > armX && Date().timeIntervalSince(enteredAt) > 0.6 { armed = true }
    if armed && x <= 0.5 { leave(activatePrevious: true) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = ui
app.run()
