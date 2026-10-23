# droidlink

맥북 키보드와 트랙패드를 안드로이드 폰에 **실제 USB/블루투스 키보드·마우스처럼** 연결해서 쓰는 macOS용 앱.

내부적으로 [scrcpy](https://github.com/Genymobile/scrcpy)의 UHID 모드를 사용한다. 폰 쪽에 따로 앱을 설치할 필요가 없고, 한/영 전환·단축키·마우스 커서가 안드로이드에서 그대로 동작한다.

## 설치

```bash
brew install scrcpy android-platform-tools
git clone https://github.com/ttekkeollug/droidlink && cd droidlink
ln -s "$PWD/droidlink" /usr/local/bin/droidlink
```

폰: **설정 → 휴대전화 정보 → 빌드번호 7번 탭** → 개발자 옵션 → **USB 디버깅** 켜기.

## 사용

```bash
droidlink                          # USB 케이블 연결
droidlink pair 192.168.0.12:41234 123456   # 무선 디버깅 페어링 (최초 1회, Android 11+)
droidlink 192.168.0.12:37123       # 와이파이로 연결
droidlink mirror                   # 화면 미러링도 같이
```

### 화면 끝으로 전환 (듀얼 모니터처럼)

폰이 맥 화면 **오른쪽**에 붙어 있다고 생각하면 된다.

- 맥 커서를 화면 **오른쪽 끝**으로 밀면 → 커서와 키보드가 폰으로 넘어간다.
- 폰 커서를 화면 **왼쪽 끝**으로 밀면 → 커서와 키보드가 맥으로 돌아온다.
- 왼쪽 Cmd/Option 키로도 언제든 맥으로 빠져나올 수 있다.

작은 `droidlink` 창(항상 위)이 입력을 받는 창이다. 창을 닫거나 터미널에서 `Ctrl+C`로 종료.

처음 실행할 때 **손쉬운 사용 권한**을 묻는다: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 터미널 앱을 켠다.

동작 원리: `edge.swift`가 맥 커서 위치를 보고 있다가 오른쪽 끝에 닿으면 scrcpy 창을 클릭해 마우스를 잡게 하고,
폰 커서 위치는 `adb shell dumpsys input`으로 읽어 왼쪽 끝(x=0)에 닿으면 원래 앱으로 포커스를 돌려준다.

## 요구사항

- macOS (Xcode Command Line Tools: `swiftc`), scrcpy 2.4+
- Android 9+ (UHID), 무선은 Android 11+
