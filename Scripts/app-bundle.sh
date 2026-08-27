#!/bin/bash
#
# 소스 전용. 이 맥의 아키텍처만 릴리스로 빌드하고, Developer ID로 서명된 앱 번들을
# 호출자가 지정한 경로에 조립한다. dev-dmg.sh 와 dev-run.sh 기본 경로가 나란히 쓴다 --
# 세 번째 복사를 만들지 않으려고 여기로 뽑았다.
source "$(dirname "${BASH_SOURCE[0]}")/signing-keychain.sh"

# VERSION / COMMIT 을 설정한다.
trolley_stamp_version() {
    VERSION=$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' Sources/TrolleyKit/Version.swift)
    if [ -z "$VERSION" ]; then
        echo "error: Sources/TrolleyKit/Version.swift에서 버전을 읽지 못했습니다." >&2
        exit 1
    fi
    COMMIT="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        COMMIT="$COMMIT-dirty"
    fi
}

# 이 맥의 아키텍처만 릴리스로 빌드하고 BINARY 를 설정한다. 유니버설(arm64+x86_64)이
# 아닌 이유: 로컬에서 쓸 것이라 이 맥에서 도는 한 종류면 충분하고, 그만큼 훨씬 빠르다.
trolley_build_native_release() {
    echo "==> 빌드 ($(uname -m))"
    swift build -c release
    BINARY=$(swift build -c release --show-bin-path)/trolley
    [ -f "$BINARY" ] || { echo "error: $BINARY 가 없습니다." >&2; exit 1; }
}

# VERSION/COMMIT/BINARY 가 설정돼 있고 trolley_keychain_create_dev 로 서명 키체인이
# 이미 활성화돼 있다고 가정한다. $1 = 번들을 조립할 경로.
trolley_assemble_signed_bundle() {
    local app="$1"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    install -m 755 "$BINARY" "$app/Contents/MacOS/trolley"
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$COMMIT/g" \
        Scripts/app/Info.plist > "$app/Contents/Info.plist"

    # iconutil 은 소스 디렉터리 이름이 .iconset 으로 끝나지 않으면 "Invalid Iconset"
    # 으로 거부한다 -- mktemp -d 가 주는 이름은 그렇지 않으므로 지어서 옮긴다.
    local tmp iconset
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/trolley-iconset-XXXXXX")
    iconset="$tmp.iconset"
    mv "$tmp" "$iconset"
    "$BINARY" export-icon --output "$iconset" >/dev/null
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/trolley.icns"
    rm -rf "$iconset"

    echo "==> 서명: $TROLLEY_SIGN_ID"
    codesign --force --options runtime --timestamp \
        --keychain "$TROLLEY_KEYCHAIN" --sign "$TROLLEY_SIGN_ID" "$app"
    codesign --verify --deep --strict --verbose=2 "$app"
}
