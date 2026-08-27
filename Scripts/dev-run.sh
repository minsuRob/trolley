#!/bin/bash
#
# 기본값: 빌드해서 Developer ID로 서명하고, 그 자리에서 /Applications/trolley.app
# 을 바꿔치기한 뒤 다시 연다 -- 사람이 지금 쓰는 설치본을 그대로 덮어쓴다. 의도한
# 것이다: 애드혹 서명(옛 기본 경로)은 빌드마다 cdhash 가 바뀌어 손쉬운 사용·화면
# 기록 허락을 매번 다시 묻는데, 설치본 자리에서 Developer ID로 서명해 두면 허락이
# (경로 + 팀 id)에 묶여 그대로 유지된다. 위키 대화나 LLM 생성이 진행 중이어도
# 상관없이 교체한다 -- 그 트레이드오프는 CLAUDE.md 에 적어 뒀다.
#
# 설치본은 안 건드리고 잠깐 보기만 하고 싶으면 --preview (오늘까지의 기본 동작을
# 그대로 유지: 애드혹 서명, .build/dev 에서 open -n, /Applications 는 안 건드림).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--preview" ]; then
    shift

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
    exit 0
fi

# ---- 기본 경로: 서명해서 /Applications 에 설치하고 재실행 ----
source Scripts/app-bundle.sh

TARGET=/Applications/trolley.app
# target 과 같은 디렉터리에 짓는다: 뒤이은 install-local 의 원자적 스왑(renamex_np)
# 은 같은 파일시스템을 요구하는데, dist/나 .build/는 체크아웃이 다른 볼륨에 있으면
# 그 전제가 깨진다. UpdateInstaller.stage() 가 쓰는 것과 같은 네이밍 관례.
STAGING=/Applications/.trolley.app.update

trap trolley_keychain_destroy EXIT

trolley_stamp_version
echo "==> trolley $VERSION ($COMMIT) -- /Applications 에 설치"

trolley_build_native_release

echo "==> 서명용 임시 키체인 준비"
trolley_keychain_create_dev

echo "==> 앱 번들 조립"
trolley_assemble_signed_bundle "$STAGING"

echo "==> 설치: $TARGET"
# install-local 이 자기 자신(방금 서명한 이 번들)을 검증하고 target 자리에 원자적으로
# 바꿔친다 -- trolley update 가 쓰는 것과 같은 스왑 경로. 옛 프로세스가 아직 살아
# 있어도 안전하다: renamex_np 는 경로만 바꾸고, 열려 있던 inode는 그대로 유지된다.
"$STAGING/Contents/MacOS/trolley" install-local "$STAGING" "$TARGET"

echo "==> 이미 떠 있는 trolley 종료"
pkill -x trolley || true
# 상한을 둔다: 멈춰서 안 죽는 프로세스가 스크립트를 영원히 붙잡지 않게.
for i in $(seq 1 100); do pgrep -x trolley >/dev/null || break; sleep 0.1; done
if pgrep -x trolley >/dev/null; then
    echo "경고: trolley 가 10초 안에 종료되지 않았습니다. 그래도 새 번들을 엽니다." >&2
fi

echo "==> 실행: $TARGET ($VERSION $COMMIT)"
# -n 이 아니라 -a: 이 시점엔 옛 프로세스가 확실히 죽었으므로, 재활성화될 옛
# 인스턴스가 없다 (TrolleyRelaunch 와 같은 순서 -- 죽기 전에 열면 옛 인스턴스만
# 앞으로 나오고 새 번들은 안 뜬다).
open -a "$TARGET"
echo "    끄기: 메뉴 막대 trolley 아이콘 → 종료, 또는 pkill -x trolley"
