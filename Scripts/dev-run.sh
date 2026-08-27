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
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        # 설치본과 identifier 가 같으므로 나란히 뜬다. 메뉴 막대 아이콘 두 개와 폴더
        # 두 개를 헷갈리지 않으려면 이쪽.
        --replace) KILL_RUNNING=1 ;;
        *) echo "error: 모르는 옵션 $arg" >&2; exit 1 ;;
    esac
done

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
