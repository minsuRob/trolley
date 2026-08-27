#!/bin/bash
#
# 패키징 없이 지금 트리를 앱으로 띄운다. `swift build` → 껍데기 번들 → open.
#
# 왜 스크립트가 필요한가: `swift run trolley` 로는 창이 절대 안 뜬다. `WelcomeFlow`
# 는 "이 번들의 identifier 로 launchd 가 띄웠을 것"을 조건으로 잡고 있고 -- 터미널이
# 자기 `__CFBundleIdentifier` 를 모든 셸에 물려주기 때문에 느슨하게 두면 `trolley` 만
# 쳐도 창이 열린다 -- 맨 바이너리에는 identifier 가 아예 없다. 그래서 Info.plist 를
# 씌운 번들이 최소 단위다.
#
# build-installer.sh 와 겹치지 않는다. 저쪽은 배포용이라 유니버설 빌드, 임시 키체인,
# Developer ID 서명, 공증 왕복 두 번, dmg 까지 간다. 여기서 필요한 건 그중 어느
# 것도 아니다: 로컬에서 방금 만든 앱은 Gatekeeper 를 거치지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
KILL_RUNNING=0
SIGNED=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        # 설치본과 identifier 가 같으므로 나란히 뜬다. 메뉴 막대 아이콘 두 개와 폴더
        # 두 개를 헷갈리지 않으려면 이쪽.
        --replace) KILL_RUNNING=1 ;;
        # 권한이 걸린 것을 확인할 때. 아래 do_signed 참고.
        --signed) SIGNED=1 ;;
        *) echo "error: 모르는 옵션 $arg" >&2; exit 1 ;;
    esac
done

# 권한 팝업이 매번 새로 뜨는 이유, 그리고 이 경로가 있는 이유.
#
# swift build 는 애드혹으로 서명한다(TeamIdentifier 없음). 손쉬운 사용·화면 기록·데스크탑
# 접근은 전부 서명에 묶이고 애드혹 서명의 cdhash 는 빌드마다 바뀌므로, macOS 는 매번
# 처음 보는 앱으로 취급한다 -- 허락은 저장돼도 다음 빌드가 그것을 물려받지 못한다.
# 게다가 trolley 는 .accessory 라 그 동의 창이 앞으로 나오지 않을 때가 있고, 그러면
# 폴더를 여는 open() 이 아무 말 없이 막힌 채로 남는다(실측: 위키 순회 스레드 3개가
# 그 상태로 멈춰 있었다).
#
# Developer ID 로 서명하면 사라진다. 허락이 (번들 id + 팀 id) 에 묶이는데 그 둘이
# 설치본과 같으므로, 이미 허락해 둔 것을 그대로 물려받고 다시 빌드해도 유지된다.
# 대신 유니버설 릴리스 빌드와 SSM 서명 자산이 필요해서 몇 분 걸린다 -- 권한이 걸린
# 것을 볼 때만 쓰고, 나머지는 기본 경로가 빠르다.
do_signed() {
    echo "==> 서명 빌드 (공증 생략)"
    ./Scripts/build-installer.sh --skip-notarize
    # 조립 디렉터리(dist/dmgroot)는 build-installer 가 끝나면서 지운다. 서명된 번들이
    # 남는 곳은 zip 안이다 -- `trolley update` 가 받아가는 바로 그 자산.
    #
    # unzip 이 아니라 ditto: 확장 속성과 서명을 그대로 옮기는 쪽이고, unzip 으로 푼
    # 번들은 서명 검증에서 떨어질 수 있다.
    SIGNED_DIR=.build/signed
    rm -rf "$SIGNED_DIR"
    mkdir -p "$SIGNED_DIR"
    ditto -xk dist/trolley-app.zip "$SIGNED_DIR"
    APP="$SIGNED_DIR/trolley.app"
    [ -d "$APP" ] || { echo "error: $APP 가 없습니다." >&2; exit 1; }
    codesign --verify --strict "$APP" || { echo "error: 서명 검증 실패" >&2; exit 1; }
    if [ "$KILL_RUNNING" = "1" ]; then
        pkill -x trolley || true
        while pgrep -x trolley >/dev/null; do sleep 0.2; done
    fi
    echo "==> 실행: $APP (서명 · 설치본과 같은 권한)"
    # /Applications 는 건드리지 않는다. 서명이 같으므로 여기서 떠도 허락은 그대로다.
    open -n "$APP"
    exit 0
}
[ "$SIGNED" = "1" ] && do_signed

VERSION=$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' Sources/TrolleyKit/Version.swift)
COMMIT="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    COMMIT="$COMMIT-dirty"
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BINARY=$(swift build -c "$CONFIG" --show-bin-path)/trolley

APP=.build/dev/trolley.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
install -m 755 "$BINARY" "$APP/Contents/MacOS/trolley"
# 설치본과 같은 identifier 를 일부러 쓴다. UserDefaults 도메인이 여기서 갈리기
# 때문이다: 다른 값을 넣으면 미리보기가 읽는 설정이 실제 앱의 설정이 아니라 빈
# 도메인이 되고, 그러면 지금 화면이 무엇을 보여주는지 알 수 없다. 대신 창 제목의
# 커밋이 `dev-` 로 시작하니 어느 쪽을 보고 있는지는 제목만 봐도 안다.
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$COMMIT/g" \
    Scripts/app/Info.plist > "$APP/Contents/Info.plist"
# 아이콘은 굽지 않는다. 앱이 `.accessory` 라 Dock 에 뜨지 않고, 화면의 폴더는 위젯이
# 코드로 그린다 -- 번들의 .icns 는 이 미리보기에서 아무 데도 쓰이지 않는다.

if [ "$KILL_RUNNING" = "1" ]; then
    echo "==> 이미 떠 있는 trolley 종료"
    pkill -x trolley || true
    # 종료가 끝나기 전에 open 하면 LaunchServices 가 죽어가는 인스턴스를 살려낸다.
    while pgrep -x trolley >/dev/null; do sleep 0.2; done
fi

echo "==> 실행: $APP ($VERSION $COMMIT)"
# -n 이 없으면 identifier 가 같은 설치본이 떠 있을 때 그놈을 앞으로 부르고 끝난다.
open -n "$APP"
echo "    끄기: 메뉴 막대 trolley 아이콘 → 종료, 또는 pkill -x trolley"
