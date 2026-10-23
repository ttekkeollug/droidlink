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

작은 `droidlink` 창이 뜬다. 그 창에 포커스가 있는 동안 맥 키보드·트랙패드 입력이 폰으로 간다.
**왼쪽 Cmd 또는 Option** 키를 누르면 마우스 캡처를 풀고 맥으로 돌아온다. 창을 닫으면 종료.

## 요구사항

- macOS, scrcpy 2.4+
- Android 9+ (UHID), 무선은 Android 11+
