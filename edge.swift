// edge: 맥 화면 오른쪽 끝 ↔ 안드로이드 화면 왼쪽 끝으로 커서·키보드를 넘긴다.
// 사용: edge <scrcpy pid>   (ANDROID_SERIAL로 기기 지정 가능)
import AppKit

let edgeMargin = 1.0      // 맥 오른쪽 끝 판정 여유(px)
let armX = 30.0           // 안드로이드에서 이만큼 오른쪽으로 들어가야 복귀 판정 시작
let returnInset = 40.0    // 맥으로 돌아올 때 오른쪽 끝에서 띄울 거리

// 폴러 출력 한 줄: "<deviceId> <x>"
func parseX(_ line: String) -> Double? { line.split(separator: " ").last.flatMap { Double($0) } }
assert(parseX("16 257.995") == 257.995)

guard CommandLine.arguments.count == 2, let pid = pid_t(CommandLine.arguments[1]),
      let scrcpy = NSRunningApplication(processIdentifier: pid) else {
    print("사용법: edge <scrcpy pid>"); exit(1)
}

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

Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    if scrcpy.isTerminated { poller?.terminate(); exit(0) }
    if !onAndroid {
        if cursor().x >= rightEdge() - edgeMargin { enter() }
        return
    }
    // 사용자가 Cmd/Option으로 직접 빠져나온 경우
    if !scrcpy.isActive && Date().timeIntervalSince(enteredAt) > 1 { leave(activatePrevious: false); return }
    guard let x = androidX else { return }
    if x > armX { armed = true }
    if armed && x <= 0.5 { leave(activatePrevious: true) }
}
print("droidlink: 맥 화면 오른쪽 끝으로 커서를 밀면 폰으로, 폰 화면 왼쪽 끝으로 밀면 맥으로 돌아옵니다.")
RunLoop.main.run()
