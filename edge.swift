// edge: 맥 화면 오른쪽 끝 ↔ 안드로이드 화면 왼쪽 끝으로 커서·키보드를 넘긴다.
// 사용: edge <scrcpy pid>   (ANDROID_SERIAL로 기기 지정 가능)
import AppKit

let edgeMargin = 1.0      // 맥 오른쪽 끝 판정 여유(px)
let armX = 30.0           // 안드로이드에서 이만큼 오른쪽으로 들어가야 복귀 판정 시작
let returnInset = 40.0    // 맥으로 돌아올 때 오른쪽 끝에서 띄울 거리

// 폴러 출력 한 줄: "<deviceId> <x>"
func parseX(_ line: String) -> Double? { line.split(separator: " ").last.flatMap { Double($0) } }
assert(parseX("16 257.995") == 257.995)

// guard let은 최상위 코드의 지역값이 되어 C 콜백에서 못 쓰므로 전역 상수로 둔다.
let pid = CommandLine.arguments.count == 2 ? pid_t(CommandLine.arguments[1]) ?? 0 : 0
let scrcpy: NSRunningApplication! = NSRunningApplication(processIdentifier: pid)
if scrcpy == nil { print("사용법: edge <scrcpy pid>"); exit(1) }

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    print("손쉬운 사용 권한이 필요합니다: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 이 터미널을 켜고 다시 실행하세요.")
}

var onAndroid = false, armed = false, androidX: Double?
var previousApp: NSRunningApplication?, enterY = 0.0, poller: Process?, enteredAt = Date()

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

// scrcpy를 재시작하면 이전 가상 마우스 기록이 남으므로 가장 최근(가장 큰 DeviceId) 것을 쓴다.
// ponytail: dumpsys를 0.1초마다 폴링. 폰 CPU가 아깝다면 안드로이드 쪽 접근성 서비스로 교체.
func startPoller() {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["adb", "shell", "while :; do dumpsys input 2>/dev/null | sed -n 's/.*DeviceId(\\([0-9]*\\)).*MOUSE) at (\\([0-9.]*\\).*/\\1 \\2/p' | sort -n | tail -n1; sleep 0.1; done"]
    p.standardOutput = pipe
    pipe.fileHandleForReading.readabilityHandler = { h in
        let text = String(decoding: h.availableData, as: UTF8.self)
        if let x = text.split(separator: "\n").compactMap({ parseX(String($0)) }).last {
            DispatchQueue.main.async { androidX = x }
        }
    }
    try? p.run()
    poller = p
}

func enter() {
    guard let center = scrcpyWindowCenter() else { return }
    if let front = NSWorkspace.shared.frontmostApplication, front != scrcpy { previousApp = front }
    enterY = cursor().y
    onAndroid = true; armed = false; androidX = nil; enteredAt = Date()
    scrcpy.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { click(at: center) }  // 클릭하면 scrcpy가 마우스를 잡는다
    startPoller()
    print("→ 폰 (이전 앱: \(previousApp?.localizedName ?? "-"))")
}

func leave(activatePrevious: Bool) {
    print(activatePrevious ? "→ 맥 (폰 왼쪽 끝)" : "→ 맥 (scrcpy 포커스 잃음)")
    onAndroid = false
    poller?.terminate(); poller = nil
    if activatePrevious {
        (previousApp ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)?.activate()
    }  // 포커스를 잃으면 scrcpy가 마우스를 놓는다
    CGWarpMouseCursorPosition(CGPoint(x: rightEdge() - returnInset, y: enterY))
}

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
let tapMask = ([CGEventType.keyDown, .keyUp, .flagsChanged].map { $0.rawValue } + gestureTypes)
    .reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }
func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard onAndroid else { return Unmanaged.passUnretained(event) }
    if gestureTypes.contains(type.rawValue) { return nil }
    guard let e = event.copy() else { return nil }
    e.flags = CGEventFlags(rawValue: swapCmdCtrl(event.flags.rawValue))
    if let k = swapKeycodes[e.getIntegerValueField(.keyboardEventKeycode)] { e.setIntegerValueField(.keyboardEventKeycode, value: k) }
    e.postToPid(pid)
    return nil
}
tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: tapMask,
                        callback: { _, type, event, _ in handleTap(type, event) }, userInfo: nil)
if let tap {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
} else {
    print("키보드 가로채기 실패: 손쉬운 사용 권한을 확인하세요. (단축키가 맥에서도 실행됩니다)")
}

// MARK: 트랙패드 제스처 — 손가락 3개 이상 스와이프를 안드로이드 키로 바꾼다.
// 맥과 같은 느낌: 오른쪽 = 뒤로, 왼쪽 = 앞으로, 위 = 최근 앱(Mission Control), 아래 = 홈.
let swipeDistance = 0.12  // 트랙패드 폭 대비 이동 비율. 너무 민감/둔하면 조절
signal(SIGPIPE, SIG_IGN)
var keyShell: FileHandle?
func androidKey(_ code: Int, _ name: String) {
    if keyShell == nil {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["adb", "shell"]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        keyShell = pipe.fileHandleForWriting
    }
    keyShell?.write(Data("input keyevent \(code)\n".utf8))
    print("  제스처: \(name)")
}

var swipeStart: (x: Double, y: Double)?, swipeFired = false
func handleTouches(_ n: Int, _ x: Double, _ y: Double) {
    guard onAndroid, n >= 3 else { if n == 0 { swipeStart = nil }; return }
    guard let s = swipeStart else { swipeStart = (x, y); swipeFired = false; return }
    let dx = x - s.x, dy = y - s.y
    guard !swipeFired, max(abs(dx), abs(dy)) > swipeDistance else { return }
    swipeFired = true
    if abs(dx) > abs(dy) {
        dx > 0 ? androidKey(4, "뒤로") : androidKey(125, "앞으로")
    } else {
        dy > 0 ? androidKey(187, "최근 앱") : androidKey(3, "홈")
    }
}

// 비공개 MultitouchSupport 프레임워크로 손가락 좌표를 읽는다 (BetterTouchTool 등이 쓰는 방식).
// 손가락 구조체는 96바이트, 정규화 좌표 x,y는 32/36 바이트 위치의 Float (y는 위로 갈수록 커짐).
typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
func mtSym<T>(_ name: String, _: T.Type) -> T? { dlsym(mt, name).map { unsafeBitCast($0, to: T.self) } }
if let createList = mtSym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>).self),
   let register = mtSym("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void).self),
   let start = mtSym("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self) {
    let devices = createList().takeRetainedValue()
    for i in 0..<CFArrayGetCount(devices) {
        let dev = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(devices, i)!)
        register(dev) { _, touches, n, _, _ in onTouchFrame(touches, n) }
        start(dev, 0)
    }
} else {
    print("트랙패드 제스처를 읽을 수 없습니다 (MultitouchSupport 없음).")
}
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

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    if scrcpy.isTerminated { poller?.terminate(); exit(0) }
    if !onAndroid {
        if cursor().x >= rightEdge() - edgeMargin { enter() }
        return
    }
    // 다른 이유로 scrcpy 창이 포커스를 잃은 경우
    if !scrcpy.isActive && Date().timeIntervalSince(enteredAt) > 1 { leave(activatePrevious: false); return }
    guard let x = androidX else { return }
    if x > armX { armed = true }
    if armed && x <= 0.5 { leave(activatePrevious: true) }
}
print("droidlink: 맥 화면 오른쪽 끝으로 커서를 밀면 폰으로, 폰 화면 왼쪽 끝으로 밀면 맥으로 돌아옵니다.")
RunLoop.main.run()
